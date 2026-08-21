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
    /// There is no separate hover state any more. It existed to ask which mode you wanted,
    /// and a button per mode answers that without a step — so reaching for the pill opens
    /// the controls directly.
    ///
    /// `armed` is still only reached by pointer: pressing the key means you have already
    /// decided, and showing a summary at that point would just delay the recording.
    enum Phase: Equatable {
        case resting
        case armed
        case dictating
        case meeting
        /// Transcribing, tidying, writing a note — one row, one label.
        case working(String)
        case failed(Failure)

        var isBusy: Bool {
            switch self {
            case .dictating, .meeting, .working: true
            case .resting, .armed, .failed: false
            }
        }

        /// What this state offers as a way out.
        ///
        /// Two buttons rather than one, because a single ✕ would have to mean "cancel" for
        /// a dictation and "hide, but keep recording" for a meeting — one control, two
        /// opposite outcomes, on states that look alike. Removing it entirely was the
        /// wrong correction: it left a meeting you could start from the panel but not
        /// stop from it.
        var controls: Controls {
            switch self {
            case .dictating:
                // Ten seconds of audio, so throwing away a fluffed sentence is cheap.
                Controls(stop: true, discard: true)
            case .meeting:
                // Stop only. Discarding forty minutes on one stray click of a floating
                // panel is not a risk worth offering; that lives in the window, where it
                // can ask first.
                Controls(stop: true, discard: false)
            case .armed, .failed:
                // Nothing was started, or it already ended — discard just dismisses.
                Controls(stop: false, discard: true)
            case .resting, .working:
                // Mid-transcription there is nothing useful to stop *into*.
                Controls()
            }
        }
    }

    struct Controls: Equatable {
        var stop = false
        var discard = false
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

    /// The key that starts a dictation, shown as a keycap. Nil when there isn't one, so
    /// the row does not claim a shortcut that will not fire.
    var hotkeyLabel: String?

    var promptName: String = "Default"
    var promptOptions: [(id: UUID, name: String)] = []

    /// True once the user has hidden it. The key still works and still opens the panel —
    /// a global hotkey that fires invisibly is a trap.
    private(set) var isHidden = false

    // MARK: - Actions, wired by the app

    /// Fired whenever the phase changes, because the phase determines `size` and the
    /// window has to follow it.
    ///
    /// Without this, hover changed the phase from inside the view — where nothing was
    /// listening — so a 132×84 cluster was laid out inside a window still 62×34. The
    /// buttons were pushed out of the bottom of it and over the Dock, which looked like a
    /// layout bug and was a plumbing one.
    var onPhaseChange: (@MainActor () -> Void)?

    var onToggleDictation: (@MainActor () -> Void)?
    var onToggleMeeting: (@MainActor () -> Void)?
    /// Finish properly: transcribe and insert, or write the note.
    var onStop: (@MainActor () -> Void)?
    /// Throw it away.
    var onDiscard: (@MainActor () -> Void)?
    var onPickPrompt: (@MainActor (NSPoint) -> Void)?

    // MARK: - Transitions

    func set(_ phase: Phase) {
        guard self.phase != phase else { return }
        // Anything that starts running un-hides the panel: you should never be recording
        // with no sign of it on screen.
        if phase.isBusy { isHidden = false }
        self.phase = phase
        onPhaseChange?()
    }

    /// Pointer arrived or left. Ignored while something is running — a hover is an offer,
    /// and there is nothing to offer mid-recording.
    func hover(_ isInside: Bool) {
        guard !phase.isBusy else { return }
        switch (phase, isInside) {
        case (.resting, true): set(.armed)
        case (.armed, false): set(.resting)
        default: break
        }
    }

    /// How far the Notes satellite sits outside the row, and how big it is. The window is
    /// widened by this on **both** sides so the row itself stays centred on the screen and
    /// the existing centring needs no special case — the spare width on the right is
    /// simply transparent.
    static let satelliteSize: CGFloat = 30
    static let satelliteGap: CGFloat = 9
    static var satelliteReach: CGFloat { satelliteSize + satelliteGap }

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
            // Tall enough to hold a capsule centred on the shared centre line, plus room
            // for its shadow.
            CGSize(width: 62, height: 34)
        case .armed:
            // The row, plus the satellite's reach mirrored on both sides.
            CGSize(width: 268 + Self.satelliteReach * 2, height: 48)
        case .dictating:
            preview.isEmpty
                ? CGSize(width: 330, height: 48)
                : CGSize(width: 452, height: 90)
        case .working:
            CGSize(width: 232, height: 48)
        case .meeting:
            CGSize(width: 368, height: 48)
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
