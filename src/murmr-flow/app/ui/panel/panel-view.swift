import SwiftUI

/// The floating panel's contents.
///
/// One view for every state on purpose. The panel's whole character is that it *grows*
/// between states rather than swapping a box's insides, so the states share a container
/// and differ only in what fills it.
struct PanelView: View {

    @Bindable var model: PanelModel

    var body: some View {
        content
            .frame(width: model.size.width, height: model.size.height)
            .contentShape(.rect)
            .onHover { model.hover($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .resting: resting
        case .hovering: cluster
        case .armed: armed
        case .dictating: dictating
        case .meeting: meeting
        case .working(let label): working(label)
        case .failed(let failure): failed(failure)
        }
    }

    // MARK: - Resting

    /// Deliberately almost nothing. If you are not reaching for it, it should not be
    /// asking for attention.
    private var resting: some View {
        Capsule()
            .fill(.secondary.opacity(0.55))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 4)
    }

    // MARK: - Hover

    private var cluster: some View {
        VStack(spacing: 7) {
            Text(model.mode == .note ? "Start meeting" : "Dictate")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: .capsule)
                .overlay(Capsule().stroke(.separator, lineWidth: 0.5))

            HStack(spacing: 8) {
                round("mic.fill", active: model.mode == .dictation) {
                    model.mode = .dictation
                    model.onToggleDictation?()
                }
                .onHover { if $0 { model.mode = .dictation; model.armIfHovering() } }

                round("text.document", active: model.mode == .note) {
                    model.mode = .note
                    model.onToggleMeeting?()
                }
                .onHover { if $0 { model.mode = .note } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 5)
    }

    private func round(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 34)
                .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial),
                            in: .circle)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .overlay(Circle().stroke(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Armed

    /// The icon *is* the app name, and the key needs no verb in front of it.
    private var armed: some View {
        shell {
            modes
            divider
            appIcon
            Text(hotkeyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            promptChip
            closeButton
        }
    }

    private var hotkeyHint: String {
        model.mode == .note ? "Start meeting" : "Hold to speak"
    }

    // MARK: - Dictating

    private var dictating: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.preview.isEmpty {
                Text(model.preview)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            HStack(spacing: 8) {
                modes
                divider
                appIcon
                Waveform(level: model.micLevel)
                Text(model.clock)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                promptChip
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: shape)
        .overlay(shape.stroke(.separator, lineWidth: 0.5))
    }

    // MARK: - Meeting

    private var meeting: some View {
        shell {
            modes
            divider
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(model.clock).font(.caption.monospacedDigit())
            }
            Meter(label: "You", level: model.youLevel)
            Meter(label: "Them", level: model.themLevel)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Working & failed

    private func working(_ label: String) -> some View {
        shell {
            modes
            divider
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func failed(_ failure: PanelModel.Failure) -> some View {
        shell {
            modes
            divider
            Text(failure.message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
            closeButton
        }
    }

    // MARK: - Parts

    /// One radius, named once, used for both the fill and the hairline — so the two can
    /// never drift apart by a point and start looking wrong.
    private static let corner: CGFloat = 22

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
    }

    private func shell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(.separator, lineWidth: 0.5))
    }

    /// Present in every open state, and dead while something runs — you cannot slide
    /// from dictating into a meeting, you stop first.
    private var modes: some View {
        HStack(spacing: 2) {
            modeDot("mic.fill", isOn: model.mode == .dictation) {
                guard !model.phase.isBusy else { return }
                model.mode = .dictation
            }
            modeDot("text.document", isOn: model.mode == .note) {
                guard !model.phase.isBusy else { return }
                model.mode = .note
            }
        }
    }

    private func modeDot(
        _ symbol: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 22)
                .background(isOn ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .circle)
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .disabled(model.phase.isBusy)
    }

    private var divider: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 18)
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
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if model.phase.allowsClose {
            Button {
                model.onCancel?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: .circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
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
                    .fill(.tint)
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
        let scaled = Double(min(max(level, 0), 1))
        return 3 + 15 * scaled * falloff
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
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(lit(index) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: lit(index) ? 13 : 6)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func lit(_ index: Int) -> Bool {
        Double(level) > Double(index) * 0.14 + 0.02
    }
}
