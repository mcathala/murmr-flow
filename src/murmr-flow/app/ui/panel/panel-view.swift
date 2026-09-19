import SwiftUI

/// The floating panel's contents.
///
/// **One row of parts that move, not seven pictures that swap.** Every state used to build
/// its own `HStack` from scratch, so starting a dictation replaced the whole row at once —
/// which is why it could only ever cross-fade. The parts are declared once here and shown
/// or hidden per phase, so the ones that survive a transition keep their identity and
/// *slide*: press start and the mic leaves, the target well travels into its slot, and the
/// clock opens in the gap behind it.
///
/// Two rules hold the rest of it together. **The ring is the only thing you press** — it
/// changes what it holds rather than being replaced. **The mark is the only thing that
/// reports** — sound, work and silence, never a spinner or a generic bar.
struct PanelView: View {

    @Bindable var model: PanelModel

    /// One curve for the whole panel, and it does **not** overshoot.
    ///
    /// The prototype's water-drop spring bounced 8% past its target, which a window cannot
    /// do: the panel is exactly the size of its contents, so everything the bounce pushes
    /// past the edge is clipped flat by the window's backing store. The pill appeared to
    /// squash against its own frame on every transition.
    ///
    /// The window animates to the same curve over the same duration — see
    /// `FloatingPanel.apply()`. That is the part that was actually wrong: the frame used to
    /// snap to its new size while the contents eased into it, so the glass arrived before
    /// the things inside it.
    static let duration: Double = 0.32
    static let drop = Animation.smooth(duration: duration)

    /// Drives the red ring's pulse while something is recording.
    @State private var breath = false
    /// How far round the hold-to-destroy arc has travelled, 0…1.
    @State private var hold: CGFloat = 0
    @State private var holdTask: Task<Void, Never>?
    /// The message countdown, draining left to right.
    @State private var drain: CGFloat = 1

    var body: some View {
        // Bottom-aligned, because the panel grows upward from where it rests. The
        // `Color.clear` is what gives the stack the whole window to align within —
        // without it the stack shrinks to its content and there is nothing to centre
        // against.
        ZStack(alignment: .bottom) {
            Color.clear
            if model.phase == .resting { resting } else { open }
        }
        // The animations go **inside** the frame, and the frame is not one of them.
        //
        // Attached outside, they animated `model.size` too — so the window snapped to its
        // new size while this box eased there over a third of a second, and for that third
        // the contents were laid out in a small box floating inside a large window. That
        // is the resting lozenge appearing up beside the deck: not a stray view, the right
        // view in a box that had not caught up.
        //
        // The window owns the size and takes it in one step. Everything in here moves
        // within a frame that is already correct.
        //
        // And coming out of rest does not move at all — see `animatesTransition`. The
        // lozenge and the row have no parts in common, so there was nothing being carried
        // across and the tween only drew attention to itself.
        .animation(model.animatesTransition ? Self.drop : nil, value: model.phase)
        .animation(Self.drop, value: model.mode)
        .frame(width: model.size.width, height: model.size.height)
        // The whole window, including the transparent margin the satellites orbit in.
        // Without it, moving the pointer from the row toward a satellite leaves the pill
        // and collapses it mid-reach.
        .contentShape(.rect)
        .onHover { model.hover($0) }
    }

    // MARK: - The centre line

    /// Distance from the window's bottom edge to the line the pill and the satellites
    /// **share**.
    ///
    /// This is the whole geometry of the collapsed state in one number. Both are centred on
    /// it, so hovering swaps a 5pt capsule for a 28pt button in the same place rather than
    /// stacking one above the other. Stacking was the bug: the buttons ended up in the
    /// strip between the pill and the Dock, and at full height they reached into it.
    static let centreLine: CGFloat = 24

    // MARK: - Resting

