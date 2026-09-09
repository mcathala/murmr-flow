import Foundation
import Testing

@testable import MurmrFlow

/// Which screens a first launch shows, and when none are shown at all.
@MainActor
@Suite("Onboarding")
struct OnboardingTests {

    typealias Step = OnboardingCoordinator.Step

    /// What the world looks like to the flow. A class so a test can change it after the
    /// coordinator has captured it, the way a permission grant does.
    private final class World {
        var satisfied: Set<Step> = []
    }

    private func make(
        _ world: World, defaults: UserDefaults? = nil
    ) -> OnboardingCoordinator {
        let defaults = defaults ?? UserDefaults(suiteName: "murmr-onboarding-\(UUID())")!
        return OnboardingCoordinator(defaults: defaults) { world.satisfied.contains($0) }
    }

    /// The person picks languages; the model follows. Only English alone gets the English
    /// model — it is the better one for English, not a lesser one.
    @Test("languages decide the model")
    func languagesDecideTheModel() {
        #expect(SpeechModel.covering(["English"]) == .parakeetV2)
        #expect(SpeechModel.covering(["English", "French"]) == .parakeetV3)
        #expect(SpeechModel.covering(["French"]) == .parakeetV3)
        #expect(Array(SpeechModel.languageChoices.prefix(2)) == ["English", "French"])
        #expect(SpeechModel.otherLanguages == SpeechModel.otherLanguages.sorted())
        #expect(Set(SpeechModel.languageChoices) == Set(SpeechModel.parakeetV3.languages))
        // Every language offered has a flag; a chip without one would look like a mistake.
        for language in SpeechModel.languageChoices {
            #expect(SpeechModel.flag(for: language) != nil, "\(language) has no flag")
        }
    }

    @Test("a fresh machine starts at the first question")
    func fresh() {
        let flow = make(World())
        flow.begin()
        #expect(!flow.isComplete)
        #expect(flow.step == .language)
    }

    /// A model on disk does not answer which languages the person dictates in — it only
    /// makes the answer free. The question is asked whenever the flow runs.
    @Test("the language question is asked even when a model is already on disk")
    func languageAlwaysAsked() {
        let world = World()
        world.satisfied = [.language]
        let flow = make(world)
        flow.begin()
        #expect(flow.step == .language)
        #expect(flow.total == 7)
    }

    /// System audio is the one ask with a page of its own, so it is the one page a
    /// grant already made removes. The teaching pages stay whatever their cards say.
    @Test("a satisfied system-audio ask is not shown")
    func startsAtFirstGap() {
        let world = World()
        world.satisfied = [.language, .systemAudio]
        let flow = make(world)
        flow.begin()
        #expect(flow.step == .language)
        #expect(flow.total == 6)
        #expect(!flow.plan.contains(.systemAudio))
    }

    /// The first page a person sees must say "1", whatever it is.
    @Test("numbering counts the steps shown, not the steps that exist")
    func numbering() {
        let world = World()
        world.satisfied = [.systemAudio]
        let flow = make(world)
        flow.begin()
        #expect(flow.step == .language)
        #expect(flow.position == 1)
        #expect(flow.total == 6)
        flow.advance()
        #expect(flow.step == .underTheHood)
        #expect(flow.position == 2)
    }

    @Test("advancing skips over anything already met")
    func advanceSkips() {
        let world = World()
        let flow = make(world)
        flow.begin()
        flow.advance()
        flow.advance()
        #expect(flow.step == .howItWorks)
        // The grant lands from elsewhere while the flow is on an earlier page…
        world.satisfied.insert(.systemAudio)
        flow.advance()
        // …and its page drops out of the plan rather than showing a done deal.
        #expect(flow.step == .style)
    }

    /// A machine that already has the model and both grants — a developer's, or one where
    /// the grants survived a rebuild — has nothing to be walked through.
    @Test("an install that is already set up completes without being shown")
    func silentCompletion() {
        let world = World()
        world.satisfied = [.language, .howItWorks, .systemAudio, .tryIt]
        let flow = make(world)
        flow.begin()
        #expect(flow.isComplete)
    }

    /// A machine that lacks only system audio still gets the flow, and its ask comes
    /// right after the page that introduces meetings.
    @Test("system audio is asked for, right after the keys page")
    func systemAudioStep() {
        let world = World()
        world.satisfied = [.language, .howItWorks, .tryIt]
        let flow = make(world)
        flow.begin()
        #expect(!flow.isComplete)
        #expect(flow.step == .language)
        flow.advance()
        #expect(flow.step == .underTheHood)
        flow.advance()
        #expect(flow.step == .howItWorks)
        flow.advance()
        #expect(flow.step == .systemAudio)
    }

