import AppKit
import Foundation
import Observation

/// Everything the floating panel shows, and everything it can ask for.
///
/// The panel knows nothing about coordinators; the app wires the closures. That keeps a
/// window out of the dictation logic and lets the whole thing be reasoned about as a
/// state machine, which is what it is.
@MainActor
@Observable
final class PanelModel {

    /// Which of the two jobs the panel is offering.
    enum Mode: Equatable {
        case dictation
        case note
    }

    /// The panel's shape. Ordered roughly as you meet them.
    ///
    /// `armed` exists only on the pointer route: pressing the key means you have already
    /// decided, and showing a summary at that point would just delay the recording.
    enum Phase: Equatable {
        case resting
        case hovering
        case armed
        case dictating
        case meeting
        /// Transcribing, tidying, writing a note — one row, one label.
        case working(String)
        case failed(Failure)

        var isBusy: Bool {
            switch self {
            case .dictating, .meeting, .working: true
            case .resting, .hovering, .armed, .failed: false
            }
        }

        /// While something is running, there is no ✕. It would have to mean "cancel" for
        /// a dictation and "hide, but keep recording" for a meeting — one button, two
        /// opposite outcomes, on states that look alike. Stopping is the way out.
        var allowsClose: Bool {
            switch self {
            case .armed, .failed: true
            default: false
            }
        }
    }

    /// The whole failure vocabulary. Which half broke is all you need in the moment; the
    /// detail belongs on Home, where there is room for it.
    enum Failure: Equatable {
        case transcription
        case cleanup

        var message: String {
            switch self {
            case .transcription: "Voice transcription failed"
            case .cleanup: "AI clean-up failed"
            }
        }
    }

    // MARK: - State

    private(set) var phase: Phase = .resting
    var mode: Mode = .dictation

    var elapsed: TimeInterval = 0
    var micLevel: Float = 0
    var youLevel: Float = 0
    var themLevel: Float = 0

    /// Words as they are recognised. Empty until the first pass lands.
    var preview: String = ""

    /// Where the text will go. Knowing this *before* speaking is the point — otherwise
    /// you find out afterwards, from the wrong window.
    var targetAppName: String?
    var targetAppIcon: NSImage?

    var promptName: String = "Default"
    var promptOptions: [(id: UUID, name: String)] = []

    /// True once the user has hidden it. The key still works and still opens the panel —
    /// a global hotkey that fires invisibly is a trap.
    private(set) var isHidden = false

    // MARK: - Actions, wired by the app

    var onToggleDictation: (@MainActor () -> Void)?
    var onToggleMeeting: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?
    var onPickPrompt: (@MainActor (NSPoint) -> Void)?

    // MARK: - Transitions

    func set(_ phase: Phase) {
        guard self.phase != phase else { return }
        // Anything that starts running un-hides the panel: you should never be recording
        // with no sign of it on screen.
        if phase.isBusy { isHidden = false }
        self.phase = phase
    }

    /// Pointer arrived or left. Ignored while something is running — a hover is an offer,
    /// and there is nothing to offer mid-recording.
    func hover(_ isInside: Bool) {
        guard !phase.isBusy else { return }
        switch (phase, isInside) {
        case (.resting, true): set(.hovering)
        case (.hovering, false): set(.resting)
        case (.armed, false): set(.resting)
        default: break
        }
    }

    /// Pointer moved onto the dictate button: show what is about to happen.
    func armIfHovering() {
        if phase == .hovering { set(.armed) }
    }

    func hide() {
        guard !phase.isBusy else { return }
        isHidden = true
        set(.resting)
    }

    func reveal() {
        isHidden = false
    }

    // MARK: - Geometry

    /// The panel is sized from its state rather than laid out to a fixed frame, so it
    /// grows and shrinks between states instead of swapping content inside a box.
    var size: CGSize {
        switch phase {
        case .resting:
            CGSize(width: 62, height: 18)
        case .hovering:
            // Width fits the longest tooltip ("Start meeting"), not the two buttons alone
            // — at 116 the label was squeezed, which pulled the cluster off centre.
            //
            // Height is the stack read bottom-up: 5 pill inset + 5 pill + 10 gap +
            // 34 buttons + 7 gap + 24 tooltip = 85, plus a little slack. The pill's own
            // position is unchanged, so opening the cluster only adds height upward.
            CGSize(width: 132, height: 92)
        case .armed:
            CGSize(width: 272, height: 48)
        case .dictating:
            preview.isEmpty
                ? CGSize(width: 272, height: 48)
                : CGSize(width: 412, height: 90)
        case .working:
            CGSize(width: 232, height: 48)
        case .meeting:
            CGSize(width: 336, height: 48)
        case .failed:
            CGSize(width: 268, height: 48)
        }
    }

    /// `0:04`, and `12:04` once a meeting runs long.
    var clock: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