    /// Deliberately almost nothing. If you are not reaching for it, it should not be asking
    /// for attention.
    ///
    /// It stays muted whatever the settings are. Lighting it gold when translate was left
    /// on was a way of answering "why is this coming out in English?" a moment earlier —
    /// but it spends the resting state's whole job to do it. A 44×5 bar glowing at the
    /// bottom of the screen is not discreet, and this state exists to be ignored. The deck
    /// says it the moment you reach for the pill, which is soon enough.
    private var resting: some View {
        Capsule()
            .fill(Theme.Palette.muted.opacity(0.5))
            .frame(width: 44, height: 5)
            .overlay(Capsule().fill(Theme.Palette.rim).frame(height: 1), alignment: .top)
            .padding(.bottom, Self.centreLine - 2.5)
    }

    // MARK: - Open

    private var open: some View {
        VStack(spacing: 0) {
            if model.showsShoulder { shoulder }
            row
        }
    }

    /// The settings deck, grown out of the pill's top edge rather than floating above it.
    ///
    /// It extends 4pt *under* the row and is drawn first, so the row's own glass covers its
    /// lower corners — which is what makes the two read as one object with two decks rather
    /// than as a capsule with a tab balanced on it.
    private var shoulder: some View {
        HStack(spacing: PanelLayout.shoulderGap) {
            deckButton(model.shoulderLanguage, lit: model.translateOn, help: translateHelp) {
                model.onToggleTranslate?()
            }
            Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 8)
            deckButton(model.styleLabel, lit: model.promptDetail != nil, help: styleHelp) {
                model.onPickPrompt?(NSEvent.mouseLocation)
            }
        }
        .padding(.horizontal, PanelLayout.shoulderPad)
        // The nudge goes *inside* the frame. Outside it, the 3pt was added to the deck's
        // height after the model had already sized the window from `PanelLayout.shoulder`,
        // so the panel came to 59pt in a 56pt window — and since the stack is bottom
        // aligned, the 3pt that had nowhere to go was taken off the top of the deck.
        .padding(.top, 2)
        .frame(height: PanelLayout.shoulder + 4, alignment: .top)
        .glass(.floating, radius: 9, elevated: false)
        .padding(.bottom, -4)
        .zIndex(-1)
    }

    private func deckButton(
        _ text: String, lit: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(text)
                .font(Theme.Text.label)
                .tracking(Theme.labelTracking)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .foregroundStyle(lit ? Theme.Palette.gold : Theme.Palette.muted)
        .help(help)
    }

    private var translateHelp: String {
        model.translateOn
            ? "Coming out in \(model.translateLanguage) — click to turn off"
            : "Click to translate to \(model.translateLanguage)"
    }

    private var styleHelp: String {
        guard model.mode != .note, let detail = model.promptDetail else {
            return "Style — click to change"
        }
        return "\(model.promptName), because of \(detail) — click to change"
    }

    // MARK: - The row

    /// The chrome every open state shares, with the satellites in orbit around it.
    ///
    /// `elevated: false` is load-bearing, not a preference. The window is exactly the size
    /// of its contents, so a shadow drawn *inside* it spreads into the transparent margins
    /// and is cut flat at the frame — a window's backing store ends there. That clip was
    /// the hard-edged rectangle around the pill.
    private var row: some View {
        contents
            .padding(.horizontal, shows.messagePadding
                ? PanelLayout.messagePad : PanelLayout.pad)
            .frame(width: model.rowWidth, height: model.rowHeight)
            .glass(.floating, radius: model.rowHeight / 2, elevated: false)
            .overlay(alignment: .bottom) { countdown }
            .contentShape(.rect)
            .onTapGesture { if shows.dismissOnTap { model.onDiscard?() } }
            .overlay(alignment: .leading) {
                if model.showsModeSatellite {
                    modeSatellite.offset(x: -PanelLayout.satelliteReach)
                }
            }
            .overlay(alignment: .trailing) {
                if model.showsExitSatellite {
                    exitSatellite.offset(x: PanelLayout.satelliteReach)
                }
            }
    }

    /// Every part the row can hold, in one order that serves all of them — which is what
    /// lets a part survive a phase change instead of being rebuilt.
    private var contents: some View {
        HStack(spacing: PanelLayout.gap) {
            if shows.modeDisc { modeDisc }
            if shows.well { well }
            if let motion = markMotion {
                MarkBars(motion: motion, height: markHeight, tint: markTint)
            }
            if let message = messageText { messageLabel(message) }
            if shows.clock { clock }
            if shows.meters {
                meter("You", level: model.youLevel, tint: Theme.Palette.gold)
                    .padding(.leading, PanelLayout.groupGap)
                meter("Them", level: model.themLevel, tint: Theme.Palette.tide)
                    .padding(.leading, PanelLayout.groupGap)
            }
            if shows.ring {
                ring.padding(.leading, shows.meters ? PanelLayout.groupGap : 0)
            }
        }
    }

    // MARK: - What each phase shows

    private struct Parts {
        var modeDisc = false
        var well = false
        var clock = false
        var meters = false
        var ring = false
        var messagePadding = false
        var dismissOnTap = false
    }

    private var shows: Parts {
        switch model.phase {
        case .resting:
            Parts()
        case .armed:
            Parts(modeDisc: true, well: true, ring: true)
        case .dictating:
            // The mic has gone: you know which job is running, and its slot is better spent
            // on the target the words are about to land in.
            Parts(well: true, clock: true, ring: true)
        case .meeting:
            // No mode icon, no record dot. The red ring already says recording, and two
            // people's voices moving says meeting more plainly than an icon does.
            Parts(clock: true, meters: true, ring: true)
        case .working:
            Parts()
        case .notice, .failed:
            // Only a message, so no control at all: the countdown says it is leaving and
            // the row itself is the dismiss.
            Parts(messagePadding: true, dismissOnTap: true)
        }
    }

    // MARK: - Parts

    /// Which job is armed. A label, not a control — so it is muted, with only a trace of
    /// gold on its rim. Lighting it made the row two primaries and no answer to "what do I
    /// press".
    private var modeDisc: some View {
        Image(systemName: model.mode == .note ? "text.document" : "mic.fill")
            .font(.system(size: 12, weight: .medium))
            .frame(width: PanelLayout.slot, height: PanelLayout.slot)
            .background(Color.white.opacity(0.06), in: .circle)
            .overlay(Circle().stroke(Theme.Palette.gold.opacity(0.17), lineWidth: 1))
            .foregroundStyle(Theme.Palette.text.opacity(0.85))
    }

    /// What the row *knows*: where this lands, and which key fires it. Recessed, because
    /// nothing in here is pressable — raised is pressed, sunken is read — and the key is
    /// set in gold, since it is the thing that starts the job.
    private var well: some View {
        HStack(spacing: PanelLayout.wellGap) {
            if model.mode == .note {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: PanelLayout.wellIcon, height: PanelLayout.wellIcon)
                    .foregroundStyle(Theme.Palette.muted)
                    .help("Saved to your notes folder")
            } else if let icon = model.targetAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: PanelLayout.wellIcon, height: PanelLayout.wellIcon)
                    .help(model.targetAppName ?? "")
            }
            if let label = model.mode == .note ? model.meetingHotkeyLabel : model.hotkeyLabel {
                Text(label)
                    .font(Theme.Text.mono)
                    // The row is sized from this string's measured width, so it must be
                    // allowed to take it. Without this a two-word key like `right ⌥` wraps
                    // to two lines inside a slot one line tall.
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Theme.Palette.gold)
                    .opacity(model.hotkeyArmed ? 1 : 0.45)
                    .help(
                        model.hotkeyArmed
                            ? ""
                            : "The key won\u{2019}t fire until Accessibility is granted"
                    )
            }
        }
        .padding(.horizontal, PanelLayout.wellPad)
        .frame(height: PanelLayout.slot)
        .background(
            Theme.Palette.abyss.opacity(0.5),
            in: .rect(cornerRadius: PanelLayout.wellRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PanelLayout.wellRadius)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private var clock: some View {
        Text(model.clock)
            .font(Theme.Text.monoLarge)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.Palette.text)
    }

    /// One speaker, drawn as the mark rather than as a track. The label sits **under** the
    /// bars: on top it was the highest thing in the row and crowded the seam the deck docks
    /// to.
    private func meter(_ name: String, level: Float, tint: Color) -> some View {
        VStack(spacing: 2) {
            MarkBars(motion: .level(level), height: PanelLayout.meterHeight, tint: tint)
            Text(name)
                .font(Theme.Text.label)
                .tracking(Theme.labelTracking)
                .foregroundStyle(Theme.Palette.faint)
        }
    }

    private func messageLabel(_ text: String) -> some View {
        Text(text)
            .font(isFailure ? Theme.Text.bodyStrong : Theme.Text.small)
            // A fault spends no colour. Red is for what is live or about to be lost, and a
            // failure is neither — the words carry it, and the mark lies flat beside them.
            .foregroundStyle(isFailure ? Theme.Palette.text : Theme.Palette.muted)
            .lineLimit(1)
            .fixedSize()
    }

    /// The one thing you press. It is never replaced, only reloaded: play to start, a red
    /// square to stop. Outlined rather than filled, so the gold is a drawn line rather than
    /// a mass sitting on the glass.
    private var ring: some View {
        Button(action: primaryAction) {
            ZStack {
                Circle().fill(Theme.Palette.abyss.opacity(0.55))
                Circle().stroke(ringTint, lineWidth: 1.5)
                Image(systemName: isRecording ? "stop.fill" : "play.fill")
                    .font(.system(size: isRecording ? 10 : 11, weight: .bold))
                    // A triangle centred on its bounding box always looks left of centre.
                    .offset(x: isRecording ? 0 : 0.5)
            }
            .frame(width: PanelLayout.slot, height: PanelLayout.slot)
            .foregroundStyle(ringTint)
            .shadow(
                color: ringTint.opacity(isRecording ? (breath ? 0.5 : 0.16) : 0.26),
                radius: isRecording ? 7 : 5
            )
        }
        .buttonStyle(.plain)
        .help(ringHelp)
        .task(id: isRecording) {
            guard isRecording else {
                breath = false
                return
            }
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                breath = true
            }
        }
    }

    private func primaryAction() {
        switch model.phase {
        case .dictating, .meeting:
            model.onStop?()
        default:
            if model.mode == .note { model.onToggleMeeting?() } else { model.onToggleDictation?() }
        }
    }

    private var ringHelp: String {
        if isRecording { return "Stop" }
        return model.mode == .note ? "Start recording the meeting" : "Start dictating"
    }

    // MARK: - Orbit

    /// Offers the job you are **not** set up for. It must never repeat the glyph already in
    /// the row, or the pair reads as one control duplicated rather than two jobs to choose
    /// between.
    private var modeSatellite: some View {
        satellite(
            model.mode == .note ? "mic.fill" : "text.document",
            tint: Theme.Palette.muted,
            help: model.mode == .note ? "Set up a dictation" : "Set up the Notetaker"
        ) {
            model.arm(model.mode == .note ? .dictation : .note)
        }
    }

    /// ✕ puts the pill down. The same ✕ in red throws the work away — and the red one only
    /// fires if you hold it, whether that work is ten seconds or forty minutes.
    ///
    /// A bin was the wrong correction: it read as a different *control* when the action is
    /// the same one, just costlier. And a hold is the only confirmation a floating panel can
    /// offer, having nowhere to put a sheet.
    /// How long the red one has to be held before it fires.
    static let holdToDestroy: Double = 0.6

    @ViewBuilder
    private var exitSatellite: some View {
        if model.exitDestroys {
            // **Not a Button.** A Button takes the press for itself, so the drag gesture
            // that used to drive the arc never received a single event and the red ✕ did
            // nothing at all while recording. A long press is the gesture this actually
            // is, and `onPressingChanged` gives the arc its start and its cancel for free.
            satelliteFace("xmark", tint: Theme.Palette.danger)
                .overlay {
                    Circle()
                        .trim(from: 0, to: hold)
                        .stroke(
                            Theme.Palette.danger,
                            style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: PanelLayout.satellite, height: PanelLayout.satellite)
                        .allowsHitTesting(false)
                }
                .contentShape(.circle)
                .onLongPressGesture(minimumDuration: Self.holdToDestroy) {
                    hold = 0
                    model.onDiscard?()
                } onPressingChanged: { pressing in
                    withAnimation(
                        pressing
                            ? .linear(duration: Self.holdToDestroy)
                            : .easeOut(duration: 0.18)
                    ) {
                        hold = pressing ? 1 : 0
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(destroyLabel)
                .help(destroyLabel)
        } else {
            Button { model.onDiscard?() } label: {
                satelliteFace("xmark", tint: Theme.Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Hide the pill")
        }
    }

    private var destroyLabel: String {
        model.phase == .meeting ? "Hold to delete the recording" : "Hold to discard"
    }

    private func satellite(
        _ symbol: String, tint: Color, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { satelliteFace(symbol, tint: tint) }
            .buttonStyle(.plain)
            .help(help)
    }

    private func satelliteFace(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: PanelLayout.satellite, height: PanelLayout.satellite)
            // Same reason as the row: no shadow inside a window with no room for one.
            .glass(.floating, radius: PanelLayout.satellite / 2, elevated: false)
            .foregroundStyle(tint)
    }

    // MARK: - The countdown

    /// A hairline that drains over exactly as long as the message has left.
    ///
    /// It is drawn from the same numbers the bridge's timer uses, so the countdown cannot
    /// disagree with the dismissal — and it is the reason neither a notice nor a failure
    /// needs a control.
    @ViewBuilder
    private var countdown: some View {
        if let duration = PanelModel.dismissal(for: model.phase) {
            Capsule()
                .fill(
                    isFailure
                        ? Theme.Palette.text.opacity(0.4)
                        : Theme.Palette.gold.opacity(0.65)
                )
                .frame(height: 1)
                .scaleEffect(x: drain, anchor: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
                .task(id: model.phase) {
                    drain = 1
                    withAnimation(.linear(duration: duration)) { drain = 0 }
                }
        }
    }

    // MARK: - Reading the phase

    private var isRecording: Bool {
        model.phase == .dictating || model.phase == .meeting
    }

    private var isFailure: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    private var messageText: String? {
        switch model.phase {
        case .working(let label): label
        case .notice(let text): text
        case .failed(let failure): failure.headline
        default: nil
        }
    }

    /// What the mark is doing, which is the only thing on the panel that reports.
    private var markMotion: MarkBars.Motion? {
        switch model.phase {
        // No live transcript here, on purpose. Reading your own words as they are guessed
        // pulls attention mid-sentence and shows the roughest draft the pipeline ever has.
        // The mark says "heard, running" without inviting proofreading.
        case .dictating: .level(model.micLevel)
        case .working: .working
        case .notice: .settling
        case .failed: .still
        default: nil
        }
    }

    private var markHeight: CGFloat {
        if case .working = model.phase { return PanelLayout.workingMarkHeight }
        return PanelLayout.markHeight
    }

    private var markTint: Color {
        isFailure ? Theme.Palette.faint : Theme.Palette.gold
    }

    private var ringTint: Color {
        isRecording ? Theme.Palette.danger : Theme.Palette.gold
    }
}
