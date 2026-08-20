import Foundation
import Observation

/// Drives one dictation: record, transcribe, report.
///
/// Phase 1 stops at "report" — the text is displayed rather than typed at the cursor.
/// The hotkey and text injection arrive in Phase 2, at which point this gains an
/// `injecting` stage and the AI cleanup step slots in between transcribe and inject.
@MainActor
@Observable
final class DictationCoordinator {

    enum Stage: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)

        var isRecording: Bool { self == .recording }
        var isBusy: Bool { self == .recording || self == .transcribing }
    }

    /// What the gate measures.
    struct Timing: Sendable {
        /// Length of the audio captured.
        let audioDuration: TimeInterval
        /// Time the model itself spent transcribing.
        let modelTime: TimeInterval
        /// Stop-of-recording to text-in-hand, including resampling. This is the number
        /// that decides whether dictation feels instant.
        let endToEnd: TimeInterval

        var realtimeFactor: Double {
            modelTime > 0 ? audioDuration / modelTime : 0
        }
    }

    private(set) var stage: Stage = .idle
    private(set) var transcript = ""
    private(set) var confidence: Float?
    private(set) var timing: Timing?

    /// Seconds elapsed in the current recording, for the UI.
    private(set) var elapsed: TimeInterval = 0

    let models = ModelManager()

    private let recorder = MicRecorder()
    private let service = TranscriptionService()
    private var tickTask: Task<Void, Never>?

    // MARK: - Recording

    func startRecording() {
        guard !stage.isBusy else { return }
        do {
            try recorder.start()
            transcript = ""
            confidence = nil
            timing = nil
            elapsed = 0
            stage = .recording
            startTicking()
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func cancelRecording() {
        stopTicking()
        recorder.cancel()
        stage = .idle
        elapsed = 0
    }

    func stopAndTranscribe() async {
        guard stage == .recording else { return }
        stopTicking()
        stage = .transcribing

        let clock = ContinuousClock()
        let started = clock.now

        do {
            // Resampling is CPU work; keep it off the main actor.
            let recorder = self.recorder
            let samples = try await Task.detached(priority: .userInitiated) {
                try recorder.stop()
            }.value

            try await ensureServiceLoaded()
            let output = try await service.transcribe(samples)
            let endToEnd = clock.now - started

            transcript = output.text
            confidence = output.confidence
            timing = Timing(
                audioDuration: output.audioDuration,
                modelTime: output.processingTime,
                endToEnd: endToEnd.seconds
            )
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Model

    /// Loads the model into the inference actor, downloading it first if necessary.
    private func ensureServiceLoaded() async throws {
        if await service.isReady { return }
        if models.models == nil {
            await models.prepare()
        }
        guard let loaded = models.models else {
            throw TranscriptionService.ServiceError.modelsNotLoaded
        }
        try await service.load(loaded)
    }

    /// Downloads and loads ahead of first use, so the first dictation isn't slow.
    func warmUp() async {
        await models.prepare()
        if let loaded = models.models {
            try? await service.load(loaded)
        }
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

extension Duration {
    /// Seconds as a Double, for display and arithmetic against `TimeInterval`.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
