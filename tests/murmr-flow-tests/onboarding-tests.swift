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

    @Test("a fresh machine starts at the first question")
    func fresh() {
        let flow = make(World())
        flow.begin()
        #expect(!flow.isComplete)
        #expect(flow.step == .language)
    }

    /// The model is already on disk, so the language question would be asking about a
    /// download that isn't going to happen.
    @Test("a satisfied step is not shown")
    func startsAtFirstGap() {
        let world = World()
        world.satisfied = [.language]
        let flow = make(world)
        flow.begin()
        #expect(flow.step == .microphone)
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

    @Test("advancing past the last step finishes")
    func finishesAtEnd() {
        let world = World()
        world.satisfied = [.language, .microphone]
        let flow = make(world)
        flow.begin()
        #expect(flow.step == .accessibility)
        flow.advance()
        #expect(flow.step == .tryIt)
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
