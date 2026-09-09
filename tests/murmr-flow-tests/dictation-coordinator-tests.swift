import Foundation
import Testing

@testable import MurmrFlow

/// The dictation loop, driven end to end with a fake microphone, transcriber, clean-up and
/// pasteboard. This is the state machine the app *is*, and until these existed it had no
/// tests at all.
@MainActor
@Suite("Dictation coordinator")
struct DictationCoordinatorTests {

    typealias Stage = DictationCoordinator.Stage

    /// Everything one test needs, wired once.
    @MainActor
    final class Rig {
        let mic: FakeMic
        let transcriber: FakeTranscriber
        let cleaner: FakeCleaner
        let media: FakeMedia
        let sink: InjectionSink
        let stages: StageLog<Stage>
        let settings: SettingsStore
        let history: HistoryStore
        let providers: ProviderStore
        let prompts: PromptStore
        let speech: SpeechModelStore
        let coordinator: DictationCoordinator

        init() {
            // Locals first: `self` may not be read until every property is set.
            let mic = FakeMic()
            let transcriber = FakeTranscriber()
            let cleaner = FakeCleaner()
            let media = FakeMedia()
            let sink = InjectionSink()
            let stages = StageLog<Stage>()
            let defaults = Scratch.defaults("dictation")
            let settings = SettingsStore(defaults: defaults)
            let history = HistoryStore(
                url: Scratch.folder("history").appendingPathComponent("dictations.jsonl")
            )
            let providers = ProviderStore(defaults: defaults)
            // The Custom provider needs no key, so "usable" does not depend on what is in
            // this machine's Keychain. The first run of these tests passed here and
            // failed on CI for exactly that reason: a Groq key on the developer's Mac.
            providers.update(baseURL: "http://localhost:11434/v1", model: "test-model", for: "custom")
            providers.activeID = "custom"
            let prompts = PromptStore(defaults: defaults)
            let speech = SpeechModelStore(defaults: defaults)

            self.mic = mic
            self.transcriber = transcriber
            self.cleaner = cleaner
            self.media = media
            self.sink = sink
            self.stages = stages
            self.settings = settings
            self.history = history
            self.providers = providers
            self.prompts = prompts
            self.speech = speech
            coordinator = DictationCoordinator(
                settings: settings,
                loader: SpeechModelLoader(),
                transcriber: transcriber,
                history: history,
                prompts: prompts,
                providers: providers,
                speech: speech,
                dictionary: DictionaryStore(defaults: defaults),
                devices: nil,
                recorder: mic,
                cleanup: cleaner,
                media: media,
                inject: { try sink.inject($0) },
                assumeModelsLoaded: true
            )
            coordinator.onStageChange = { stages.stages.append($0) }
        }

        /// One whole dictation: press, the transcriber hears `text`, release.
        func dictate(_ text: String) async {
            transcriber.outputs = [.success(text)]
            coordinator.beginDictation()
            await coordinator.endDictation()
        }
    }

    @Test("a dictation walks every stage, types the cleaned text and keeps both versions")
    func happyPath() async {
        let rig = Rig()
        await rig.dictate("hello there")

        #expect(rig.stages.stages == [.recording, .transcribing, .cleaning, .injecting, .idle])
        #expect(rig.sink.texts == ["HELLO THERE"])
        #expect(rig.history.dictations.count == 1)
        #expect(rig.history.dictations.first?.rawText == "hello there")
        #expect(rig.history.dictations.first?.finalText == "HELLO THERE")
        #expect(rig.history.dictations.first?.usedRawFallback == false)
        #expect(rig.coordinator.lastRun?.insertionFailed == false)
        // Words came back, so the speech model is proved without a separate test.
        #expect(rig.speech.verification(for: rig.speech.activeModel).isWorking)
    }

    @Test("music paused for the dictation is resumed after it")
    func mediaRoundTrip() async {
        let rig = Rig()
        await rig.dictate("one")
        #expect(rig.media.pauses == 1)
        #expect(rig.media.resumes == [true])

        // Off means never touched.
        rig.settings.pauseMediaWhileDictating = false
        await rig.dictate("two")
        #expect(rig.media.pauses == 1)
        #expect(rig.media.resumes == [true])
    }

    /// Saying nothing used to return early — and leave the music paused for good.
    @Test("hearing nothing is counted, records nothing, and still restores the music")
    func nothingHeard() async {
        let rig = Rig()
        await rig.dictate("   ")

        #expect(rig.coordinator.nothingHeardCount == 1)
        #expect(rig.coordinator.stage == .idle)
        #expect(rig.history.dictations.isEmpty)
        #expect(rig.sink.texts.isEmpty)
        #expect(rig.coordinator.lastRun == nil)
        #expect(rig.media.resumes == [true])
        #expect(rig.stages.stages == [.recording, .transcribing, .idle])
    }

    /// The one invariant: once transcribed, the words reach the user. A dead provider
    /// degrades to the raw transcript, never to a failure.
    @Test("a clean-up that falls back still types the raw words and says so on the record")
    func cleanupFallback() async {
        let rig = Rig()
        rig.cleaner.outcome = { CleanupService.Outcome.raw($0, note: "provider down") }
        await rig.dictate("raw words")

        #expect(rig.coordinator.stage == .idle)
        #expect(rig.sink.texts == ["raw words"])
        #expect(rig.history.dictations.first?.usedRawFallback == true)
        #expect(rig.coordinator.lastRun?.note == "provider down")
        #expect(rig.coordinator.lastRun?.insertionFailed == false)
    }

