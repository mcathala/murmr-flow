import SwiftUI

/// The floating panel's contents.
///
/// **Every state goes through one container.** Each state used to apply its own
/// `frame(maxWidth:maxHeight:alignment:)` and its own padding, in a different order — so
/// each one centred slightly differently, and some not at all. Position belongs to the
/// container now; the states own only their contents.
struct PanelView: View {

    @Bindable var model: PanelModel

    var body: some View {
        // Bottom-aligned, because the panel grows upward from where it rests. The
        // `Color.clear` is what gives the stack the whole window to align within —
        // without it the stack shrinks to its content and there is nothing to centre
        // against.
        ZStack(alignment: .bottom) {
            Color.clear
            content
        }
        .overlay(alignment: .top) {
            if model.showsBubbles {
                HStack(spacing: 8) {
                    translateBubble
                    promptBubble
                }
            }
        }
        .frame(width: model.size.width, height: model.size.height)
        .contentShape(.rect)
        .onHover { model.hover($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .resting: resting
        case .armed: armed
        case .dictating: dictating
        case .meeting: meeting
        case .working(let label): working(label)
        case .notice(let text): notice(text)
        case .failed(let failure): failed(failure)
        }
    }

    // MARK: - The centre line

    /// Distance from the window's bottom edge to the line the pill and the two round
    /// buttons **share**.
    ///
    /// This is the whole geometry of the collapsed states in one number. Both are centred
    /// on it, so hovering swaps a 5pt capsule for a 34pt button in the same place rather
    /// than stacking one above the other. Stacking was the bug: the buttons ended up in
    /// the strip between the pill and the Dock, and at 34pt tall they reached into it.
    ///
    /// 24 is the smallest value that leaves a button clear of the Dock: the window sits
    /// 10pt above it, a button centred here spans 7…41pt from the window's bottom edge,
    /// so its lowest point is 17pt clear.
    static let centreLine: CGFloat = 24

    // MARK: - Resting

    /// Deliberately almost nothing. If you are not reaching for it, it should not be
    /// asking for attention.
    private var resting: some View {
        Capsule()
            .fill(Theme.Palette.muted.opacity(0.5))
            .frame(width: 44, height: 5)
            .overlay(Capsule().fill(Theme.Palette.rim).frame(height: 1), alignment: .top)
            .padding(.bottom, Self.centreLine - 2.5)
    }

    // MARK: - Armed

    /// Reaching for the pill opens the controls directly. The two-button cluster that used
    /// to sit in between existed only to ask which mode you wanted, and a button per mode
    /// answers that without a step.
    ///
    /// Notes is an overlay rather than a sibling in the stack, which is what keeps the row
    /// centred on the screen: a plain `HStack` would centre the *pair*, shifting the row
    /// right by half the satellite every time it opened.
    private var armed: some View {
        row {
            HStack(spacing: 8) {
                indicator
                divider
                if model.mode == .note {
                    keycap(model.meetingHotkeyLabel)
                } else {
                    appIcon
                    keycap(model.hotkeyLabel)
                }
                Spacer(minLength: 0)
                // The primary action ends the row: the eye reads the row's facts
                // left-to-right and lands here, on the thing it came to do — not on a
                // button that makes the pill go away, which is what used to own this slot.
                startButton
            }
        }
        .overlay(alignment: .leading) {
            leftSatellite.offset(x: -PanelModel.satelliteReach)
        }
        // In orbit, like the satellite opposite: in the row is the work, around it is
        // meta. Dismissing the pill from inside the row was one fat-finger away from
        // "stop", and the window was already widened on this side for symmetry.
        .overlay(alignment: .trailing) {
            satellite("xmark", size: 8, help: "Hide the pill") { model.onDiscard?() }
                .offset(x: PanelModel.satelliteReach)
        }
        .frame(width: rowWidth)
    }

    @ViewBuilder
    private func keycap(_ label: String?) -> some View {
        if let label {
            Text(label)
                .font(Theme.Text.mono)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .glass(.thin, radius: Theme.Radius.inner, elevated: false)
                .foregroundStyle(.secondary)
                .opacity(model.hotkeyArmed ? 1 : 0.45)
                .help(
                    model.hotkeyArmed
                        ? ""
                        : "The key won\u{2019}t fire until Accessibility is granted"
                )
        }
    }

    /// Play, as the user reads it: start the job this row is set up for.
    private var startButton: some View {
        Button {
            if model.mode == .note {
                model.onToggleMeeting?()
            } else {
                model.onToggleDictation?()
            }
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 26)
                .glass(.thin, radius: 13, elevated: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Palette.gold)
        .help(model.mode == .note ? "Start recording the meeting" : "Start dictating")
    }

    /// The row's own width, with the satellite's reach removed from both sides.
    private var rowWidth: CGFloat {
        model.size.width - PanelModel.satelliteReach * 2
    }

    /// Switches which job the row is set up for — it does not start anything. A meeting
    /// used to begin on one click of this floating button; an hour of recording is not a
    /// thing to start by accident, and dictation always got an armed row first. Now both do.
    @ViewBuilder
    private var leftSatellite: some View {
        if model.mode == .note {
            satellite("mic.fill", size: 12, help: "Set up a dictation") {
                model.arm(.dictation)
            }
        } else {
            satellite("text.document", size: 12, help: "Set up the Notetaker") {
                model.arm(.note)
            }
        }
    }

    private func satellite(
        _ symbol: String, size: CGFloat, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: PanelModel.satelliteSize, height: PanelModel.satelliteSize)
                // Same reason as the row: no shadow inside a window with no room for one.
                .glass(.floating, radius: PanelModel.satelliteSize / 2, elevated: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Palette.muted)
        .help(help)
    }

