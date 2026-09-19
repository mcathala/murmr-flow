import AppKit
import Observation
import SwiftUI

/// When the section menu is out, and the waiting either side of it.
///
/// The waiting is the whole design. The name sits at the top-left of the content, in the
/// path between the traffic lights and the window's left edge — so a pointer merely
/// travelling somewhere passes over it. Opening on contact would mean the menu appearing
/// on trips that had nothing to do with it. Opening after a pause means resting on the
/// name opens it and crossing it does not.
///
/// Its own object rather than `@State` in a view, because the name and the menu are two
/// views and each has to be able to cancel what the other started.
@MainActor
@Observable
final class SectionMenu {

    /// Long enough that crossing the title bar never opens it, short enough that resting
    /// on the name does not feel like waiting. Tuned in the prototype before it was built.
    static let openDelay = Duration.milliseconds(250)

    /// The pointer has to cross the gap between the name and the menu below it. Without
    /// the wait the menu shuts in that gap, under the pointer on its way in.
    static let closeDelay = Duration.milliseconds(180)

    /// The same two waits again, one level down, for the Settings flyout.
    ///
    /// Shorter to open than the menu itself: the pointer is already inside a menu it meant
    /// to open, so the only thing left to guard against is it running down the list on its
    /// way out. Longer to close, because the path from the parent row to the panes is
    /// diagonal — it leaves the row before it reaches them, and without the wait the flyout
    /// shuts in the gap the pointer is crossing.
    static let submenuOpenDelay = Duration.milliseconds(150)
    static let submenuCloseDelay = Duration.milliseconds(200)

    private(set) var isOpen = false

    /// Whether the panes are out, and whether the parent is lit on the way to them.
    private(set) var isSubmenuOpen = false
    private(set) var isSubmenuArmed = false

    private var openWork: Task<Void, Never>?
    private var closeWork: Task<Void, Never>?
    private var submenuOpenWork: Task<Void, Never>?
    private var submenuCloseWork: Task<Void, Never>?

    /// The pointer has arrived on the name. Nothing shows yet.
    func arm() {
        cancelClose()
        cancelOpen()
        openWork = Task { [weak self] in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled else { return }
            self?.isOpen = true
        }
    }

    /// The pointer has left the name, or something else has claimed it.
    func disarm() {
        cancelOpen()
    }

    /// The pointer is on the menu itself; whatever close was pending is off.
    func keepOpen() {
        cancelClose()
    }

    func scheduleClose() {
        cancelOpen()
        cancelClose()
        closeWork = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled else { return }
            self?.isOpen = false
        }
    }

    /// Now, with no wait: a section was chosen, or the peek took over.
    func close() {
        cancelOpen()
        cancelClose()
        isOpen = false
        closeSubmenu()
    }

    // MARK: - The Settings flyout

    /// The pointer has arrived on Settings. The row lights at once; the panes wait.
    func armSubmenu() {
        cancelSubmenuClose()
        cancelSubmenuOpen()
        isSubmenuArmed = true
        submenuOpenWork = Task { [weak self] in
            try? await Task.sleep(for: Self.submenuOpenDelay)
            guard !Task.isCancelled else { return }
            self?.isSubmenuOpen = true
        }
    }

    /// The pointer has left Settings — on its way to the panes, or away entirely. Which of
    /// the two it was only becomes clear after the wait.
    func disarmSubmenu() {
        cancelSubmenuOpen()
        cancelSubmenuClose()
        isSubmenuArmed = false
        submenuCloseWork = Task { [weak self] in
            try? await Task.sleep(for: Self.submenuCloseDelay)
            guard !Task.isCancelled else { return }
            self?.isSubmenuOpen = false
        }
    }

    /// The pointer made it onto the panes.
    func keepSubmenu() {
        cancelSubmenuClose()
    }

    /// Landing on another section is a decision: the flyout goes now, with no wait.
    func closeSubmenu() {
        cancelSubmenuOpen()
        cancelSubmenuClose()
        isSubmenuOpen = false
        isSubmenuArmed = false
    }

    private func cancelSubmenuOpen() {
        submenuOpenWork?.cancel()
        submenuOpenWork = nil
    }

    private func cancelSubmenuClose() {
        submenuCloseWork?.cancel()
        submenuCloseWork = nil
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }
}

/// The sections, under the name at the top of the content, while the sidebar is away.
///
/// Drawn by the app rather than handed to `NSMenu`. A system menu cannot be recoloured —
/// the same reason `SelectableRow` exists — so it would have arrived grey in the middle of
/// a navy and gold window. The cost is the conventions that come free with a real menu,
/// type-ahead among them.
struct SectionMenuView: View {

    let services: AppServices

