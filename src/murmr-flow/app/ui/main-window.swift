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
            case .dictaphone: "Dictaphone"
            case .notes: "Notes"
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

    /// Held at `.all`, so the column is never actually taken away.
    ///
    /// `NavigationSplitView` persists its collapsed state, and the sidebar *is* this app's
    /// navigation — so a session that left it collapsed opened the next one with no way to
    /// reach any page. Closing is `isRail` instead: the column narrows to its icons rather
    /// than disappearing, which keeps every page one click away and keeps the button that
    /// reopens it on screen.
    @State private var columns: NavigationSplitViewVisibility = .all

    /// Closed. The column keeps its icons, at `railWidth`.
    @State private var isRail = false

    /// Wide enough for the window's own buttons.
    ///
    /// The traffic lights sit in the sidebar's region, and they are not ours to move:
    /// measured, close is at x=19, minimise at 42, zoom at 65, each 14 across — so the green
    /// one ends at 79. A 64pt column cut it exactly in half, one part over the sidebar and
    /// one over the detail. 88 clears it with a little room to spare.
    ///
    /// `NavigationSplitView` rounds the request up: asking for 88 is granted 96, and it
    /// clamps at 64 below that. Measured in the running window — the green button ends at 79,
    /// the column is 96, so it clears by 17.
    static let railWidth: CGFloat = 88
    static let fullWidth: CGFloat = 198

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .glassColumn(.thick)
                // A fixed width rather than a range: the two states are the design, and a
                // draggable divider in between was never a feature anyone used.
                .navigationSplitViewColumnWidth(isRail ? Self.railWidth : Self.fullWidth)
        } detail: {
            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background(InkGround())
        }
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

    // MARK: - Sidebar

    private var sidebar: some View {
        // Selection is drawn by `SelectableRow`, not by `List`. The system highlight is
        // `controlAccentColor` — a system-wide setting no app can override — so a selected
        // row arrived bright blue in the middle of a navy and gold interface.
        VStack(spacing: 0) {
            List {
                ForEach(Route.top, id: \.self) { route in
                    sidebarRow(route.label, symbol: route.symbol, route: route)
                }

                Section {
                    ForEach(SettingsPane.allCases) { pane in
                        sidebarRow(pane.label, symbol: pane.symbol, route: .settings(pane))
                    }
                } header: {
                    // Closed, the heading would be an ellipsis in an 88pt column. A rule
                    // says the same thing in the space available.
                    if isRail {
                        Rectangle()
                            .fill(Theme.Palette.hairline)
                            .frame(height: 1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    } else {
                        Text("Settings")
                            .font(Theme.Text.label)
                            .tracking(Theme.labelTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Palette.faint)
                    }
                }
            }
            .listStyle(.sidebar)
            // Hidden, or `List` paints its own opaque sidebar material and the window ends
            // up with a grey column beside a navy one.
            .scrollContentBackground(.hidden)

            railToggle
        }
    }

    /// Opens and closes the sidebar.
    ///
    /// Ours, and inside the sidebar. The system's toggle lived in the window toolbar, and a
    /// toolbar with items carries a clipped-items indicator — the round `»` that flashed at
    /// the top right whenever the column's width changed. This draws in the palette, sits in
    /// a place that exists in both states, and adds nothing to the toolbar.
    /// At the foot of the column, under a rule.
    ///
    /// It was at the top, and both places it tried there were wrong: beside the traffic
    /// lights it competed with buttons that are not ours to move, and above the first item
    /// it read as an unlabelled navigation row. The foot is the one part of the column that
    /// holds nothing else, in either width.
    ///
    /// No `withAnimation`. Animating the column's width re-laid-out the detail pane on every
    /// frame and the settings panes lurched through it. The change snaps.
    private var railToggle: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 1)

            Image(systemName: isRail ? "sidebar.right" : "sidebar.left")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.faint)
                .frame(width: 17)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: isRail ? .center : .trailing)
                .contentShape(.rect)
                .onTapGesture { isRail.toggle() }
                .help(isRail ? "Show the labels" : "Hide the labels")
                .padding(.horizontal, isRail ? 0 : 8)
                .padding(.bottom, 4)
        }
    }

    private static let rowPadding: CGFloat = 5
    private static let rowInsets = EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)

    private func sidebarRow(_ label: String, symbol: String, route: Route) -> some View {
        let selected = services.route == route

        return SelectableRow(isSelected: selected, verticalPadding: Self.rowPadding) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    // A fixed width, so the labels line up whatever the glyph's shape.
                    .frame(width: 17)
                    .foregroundStyle(selected ? Theme.Palette.gold : Theme.Palette.muted)
                if !isRail {
                    Text(label)
                        .font(Theme.Text.body)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Theme.Palette.text : Theme.Palette.muted)
                }
            }
            // Centred in the rail, so the icons form a column rather than sitting off to
            // one side of it.
            .frame(maxWidth: .infinity, alignment: isRail ? .center : .leading)
        }
        // The label has to come back as a tooltip, or the rail is ten glyphs and a guess.
        .help(label)
        .listRowInsets(Self.rowInsets)
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
            NotesView(notes: services.notes, meetings: services.meetings)
        case .insights:
            InsightsView(history: services.history)
        case .settings(let pane):
            SettingsPaneView(pane: pane, services: services)
        }
    }

}
