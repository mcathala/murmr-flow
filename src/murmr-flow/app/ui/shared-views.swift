import SwiftUI

/// Small pieces reused across the sections, so headings, rows and warnings look the same
/// everywhere rather than drifting apart per screen.

struct SectionLabel: View {
    let title: String
    var icon: String?

    var body: some View {
        Group {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .font(Theme.Text.label)
        .tracking(Theme.labelTracking)
        .foregroundStyle(Theme.Palette.faint)
        .textCase(.uppercase)
    }
}

/// A segmented control: one of a small closed set, chosen by tapping it.
///
/// Two jobs. As a **tab bar** at the top of a section, and as an inline **picker** for a
/// value with three or four possibilities — a dictionary entry's scope. Same shape both
/// times, because both are "these are the options, this is the one".
///
/// **The rule for using it as a tab bar: three groups with real content, and you are only
/// ever in one of them.** AI clean-up qualifies — provider, prompts, dictionary. Nothing
/// else does yet: Speech model is one list, Hotkeys is two keys and two toggles, and
/// Privacy & data has four groups that are each two lines, where seeing the permissions and
/// the delete buttons at once is worth more than hiding either. A section with one subject
/// must not sprout an empty tab bar.
///
/// A `SectionLabel` is 9.5pt uppercase in the faintest colour in the palette, which is a
/// hint rather than a division. That is fine for two groups in one scroll and was not
/// enough for three, each of which opens an editor of its own.
///
/// Not a `Picker(.segmented)`: the system control draws its selection in
/// `controlAccentColor`, the same system-wide colour that made `List(selection:)`
/// unusable here — see `SelectableRow`.
///
/// Selection is `tide`, not gold. Gold means live or chosen and there is one per screen;
/// the sidebar's selected row has already spent it, and this is the palette's stated
/// answer for any other highlight.
struct PaneTabs<Tab: Hashable & Identifiable>: View {

    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab
    /// Centred as a tab bar, leading as an inline picker sitting after its label.
    var alignment: Alignment = .center

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                Button {
                    selection = tab
                } label: {
                    Text(title(tab))
                        .font(isSelected ? Theme.Text.bodyStrong : Theme.Text.body)
                        .foregroundStyle(
                            isSelected ? Theme.Palette.text : Theme.Palette.muted
                        )
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                RoundedRectangle(
                                    cornerRadius: Theme.Radius.inner, style: .continuous
                                )
                                .fill(Theme.Palette.tide.opacity(0.20))
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: Theme.Radius.inner, style: .continuous
                                    )
                                    .strokeBorder(
                                        Theme.Palette.tide.opacity(0.42), lineWidth: 1
                                    )
                                }
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        // A recessed track, so three pills read as one control rather than as three
        // loose buttons that happen to sit in a row.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.Palette.abyss.opacity(0.40))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                }
        }
        // The track hugs the tabs, and the control is placed rather than stretched.
        // Filling the column's width left the labels in the top-left corner of a mostly
        // empty box — the one element in a pane of full-width cards that had to invent
        // something to do with the space.
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct WarningRow: View {
    let message: String
    var tint: Color = Theme.Palette.gold
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.row))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        }
    }
}

/// A labelled key/value grid, for anything tabular.
struct DetailGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            content
        }
        .font(.caption)
    }
}

/// A dot and a word. Green means tested and working — not merely configured.
struct StatusChip: View {
    enum Level {
        case ok, waiting, bad

        var color: Color {
            switch self {
            case .ok: Theme.Palette.ok
            case .waiting: Theme.Palette.faint
            case .bad: Theme.Palette.gold
            }
        }
    }

    let title: String
    var level: Level = .ok

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(level.color).frame(width: 7, height: 7)
            Text(title).font(Theme.Text.small)
        }
        .foregroundStyle(Theme.Palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glass(.thin, radius: 20, elevated: false)
    }
}

/// A bordered container. The one box style in the app, so nothing has to decide.
struct Card<Content: View>: View {
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(.thin, radius: Theme.Radius.pane, elevated: false)
            .overlay {
                // Gold marks the chosen one — the only place a border is allowed to carry
                // the accent, because "this is the one in use" is exactly what it means.
                if highlighted {
                    RoundedRectangle(cornerRadius: Theme.Radius.pane)
                        .strokeBorder(Theme.Palette.gold.opacity(0.55), lineWidth: 1.5)
                }
            }
    }
}

/// One setting: what it is on the left, the control on the right.
///
/// No explanatory caption. If a label needs a paragraph underneath it, the label is wrong
/// — the one exception in the app is the hold-to-talk toggle, where "off" genuinely needs
/// a sentence.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Text.bodyStrong)
                    if let detail {
                        Text(detail)
                            .font(Theme.Text.small)
                            .foregroundStyle(Theme.Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                control
            }
        }
    }
}