    /// Sized to its longest row, not to the column it replaces.
    ///
    /// 186 was the collapsed sidebar's width carried over, and the sections are short words
    /// — every row ended in 40pt of nothing. The binding row is Settings, which is the only
    /// one with a trailing shortcut: 12 of panel padding, 18 of row padding, a 17pt glyph,
    /// a 9pt gap, the label, and ⌘, at the end comes to about 133. 158 leaves slack for a
    /// longer section name without leaving a margin wide enough to notice.
    static let width: CGFloat = 158

    var body: some View {
        panel
            // Flush against the panel, bottom edges level — which is where the panes end up
            // beside the row that opened them, Settings being the last one. A gap here
            // would be a dead zone: the pointer crosses it on the diagonal and the flyout
            // would shut underneath it.
            .overlay(alignment: .bottomTrailing) {
                flyout.offset(x: Self.width - 1)
            }
    }

    private var panel: some View {
        VStack(spacing: 2) {
            ForEach(MainWindow.Route.top, id: \.self) { route in
                row(route.label, symbol: route.symbol, isSelected: services.route == route) {
                    services.route = route
                    services.sectionMenu.close()
                }
                // Reaching a section is a decision; the flyout does not linger over it.
                .onHover { if $0 { services.sectionMenu.closeSubmenu() } }
            }

            // Settings is a level rather than a section, so it sits under a rule with its
            // shortcut beside it. It opens the pane you were last in, which is what
            // `openSettings()` has always done.
            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 1)
                .padding(.horizontal, 3)
                .padding(.vertical, 4)

            // Settings is a *parent*, not a destination. Clicking it does nothing on
            // purpose: every one of its children is a real place and it is not, so a click
            // here would have to pick one of them for you. The chevron says the panes are
            // to the right; resting on the row brings them. ⌘, still opens the level, it
            // just isn't advertised on a row that doesn't do it.
            row(
                "Settings", symbol: "gearshape", isSelected: services.route.isSettings,
                trailing: "chevron.right",
                isArmed: services.sectionMenu.isSubmenuArmed
                    || services.sectionMenu.isSubmenuOpen
            ) {}
            .onHover { hovering in
                if hovering {
                    services.sectionMenu.armSubmenu()
                } else {
                    services.sectionMenu.disarmSubmenu()
                }
            }
        }
        // The same 6pt the sidebar insets its rows by. This menu *is* the sidebar while the
        // column is away, drawn from the same component — so the wash has to sit the same
        // distance from its edge in both, or toggling the sidebar reads as the sections
        // changing rather than merely moving.
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(width: Self.width)
        .glass(.thick, radius: 11)
        .onHover { hovering in
            if hovering {
                services.sectionMenu.keepOpen()
            } else {
                services.sectionMenu.scheduleClose()
            }
        }
    }

    /// The Settings panes, beside the row that opens them.
    ///
    /// Its own panel rather than an unfolding of this one: the menu keeps its size, the
    /// sections stay where they were, and picking a pane never moves the list under the
    /// pointer that came for it.
    private var flyout: some View {
        let menu = services.sectionMenu
        return VStack(spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                row(
                    pane.label, symbol: pane.symbol,
                    isSelected: services.route == .settings(pane)
                ) {
                    services.openSettings(pane)
                    menu.close()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(width: Self.width)
        .glass(.thick, radius: 11)
        // Grows out of the corner it is anchored to, rather than appearing whole.
        .scaleEffect(menu.isSubmenuOpen ? 1 : 0.98, anchor: .bottomLeading)
        .offset(x: menu.isSubmenuOpen ? 0 : -6)
        .opacity(menu.isSubmenuOpen ? 1 : 0)
        .allowsHitTesting(menu.isSubmenuOpen)
        // Both waits, not just the flyout's. This panel hangs *outside* the menu's frame,
        // so reaching it is a departure as far as the menu is concerned — and the menu
        // would take the panes down with it while the pointer was still on them.
        .onHover { hovering in
            if hovering {
                menu.keepOpen()
                menu.keepSubmenu()
            } else {
                menu.scheduleClose()
                menu.disarmSubmenu()
            }
        }
        .animation(.smooth(duration: 0.14), value: menu.isSubmenuOpen)
    }

    private func row(
        _ label: String,
        symbol: String,
        isSelected: Bool,
        trailing: String? = nil,
        isArmed: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        // 4 against the sidebar's 7: a menu is picked from in a hurry and a sidebar is read
        // at rest, so this is the one dimension where the two should differ.
        SelectableRow(isSelected: isSelected, radius: 8, verticalPadding: 4, isArmed: isArmed) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .frame(width: 17)
                    .foregroundStyle(isSelected ? Theme.Palette.gold : Theme.Palette.muted)
                Text(label)
                    .font(Theme.Text.body)
                    .foregroundStyle(isSelected ? Theme.Palette.text : Theme.Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.faint)
                }
            }
        }
        .onTapGesture(perform: action)
    }
}
