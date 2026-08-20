import AppKit
import Foundation
import Observation

/// Drives one dictation end to end: hold the key, speak, release, text appears.
///
/// ```
///  idle ──hotkey down──► recording ──hotkey up──► transcribing
///   ▲                        │                        │
///   │                    cancelled                    ▼
///   │                        │                     cleaning ──fails──┐
///   └──── injecting ◄────────┴────────────────────────┘◄─────────────┘
///                                                   (raw transcript)
/// ```
///
/// The one invariant: **once audio has been transcribed, text reaches the user.**
/// Cleanup failure, a dead network, a rejected API key — all of them degrade to typing
/// the raw transcript, never to losing the dictation.
@MainActor
@Observable
final class DictationCoordinator {

    enum Stage: Equatable {
        case idle
        case recording
        case transcribing
        case cleaning
        case injecting
        case failed(String)

        var isRecording: Bool { self == .recording }
        var isBusy: Bool {
            switch self {
            case .recording, .transcribing, .cleaning, .injecting: true
            case .idle, .failed: false
            }
        }

        var label: String {
            switch self {
            case .idle: "Ready"
            case .recording: "Listening…"
            case .transcribing: "Transcribing…"
            case .cleaning: "Cleaning up…"
            case .injecting: "Typing…"
            case .failed: "Failed"
            }
        }

        /// The reason, when there is one. `label` alone threw the associated message
        /// away, so a failure showed a bare "Failed" with nothing actionable.
        var detail: String? {
            switch self {
            case .failed(let message): message
            default: nil
            }
        }
    }

    /// What one dictation cost, broken down so a slow step is identifiable.
    struct Timing: Sendable {
        let audioDuration: TimeInterval
        let transcribeTime: TimeInterval
        let cleanupTime: TimeInterval
        /// Key release to text typed. The number that decides whether this feels instant.
        let endToEnd: TimeInterval

        var realtimeFactor: Double {
            transcribeTime > 0 ? audioDuration / transcribeTime : 0
        }
    }

    struct Run: Sendable {
        let rawTranscript: String
        let finalText: String
        let usedRawFallback: Bool
        let note: String?
        let targetApp: String?
        let timing: Timing
    }

    private(set) var stage: Stage = .idle {
        didSet {
            guard stage != oldValue else { return }
            onStageChange?(stage)
        }
    }

    /// Lets the HUD react without the coordinator knowing what a window is.
    ///
    /// Only stage *transitions* are pushed. The elapsed counter used to go through here
    /// too, which rebuilt the HUD's hosting view ten times a second; the HUD runs its own
    /// ticker instead.
    var onStageChange: (@MainActor (Stage) -> Void)?

    private(set) var lastRun: Run?
    private(set) var elapsed: TimeInterval = 0
    private(set) var hotkeyActive = false

    let settings: SettingsStore
    let models = ModelManager()

    private let recorder = MicRecorder()
    private let transcriber = TranscriptionService()
    private let cleanup = CleanupService()
    private let hotkey = HotkeyMonitor()
    private var tickTask: Task<Void, Never>?

