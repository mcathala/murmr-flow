import AppKit
import Foundation
import Observation
import OSLog

/// Drives one meeting end to end: press start, talk, press stop, get a note.
///
/// Transcription happens *after* the recording rather than live. Two reasons: the model
/// runs far faster than real time, so a finished hour takes well under a minute; and
/// transcribing the whole stream in one pass lets the decoder keep context across the
/// entire meeting, which is measurably better than stitching together chunks it never
/// saw the sides of.
///
/// Audio is deleted as soon as the note is written. Nothing is kept that the user did not
/// ask to keep.
@MainActor
@Observable
final class MeetingCoordinator {

    enum Stage: Equatable {
        case idle
        case recording
        case transcribing(TranscribeStep)
        case saved
        case failed(String)

        var isRecording: Bool { self == .recording }

        var isBusy: Bool {
            switch self {
            case .recording, .transcribing: true
            case .idle, .saved, .failed: false
            }
        }

        var label: String {
            switch self {
            case .idle: "Ready"
            case .recording: "Recording"
            case .transcribing(let step): step.label
            case .saved: "Saved"
            case .failed: "Failed"
            }
        }
    }

    /// The steps are named because transcribing a long meeting is the one part with a
    /// visible wait, and "Working…" for forty seconds looks like a hang.
    enum TranscribeStep: Equatable {
        case reading
        case you
        case them
        case writing

        var label: String {
            switch self {
            case .reading: "Reading the recording"
            case .you: "Transcribing your side"
            case .them: "Transcribing their side"
            case .writing: "Writing the note"
            }
        }
    }

    /// What the last finished meeting produced.
    struct Result: Sendable {
        let transcript: MeetingTranscript
        let note: NoteFile
        /// Time spent transcribing, not the meeting's length.
        let processingTime: TimeInterval
    }

    enum RecordingError: LocalizedError {
        case noAudio

        var errorDescription: String? {
            switch self {
            case .noAudio:
                "No audio was captured. Check that Murmr Flow is allowed under Privacy & "
                    + "Security \u{203A} System Audio Recording, and that a microphone is "
                    + "connected."
            }
        }
    }

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "meetings")

    private(set) var stage: Stage = .idle {
        didSet {
            guard stage != oldValue else { return }
            onStageChange?(stage)
        }
    }

    /// Lets the floating panel react without this class knowing what a window is.
    var onStageChange: (@MainActor (Stage) -> Void)?
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastResult: Result?

    /// Live levels, republished on the same tick as the timer.
    private(set) var youLevel: Float = 0
    private(set) var themLevel: Float = 0

    /// Set while a meeting holds the microphone, so dictation can stand down rather than
    /// opening a second input stream over the top of it.
    var onRecordingChange: (@MainActor (Bool) -> Void)?

    private let models: ModelManager
    private let transcriber: TranscriptionService
    private let notes: MeetingStore
    private let recorder = MeetingRecorder()
    private var tickTask: Task<Void, Never>?

    init(models: ModelManager, transcriber: TranscriptionService, notes: MeetingStore) {
        self.models = models
        self.transcriber = transcriber
        self.notes = notes
    }

    var isRecording: Bool { recorder.isRecording }

    // MARK: - Start / stop

    func toggle() {
        if recorder.isRecording {
            Task { await stop() }
        } else {
            start()
        }
    }

    func start() {
        guard !stage.isBusy else { return }

        // Refuse rather than downloading mid-meeting. Otherwise the user records for an
        // hour and only then discovers there is no model to transcribe it with.
        guard models.models != nil else {
            stage = .failed(modelNotReadyMessage())
            if !models.isPreparing { Task { await models.prepare() } }
            return
        }

        do {
            try recorder.start()
            elapsed = 0
            stage = .recording
            startTicking()
            onRecordingChange?(true)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        stopTicking()
        guard let recording = recorder.stop() else {
            onRecordingChange?(false)
            stage = .failed("Nothing was recorded.")
            return
        }
        onRecordingChange?(false)

        let clock = ContinuousClock()
        let started = clock.now

        do {
            stage = .transcribing(.reading)
            // Each side is read on its own. One stream can legitimately be empty — a
            // meeting where you never spoke, or a muted microphone — and that must not
            // cost the other half of the transcript.
            let yourSamples = (try? AudioFileReader.samples(at: recording.you)) ?? []
            let theirSamples = (try? AudioFileReader.samples(at: recording.them)) ?? []
            guard !yourSamples.isEmpty || !theirSamples.isEmpty else {
                throw RecordingError.noAudio
            }

            stage = .transcribing(.you)
            let yours = try await segments(from: yourSamples)

            stage = .transcribing(.them)
            let theirs = try await segments(from: theirSamples)

            stage = .transcribing(.writing)
            let transcript = MeetingTranscript.weave(
                you: yours,
                them: theirs,
                startedAt: recording.startedAt,
                duration: recording.duration,
                title: MeetingStore.defaultTitle(for: recording.startedAt)
            )
            let saved = try notes.save(transcript)

            lastResult = Result(
                transcript: transcript,
                note: saved,
                processingTime: (clock.now - started).seconds
            )
            stage = .saved
            Self.log.notice(
                "meeting saved: \(transcript.utterances.count, privacy: .public) utterances"
            )
        } catch {
            stage = .failed(error.localizedDescription)
            Self.log.error("meeting failed: \(error.localizedDescription, privacy: .public)")
        }

        // Whether it worked or not, the audio goes. Keeping a failed recording around
        // would be keeping a recording the user was never told about.
        try? FileManager.default.removeItem(at: recording.folder)
    }

    /// Abandons the recording without transcribing or saving anything.
    func discard() {
        stopTicking()
        recorder.discard()
        onRecordingChange?(false)
        stage = .idle
        elapsed = 0
    }

    // MARK: - Transcription

    /// Transcribes one stream. Silence filtering lives in the service, which has both the
    /// samples and the per-token timings needed to do it properly.
    private func segments(from samples: [Float]) async throws -> [TranscriptionService.Segment] {
        guard !samples.isEmpty else { return [] }
        return try await transcriber.transcribeSegments(samples)
    }

    // MARK: - Model state

    private func modelNotReadyMessage() -> String {
        switch models.state {
        case .downloading(let fraction):
            "Still downloading the speech model — \(Int(fraction * 100))%."
        case .preparing, .loading:
            "The speech model is still getting ready."
        case .failed(let message):
            message
        case .notLoaded, .ready:
            "The speech model isn't loaded yet. Open Setup to load it."
        }
    }

    // MARK: - Elapsed counter

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.recorder.isRecording else { return }
                self.elapsed = self.recorder.elapsed
                self.youLevel = self.recorder.youLevel
                self.themLevel = self.recorder.themLevel
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
        youLevel = 0
        themLevel = 0
    }

    // MARK: - Files

    func revealLastNote() {
        guard let note = lastResult?.note else { return }
        notes.reveal(note)
    }

    func openLastNote() {
        guard let note = lastResult?.note else { return }
        notes.open(note)
    }

    func openNotesFolder() { notes.openFolder() }

    /// Opens the pane holding the System Audio Recording toggle, for when the tap was
    /// refused. There is no API to grant it and no notification when it changes.
    func openSystemAudioSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
