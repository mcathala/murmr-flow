import AppKit
import Foundation
import Observation
import OSLog

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
            case .injecting: "Inserting…"
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

    struct Run: Sendable, Identifiable {
        let id = UUID()
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

    /// True while the microphone test is recording. The *result* lives with the model in
    /// `SpeechModelStore`, so it survives switching models and relaunching.
    private(set) var isTestingSpeechModel = false

    /// What the last test heard back, kept only for the run that produced it.
    private(set) var lastHeard: String?

    /// Which provider is mid-test, if any. The *result* lives with the provider in
    /// `ProviderStore`, so it survives switching away and relaunching.
    private(set) var testingProviderID: String?

    /// Microphone loudness, 0…1, for the waveform.
    private(set) var micLevel: Float = 0

    /// Words as they are recognised, while you are still speaking. Provisional — the
    /// authoritative transcript is the one taken at the end.
    private(set) var preview: String = ""

    let settings: SettingsStore
    let loader: SpeechModelLoader

    private let recorder = MicRecorder()

    /// Optional so the convenience initialiser used by tests need not build one.
    private let devices: AudioDeviceStore?
    /// Shared with meetings mode, so only one copy of the ~600 MB model is resident and
    /// the two never run inference over each other's decoder state.
    private let transcriber: TranscriptionService
    let history: HistoryStore
    let prompts: PromptStore
    let providers: ProviderStore
    let speech: SpeechModelStore
    private let cleanup = CleanupService()
    private let hotkey = HotkeyMonitor()
    private let media = MediaPlaybackController()
    private static let mediaLog = Logger(subsystem: "app.murmr.MurmrFlow", category: "media")
    private var tickTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    /// Started at key-down so pausing never delays the recording; awaited before
    /// resuming so we know whether we were the ones who paused.
    private var mediaPauseTask: Task<Bool, Never>?

    /// Captured when recording starts. The HUD is non-activating so this should not
    /// change under us, but the paste needs to land where the user was actually typing.
    private var targetApp: NSRunningApplication?

    /// True while meetings mode holds the microphone. Dictation stands down rather than
    /// opening a second input stream over the top of an hour-long recording.
    var isSuspended = false

    init(
        settings: SettingsStore = SettingsStore(),
        loader: SpeechModelLoader = SpeechModelLoader(),
        transcriber: TranscriptionService = TranscriptionService(),
        history: HistoryStore = HistoryStore(),
        prompts: PromptStore = PromptStore(),
        providers: ProviderStore = ProviderStore(),
        speech: SpeechModelStore = SpeechModelStore(),
        devices: AudioDeviceStore? = nil
    ) {
        self.settings = settings
        self.loader = loader
        self.transcriber = transcriber
        self.history = history
        self.prompts = prompts
        self.providers = providers
        self.speech = speech
        self.devices = devices
        loader.select(speech.activeModel)
    }

    // MARK: - Hotkey

    func installHotkey() {
        do {
            hotkey.onPress = { [weak self] in
                guard let self else { return }
                if self.settings.holdToTalk {
                    self.beginDictation()
                } else if self.stage.isRecording {
                    // Toggle mode: the same key both starts and stops, so a long
                    // dictation doesn't mean holding a key for two minutes.
                    Task { @MainActor in await self.endDictation() }
                } else {
                    self.beginDictation()
                }
            }
            hotkey.onRelease = { [weak self] in
                guard let self, self.settings.holdToTalk else { return }
                Task { @MainActor in await self.endDictation() }
            }
            try hotkey.start(hotkey: settings.hotkey)
            hotkeyActive = true
        } catch {
            hotkeyActive = false
            stage = .failed(error.localizedDescription)
        }
    }

    func changeHotkey(to newHotkey: Hotkey) {
        settings.hotkey = newHotkey
        guard hotkeyActive else { return }
        installHotkey()
    }

    // MARK: - The loop

    func beginDictation() {
        guard !stage.isBusy else { return }
        guard !isSuspended else {
            stage = .failed("A meeting is being recorded. Stop it first.")
            return
        }

        // Refuse rather than downloading mid-dictation. Loading is kicked off at launch,
        // so this only fires if that hasn't finished — and holding the key through a
        // ~600 MB download would look like the app had hung.
        if loader.models == nil {
            // A fast load deliberately shows no busy state, so check the flag too.
            if loader.isPreparing {
                stage = .failed("The speech model is still getting ready.")
                return
            }
            switch loader.state {
            case .preparing:
                stage = .failed("The speech model is still getting ready.")
            case .downloading(let fraction):
                stage = .failed("Still downloading the speech model — \(Int(fraction * 100))%.")
            case .loading:
                stage = .failed("The speech model is still loading.")
            case .failed(let message):
                stage = .failed(message)
            case .notLoaded, .ready:
                stage = .failed("The speech model isn't loaded. Open Settings › Speech model.")
                Task { await warmUp() }
            }
            return
        }

        // Remember where the text has to go before anything else can steal focus.
        targetApp = NSWorkspace.shared.frontmostApplication

        do {
            recorder.inputDeviceID = devices?.selectedInputDeviceID
            try recorder.start()
            elapsed = 0
            micLevel = 0
            preview = ""
            stage = .recording
            startTicking()
            startPreviewing()

            // Runs alongside recording rather than before it. The adapter reports the
            // media app's own playback state, which our microphone cannot influence, so
            // there is no need to serialise this ahead of opening the mic.
            if settings.pauseMediaWhileDictating {
                mediaPauseTask = Task { [media] in await media.pauseIfPlaying() }
            }
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func cancelDictation() {
        stopTicking()
        stopPreviewing()
        recorder.cancel()
        stage = .idle
        elapsed = 0
        Task { await restoreMedia() }
    }

    func endDictation() async {
        guard stage == .recording else {
            // Not recording, but a pause may still be outstanding from a run that ended
            // some other way. Never leave playback stopped.
            await restoreMedia()
            return
        }
        stopTicking()
        // Before anything awaits: the transcriber is an actor, so an in-flight preview
        // would otherwise sit in front of the transcription that actually matters.
        stopPreviewing()
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
            if raw.isEmpty {
                // Nothing was said. Deliberately *not* an early return: this used to
                // `return` here, which skipped restoring paused music — so holding the
                // key without speaking left playback paused for good.
                stage = .idle
                await restoreMedia()
                return
            }

            // From here on, text reaches the user no matter what fails.
            stage = .cleaning
            let outcome = await cleanup.clean(
                transcript: raw,
                config: settings.cleanupEnabled ? providers.activeConfig : nil,
                prompt: PromptLibrary(template: prompts.dictationPrompt.template),
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

            // On the record. Both texts are kept: the raw one is what makes a later
            // "what did the AI change?" or a re-run against a different prompt possible
            // at all, and until now it was discarded the instant cleanup returned.
            history.add(
                DictationRecord(
                    audioDuration: transcription.audioDuration,
                    rawText: raw,
                    finalText: outcome.text,
                    usedRawFallback: outcome.usedRawFallback,
                    promptName: prompts.dictationPrompt.name,
                    targetAppName: targetApp?.localizedName,
                    targetBundleID: targetApp?.bundleIdentifier
                )
            )
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }

        // Always restore, including on the failure paths above.
        await restoreMedia()
    }

    /// Resumes playback only if we paused it. Anything the user paused stays paused.
    private func restoreMedia() async {
        guard let task = mediaPauseTask else {
            Self.mediaLog.notice("restoreMedia: nothing to restore")
            return
        }
        mediaPauseTask = nil
        await media.resumeIfWePaused(task.value)
    }

    // MARK: - Model

    private func ensureModelLoaded() async throws {
        if await transcriber.isReady { return }
        if loader.models == nil { await loader.prepare() }
        guard let loaded = loader.models else {
            throw TranscriptionService.ServiceError.modelsNotLoaded
        }
        try await transcriber.load(loaded)
    }

    /// Switches the speech model. The only thing that changes which one is used.
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
        guard model != speech.activeModel else { return }
        speech.setActive(model)
        loader.select(model)
        Task {
            await transcriber.unload()
            if SpeechModelLoader.isDownloaded(model) {
                await warmUp()
            }
        }
    }

    /// Download and load ahead of first use, so the first dictation isn't slow.
    func warmUp() async {
        loader.select(speech.activeModel)
        await loader.prepare()
        if let loaded = loader.models {
            try? await transcriber.load(loaded)
        }
    }


    // MARK: - Elapsed timer

    private func startTicking() {
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let startedAt = self.recorder.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                self.micLevel = self.recorder.level
            }
        }
    }

    // MARK: - Re-run

    /// Cleans a past dictation again, with whatever prompt is now selected.
    ///
    /// Only possible because the raw transcript is kept. Before, changing a prompt and
    /// wanting the old text through it meant saying the whole thing again.
    func rerunCleanup(on record: DictationRecord) async {
        guard settings.cleanupEnabled, let config = providers.activeConfig else { return }

        let outcome = await cleanup.clean(
            transcript: record.rawText,
            config: config,
            prompt: PromptLibrary(template: prompts.dictationPrompt.template),
            context: PromptLibrary.Context(
                transcript: record.rawText,
                customWords: settings.customWords
            )
        )

        history.replace(
            DictationRecord(
                id: record.id,
                date: record.date,
                audioDuration: record.audioDuration,
                rawText: record.rawText,
                finalText: outcome.text,
                usedRawFallback: outcome.usedRawFallback,
                promptName: prompts.dictationPrompt.name,
                targetAppName: record.targetAppName,
                targetBundleID: record.targetBundleID
            )
        )
    }

    // MARK: - Provider test

    /// Sends a tiny transcript through the real cleanup path and records the result
    /// against **that** provider.
    ///
    /// Takes an id so a provider can be proved without being made active — setting up a
    /// second endpoint used to mean switching to it first, which took the working one out
    /// of service to try an untested one.
    func testProvider(_ id: String) {
        guard testingProviderID == nil else { return }
        guard let config = providers.config(for: id) else {
            providers.setVerification(.failed("No endpoint or model is set."), for: id)
            return
        }
        testingProviderID = id

        Task { @MainActor in
            defer { testingProviderID = nil }

            let clock = ContinuousClock()
            let started = clock.now
            let probe = "this is a test of the clean up"

            let outcome = await cleanup.clean(
                transcript: probe,
                config: config,
                prompt: PromptLibrary(template: prompts.dictationPrompt.template),
                context: PromptLibrary.Context(transcript: probe)
            )

            // `clean` never throws by design — it falls back to the raw text and says why.
            // So the fallback flag, not an error, is what tells us the provider failed.
            providers.setVerification(
                outcome.usedRawFallback
                    ? .failed(outcome.note ?? "The provider didn't reply.")
                    : .working(latency: (clock.now - started).seconds, at: Date()),
                for: id
            )
        }
    }

    /// Makes a provider the one dictation uses, and proves it while we are here — this is
    /// the moment you care whether it works.
    func activateProvider(_ id: String) {
        providers.activeID = id
        if !providers.state(for: id).verification.isWorking, providers.isUsable(id) {
            testProvider(id)
        }
    }

    // MARK: - Voice test

    /// Records, transcribes, and shows the words back — without inserting anything.
    ///
    /// This exists because "ready" and "working" were never the same claim. The model
    /// reported ready as soon as its files were on disk, which said nothing about whether
    /// inference runs, which microphone is selected, or whether that microphone is muted.
    /// The first time you found out was your first real dictation.
    func toggleSpeechModelTest() {
        if isTestingSpeechModel {
            Task { await finishSpeechModelTest() }
            return
        }

        // Never over the top of a real dictation — they would fight for the microphone.
        guard !stage.isBusy, !isSuspended else {
            speech.setVerification(
                .failed("Something else is using the microphone."), for: speech.activeModel
            )
            return
        }

        do {
            recorder.inputDeviceID = devices?.selectedInputDeviceID
            try recorder.start()
            lastHeard = nil
            isTestingSpeechModel = true
        } catch {
            speech.setVerification(
                .failed(error.localizedDescription), for: speech.activeModel
            )
        }
    }

    private func finishSpeechModelTest() async {
        let model = speech.activeModel
        let clock = ContinuousClock()
        let started = clock.now
        defer { isTestingSpeechModel = false }

        do {
            let capture = try recorder.finishCapture()
            let samples = try await Task.detached(priority: .userInitiated) {
                try MicRecorder.resample(capture)
            }.value

            try await ensureModelLoaded()
            let text = try await transcriber.transcribe(samples).text
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if text.isEmpty {
                // Silence is its own answer, and a more useful one than an empty string:
                // it points at the microphone rather than at the model.
                lastHeard = nil
                speech.setVerification(
                    .failed("Nothing was heard — check the microphone."), for: model
                )
            } else {
                lastHeard = text
                speech.setVerification(
                    .working(latency: (clock.now - started).seconds, at: Date()), for: model
                )
            }
        } catch MicRecorder.RecorderError.nothingRecorded {
            lastHeard = nil
            speech.setVerification(
                .failed("Nothing was recorded — check the microphone."), for: model
            )
        } catch {
            lastHeard = nil
            speech.setVerification(.failed(error.localizedDescription), for: model)
        }
    }

    // MARK: - Live preview

    /// Re-transcribes what has been captured so far, every so often, while recording.
    ///
    /// Deliberately *not* the library's streaming engine: that would mean a second model
    /// bundle to download and hold in memory. Re-running the ordinary transcription over
    /// the audio so far costs nothing new and is imperceptible at dictation length — a
    /// few passes over a few seconds each.
    ///
    /// It does not scale, and that is fine. Each pass starts from the beginning, so the
    /// work grows with the square of the recording; past `previewCutoff` the preview
    /// simply stops updating rather than getting slower and slower.
    private func startPreviewing() {
        previewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.previewInterval)
                guard let self, self.stage.isRecording else { return }
                guard self.elapsed < Self.previewCutoff else { return }
                guard let capture = self.recorder.snapshot() else { continue }
                guard await self.transcriber.isReady else { continue }

                do {
                    let samples = try await Task.detached(priority: .utility) {
                        try MicRecorder.resample(capture)
                    }.value
                    let text = try await self.transcriber.transcribe(samples).text
                    // Recording may have ended while that was in flight; a late preview
                    // overwriting the finished state would be a flicker of stale text.
                    guard self.stage.isRecording else { return }
                    self.preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    // A failed preview is not a failed dictation. Stay quiet.
                }
            }
        }
    }

    private func stopPreviewing() {
        previewTask?.cancel()
        previewTask = nil
    }

    private static let previewInterval: Duration = .milliseconds(1500)

    /// Past this, previewing stops. Long dictations are rare and the cost is quadratic.
    private static let previewCutoff: TimeInterval = 60

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
        micLevel = 0
    }
}
