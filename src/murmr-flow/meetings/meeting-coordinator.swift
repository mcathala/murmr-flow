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
        /// Which part broke, and the sentence for the window. Decided here, where the
        /// failure is seen, so the pill never has to guess it from the words.
        case failed(FailureKind, String)

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
        case noting
        case writing

        var label: String {
            switch self {
            case .reading: "Reading the recording"
            case .you: "Transcribing your side"
            case .them: "Transcribing their side"
            case .noting: "Writing the note"
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
        /// Why clean-up was skipped, or what it couldn't finish. Non-blocking: the note
        /// is already saved either way, and this is what stops that being silent.
        let cleanupNote: String?
    }

    enum RecordingError: LocalizedError {
        case noAudio
        case systemCaptureFailed

        var errorDescription: String? {
            switch self {
            case .noAudio:
                "No audio was captured. Check that Murmr Flow is allowed under Privacy & "
                    + "Security \u{203A} \(SystemSettingsPane.systemAudio), and that a "
                    + "microphone is connected."
            case .systemCaptureFailed:
                "System audio capture failed — the recording never received a single "
                    + "frame of what the Mac was playing. Nothing was wrong with the "
                    + "meeting; the tap did not run. Try recording again."
            }
        }

        var kind: FailureKind {
            switch self {
            case .noAudio: .microphone
            case .systemCaptureFailed: .systemAudio
            }
        }
    }

    /// Wraps a failure from writing the note file, so the catch below can tell "the model
    /// failed" from "the disk did" — the words are the same shape, the remedy is not.
    private struct SaveError: Error {
        let underlying: Error
    }

    /// Which part an error belongs to. Our own errors say; anything from the system-audio
    /// tap is that grant; the recorder's are the microphone; the rest is the model.
    private static func kind(of error: Error) -> FailureKind {
        if let ours = error as? RecordingError { return ours.kind }
        if error is SystemAudioRecorder.RecorderError { return .systemAudio }
        if error is MeetingRecorder.RecorderError { return .microphone }
        return .speechModel
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

    /// What the person is typing while the meeting runs.
    ///
    /// Held here rather than in the view, because a pane that is scrolled away, or a
    /// window that is closed, must not take the notes with it — and because the note
    /// written at the end is built from them.
    var liveNotes: String = ""

    /// Live levels, republished on the same tick as the timer.
    private(set) var youLevel: Float = 0
    private(set) var themLevel: Float = 0

    /// Set while a meeting holds the microphone, so dictation can stand down rather than
    /// opening a second input stream over the top of it.
    var onRecordingChange: (@MainActor (Bool) -> Void)?

    private let loader: SpeechModelLoader
    private let transcriber: any Transcribing
    private let notes: NoteStore
    private let settings: SettingsStore
    private let prompts: PromptStore
    private let providers: ProviderStore
    private let dictionary: DictionaryStore
    private let devices: AudioDeviceStore?
    private let recorder: any MeetingRecording
    private let cleanup: any Cleaning
    /// Reads a recorded stream back as samples. The real one opens a wav file; a test's
    /// hands back whatever the fake recorder "recorded".
    private let readSamples: @Sendable (URL) throws -> [Float]
    /// Tests only: the fake transcriber needs no model files, so the "is the model on
    /// disk" gate would otherwise refuse every meeting before it began.
    private let assumeModelsLoaded: Bool
    private var tickTask: Task<Void, Never>?

    init(
        loader: SpeechModelLoader,
        transcriber: any Transcribing,
        notes: NoteStore,
        settings: SettingsStore,
        prompts: PromptStore,
        providers: ProviderStore,
        dictionary: DictionaryStore,
        devices: AudioDeviceStore?,
        recorder: any MeetingRecording = MeetingRecorder(),
        cleanup: any Cleaning = CleanupService(),
        readSamples: @escaping @Sendable (URL) throws -> [Float] = AudioFileReader.samples(at:),
        assumeModelsLoaded: Bool = false
    ) {
        self.recorder = recorder
        self.cleanup = cleanup
        self.readSamples = readSamples
        self.assumeModelsLoaded = assumeModelsLoaded
        self.loader = loader
        self.transcriber = transcriber
        self.notes = notes
        self.settings = settings
        self.prompts = prompts
        self.providers = providers
        self.dictionary = dictionary
        self.devices = devices
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
        guard loader.models != nil || assumeModelsLoaded else {
            stage = .failed(.speechModel, modelNotReadyMessage())
            if !loader.isPreparing { Task { await loader.prepare() } }
            return
        }

        // Read before the attempt, because the attempt is what sets it.
        let hadBeenAsked = SystemAudioRecorder.hasBeenAsked

        do {
            // Read the choice at the moment of recording rather than holding it, so
            // picking a different microphone takes effect on the very next take.
            recorder.inputDeviceID = devices?.selectedInputDeviceID
            try recorder.start()
            elapsed = 0
            // Cleared here, where a recording genuinely begins — not at the top, where a
            // refused start would throw away notes from the meeting still running.
            liveNotes = ""
            stage = .recording
            startTicking()
            onRecordingChange?(true)
        } catch {
            var kind = Self.kind(of: error)
            var message = error.localizedDescription
            // The first attempt on this machine is the one that raised Apple's dialog, and
            // it could not have succeeded whatever the answer. Say what to do next instead
            // of announcing a refusal nobody has made.
            if kind == .systemAudio, !hadBeenAsked {
                kind = .systemAudioPending
                message = "Allow system audio in the dialog, then start the meeting again."
            }
            stage = .failed(kind, message)
        }
    }

    func stop() async {
        stopTicking()
        guard let recording = recorder.stop() else {
            onRecordingChange?(false)
            stage = .failed(.microphone, "Nothing was recorded.")
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
            let yourSamples = (try? readSamples(recording.you)) ?? []
            let theirSamples = (try? readSamples(recording.them)) ?? []
            guard !yourSamples.isEmpty || !theirSamples.isEmpty else {
                throw RecordingError.noAudio
            }

            stage = .transcribing(.you)
            let yours = try await segments(from: yourSamples)

            stage = .transcribing(.them)
            let theirs = try await segments(from: theirSamples)

            let woven = MeetingTranscript.weave(
                you: yours,
                them: theirs,
                startedAt: recording.startedAt,
                duration: recording.duration,
                title: NoteStore.defaultTitle(for: recording.startedAt)
            )

            // A silent meeting and a dead tap both produce nothing. Only the callback
            // count tells them apart, and saving a note that says "nothing was
            // transcribed" for the second one sends the user looking at their microphone
            // when the fault was ours.
            if woven.isEmpty, recording.systemCallbacks == 0 {
                throw RecordingError.systemCaptureFailed
            }

            // One request, and the transcript is kept as heard.
            //
            // There used to be two: tidy every turn, then write the note from the tidied
            // turns. The second pass never needed the first — it carries the same
            // repair rules, the same corrections handling and the same dictionary hints,
            // so the transcript was being cleaned twice and sent twice. And the expensive
            // half was the tidying: a pass whose output is as long as its input, on a
            // forty-minute conversation, to produce something the next pass compresses to
            // a dozen bullets.
            //
            // What the transcript loses by staying raw, it arguably gains. It is the
            // evidence behind the note, the recording is deleted, and evidence reads
            // better unedited.
            let (transcript, noteWarning) = await noted(woven)

            stage = .transcribing(.writing)
            let saved: NoteFile
            do {
                saved = try notes.save(transcript)
            } catch {
                throw SaveError(underlying: error)
            }

            lastResult = Result(
                transcript: transcript,
                note: saved,
                processingTime: (clock.now - started).seconds,
                cleanupNote: noteWarning
            )
            stage = .saved
            Self.log.notice(
                "meeting saved: \(transcript.utterances.count, privacy: .public) utterances"
            )
        } catch let save as SaveError {
            stage = .failed(.notes, save.underlying.localizedDescription)
            Self.log.error("meeting failed: \(save.underlying.localizedDescription, privacy: .public)")
        } catch {
            stage = .failed(Self.kind(of: error), error.localizedDescription)
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

    // MARK: - The note

    /// Writes the note that goes above the transcript.
    ///
    /// Runs after the turns have been tidied, on purpose: the note is written from the
    /// best wording available, and mis-transcribed turns would otherwise be summarised as
    /// heard. Returns the transcript unchanged and a sentence when there is no note — the
    /// meeting is still saved, because a note that could not be written must never cost
    /// the record of what was said.
    private func noted(
        _ transcript: MeetingTranscript
    ) async -> (MeetingTranscript, String?) {
        let typed = liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Kept verbatim whatever happens next. They are the person's own words, and the
        // one thing in this file that cannot be reconstructed from anything else.
        let transcript = typed.isEmpty ? transcript : transcript.adding(ownNotes: typed)

        guard settings.notetakerCleanupEnabled else { return (transcript, nil) }
        guard !transcript.isEmpty else { return (transcript, nil) }
        guard let preset = prompts.notetakerPrompt else { return (transcript, nil) }

        stage = .transcribing(.noting)
        let outcome = await cleanup.writeNote(
            from: transcript.utterances.map {
                CleanupService.Turn(speaker: $0.speaker.rawValue, text: $0.text)
            },
            config: providers.activeConfig,
            prompt: PromptLibrary(template: preset.template),
            context: PromptLibrary.Context(
                transcript: "",  // filled in from the turns
                ownNotes: typed,
                outputLanguage: settings.notetakerTargetLanguage
            ),
            dictionary: dictionary.entries(usedIn: .notetaker),
            timeout: CleanupService.noteTimeout
        )

        guard let text = outcome.text else {
            Self.log.notice(
                "no note written: \(outcome.note ?? "nothing to write", privacy: .public)"
            )
            return (transcript, outcome.note.map { "The note could not be written. \($0)" })
        }
        Self.log.notice("note written: \(text.count, privacy: .public) characters")
        return (transcript.adding(note: text, writtenBy: preset.name), nil)
    }

    /// True while a note is being written for a meeting already on disk.
    var isWritingNote = false

    /// Writes the note for a meeting that has already been saved, from its transcript and
    /// whatever the person typed during it.
    ///
    /// The same pass that runs when a meeting ends, reachable afterwards — because the
    /// reasons there is no note are all temporary ones: the provider was down, the style
    /// was unset, clean-up was off. Returns why it could not, or nil when it did.
    @discardableResult
    func writeNote(for note: NoteFile) async -> String? {
        guard !isWritingNote else { return nil }
        guard let preset = prompts.notetakerPrompt else {
            return "No style is set for Notetaker."
        }
        guard providers.activeConfig != nil else { return "No AI is connected." }

        let body = notes.body(of: note)
        let turns = NoteFile.turns(in: body).map {
            CleanupService.Turn(speaker: $0.speaker, text: $0.text)
        }
        guard !turns.isEmpty else { return "There is no transcript to write from." }

        isWritingNote = true
        defer { isWritingNote = false }

        let outcome = await cleanup.writeNote(
            from: turns,
            config: providers.activeConfig,
            prompt: PromptLibrary(template: preset.template),
            context: PromptLibrary.Context(
                transcript: "",
                ownNotes: NoteFile.ownNotes(in: body),
                outputLanguage: settings.notetakerTargetLanguage
            ),
            dictionary: dictionary.entries(usedIn: .notetaker),
            timeout: CleanupService.noteTimeout
        )
        guard let text = outcome.text else {
            return outcome.note ?? "Nothing came back."
        }
        notes.saveSummary(text, in: note)
        return nil
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
        switch loader.state {
        case .downloading(let fraction):
            "Still downloading the speech model — \(Int(fraction * 100))%."
        case .preparing, .loading:
            "The speech model is still getting ready."
        case .failed(let message):
            message
        case .notLoaded, .ready:
            "The speech model isn't loaded yet. Open Settings › Speech model."
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

}
