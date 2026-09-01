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
        // Declaration order is flow order. Each permission is asked on the page that
        // explains the thing that uses it: the microphone lives on "What's inside"
        // (speech-to-text is what needs it), Accessibility lives on "How it works"
        // (the keys are what it powers), and system audio keeps a small page of its
        // own right after — Apple's scariest dialog earns its own beat.
        case language, underTheHood, howItWorks, systemAudio, style, tryIt

        var number: Int { rawValue + 1 }

        /// The steps that change something on the machine. The rest explain or prove, and
        /// have no condition that could already hold.
        var isSetup: Bool {
            switch self {
            case .language, .howItWorks, .systemAudio, .tryIt: true
            case .underTheHood, .style: false
            }
        }

        /// Whether the step is left out once its condition holds. Only the system-audio
        /// ask is: the language question is about the person, not the download, and the
        /// two teaching pages carry their permission as a card on the way through — a
        /// granted microphone doesn't make "What's inside" less worth reading.
        var skipsWhenSatisfied: Bool { self == .systemAudio }
    }

    /// Where completion is recorded. Public because `SettingsStore` reads it too: it is
    /// the one mark that tells an install that existed before a default changed from a
    /// fresh one.
    nonisolated static let completedDefaultsKey = "onboarding.completed"

    private enum Key {
        static let completed = OnboardingCoordinator.completedDefaultsKey
    }

    private(set) var isComplete: Bool
    private(set) var step: Step = .language

    /// The steps this run will show, in order — everything not already satisfied when it
    /// began. Numbering comes from here, not from `Step`: a first page that read "Step 2 of
    /// 6" because the model happened to be on disk already made the flow look broken.
    private(set) var plan: [Step] = Step.allCases

    /// "Step 1 of 5" — this step's place among the ones actually shown.
    var position: Int { (plan.firstIndex(of: step) ?? 0) + 1 }
    var total: Int { plan.count }

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
        // Everything already in place — the model on disk, both grants made — means there
        // is nothing to set up, so nothing is shown; the explanatory pages are for someone
        // meeting the app for the first time, not for a machine that already runs it.
        if Step.allCases.filter(\.isSetup).allSatisfy(isSatisfied) {
            finish()
            return
        }
        plan = Step.allCases.filter { !$0.skipsWhenSatisfied || !isSatisfied($0) }
        step = plan[0]
    }

    /// Moves to the next step whose condition isn't met yet, or finishes after the last.
    func advance() {
        advanceTask?.cancel()
        advanceTask = nil
        isAdvancing = false
        // A step planned but since satisfied — a grant made from elsewhere while the flow
        // was on an earlier page — drops out, so the count stays honest.
        plan.removeAll { $0.rawValue > step.rawValue && $0.skipsWhenSatisfied && isSatisfied($0) }
        guard let index = plan.firstIndex(of: step), index + 1 < plan.count else {
            finish()
            return
        }
        step = plan[index + 1]
    }

    /// One step towards the door. Anything that was decided stays decided — going back is
    /// for re-reading a page, not for undoing — and a satisfied permission step simply
    /// shows its tick and a Continue.
    func back() {
        advanceTask?.cancel()
        advanceTask = nil
        isAdvancing = false
        guard let index = plan.firstIndex(of: step), index > 0 else { return }
        step = plan[index - 1]
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
}
