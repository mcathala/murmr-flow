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

    /// Whether the settings deck — output language, style — is docked to the top edge.
    ///
    /// They were two capsules floating above the pill, which made the panel a constellation
    /// of five separate objects and cost 24pt of empty headroom to hold them apart. Grown
    /// out of the row instead, it is one object with two decks.
    ///
    /// It stays through `working`, which is the correction: it used to leave exactly when
    /// the language and the style were being applied to your words, and to be present all
    /// through the recording, when nothing was using them yet.
    var showsShoulder: Bool {
        switch phase {
        case .armed, .dictating, .meeting, .working: true
        case .resting, .notice, .failed: false
        }
    }

    /// The language half of the deck. `Off` is a value like any other here; it costs no
    /// more room than a code does, now that the deck is one line rather than two capsules.
    var shoulderLanguage: String { translateOn ? translateCode : "Off" }

    /// The style half — and, when something other than your standing style chose it, what
    /// did. `Formal · Mail`.
    ///
    /// This used to be cut to fifteen characters and an ellipsis, because the settings
    /// floated over a pill whose width they could not influence. The row is sized from this
    /// string now, so there is nothing left to cut.
    var styleLabel: String {
        guard mode != .note, let detail = promptDetail else { return activePromptName }
        return "\(promptName) \u{00B7} \(detail)"
    }

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

    /// Which satellites are in orbit. The window is widened by their reach on **both**
    /// sides so the row itself stays centred on the screen; the spare width on a side with
    /// no satellite is simply transparent.
    ///
    /// The left one offers the job you are **not** set up for, so it only exists while you
    /// are choosing — and it must never repeat the glyph already in the row, or the pair
    /// reads as one control duplicated rather than two jobs to pick between.
    var showsModeSatellite: Bool { phase == .armed }

    /// The way out: a muted ✕ that puts the pill down, or — while something is running — a
    /// red ✕ that throws the work away.
    ///
    /// One glyph that sometimes dismissed and sometimes destroyed was the worst
    /// contradiction in the old panel. The glyph stays; the colour carries the difference,
    /// and the red one only fires if you hold it.
    var showsExitSatellite: Bool {
        switch phase {
        case .armed, .dictating, .meeting: true
        case .resting, .working, .notice, .failed: false
        }
    }

    var exitDestroys: Bool {
        switch phase {
        case .dictating, .meeting: true
        default: false
        }
    }

    /// How long a message stays before clearing itself.
    ///
    /// A notice and a failure are both *only a message*, so neither carries a control: the
    /// row itself is the dismiss and a hairline drains to show it is leaving. That drain is
    /// drawn from these values, so the countdown cannot disagree with the timer that
    /// actually fires.
    static let noticeDuration: TimeInterval = 2
    /// Longer, because a failure has to be read and not merely noticed.
    static let failureDuration: TimeInterval = 6

    static func dismissal(for phase: Phase) -> TimeInterval? {
        switch phase {
        case .notice: noticeDuration
        case .failed: failureDuration
        default: nil
        }
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

    /// The panel is sized from its state rather than laid out to a fixed frame, so it grows
    /// and shrinks between states instead of swapping content inside a box.
    ///
    /// Every width here is **measured, not chosen**. The armed row used to be a hard-coded
    /// 240pt holding 143pt of content, and the 97pt of nothing between the keycap and the
    /// start button was not a spacing mistake — it was this number. Nothing is hard-coded
    /// now: a keycap reading `right ⌥` sizes the row differently from one reading `fn`,
    /// because it is a different width, and only the font knows by how much.
    var size: CGSize {
        var size = CGSize(width: rowWidth, height: PanelLayout.rowHeight)

        if case .resting = phase {
            // Tall enough to hold the lozenge centred on the shared centre line, and wide
            // enough to be a hover target rather than a hairline.
            return CGSize(width: 62, height: 34)
        }

        // The deck is docked above the row, so it is window height, not row height.
        if showsShoulder { size.height += PanelLayout.shoulder }
        // Mirrored on both sides, so the row stays centred on the screen whichever
        // satellites are out.
        size.width += PanelLayout.satelliteReach * 2
        // Whole points, because a window is measured in them. The mark's width comes from
        // its own grid — five bars of 90 on a box of 610 — which lands on fractions, and
        // AppKit rounds the frame it is given. Rounding here instead keeps the size the
        // model reports and the size the window actually takes the same number.
        size.width.round(.up)
        size.height.round(.up)
        return size
    }

    /// The pill itself, without the deck's headroom. The row is laid out to this rather
    /// than to the window: filling the window made the capsule grow taller whenever the
    /// deck appeared, swallowing the space it was supposed to occupy.
    var rowHeight: CGFloat {
        phase == .resting ? 5 : PanelLayout.rowHeight
    }

    /// The capsule's own width — its contents, or the deck docked to it, whichever is
    /// wider.
    ///
    /// The deck setting the floor is what finally fixed the truncation: `promptLabel` used
    /// to clip the style to fifteen characters because the settings floated over a pill
    /// whose width they could not influence. A layout problem solved with a substring. The
    /// row grows to meet the deck instead, so nothing is cut and no label lies.
    var rowWidth: CGFloat {
        var width = contentWidth
        if showsShoulder {
            width = max(width, shoulderWidth + PanelLayout.shoulderClearance)
        }
        return width.rounded(.up)
    }

    private var contentWidth: CGFloat {
        let slot = PanelLayout.slot
        let group = PanelLayout.groupGap

        switch phase {
        case .resting:
            return 44

        case .armed where mode == .note:
            // A note goes to a *folder*, not to a focused app — so the well holds where it
            // lands and which key fires it, and never an app icon that does not exist.
            return PanelLayout.row([
                slot,
                PanelLayout.well(icon: true, cap: meetingHotkeyLabel),
                slot,
            ])

        case .armed:
            return PanelLayout.row([
                slot,
                PanelLayout.well(icon: targetAppIcon != nil, cap: hotkeyLabel),
                slot,
            ])

        case .dictating:
            // The mic has gone and the well has taken its slot: you already know which job
            // is running, and the row would rather show you it can hear you.
            return PanelLayout.row([
                PanelLayout.well(icon: targetAppIcon != nil, cap: hotkeyLabel),
                PanelLayout.markWidth(PanelLayout.markHeight),
                PanelLayout.mono(clock, size: 12),
                slot,
            ])

        case .meeting:
            // No mode icon and no record dot: the red ring already says recording, and you
            // do not need telling you are in a meeting while watching two people's voices
            // move. What is left is the only four things it has to say.
            return PanelLayout.row([
                PanelLayout.mono(clock, size: 12),
                meterWidth("You") + group,
                meterWidth("Them") + group,
                slot + group,
            ])

        case .working(let label):
            return PanelLayout.row([
                PanelLayout.markWidth(PanelLayout.workingMarkHeight),
                PanelLayout.body(label),
            ])

        case .notice(let text):
            return PanelLayout.row(
                [PanelLayout.markWidth(PanelLayout.markHeight), PanelLayout.body(text)],
                pad: PanelLayout.messagePad
            )

        case .failed(let failure):
            return PanelLayout.row(
                [
                    PanelLayout.markWidth(PanelLayout.markHeight),
                    PanelLayout.body(failure.headline, size: 12, weight: .semibold),
                ],
                pad: PanelLayout.messagePad
            )
        }
    }

    /// A meter is as wide as its bars or its name, whichever needs more.
    private func meterWidth(_ label: String) -> CGFloat {
        max(PanelLayout.markWidth(PanelLayout.meterHeight), PanelLayout.label(label))
    }

    private var shoulderWidth: CGFloat {
        PanelLayout.shoulderPad * 2
            + PanelLayout.label(shoulderLanguage)
            + PanelLayout.shoulderGap * 2 + 1
            + PanelLayout.label(styleLabel)
    }

    /// `0:04`, and `12:04` once a meeting runs long.
    var clock: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
