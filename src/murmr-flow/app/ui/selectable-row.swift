import SwiftUI

/// A row that shows selection in the app's own colours.
///
/// `List(selection:)` draws its highlight with `controlAccentColor`, which is a system-wide
/// setting an app cannot override — so on a navy-and-gold interface the selected row came
/// out bright system blue, the one thing on screen from a different palette. Setting
/// `.tint()` does not reach it, and there is no supported way to change that colour for a
/// single app.
///
/// So the highlight is drawn here instead. `List` is still used, for scrolling and for arrow
/// keys, just without its `selection:` binding.
struct SelectableRow<Content: View>: View {

    let isSelected: Bool
    /// Rounded on all four sides and inset from the column edge, the way a Mac sidebar row
    /// sits — a full-bleed rectangle reads as a table.
    var radius: CGFloat = Theme.Radius.row
    /// Tightened for the icon rail: ten glyphs in a narrow column read as one group when
    /// they are close together and as a scattering when they are not.
    var verticalPadding: CGFloat = 7
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, verticalPadding)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Theme.Palette.gold.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(Theme.Palette.gold.opacity(0.34), lineWidth: 1)
                        }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// What a click means, given the modifiers held down.
///
/// Selection behaviour people already know: plain click replaces, ⌘ toggles one, ⇧ extends
/// to a range. Written once here rather than guessed at each call site.
enum RowClick {

    static func apply<Item: Hashable>(
        _ item: Item,
        in items: [Item],
        selection: inout Set<Item>,
        anchor: inout Item?,
        modifiers: EventModifiers
    ) {
        if modifiers.contains(.shift), let from = anchor,
           let start = items.firstIndex(of: from), let end = items.firstIndex(of: item) {
            selection = Set(items[min(start, end)...max(start, end)])
            return
        }
        if modifiers.contains(.command) {
            if selection.contains(item) {
                selection.remove(item)
            } else {
                selection.insert(item)
            }
            anchor = item
            return
        }
        selection = [item]
        anchor = item
    }

    /// Arrow keys. Moves a single selection up or down and carries the anchor with it, so a
    /// subsequent ⇧-click extends from where the keyboard left off.
    static func move<Item: Hashable>(
        _ direction: MoveCommandDirection,
        in items: [Item],
        selection: inout Set<Item>,
        anchor: inout Item?
    ) {
        guard !items.isEmpty, direction == .up || direction == .down else { return }

        let step = direction == .up ? -1 : 1
        let start = anchor.flatMap { items.firstIndex(of: $0) } ?? (step > 0 ? -1 : items.count)
        let next = min(max(start + step, 0), items.count - 1)

        selection = [items[next]]
        anchor = items[next]
    }
}