    /// Captured when recording starts. The HUD is non-activating so this should not
    /// change under us, but the paste needs to land where the user was actually typing.
    private var targetApp: NSRunningApplication?

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        models.select(settings.speechModel)
    }

    // MARK: - Hotkey

    func installHotkey() {
        do {
            hotkey.onPress = { [weak self] in self?.beginDictation() }
            hotkey.onRelease = { [weak self] in
                Task { @MainActor in await self?.endDictation() }
            }
            try hotkey.start(trigger: settings.hotkey)
            hotkeyActive = true
        } catch {
            hotkeyActive = false
            stage = .failed(error.localizedDescription)
        }
    }

    func changeHotkey(to trigger: HotkeyMonitor.Trigger) {
        settings.hotkey = trigger
        guard hotkeyActive else { return }
        installHotkey()
    }

    // MARK: - The loop

    func beginDictation() {
        guard !stage.isBusy else { return }

        // Refuse rather than downloading mid-dictation. Loading is kicked off at launch,
        // so this only fires if that hasn't finished — and holding the key through a
        // ~600 MB download would look like the app had hung.
        if models.models == nil {
            // A fast load deliberately shows no busy state, so check the flag too.
            if models.isPreparing {
                stage = .failed("The speech model is still getting ready.")
                return
            }
            switch models.state {
            case .preparing:
                stage = .failed("The speech model is still getting ready.")
            case .downloading(let fraction):
                stage = .failed("Still downloading the speech model — \(Int(fraction * 100))%.")
            case .loading:
                stage = .failed("The speech model is still loading.")
            case .failed(let message):
                stage = .failed(message)
            case .notLoaded, .ready:
                stage = .failed("The speech model isn't loaded. Open Setup to load it.")
                Task { await warmUp() }
            }
            return
        }

        // Remember where the text has to go before anything else can steal focus.
        targetApp = NSWorkspace.shared.frontmostApplication

        do {
            try recorder.start()
            elapsed = 0
            stage = .recording
            startTicking()
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func cancelDictation() {
        stopTicking()
        recorder.cancel()
        stage = .idle
        elapsed = 0
    }

    func endDictation() async {
        guard stage == .recording else { return }
        stopTicking()
        stage = .transcribing

        let clock = ContinuousClock()
        let releasedAt = clock.now

        do {
            // Stop on the main actor: an off-main AVAudioEngine teardown leaves the
            // input device configured, which pins a Bluetooth headset to mono 16 kHz for
            // the rest of the process. Only the resampling goes off-main.
            let capture = try recorder.finishCapture()
            let samples = try await Task.detached(priority: .userInitiated) {
                try MicRecorder.resample(capture)
            }.value

            try await ensureModelLoaded()

            let transcribeStart = clock.now
            let transcription = try await transcriber.transcribe(samples)
            let transcribeTime = (clock.now - transcribeStart).seconds

            let raw = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                stage = .idle
                return
            }

            // From here on, text reaches the user no matter what fails.
            stage = .cleaning
            let outcome = await cleanup.clean(
                transcript: raw,
                config: settings.providerConfig,
                prompt: PromptLibrary(template: settings.promptTemplate),
                context: PromptLibrary.Context(
                    transcript: raw,
                    customWords: settings.customWords,
                    frontmostApp: targetApp?.bundleIdentifier
                )
            )

            stage = .injecting
            var note = outcome.note
            do {
                try TextInjector.inject(outcome.text)
            } catch {
                // The text is on the clipboard either way — say so rather than
                // pretending the dictation succeeded silently.
                note = [note, error.localizedDescription]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }

            lastRun = Run(
                rawTranscript: raw,
                finalText: outcome.text,
                usedRawFallback: outcome.usedRawFallback,
                note: note?.isEmpty == true ? nil : note,
                targetApp: targetApp?.localizedName,
                timing: Timing(
                    audioDuration: transcription.audioDuration,
                    transcribeTime: transcribeTime,
                    cleanupTime: outcome.latency,
                    endToEnd: (clock.now - releasedAt).seconds
                )
            )
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Model

    private func ensureModelLoaded() async throws {
        if await transcriber.isReady { return }
        if models.models == nil { await models.prepare() }
        guard let loaded = models.models else {
            throw TranscriptionService.ServiceError.modelsNotLoaded
        }
        try await transcriber.load(loaded)
    }

    /// Switches the speech model.
    ///
    /// Two things have to happen together, which is why this exists rather than callers
    /// setting the setting directly:
    ///
    ///  1. `TranscriptionService` holds the *loaded* model. Without unloading it,
    ///     `ensureModelLoaded()` sees `isReady == true` and keeps transcribing with the
    ///     previous model — switching would appear to do nothing until a restart.
    ///  2. A model already on disk should reload immediately instead of showing a
    ///     download prompt for something the user already has.
    func changeSpeechModel(_ model: SpeechModel) {
        guard model != settings.speechModel else { return }
        settings.speechModel = model
        models.select(model)
        Task {
            await transcriber.unload()
            if ModelManager.isDownloaded(model) {
                await warmUp()
            }
        }
    }

    /// Download and load ahead of first use, so the first dictation isn't slow.
    func warmUp() async {
        models.select(settings.speechModel)
        await models.prepare()
        if let loaded = models.models {
            try? await transcriber.load(loaded)
        }
    }

    /// Round-trips the configured provider so "why isn't it working" is one click rather
    /// than a guess.
    func testCleanupProvider() async -> String {
        guard let config = settings.providerConfig else {
            return "Cleanup is off, or no model is set."
        }
        let outcome = await cleanup.clean(
            transcript: "hey so uh this is a test of the cleanup provider",
            config: config,
            prompt: PromptLibrary(template: settings.promptTemplate),
            context: PromptLibrary.Context(transcript: ""),
            timeout: 15
        )
        if outcome.usedRawFallback {
            return outcome.note ?? "Failed for an unknown reason."
        }
        return "Connected in \(String(format: "%.2f", outcome.latency))s → \(outcome.text)"
    }

    // MARK: - Elapsed timer

    private func startTicking() {
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let startedAt = self.recorder.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