    // MARK: - Open states

    /// No live transcript here, on purpose. Reading your own words as they are guessed
    /// pulls attention mid-sentence and shows the roughest draft the pipeline ever has;
    /// the waveform and the clock say "heard, running" without inviting proofreading.
    /// The words land where the cursor is — that is the reveal.
    private var dictating: some View {
        row {
            HStack(spacing: 8) {
                indicator
                divider
                appIcon
                Waveform(level: model.micLevel)
                Text(model.clock)
                    .font(Theme.Text.monoLarge)
                    .foregroundStyle(Theme.Palette.text)
                Spacer(minLength: 0)
                controls
            }
        }
    }

    private var meeting: some View {
        row {
            HStack(spacing: 8) {
                indicator
                divider
                HStack(spacing: 5) {
                    Circle().fill(Theme.Palette.danger).frame(width: 7, height: 7)
                    Text(model.clock).font(Theme.Text.monoLarge)
                }
                LevelMeter(label: "You", level: model.youLevel)
                LevelMeter(label: "Them", level: model.themLevel)
                Spacer(minLength: 0)
                controls
            }
        }
    }

    private func working(_ label: String) -> some View {
        row {
            HStack(spacing: 8) {
                indicator
                divider
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(label).font(Theme.Text.small).foregroundStyle(Theme.Palette.muted)
                Spacer(minLength: 0)
            }
        }
    }

    /// Quiet, in the muted colour: information, not alarm. No controls — it goes by
    /// itself.
    private func notice(_ text: String) -> some View {
        row {
            HStack(spacing: 8) {
                indicator
                divider
                Text(text)
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func failed(_ failure: PanelModel.Failure) -> some View {
        row {
            HStack(spacing: 8) {
                Text(failure.message)
                    .font(Theme.Text.bodyStrong)
                    // Red, not gold: gold is the colour of the chosen thing everywhere
                    // else in the app, and a fault is not that.
                    .foregroundStyle(Theme.Palette.danger)
                    .lineLimit(1)
                Spacer(minLength: 0)
                controls
            }
        }
    }

    // MARK: - Parts

    /// One radius, named once, used for both the fill and the hairline — so the two can
    /// never drift apart by a point and start looking wrong.
    /// The chrome every open state shares: fill the window, one set of insets, one
    /// background. States supply contents and nothing else, which is what stopped them
    /// each aligning differently.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .frame(height: model.rowHeight)
            // `elevated: false` is load-bearing, not a preference. The window is exactly
            // the size of its contents, so a shadow drawn *inside* it spreads into the
            // transparent margins and is cut flat at the frame — a window's backing store
            // ends there. That clip was the hard-edged rectangle around the pill.
            .glass(.floating, radius: Theme.Radius.panel, elevated: false)
    }

    /// One icon saying which of the two is running.
    ///
    /// This replaced two mode dots. They were a switch you set *before* acting, and with a
    /// button per mode there is nothing left to switch — they also spent the whole of every
    /// recording disabled, which is a good sign a control has stopped being one.
    private var indicator: some View {
        Image(systemName: model.mode == .note ? "text.document" : "mic.fill")
            .font(.system(size: 10, weight: .medium))
            .frame(width: 22, height: 22)
            .background(.quaternary, in: .circle)
            .foregroundStyle(.primary)
    }

    private var divider: some View {
        Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 18)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = model.targetAppIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
                .help(model.targetAppName ?? "")
        }
    }