    @Test("text that cannot be typed is still recorded, and the run says it never landed")
    func insertionFailure() async {
        let rig = Rig()
        rig.sink.error = TestError(message: "secure field")
        await rig.dictate("password is hunter2")

        #expect(rig.coordinator.stage == .idle)
        #expect(rig.coordinator.lastRun?.insertionFailed == true)
        #expect(rig.coordinator.lastRun?.note?.contains("secure field") == true)
        #expect(rig.history.dictations.count == 1)
    }

    @Test("clean-up is skipped, not failed, when it is switched off")
    func cleanupOff() async {
        let rig = Rig()
        rig.settings.cleanupEnabled = false
        await rig.dictate("as spoken")
        // The fake is still asked — that is where the dictionary swaps happen — but with
        // no provider, which is how it knows to leave the words alone.
        #expect(rig.cleaner.providerIDs == ["none"])
    }

    @Test("a microphone that will not start is a microphone failure")
    func micStartFails() async {
        let rig = Rig()
        rig.mic.startError = TestError(message: "no input device")
        rig.coordinator.beginDictation()

        #expect(rig.coordinator.stage == .failed(.microphone, "no input device"))
        #expect(rig.history.dictations.isEmpty)
    }

    @Test("a transcriber that throws is a speech-model failure, and the music comes back")
    func transcriberFails() async {
        let rig = Rig()
        rig.transcriber.outputs = [.failure(TestError(message: "model exploded"))]
        rig.coordinator.beginDictation()
        await rig.coordinator.endDictation()

        #expect(rig.coordinator.stage == .failed(.speechModel, "model exploded"))
        #expect(rig.media.resumes == [true])
        #expect(rig.sink.texts.isEmpty)
    }

    @Test("dictation stands down while a meeting holds the microphone")
    func suspended() {
        let rig = Rig()
        rig.coordinator.isSuspended = true
        rig.coordinator.beginDictation()
        guard case .failed(let kind, _) = rig.coordinator.stage else {
            Issue.record("expected a failure, got \(rig.coordinator.stage)")
            return
        }
        #expect(kind == .microphone)
    }

    @Test("cancelling throws the audio away and restores the music")
    func cancel() async {
        let rig = Rig()
        rig.coordinator.beginDictation()
        #expect(rig.coordinator.stage == .recording)
        rig.coordinator.cancelDictation()
        #expect(rig.coordinator.stage == .idle)
        #expect(rig.mic.cancels == 1)
        await Scratch.waitUntil { rig.media.resumes == [true] }
        #expect(rig.media.resumes == [true])
        #expect(rig.history.dictations.isEmpty)
    }

    // MARK: - Re-run

    @Test("re-run uses the same context as the first run and replaces the text")
    func rerun() async {
        let rig = Rig()
        rig.settings.dictationTranslates = true
        rig.settings.dictationOutputLanguage = "French"
        await rig.dictate("bonjour")
        let record = rig.history.dictations[0]

        rig.cleaner.outcome = {
            CleanupService.Outcome(text: "again: \($0)", usedRawFallback: false, note: nil, latency: 0)
        }
        let blocker = await rig.coordinator.rerunCleanup(on: record)

        #expect(blocker == nil)
        #expect(rig.history.dictations[0].finalText == "again: bonjour")
        #expect(rig.history.dictations[0].id == record.id)
        // The translation the first run had, not a bare transcript.
        #expect(rig.cleaner.contexts.last?.outputLanguage == "French")
    }

    @Test("re-run keeps the text when the AI falls back, and says why")
    func rerunFallback() async {
        let rig = Rig()
        await rig.dictate("keep me")
        let record = rig.history.dictations[0]

        rig.cleaner.outcome = { CleanupService.Outcome.raw($0, note: "timed out") }
        let reason = await rig.coordinator.rerunCleanup(on: record)

        #expect(reason == "timed out")
        #expect(rig.history.dictations[0].finalText == "KEEP ME")
    }

    @Test("re-run is blocked, with a reason, when clean-up is off")
    func rerunBlocked() async {
        let rig = Rig()
        await rig.dictate("blocked")
        rig.settings.cleanupEnabled = false

        #expect(rig.coordinator.rerunBlocker == "Clean-up is off for dictation")
        let reason = await rig.coordinator.rerunCleanup(on: rig.history.dictations[0])
        #expect(reason == "Clean-up is off for dictation")
        #expect(rig.cleaner.transcripts == ["blocked"])
    }

    // MARK: - Provider test

    /// Every change to a provider runs a test, so two can be asked for faster than one
    /// finishes. The newest waits; the one in between is dropped.
    @Test("provider tests queue the newest request while one is running")
    func providerTestQueue() async {
        let rig = Rig()
        rig.cleaner.delay = .milliseconds(80)

        rig.coordinator.testProvider("groq")
        rig.coordinator.testProvider("cerebras")
        rig.coordinator.testProvider("openrouter")
        #expect(rig.coordinator.testingProviderID == "groq")

        await Scratch.waitUntil { rig.cleaner.providerIDs.count == 2 && rig.coordinator.testingProviderID == nil }

        #expect(rig.cleaner.providerIDs == ["groq", "openrouter"])
        #expect(rig.providers.state(for: "groq").verification.isWorking)
        #expect(rig.providers.state(for: "openrouter").verification.isWorking)
        #expect(rig.providers.state(for: "cerebras").verification == .untested)
    }

    @Test("a provider whose reply falls back is recorded as not working, with the reason")
    func providerTestFails() async {
        let rig = Rig()
        rig.cleaner.outcome = { CleanupService.Outcome.raw($0, note: "invalid key") }
        rig.coordinator.testProvider("groq")
        await Scratch.waitUntil { rig.coordinator.testingProviderID == nil }

        #expect(rig.providers.state(for: "groq").verification == .failed("invalid key"))
    }
}
