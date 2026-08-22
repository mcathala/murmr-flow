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
                dictateButton
                divider
                appIcon
                if let key = model.hotkeyLabel {
                    Text(key)
                        .font(Theme.Text.mono)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glass(.thin, radius: Theme.Radius.inner, elevated: false)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                promptChip
                controls
            }
        }
        .overlay(alignment: .leading) {
            noteSatellite.offset(x: -PanelModel.satelliteReach)
        }
        .frame(width: rowWidth)
    }

    /// The row's own width, with the satellite's reach removed from both sides.
    private var rowWidth: CGFloat {
        model.size.width - PanelModel.satelliteReach * 2
    }

    /// Starts a meeting. Present only while nothing is running: leaving a live
    /// "start recording" button beside one that is already recording invites exactly one
    /// kind of accident.
    private var noteSatellite: some View {
        Button {
            model.onToggleMeeting?()
        } label: {
            Image(systemName: "text.document")
                .font(.system(size: 12, weight: .medium))
                .frame(width: PanelModel.satelliteSize, height: PanelModel.satelliteSize)
                .glass(.thick, radius: PanelModel.satelliteSize / 2)
        }
        .buttonStyle(.plain)
        .help("Start recording a meeting")
    }

    /// The pill *is* the dictaphone, so this is the primary action of the row.
    private var dictateButton: some View {
        Button {
            model.onToggleDictation?()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .glass(.thin, radius: 12, elevated: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Palette.text)
        .help("Start dictating")
    }

    // MARK: - Open states

    private var dictating: some View {
        row {
            VStack(alignment: .leading, spacing: 6) {
                if !model.preview.isEmpty {
                    Text(model.preview)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Palette.text)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    indicator
                    divider
                    appIcon
                    Waveform(level: model.micLevel)
                    Text(model.clock)
                        .font(Theme.Text.monoLarge)
                        .foregroundStyle(Theme.Palette.text)
                    Spacer(minLength: 0)
                    promptChip
                    controls
                }
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
                Meter(label: "You", level: model.youLevel)
                Meter(label: "Them", level: model.themLevel)
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

    private func failed(_ failure: PanelModel.Failure) -> some View {
        row {
            HStack(spacing: 8) {
                indicator
                divider
                Text(failure.message)
                    .font(Theme.Text.bodyStrong)
                    .foregroundStyle(Theme.Palette.gold)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Thick: this floats over other applications, so it should read as heavier
            // than a card sitting inside a window.
            .glass(.thick, radius: Theme.Radius.panel)
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

    @ViewBuilder
    private var promptChip: some View {
        if model.mode == .dictation {
            Button {
                model.onPickPrompt?(NSEvent.mouseLocation)
            } label: {
                Text(model.promptName)
                    .font(Theme.Text.small)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .glass(.thin, radius: 20, elevated: false)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.muted)
        }
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
private struct Waveform: View {
    let level: Float
    private static let bars = 11

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(Theme.Palette.gold)
                    .frame(width: 2.5, height: height(index))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// Loudest in the middle, so the shape reads as a voice rather than a bar chart.
    private func height(_ index: Int) -> CGFloat {
        let centre = Double(Self.bars - 1) / 2
        let falloff = 1 - abs(Double(index) - centre) / (centre + 1)
        return 3 + 15 * AudioLevel.normalised(level) * falloff
    }
}

/// One stream's level, labelled. Two of these side by side is how you catch a tap that
/// started cleanly and is capturing silence.
private struct Meter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Theme.Text.label)
                .tracking(Theme.labelTracking)
                .foregroundStyle(Theme.Palette.faint)
                .fixedSize()
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(lit(index) ? Theme.Palette.gold : Theme.Palette.hairline)
                    .frame(width: 3, height: lit(index) ? 13 : 6)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func lit(_ index: Int) -> Bool {
        AudioLevel.isLit(level, bar: index)
    }
}
