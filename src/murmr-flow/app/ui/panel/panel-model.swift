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
        /// Something worth a sentence that is not a fault — nothing was heard, say. Quiet,
        /// and gone by itself a moment later; the bridge clears it.
        case notice(String)
        case failed(Failure)

        var isBusy: Bool {
            switch self {
            case .dictating, .meeting, .working: true
            case .resting, .armed, .notice, .failed: false
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
            case .resting, .working, .notice:
                // Mid-transcription there is nothing useful to stop *into*; a notice
                // leaves on its own.
                Controls()
            }
        }
    }

    struct Controls: Equatable {
        var stop = false
        var discard = false
    }

    /// Which part broke — `FailureKind`, decided by the coordinator that saw it happen. The
    /// pill only turns the kind into words; it never reads the message.
    typealias Failure = FailureKind

    // MARK: - State

    private(set) var phase: Phase = .resting
    var mode: Mode = .dictation

    var elapsed: TimeInterval = 0
    var micLevel: Float = 0
    var youLevel: Float = 0
    var themLevel: Float = 0

    /// Where the text will go. Knowing this *before* speaking is the point — otherwise
    /// you find out afterwards, from the wrong window.
    var targetAppName: String?
    var targetAppIcon: NSImage?
    /// The app's bundle id, which is what a per-app style rule is keyed by. Kept beside
    /// the name because the row has to resolve the style *before* you speak, and a name is
    /// not something a rule can be looked up by.
    var targetBundleID: String?

    /// The key that starts a dictation, shown as a keycap. Nil when there isn't one, so
    /// the row does not claim a shortcut that will not fire.
    var hotkeyLabel: String?

    var promptName: String = "Default"
    /// Why that style and not the standing one — the app whose rule chose it, or the key
    /// that was held. Nil when nothing overrode the standing style, which is when there is
    /// nothing worth saying.
    var promptDetail: String?
    var notePromptName: String = "Meeting"

    /// The style the pill is actually about, which depends on which job it is showing.
    /// The menu ticked `promptName` regardless, so in note mode it put the checkmark
    /// beside the dictation style while the bubble named the Notetaker's.
    var activePromptName: String { mode == .note ? notePromptName : promptName }
    var promptOptions: [(id: UUID, name: String)] = []

    /// The meeting key, for the note-armed row. Nil reads as "no key set".
    var meetingHotkeyLabel: String?

    /// Whether the watcher behind those keys is actually running. The keys stay visible
    /// either way — a blank where the bind should be reads as a bug — but an unarmed one
    /// is dimmed, and says why.
    var hotkeyArmed = false

    /// The *active job's* output language — the bridge refills these when the mode
    /// flips — as the chip and bubble show it ("EN"), plus the full name for tooltips,
    /// and whether it currently applies. The language itself is chosen in the window;
    /// the pill only flips it on and off.
    var translateCode: String = "EN"
    var translateLanguage: String = "English"
    var translateOn = false

    /// Whether the two bubbles — 文A language, ✦ style — ride the top edge. They are the
    /// job's *settings*, floated above the row so the row keeps only facts and actions,
    /// and so the settings stay visible mid-recording, which is exactly when "is this
    /// coming out in English?" matters.
    var showsBubbles: Bool {
        switch phase {
        case .armed, .dictating, .meeting: true
        case .resting, .working, .notice, .failed: false
        }
    }

    /// Height the bubble needs above the row.
    static let bubbleReach: CGFloat = 24

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
    var onToggleTranslate: (@MainActor () -> Void)?

    /// Which job the armed row offers. Flipped by the satellites; remembering it across
    /// a hover is deliberate — the row you left is the row you get back.
    func arm(_ mode: Mode) {
        self.mode = mode
        set(.armed)
    }

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
        var size: CGSize = switch phase {
        case .resting:
            // Tall enough to hold a capsule centred on the shared centre line, plus room
            // for its shadow.
            CGSize(width: 62, height: 34)
        case .armed:
            // The row, plus the satellite's reach mirrored on both sides. Slim: with the
            // two settings in orbit above, the row only holds facts and the start button.
            CGSize(width: 240 + Self.satelliteReach * 2, height: 48)
        case .dictating:
            // Content-hugging: icon, app, waveform, clock, two controls, no dead middle.
            CGSize(width: 250, height: 48)
        case .working:
            CGSize(width: 232, height: 48)
        case .meeting:
            CGSize(width: 368, height: 48)
        case .notice:
            CGSize(width: 200, height: 48)
        case .failed(let failure):
            // The message and the way out — the two-word failure needs no mode icon.
            CGSize(width: failure.pillWidth, height: 48)
        }
        // The bubbles ride above the row, so they are window height, not row height.
        if showsBubbles { size.height += Self.bubbleReach }
        return size
    }

    /// The pill itself, without the bubbles' headroom. The row must be laid out to this,
    /// not to the window: filling the window made the capsule grow taller whenever the
    /// bubbles appeared, swallowing the space they were supposed to float in.
    var rowHeight: CGFloat {
        size.height - (showsBubbles ? Self.bubbleReach : 0)
    }

    /// `0:04`, and `12:04` once a meeting runs long.
    var clock: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
