import Foundation
import Observation

/// The first launch: which model to download, the two permissions dictation needs, and
/// one dictation to prove the chain. Each step moves on by itself once its condition is
/// met, so the user never comes back from System Settings to hunt for a Next button.
///
/// The pieces were built for this and then never joined up — `PermissionManager` polls
/// for Accessibility "so onboarding can advance by itself", `SpeechModel` is written around
/// "one question, English or many" — while the actual first launch downloaded 600 MB of
/// one model unasked and showed the microphone prompt in the middle of the first dictation.
///
/// Two rules:
///
///  - **A step already satisfied is not shown.** A machine that has the model and both
///    grants has nothing to be walked through, so it completes silently. The same rule
///    starts a partly set-up machine at its first real gap.
///  - **Afterwards, a missing permission is Home's job, not this flow's.** An ad-hoc
///    signature revokes the grants on every rebuild; a wizard that reappeared each time
///    would be punishment rather than help. The warning row on Home already says what is
///    broken and opens the right pane.
@MainActor
@Observable
final class OnboardingCoordinator {

    enum Step: Int, CaseIterable, Sendable {
        case language, microphone, accessibility, tryIt

        var next: Step? { Step(rawValue: rawValue + 1) }
        var number: Int { rawValue + 1 }
        static var count: Int { allCases.count }
    }

    private enum Key {
        static let completed = "onboarding.completed"
    }

    private(set) var isComplete: Bool
    private(set) var step: Step = .language

    /// True for the beat between a step's condition being met and the next step appearing,
    /// so the tick is seen rather than the screen simply changing under the user.
    private(set) var isAdvancing = false

    private let defaults: UserDefaults
    /// Whether a step's condition already holds. Injected, because the answer lives in
    /// `PermissionManager` and on disk, and the step logic should be testable without either.
    private let isSatisfied: (Step) -> Bool
    private var advanceTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, isSatisfied: @escaping (Step) -> Bool) {
        self.defaults = defaults
        self.isSatisfied = isSatisfied
        self.isComplete = defaults.bool(forKey: Key.completed)
    }

    // MARK: - Moving through

    /// Decides where to start. Called once, at launch.
    func begin() {
        guard !isComplete else { return }
        let first = Self.firstUnsatisfied(from: .language, isSatisfied)
        // Only the try-it step left means everything is already in place — the model is on
        // disk and both grants exist. There is nothing to set up, so nothing is shown.
        if first == .tryIt {
            finish()
            return
        }
        step = first
    }

    /// Moves to the next step whose condition isn't met yet, or finishes after the last.
    func advance() {
        advanceTask?.cancel()
        advanceTask = nil
        isAdvancing = false
        guard let next = step.next else {
            finish()
            return
        }
        // Try-it is never "satisfied", so this always lands on a step.
        step = Self.firstUnsatisfied(from: next, isSatisfied)
    }

    /// Checks the current step against the world and, if its condition now holds, moves on
    /// after a beat. Called from whatever notices a change — a returned system prompt, a
    /// poll — because neither permission announces itself.
    func noteProgress() {
        guard !isComplete, !isAdvancing, isSatisfied(step) else { return }
        isAdvancing = true
        advanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            self.advance()
        }
    }

    func finish() {
        advanceTask?.cancel()
        advanceTask = nil
        isAdvancing = false
        isComplete = true
        defaults.set(true, forKey: Key.completed)
    }

    private static func firstUnsatisfied(
        from start: Step, _ isSatisfied: (Step) -> Bool
    ) -> Step {
        var current = start
        while isSatisfied(current), let next = current.next {
            current = next
        }
        return current
    }
}
