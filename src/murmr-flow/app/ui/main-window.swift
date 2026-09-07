import SwiftUI

/// The app window: a sidebar and one section at a time.
///
/// Settings lives **in** the sidebar, as a level you enter, rather than in a separate
/// Settings window. One window means one place to be, and ⌘, enters that level rather
/// than opening a second scene.
struct MainWindow: View {

    let services: AppServices

    /// Both levels of navigation in one value, so selection is a single source of truth
    /// and the keyboard shortcut can move it from outside the view.
    enum Route: Hashable {
        case home
        case dictation
        case notetaker
        case insights
        case settings(SettingsPane)

        static let top: [Route] = [.home, .dictation, .notetaker, .insights]

        var label: String {
            switch self {
            case .home: "Home"
            case .dictation: "Dictation"
            case .notetaker: "Notetaker"
            case .insights: "Insights"
            case .settings(let pane): pane.label
            }
        }

        var symbol: String {
            switch self {
            case .home: "square.grid.2x2"
            case .dictation: "mic"
            case .notetaker: "text.document"
            case .insights: "chart.bar"
            case .settings(let pane): pane.symbol
            }
        }

        /// Which of the sidebar's two levels this route belongs to.
        var isSettings: Bool {
            if case .settings = self { return true }
            return false
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
        Group {
            // First launch takes the whole window. The sidebar is navigation, and there is
            // nowhere to navigate to until the app can hear you.
            if services.onboarding.isComplete {
                shell.transition(.opacity)
            } else {
                OnboardingView(services: services).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: services.onboarding.isComplete)
        // One ground behind everything, so no layout state leaves a strip unpainted.
        .background(InkGround())
        .font(Theme.Text.body)
        .foregroundStyle(Theme.Palette.text)
        .tint(Theme.Palette.gold)
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .onAppear {
            // Land on the thing that needs attention rather than hiding a broken
            // permission behind a row the user has no reason to click. Not on a first
            // launch, where the flow covering the window is already that landing.
            if services.onboarding.isComplete, !services.permissions.allGranted {
                services.openSettings(.privacyData)
            }
        }
    }

    /// The sidebar and the section it selects — the window on every launch but the first.
    private var shell: some View {
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
    }

    /// The app's sections on top, Settings pinned to the bottom — where configuration
    /// belongs: last, out of the way, and always in the same place. It used to swap the
    /// whole list for its four panes, which made "where did Home go?" the price of
    /// opening it; now the panes unfold above the gear, and the app's own rows never move.
    ///
    /// Selection is drawn by `SelectableRow`, not by `List`. The system highlight is
    /// `controlAccentColor` — a system-wide setting no app can override — so a selected row
    /// arrived bright blue in the middle of a navy and gold interface.
    private var sidebar: some View {
        // The header takes the title bar's own height, read from the safe area rather than
        // assumed, so it sits exactly where AppKit's title did whatever this macOS makes the
        // bar. Only the stack below ignores the inset; the reader keeps it so it can be read.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                SidebarHeader()
                    .frame(height: proxy.safeAreaInsets.top)

                List {
                    topLevel
                }
                .listStyle(.sidebar)
                // Hidden, or `List` paints its own opaque sidebar material and the window
                // ends up with a grey column beside a navy one.
                .scrollContentBackground(.hidden)

                settingsBlock
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder
    private var topLevel: some View {
        ForEach(Route.top, id: \.self) { route in
            sidebarRow(
                route.label, symbol: route.symbol, isSelected: services.route == route
            ) {
                services.route = route
            }
        }

    }

    /// The gear, and — while Settings is open — its four panes unfolded above it. Not a
    /// `Route` of its own: there is no detail view for "Settings", only for the sections
    /// inside it, so the gear either opens the level or puts you back where you were.
    @ViewBuilder
    private var settingsBlock: some View {
        if services.route.isSettings {
            VStack(spacing: 1) {
                ForEach(SettingsPane.allCases) { pane in
                    sidebarRow(
                        pane.label, symbol: pane.symbol,
                        isSelected: services.route == .settings(pane)
                    ) {
                        services.route = .settings(pane)
                    }
                }
                sidebarRow(
                    "Settings", symbol: "gearshape", isSelected: false,
                    trailing: "chevron.down", isTitle: true
                ) {
                    services.closeSettings()
                }
            }
        } else {
            sidebarRow(
                "Settings", symbol: "gearshape", isSelected: false, trailing: "chevron.up"
            ) {
                services.openSettings()
            }
        }
    }

    private func sidebarRow(
        _ label: String,
        symbol: String,
        isSelected: Bool,
        trailing: String? = nil,
        isTitle: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        SelectableRow(isSelected: isSelected) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    // A fixed width, so the labels line up whatever the glyph's shape.
                    .frame(width: 17)
                    .foregroundStyle(isSelected ? Theme.Palette.gold : Theme.Palette.muted)
                Text(label)
                    .font(isTitle ? Theme.Text.bodyStrong : Theme.Text.body)
                    .foregroundStyle(
                        isSelected || isTitle ? Theme.Palette.text : Theme.Palette.muted
                    )
                Spacer(minLength: 0)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.faint)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .onTapGesture(perform: action)
    }

    @ViewBuilder
    private var detail: some View {
        switch services.route {
        case .home:
            HomeView(services: services, onOpen: { services.route = $0 })
        case .dictation:
            DictationView(
                dictation: services.dictation,
                history: services.history,
                prompts: services.prompts
            )
        case .notetaker:
            NotetakerView(
                notes: services.notes,
                meetings: services.meetings,
                settings: services.settings,
                prompts: services.prompts,
                permissions: services.permissions
            )
        case .insights:
            InsightsView(history: services.history)
        case .settings(let pane):
            SettingsPaneView(pane: pane, services: services)
        }
    }

}

/// The window's name with the mark in front of it, in the title bar's row.
///
/// Drawn by the app rather than AppKit — the system title is hidden in `AppDelegate` — so
/// the mark can sit beside the name. Most Mac apps leave their face to the Dock; this one
/// has no Dock icon, so the window is where it has to show it.
struct SidebarHeader: View {
    /// Clear of the traffic lights, which end near 80 pt on this macOS. The name then
    /// lands within a few points of where AppKit drew the title.
    static let leading: CGFloat = 92

    var body: some View {
        HStack(spacing: 8) {
            MurmrMarkShape()
                .fill(Theme.Palette.gold)
                .frame(width: 15, height: 15)
            Text("Murmr Flow")
                .font(Theme.Text.bodyStrong)
                .foregroundStyle(Theme.Palette.text)
        }
        .padding(.leading, Self.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
