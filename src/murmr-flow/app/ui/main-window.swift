import SwiftUI

/// The app window: a sidebar and one section at a time.
///
/// Settings lives **in** the sidebar, nested under its own heading, rather than in a
/// separate Settings window. One window means one place to be, and the five panes are
/// visible as a list instead of hidden behind a keystroke. ⌘, selects the first of them.
struct MainWindow: View {

    let services: AppServices

    /// Both levels of navigation in one value, so selection is a single source of truth
    /// and the keyboard shortcut can move it from outside the view.
    enum Route: Hashable {
        case home
        case dictaphone
        case notes
        case insights
        case settings(SettingsPane)

        static let top: [Route] = [.home, .dictaphone, .notes, .insights]

        var label: String {
            switch self {
            case .home: "Home"
            case .dictaphone: "Dictation"
            case .notes: "Notetaker"
            case .insights: "Insights"
            case .settings(let pane): pane.label
            }
        }

        var symbol: String {
            switch self {
            case .home: "square.grid.2x2"
            case .dictaphone: "mic"
            case .notes: "text.document"
            case .insights: "chart.bar"
            case .settings(let pane): pane.symbol
            }
        }
    }

    static let minSize = CGSize(width: 900, height: 600)

    /// A fixed column, not a `NavigationSplitView`.
    ///
    /// The split view brought nothing this window uses and a queue of faults with it. It
    /// synthesises a toolbar, and a toolbar with items carries a clipped-items indicator —
    /// the round `»` that flashed at the top right whenever the column's width changed. It
    /// draws its own sidebar toggle, which is not a toolbar item at all but SwiftUI's own
    /// view inside the column, so emptying the toolbar never removed it. It persists a
    /// collapsed state, so the app could open with no navigation at all. And nothing turns
    /// any of that off: `.toolbar(removing: .sidebarToggle)`,
    /// `.toolbar(.hidden, for: .windowToolbar)`, `CommandGroup(replacing: .sidebar) {}`, a
    /// constant `columnVisibility` binding and `NSSplitViewItem.canCollapse = false` were
    /// each measured against the running window and each did nothing.
    ///
    /// An `HStack` has no toolbar, draws no controls of its own, and remembers nothing. The
    /// sidebar is this app's navigation and is always meant to be there, so a layout that
    /// cannot take it away is the right shape.
    static let sidebarWidth: CGFloat = 198

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                // Reaches under the title bar; the contents do not, so the column is one
                // surface with no seam below the traffic lights.
                .glassColumn(.thick)

            // Drawn rather than a `Divider`, which resolves its own colour.
            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(width: 1)
                .ignoresSafeArea()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // One ground behind everything, so no layout state leaves a strip unpainted.
        .background(InkGround())
        .font(Theme.Text.body)
        .foregroundStyle(Theme.Palette.text)
        .tint(Theme.Palette.gold)
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .onAppear {
            // Land on the thing that needs attention rather than hiding a broken
            // permission behind a row the user has no reason to click.
            if !services.permissions.allGranted {
                services.route = .settings(.permissions)
            }
        }
    }

    /// Selection is drawn by `SelectableRow`, not by `List`. The system highlight is
    /// `controlAccentColor` — a system-wide setting no app can override — so a selected row
    /// arrived bright blue in the middle of a navy and gold interface.
    private var sidebar: some View {
        List {
                ForEach(Route.top, id: \.self) { route in
                    sidebarRow(route.label, symbol: route.symbol, route: route)
                }

                Section {
                    ForEach(SettingsPane.allCases) { pane in
                        sidebarRow(pane.label, symbol: pane.symbol, route: .settings(pane))
                    }
                } header: {
                    Text("Settings")
                        .font(Theme.Text.label)
                        .tracking(Theme.labelTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Palette.faint)
                }
            }
        .listStyle(.sidebar)
        // Hidden, or `List` paints its own opaque sidebar material and the window ends up
        // with a grey column beside a navy one.
        .scrollContentBackground(.hidden)
    }

    private func sidebarRow(_ label: String, symbol: String, route: Route) -> some View {
        SelectableRow(isSelected: services.route == route) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    // A fixed width, so the labels line up whatever the glyph's shape.
                    .frame(width: 17)
                    .foregroundStyle(
                        services.route == route ? Theme.Palette.gold : Theme.Palette.muted
                    )
                Text(label)
                    .font(Theme.Text.body)
                    .foregroundStyle(
                        services.route == route ? Theme.Palette.text : Theme.Palette.muted
                    )
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .onTapGesture { services.route = route }
    }

    @ViewBuilder
    private var detail: some View {
        switch services.route {
        case .home:
            HomeView(services: services, onOpen: { services.route = $0 })
        case .dictaphone:
            DictaphoneView(
                dictation: services.dictation,
                history: services.history,
                prompts: services.prompts
            )
        case .notes:
            NotesView(
                notes: services.notes,
                meetings: services.meetings,
                settings: services.settings,
                prompts: services.prompts
            )
        case .insights:
            InsightsView(history: services.history)
        case .settings(let pane):
            SettingsPaneView(pane: pane, services: services)
        }
    }

}