    /// Each ask lives with its explainer; the walk is the whole flow in order.
    @Test("the flow teaches and asks together, then tries")
    func explanationThenTry() {
        let flow = make(World())
        flow.begin()
        flow.advance()
        #expect(flow.step == .underTheHood)
        flow.advance()
        #expect(flow.step == .howItWorks)
        flow.advance()
        #expect(flow.step == .systemAudio)
        flow.advance()
        #expect(flow.step == .style)
        flow.advance()
        #expect(flow.step == .connectAI)
        flow.advance()
        #expect(flow.step == .tryIt)
    }

    /// A provider that already works is shown, not skipped: the page is where you see
    /// "Working" beside the one you will use, and where you could pick another.
    @Test("a working AI is still shown")
    func connectedAIShown() {
        let world = World()
        world.satisfied = [.connectAI]
        let flow = make(world)
        flow.begin()
        #expect(flow.total == 7)
        #expect(flow.plan.contains(.connectAI))
    }

    /// Declining once is a question, not a skip: the pause shares the AI page's number,
    /// and Back from it undoes the decline.
    @Test("declining the AI pauses on the same number, and Back undoes it")
    func declineOnce() {
        let flow = make(World())
        flow.begin()
        while flow.step != .connectAI { flow.advance() }
        let number = flow.position
        let total = flow.total

        flow.declineAI()
        #expect(flow.step == .withoutAI)
        #expect(flow.position == number)
        #expect(flow.total == total)
        #expect(flow.declinedAI)

        flow.back()
        #expect(flow.step == .connectAI)
        #expect(!flow.plan.contains(.withoutAI))
        #expect(!flow.declinedAI)
    }

    /// Declining twice gives up Try it — a first dictation with nothing to polish it is
    /// not the proof the page promises — but not the microphone it was carrying.
    @Test("declining twice swaps Try it for the microphone ask")
    func declineTwice() {
        let flow = make(World())
        flow.begin()
        while flow.step != .connectAI { flow.advance() }
        flow.declineAI()
        flow.continueWithoutAI()
        #expect(flow.step == .microphone)
        #expect(!flow.plan.contains(.tryIt))
        #expect(flow.position == flow.total)
        flow.advance()
        #expect(flow.isComplete)
    }

    /// With the microphone already granted there is nothing left to ask, so the second
    /// no is also the door.
    @Test("declining twice with the microphone granted finishes")
    func declineTwiceGranted() {
        let world = World()
        world.satisfied = [.microphone, .tryIt]
        let flow = make(world)
        flow.begin()
        while flow.step != .connectAI { flow.advance() }
        flow.declineAI()
        flow.continueWithoutAI()
        #expect(flow.isComplete)
    }

    @Test("advancing past the last step finishes")
    func finishesAtEnd() {
        let world = World()
        world.satisfied = [.language]
        let flow = make(world)
        flow.begin()
        while flow.step != .tryIt { flow.advance() }
        flow.advance()
        #expect(flow.isComplete)
    }

    /// Going back re-reads; it never un-decides. And the first page has nothing behind it.
    @Test("back walks the plan in reverse and stops at the start")
    func back() {
        let flow = make(World())
        flow.begin()
        #expect(flow.step == .language)
        flow.back()
        #expect(flow.step == .language)

        flow.advance()
        let second = flow.step
        flow.advance()
        flow.back()
        #expect(flow.step == second)
        #expect(flow.position == 2)
    }

    @Test("completion survives a relaunch")
    func persists() {
        let defaults = UserDefaults(suiteName: "murmr-onboarding-\(UUID())")!
        let world = World()

        let first = make(world, defaults: defaults)
        first.begin()
        first.finish()

        let second = make(world, defaults: defaults)
        second.begin()
        #expect(second.isComplete)
    }

    /// Nothing that isn't met moves the flow on — and nothing moves it on twice.
    @Test("progress is only noted when the step's condition holds")
    func noteProgress() {
        let world = World()
        let flow = make(world)
        flow.begin()
        while flow.step != .systemAudio { flow.advance() }

        flow.noteProgress()
        #expect(!flow.isAdvancing)

        world.satisfied.insert(.systemAudio)
        flow.noteProgress()
        #expect(flow.isAdvancing)
        // Still on the step for the beat that shows the tick; the move is deferred.
        #expect(flow.step == .systemAudio)
    }
}
