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
    /// How much air the row keeps above and below its content.
    ///
    /// The one thing that is allowed to differ between a sidebar and a menu. A sidebar is
    /// read at rest and a menu is used in a hurry, which is why every Mac menu is denser
    /// than every Mac sidebar — that is the platform's convention, not a preference. What
    /// must *not* differ is the horizontal inset: that is the wash's relationship to its
    /// container, and two answers to it in one window is how the same row starts looking
    /// like two components.
    var verticalPadding: CGFloat = 7
    /// Held lit from outside, for a row whose submenu is out.
    ///
    /// The pointer is on the flyout, not on the row that opened it — but the row is still
    /// the reason the flyout is there, and a parent that goes dark the moment you reach its
    /// children leaves the panes belonging to nothing.
    var isArmed: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    /// Selection is a gold wash; hover is a plain lift of white.
    ///
    /// The wash used to carry a gold border as well. Two marks for one state, and gold is
    /// meant to be the scarce thing on a screen — the fill alone says "chosen" and leaves
    /// the accent for the one place that has to be seen.
    private var fill: Color {
        if isSelected { return Theme.Palette.gold.opacity(0.16) }
        return isHovering || isArmed ? .white.opacity(0.065) : .clear
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, verticalPadding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // Every Mac sidebar answers the pointer. Without it a row only ever looked
            // like a target once it had already been clicked.
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
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
