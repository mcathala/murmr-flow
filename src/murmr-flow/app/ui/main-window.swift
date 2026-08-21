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
        case settings(SettingsPane)

        static let top: [Route] = [.home, .dictaphone, .notes]

        var label: String {
            switch self {
            case .home: "Home"
            case .dictaphone: "Dictaphone"
            case .notes: "Notes"
            case .settings(let pane): pane.label
            }
        }

        var symbol: String {
            switch self {
            case .home: "square.grid.2x2"
            case .dictaphone: "mic"
            case .notes: "text.document"
            case .settings(let pane): pane.symbol
            }
        }
    }

    static let minSize = CGSize(width: 900, height: 600)

    var body: some View {
        NavigationSplitView {
            List(selection: routeBinding) {
                ForEach(Route.top, id: \.self) { route in
                    Label(route.label, systemImage: route.symbol).tag(route)
                }

                Section("Settings") {
                    ForEach(SettingsPane.allCases) { pane in
                        Label(pane.label, systemImage: pane.symbol)
                            .tag(Route.settings(pane))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 184, ideal: 198, max: 250)
        } detail: {
            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { toolbar }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .onAppear {
            // Land on the thing that needs attention rather than hiding a broken
            // permission behind a row the user has no reason to click.
            if !services.permissions.allGranted {
                services.route = .settings(.permissions)
            }
        }
    }

    /// `List` needs an optional binding for selection; a nil selection would otherwise
    /// clear the detail pane and leave the window blank.
    private var routeBinding: Binding<Route?> {
        Binding(
            get: { services.route },
            set: { if let value = $0 { services.route = value } }
        )
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
        case .settings(let pane):
            SettingsPaneView(pane: pane, services: services)
        }
    }

    /// Start/stop lives here rather than being Home's reason to exist, so it is one click
    /// away from every section.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                services.meetings.toggle()
            } label: {
                if services.meetings.stage.isRecording {
                    Label("Stop · \(MeetingTranscript.clock(services.meetings.elapsed))",
                          systemImage: "stop.fill")
                } else {
                    Label("Start meeting", systemImage: "record.circle")
                }
            }
            .disabled(isTranscribing)
            .tint(services.meetings.stage.isRecording ? .red : .accentColor)
        }
    }

    private var isTranscribing: Bool {
        if case .transcribing = services.meetings.stage { return true }
        return false
    }
}
