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

    /// A grant already made is a different matter: there is nothing to ask.
    @Test("a satisfied permission step is not shown")
    func startsAtFirstGap() {
        let world = World()
        world.satisfied = [.language, .microphone]
        let flow = make(world)
        flow.begin()
        #expect(flow.step == .language)
        flow.advance()
        #expect(flow.step == .accessibility)
        #expect(flow.total == 6)
    }

    /// The first page a person sees must say "1", whatever it is.
    @Test("numbering counts the steps shown, not the steps that exist")
    func numbering() {
        let world = World()
        world.satisfied = [.microphone]
        let flow = make(world)
        flow.begin()
        #expect(flow.step == .language)
        #expect(flow.position == 1)
        #expect(flow.total == 6)
        flow.advance()
        #expect(flow.step == .accessibility)
        #expect(flow.position == 2)
    }

    @Test("advancing skips over anything already met")
    func advanceSkips() {
        let world = World()
        world.satisfied = [.microphone]
        let flow = make(world)
        flow.begin()
        #expect(flow.step == .language)
        flow.advance()
        #expect(flow.step == .accessibility)
    }

    /// A machine that already has the model and both grants — a developer's, or one where
    /// the grants survived a rebuild — has nothing to be walked through.
    @Test("an install that is already set up completes without being shown")
    func silentCompletion() {
        let world = World()
        world.satisfied = [.language, .microphone, .accessibility]
        let flow = make(world)
        flow.begin()
        #expect(flow.isComplete)
    }

    /// The two explanatory pages have no condition, so they are always walked through.
    @Test("the explanation always follows the last thing set up, then the try")
    func explanationThenTry() {
        let world = World()
        world.satisfied = [.language, .microphone]
        let flow = make(world)
        flow.begin()
        flow.advance()
        #expect(flow.step == .accessibility)
        flow.advance()
        #expect(flow.step == .howItWorks)
        flow.advance()
        #expect(flow.step == .underTheHood)
        flow.advance()
        #expect(flow.step == .style)
        flow.advance()
        #expect(flow.step == .tryIt)
    }

    @Test("advancing past the last step finishes")
    func finishesAtEnd() {
        let world = World()
        world.satisfied = [.language, .microphone]
        let flow = make(world)
        flow.begin()
        while flow.step != .tryIt { flow.advance() }
        flow.advance()
        #expect(flow.isComplete)
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
        flow.advance()
        #expect(flow.step == .microphone)

        flow.noteProgress()
        #expect(!flow.isAdvancing)

        world.satisfied.insert(.microphone)
        flow.noteProgress()
        #expect(flow.isAdvancing)
        // Still on the step for the beat that shows the tick; the move is deferred.
        #expect(flow.step == .microphone)
    }
}
