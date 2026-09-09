import Foundation
import Testing

@testable import MurmrFlow

/// A meeting from Start to a note on disk, with a fake recorder and transcriber. The
/// recording is deleted the moment the note is written, so the note is the only copy —
/// which is why every failure here has to name the right thing and lose nothing.
@MainActor
@Suite("Meeting coordinator")
struct MeetingCoordinatorTests {

    typealias Stage = MeetingCoordinator.Stage
    typealias Segment = TranscriptionService.Segment

    @MainActor
    final class Rig {
        let recorder: FakeMeetingRecorder
        let transcriber: FakeTranscriber
        let cleaner: FakeCleaner
        let stages: StageLog<Stage>
        let folder: URL
        let notes: NoteStore
        let settings: SettingsStore
        let prompts: PromptStore
        let coordinator: MeetingCoordinator
        /// Shared with the reader closure, which cannot capture `self` during init.
        private let box: SampleBox

        init(notesFolder: URL? = nil) {
            // Locals first: `self` may not be read until every property is set.
            let recorder = FakeMeetingRecorder()
            let transcriber = FakeTranscriber()
            let cleaner = FakeCleaner()
            let stages = StageLog<Stage>()
            let box = SampleBox()
            let defaults = Scratch.defaults("meeting")
            let folder = notesFolder ?? Scratch.folder("meeting-notes")
            let notes = NoteStore(folder: folder)
            let settings = SettingsStore(defaults: defaults)
            let prompts = PromptStore(defaults: defaults)

            self.recorder = recorder
            self.transcriber = transcriber
            self.cleaner = cleaner
            self.stages = stages
            self.box = box
            self.folder = folder
            self.notes = notes
            self.settings = settings
            self.prompts = prompts
            coordinator = MeetingCoordinator(
                loader: SpeechModelLoader(),
                transcriber: transcriber,
                notes: notes,
                settings: settings,
                prompts: prompts,
                providers: ProviderStore(defaults: defaults),
                dictionary: DictionaryStore(defaults: defaults),
                devices: nil,
                recorder: recorder,
                cleanup: cleaner,
                readSamples: { url in box.samples[url.lastPathComponent] ?? [] },
                assumeModelsLoaded: true
            )
            coordinator.onStageChange = { stages.stages.append($0) }

            let scratch = Scratch.folder("recording")
            recorder.recording = MeetingRecorder.Recording(
                you: scratch.appendingPathComponent("you.wav"),
                them: scratch.appendingPathComponent("them.wav"),
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                duration: 120,
                folder: scratch,
                systemCallbacks: 40
            )
            // One turn each side, so the woven transcript has something to weave.
            transcriber.segmentBatches = [
                [Segment(text: "so are we good to move it", start: 0, end: 2)],
                [Segment(text: "yeah thursday works", start: 3, end: 5)],
            ]
        }

        /// What the fake reader hands back for each stream, keyed by file name.
        func setSamples(_ samples: [String: [Float]]) {
            box.samples = samples
        }

        func run() async {
            coordinator.start()
            await coordinator.stop()
        }
    }

    final class SampleBox: @unchecked Sendable {
        var samples: [String: [Float]] = ["you.wav": [0.1, 0.2], "them.wav": [0.3, 0.4]]
    }

