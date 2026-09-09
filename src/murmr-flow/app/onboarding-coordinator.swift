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
        //
        // The AI comes right before the proof: "Try it" is the first dictation, and a
        // dictation without the AI is the raw one. Two of the cases are a branch rather
        // than steps — `withoutAI` is the pause shown to someone who skips the AI, and
        // `microphone` is what replaces Try it when they skip it twice, so the one
        // permission the app cannot live without is still asked for.
        case language, underTheHood, howItWorks, systemAudio, style, connectAI, withoutAI,
             tryIt, microphone

        var number: Int { rawValue + 1 }

        /// The steps that change something on the machine. The rest explain or prove, and
        /// have no condition that could already hold.
        ///
        /// The AI is not one of them, on purpose: a machine with the model and every grant
        /// runs the app, and a missing provider is Home's warning row to make, not a
        /// reason to walk someone through six pages again. Nor is the microphone page:
        /// Try it already stands for that grant, and this page only ever replaces it.
        var isSetup: Bool {
            switch self {
            case .language, .howItWorks, .systemAudio, .tryIt: true
            case .underTheHood, .style, .connectAI, .withoutAI, .microphone: false
            }
        }

        /// Whether the step is left out once its condition holds. Only the system-audio
        /// ask is. The language question is about the person, not the download; the two
        /// teaching pages carry their permission as a card on the way through — a granted
        /// microphone doesn't make "What's inside" less worth reading — and the AI page
        /// stays even when a provider already works, because seeing "Working" beside the
        /// one you will be using is the point of the page, and because a working key is
        /// not always the one you want.
        var skipsWhenSatisfied: Bool { self == .systemAudio }

        /// Only reached by declining the AI, never by walking forward.
        var isBranch: Bool { self == .withoutAI || self == .microphone }

        /// Whether the step counts towards "Step x of y". The pause after a skip shares
        /// the number of the page it interrupts: it is a question about that page, not a
        /// page of its own.
        var isCounted: Bool { self != .withoutAI }
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
    private(set) var plan: [Step] = Step.allCases.filter { !$0.isBranch }

    /// "Step 1 of 5" — this step's place among the ones actually shown. The uncounted
    /// pause reports the number of the page before it.
    var position: Int {
        let index = plan.firstIndex(of: step) ?? 0
        return plan[...index].filter(\.isCounted).count
    }
    var total: Int { plan.filter(\.isCounted).count }

    /// Whether the AI was declined, once or twice. The view reads it to word the last
    /// pages honestly: a Try it reached this way has no clean-up to show off.
    var declinedAI: Bool { plan.contains(.withoutAI) || plan.contains(.microphone) }

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
        plan = Step.allCases.filter {
            !$0.isBranch && (!$0.skipsWhenSatisfied || !isSatisfied($0))
        }
        step = plan[0]
    }

    // MARK: - Declining the AI

    /// "Skip for now" on the AI page. Not a skip yet: one page says what it costs and
    /// asks once more, with the same number as the page it interrupts.
    func declineAI() {
        guard step == .connectAI, let index = plan.firstIndex(of: .connectAI) else { return }
        cancelAdvance()
        if !plan.contains(.withoutAI) { plan.insert(.withoutAI, at: index + 1) }
        step = .withoutAI
    }

    /// The second no. Try it goes — a first dictation with nothing to polish it is not
    /// the proof the page promises — and the microphone, which Try it was carrying, gets
    /// a page of its own so the app can still hear. Already granted, that page drops out
    /// too and the flow finishes.
    func continueWithoutAI() {
        guard step == .withoutAI else { return }
        cancelAdvance()
        if let index = plan.firstIndex(of: .tryIt) {
            plan[index] = .microphone
        }
        plan.removeAll { $0 == .microphone && isSatisfied(.microphone) }
        advance()
    }

    /// Moves to the next step whose condition isn't met yet, or finishes after the last.
    func advance() {
        cancelAdvance()
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
    ///
    /// The one exception is the pause after declining the AI: leaving it backwards *is*
    /// undoing the decline, so the pause leaves the plan with you.
    func back() {
        cancelAdvance()
        guard let index = plan.firstIndex(of: step), index > 0 else { return }
        let previous = plan[index - 1]
        if step == .withoutAI { plan.remove(at: index) }
        step = previous
    }

    private func cancelAdvance() {
        advanceTask?.cancel()
        advanceTask = nil
        isAdvancing = false
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
