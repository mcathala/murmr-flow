import SwiftUI

/// The app window: a sidebar and one section at a time.
///
/// This replaced four tabs, two of which were configuration. Settings is now a real
/// Settings scene reachable with ⌘, — the macOS convention — which leaves the sidebar for
/// the three things you actually made or use.
///
/// Resizable, and much larger than before: Notes is a list beside a reading pane, which
/// simply does not fit in the 400×480 the tabs lived in.
struct MainWindow: View {

    let services: AppServices

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case home, dictaphone, notes

        var id: String { rawValue }

        var label: String {
            switch self {
            case .home: "Home"
            case .dictaphone: "Dictaphone"
            case .notes: "Notes"
            }
        }

        var symbol: String {
            switch self {
            case .home: "square.grid.2x2"
            case .dictaphone: "mic"
            case .notes: "text.document"
            }
        }
    }

    @State private var section: Section = .home
    @Environment(\.openSettings) private var openSettings

    static let minSize = CGSize(width: 900, height: 600)

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 240)
        } detail: {
            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { toolbar }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .onAppear {
            // Land somewhere useful when something needs attention, rather than hiding a
            // broken permission behind a section the user has no reason to open.
            if !services.permissions.allGranted { openSettings() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .home:
            HomeView(services: services, onOpen: { section = $0 })
        case .dictaphone:
            DictaphoneView(
                dictation: services.dictation,
                history: services.history,
                prompts: services.prompts
            )
        case .notes:
            NotesView(notes: services.notes, meetings: services.meetings)
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