    @Test("a meeting walks every step and ends as one note with both speakers")
    func happyPath() async throws {
        let rig = Rig()
        rig.settings.notetakerCleanupEnabled = false
        await rig.run()

        #expect(rig.stages.stages == [
            .recording, .transcribing(.reading), .transcribing(.you), .transcribing(.them),
            .transcribing(.writing), .saved,
        ])
        #expect(rig.notes.notes.count == 1)
        let body = rig.notes.body(of: rig.notes.notes[0])
        #expect(body.contains("so are we good to move it"))
        #expect(body.contains("yeah thursday works"))
        #expect(rig.coordinator.lastResult?.transcript.utterances.count == 2)
        // The audio is gone: the note is the only copy, on purpose.
        #expect(!FileManager.default.fileExists(atPath: rig.recorder.recording!.folder.path))
    }

    @Test("with clean-up on, the note carries the cleaned turns and the cleaning step shows")
    func cleaned() async {
        let rig = Rig()
        rig.settings.notetakerCleanupEnabled = true
        await rig.run()

        #expect(rig.stages.stages.contains(.transcribing(.cleaning)))
        #expect(rig.coordinator.stage == .saved)
        let body = rig.notes.body(of: rig.notes.notes[0])
        #expect(body.contains("SO ARE WE GOOD TO MOVE IT"))
        #expect(rig.coordinator.lastResult?.cleanupNote == nil)
    }

    @Test("a clean-up that falls back keeps every turn as spoken and says why")
    func cleanupFallback() async {
        let rig = Rig()
        rig.settings.notetakerCleanupEnabled = true
        rig.cleaner.turnsOutcome = { CleanupService.TurnsOutcome.raw($0, note: "provider down") }
        await rig.run()

        #expect(rig.coordinator.stage == .saved)
        #expect(rig.coordinator.lastResult?.cleanupNote == "provider down")
        #expect(rig.notes.body(of: rig.notes.notes[0]).contains("so are we good to move it"))
    }

    /// Both streams empty is a microphone problem: nothing was captured on either side.
    @Test("no audio at all is a microphone failure and writes no note")
    func noAudio() async {
        let rig = Rig()
        rig.setSamples([:])
        await rig.run()

        guard case .failed(let kind, _) = rig.coordinator.stage else {
            Issue.record("expected a failure, got \(rig.coordinator.stage)")
            return
        }
        #expect(kind == .microphone)
        #expect(rig.notes.notes.isEmpty)
    }

    /// A transcript with nothing in it *and* a tap that never ran is the system-audio
    /// grant, not a quiet meeting — and used to be announced as the speech model.
    @Test("a tap that never ran is a system-audio failure")
    func systemCaptureFailed() async {
        let rig = Rig()
        rig.transcriber.segmentBatches = [[], []]
        rig.recorder.recording = MeetingRecorder.Recording(
            you: rig.recorder.recording!.you, them: rig.recorder.recording!.them,
            startedAt: Date(), duration: 60, folder: rig.recorder.recording!.folder,
            systemCallbacks: 0
        )
        await rig.run()

        guard case .failed(let kind, _) = rig.coordinator.stage else {
            Issue.record("expected a failure, got \(rig.coordinator.stage)")
            return
        }
        #expect(kind == .systemAudio)
        #expect(rig.notes.notes.isEmpty)
    }

    @Test("a transcriber that throws is a speech-model failure")
    func transcriberFails() async {
        let rig = Rig()
        rig.transcriber.segmentError = TestError(message: "model exploded")
        await rig.run()

        #expect(rig.coordinator.stage == .failed(.speechModel, "model exploded"))
        #expect(rig.notes.notes.isEmpty)
    }

    @Test("a note that cannot be written is a notes failure, not a model one")
    func saveFails() async throws {
        let parent = Scratch.folder("blocked")
        let blocker = parent.appendingPathComponent("file")
        try Data().write(to: blocker)
        let rig = Rig(notesFolder: blocker.appendingPathComponent("notes", isDirectory: true))
        rig.settings.notetakerCleanupEnabled = false
        await rig.run()

        guard case .failed(let kind, _) = rig.coordinator.stage else {
            Issue.record("expected a failure, got \(rig.coordinator.stage)")
            return
        }
        #expect(kind == .notes)
    }

    @Test("a recorder that will not start is a microphone failure")
    func recorderFails() {
        let rig = Rig()
        rig.recorder.startError = MeetingRecorder.RecorderError.noInputDevice
        rig.coordinator.start()

        guard case .failed(let kind, _) = rig.coordinator.stage else {
            Issue.record("expected a failure, got \(rig.coordinator.stage)")
            return
        }
        #expect(kind == .microphone)
    }

    @Test("stopping with nothing recorded is a microphone failure")
    func nothingRecorded() async {
        let rig = Rig()
        rig.recorder.recording = nil
        await rig.run()
        #expect(rig.coordinator.stage == .failed(.microphone, "Nothing was recorded."))
    }

    @Test("discarding writes nothing and goes back to idle")
    func discard() {
        let rig = Rig()
        rig.coordinator.start()
        #expect(rig.coordinator.stage == .recording)
        rig.coordinator.discard()
        #expect(rig.coordinator.stage == .idle)
        #expect(rig.recorder.discards == 1)
        #expect(rig.notes.notes.isEmpty)
    }
}
