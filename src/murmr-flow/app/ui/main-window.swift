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

    var body: some View {
        NavigationSplitView {
            // Selection is drawn by `SelectableRow`, not by `List`. The system highlight
            // is `controlAccentColor` — a system-wide setting no app can override — so a
            // selected row arrived bright blue in the middle of a navy and gold interface.
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
            // The sidebar's own background is hidden so the ground shows through it. Left
            // in place, `List` paints an opaque sidebar material and the window ends up
            // with a grey column beside a navy one.
            .scrollContentBackground(.hidden)
            .glassColumn(.thick)
            .navigationSplitViewColumnWidth(min: 184, ideal: 198, max: 250)
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
            NotesView(notes: services.notes, meetings: services.meetings)
        case .insights:
            InsightsView(history: services.history)
        case .settings(let pane):
            SettingsPaneView(pane: pane, services: services)
        }
    }

}