    /// The two settings, in orbit above the row — each shown as its value, never a verb.
    /// 文A reads "Off" muted or the language code gold; one click flips it. The language
    /// itself is picked in the window.
    private var translateBubble: some View {
        Button {
            model.onToggleTranslate?()
        } label: {
            bubbleLabel(
                symbol: "translate",
                text: model.translateOn ? model.translateCode : "Off",
                active: model.translateOn
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.translateOn ? Theme.Palette.gold : Theme.Palette.text)
        .help(
            model.translateOn
                ? "Coming out in \(model.translateLanguage) — click to turn off"
                : "Click to translate to \(model.translateLanguage)"
        )
    }

    /// The active job's style, named by the app's own mark for AI clean-up.
    private var promptBubble: some View {
        Button {
            model.onPickPrompt?(NSEvent.mouseLocation)
        } label: {
            bubbleLabel(
                symbol: "sparkles",
                text: model.mode == .note ? model.notePromptName : model.promptName,
                active: false
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Palette.text)
        .help("Style — click to change")
    }

    private func bubbleLabel(symbol: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(Theme.Text.label)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // The pill's own material, not a translucent black: over a dark wallpaper the
        // black wash disappeared and the bubbles with it.
        .background {
            if active { Capsule().fill(Theme.Palette.gold.opacity(0.2)) }
        }
        .glass(.floating, radius: 20, elevated: false)
        .overlay(
            Capsule().stroke(
                active ? Theme.Palette.gold.opacity(0.7) : Theme.Palette.rim,
                lineWidth: 1
            )
        )
    }

    /// Stop and discard, as separate controls with separate shapes — a square for
    /// "finish", a cross for "throw away". Sharing one glyph is how a button ends up
    /// meaning two opposite things.
    @ViewBuilder
    private var controls: some View {
        let available = model.phase.controls
        if available.stop {
            circleButton("stop.fill", size: 9, tint: Theme.Palette.danger) { model.onStop?() }
                .help("Stop")
        }
        if available.discard {
            circleButton("xmark", size: 8, tint: nil) { model.onDiscard?() }
                .help(model.phase.controls.stop ? "Discard" : "Dismiss")
        }
    }

    private func circleButton(
        _ symbol: String, size: CGFloat, tint: Color?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .frame(width: 20, height: 20)
                .glass(.thin, radius: 10, elevated: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Theme.Palette.muted)
    }
}

/// A live level, drawn as bars rather than a number.
///
/// The bars are the mark's: at rest they sit at the M, and speech pushes the inner three
/// up toward the stems. So the logo is not a sticker on the panel — it is what the meter
/// looks like when nobody is talking.
private struct Waveform: View {
    let level: Float
    private static let rest = MurmrMark.relativeHeights
    private static let height: CGFloat = 20
    private static let scale = height / MurmrMark.bounds.height

    var body: some View {
        HStack(spacing: (MurmrMark.pitch - MurmrMark.barWidth) * Self.scale) {
            ForEach(0..<Self.rest.count, id: \.self) { index in
                Capsule()
                    .fill(Theme.Palette.gold)
                    .frame(width: MurmrMark.barWidth * Self.scale, height: height(index))
            }
        }
        .frame(height: Self.height)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// How much of the way to the stems each bar goes at full level. Less toward the
    /// middle, so loud speech is a nearly full block with a trace of the V left in it
    /// rather than five identical bars — a meter that has stopped saying anything.
    private static let reach: [CGFloat] = [1, 0.9, 0.8, 0.9, 1]

    /// Each bar rises from its resting height toward the full height as the level rises;
    /// the stems are already there, so only the letter moves.
    private func height(_ index: Int) -> CGFloat {
        let rest = Self.rest[index]
        let room = (1 - rest) * Self.reach[index]
        return Self.height * (rest + room * CGFloat(AudioLevel.normalised(level)))
    }
}