/// The card each mode puts at the top of its tab: start the thing, and what it's doing.
///
/// One component rather than two similar cards. Notes got its own copy first and drifted
/// immediately — gold button instead of the accent, the Theme fonts instead of the system
/// ones, a wider button — because "the same as the other one" is not something two files
/// can keep true. The trailing slot is the only part that differs on purpose: Dictation
/// puts its prompt there, Notes swaps in live levels while a meeting is running.
struct RecordCard<Trailing: View>: View {
    let title: String
    let subtitle: String
    let buttonTitle: String
    let buttonSymbol: String
    /// Recording. Turns the button red and marks the card, in both modes.
    var isActive = false
    var isDisabled = false
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Card(highlighted: isActive) {
            HStack(spacing: 12) {
                Button(action: action) {
                    Label(buttonTitle, systemImage: buttonSymbol)
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(isActive ? .red : .accentColor)
                .disabled(isDisabled)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                trailing
            }
        }
    }
}

/// One stream's live level, labelled.
///
/// Two of these side by side is how you catch a tap that started cleanly and is capturing
/// silence — which looks exactly like a working recording until you read the note. Shared
/// with the floating panel rather than drawn twice: the two places showing the same signal
/// differently would be its own bug.
struct LevelMeter: View {
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

/// Standard padding and rhythm for a scrolling pane.
struct PaneScroll<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let title {
                    Text(title)
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.Palette.text)
                        .padding(.bottom, 2)
                }
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A big centred prompt for a screen with nothing on it yet. Says what to do, not what
/// is missing.
struct EmptyPane: View {
    let symbol: String
    let title: String
    let hint: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.Palette.faint)
            Text(title).font(Theme.Text.heading).foregroundStyle(Theme.Palette.text)
            Text(hint)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Two letters, not a brand logo.
///
/// A wall of official marks — one orange, one black, one tan, one blue — would fight the
/// app's own palette in a single view, and each one is a trademarked asset to ship and
/// keep current. Monograms cost nothing and stay on-palette. Recognition is the trade.
struct Monogram: View {
    let name: String

    var body: some View {
        Text(initials)
            .font(Theme.Text.label)
            .frame(width: 26, height: 26)
            .glass(.thin, radius: 7, elevated: false)
            .foregroundStyle(Theme.Palette.muted)
    }

    private var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return words.prefix(2).compactMap { $0.first }.map(String.init)
                .joined().lowercased()
        }
        return String(name.prefix(2)).lowercased()
    }
}

/// An app's real icon where we can get it, a monogram where we can't.
///
/// For apps on this Mac the icon is free and always current — macOS resolves it from the
/// bundle identifier. The monogram is the fallback for an app that has since been
/// uninstalled, where a generic placeholder would say less than two letters do.
struct AppBadge: View {
    let name: String
    let bundleID: String?
    var size: CGFloat = 26

    var body: some View {
        if let icon = AppIconCache.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .help(name)
        } else {
            Monogram(name: name)
        }
    }
}

/// Chips you can remove, for a list you own — custom words.
struct RemovableChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    onRemove(item)
                } label: {
                    HStack(spacing: 4) {
                        Text(item).font(.caption)
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glass(.thin, radius: 20, elevated: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.muted)
                .help("Remove")
            }
        }
    }
}

/// Chips you can *apply*, for values we suggest — model names.
///
/// Deliberately a different shape from `RemovableChips`. Suggested models were rendered
/// with that view, so each one came with a cross on it: an offer that looked like
/// something you already had and could delete.
struct SuggestionChips: View {
    let items: [String]
    var current: String?
    let onPick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    onPick(item)
                } label: {
                    Text(item)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().stroke(
                                item == current
                                    ? Theme.Palette.gold.opacity(0.6) : Theme.Palette.hairline,
                                lineWidth: item == current ? 1.5 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    item == current ? Theme.Palette.text : Theme.Palette.muted
                )
                .help("Use this model")
            }
        }
    }
}

/// A stored secret, shown as filled dots rather than described in placeholder text.
///
/// The key field used to put "Stored in the Keychain" in a `SecureField` placeholder,
/// which renders grey and empty — so a key that existed looked exactly like one that did
/// not. State does not belong in a placeholder.
struct StoredSecretRow: View {
    let hasKey: Bool
    var isOptional = false
    let onSave: (String) -> Void
    let onRemove: () -> Void

    @State private var entered = ""
    @State private var isReplacing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasKey && !isReplacing {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.ok)
                    Text(String(repeating: "\u{25CF}", count: 16))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.text)
                    Text("in the Keychain")
                        .font(Theme.Text.small).foregroundStyle(Theme.Palette.muted)
                    Spacer(minLength: 0)
                    Button("Replace") { isReplacing = true }.controlSize(.small)
                    Button("Remove") { onRemove() }.controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("Paste your key", text: $entered)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        onSave(entered.trimmingCharacters(in: .whitespaces))
                        entered = ""
                        isReplacing = false
                    }
                    .controlSize(.small)
                    .disabled(entered.trimmingCharacters(in: .whitespaces).isEmpty)
                    if isReplacing {
                        Button("Cancel") {
                            entered = ""
                            isReplacing = false
                        }
                        .controlSize(.small)
                    }
                }
                if isOptional {
                    Text("Optional — a model served on this machine doesn\u{2019}t need one.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Lays children left to right, wrapping when the line runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var total = CGSize.zero

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > width, lineWidth > 0 {
                total.width = max(total.width, lineWidth - spacing)
                total.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        total.width = max(total.width, lineWidth - spacing)
        total.height += lineHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
