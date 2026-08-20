import SwiftUI

/// The app window: three tabs at a fixed size.
///
/// Tabs rather than one long stack because two of the three screens are setup-time UI.
/// Stacked, they pushed the window to 932 pt — taller than a MacBook's usable height,
/// so the cleanup settings were simply unreachable.
///
/// The fixed outer frame is also what lets each tab scroll: a `ScrollView` has no
/// intrinsic height, so under `windowResizability(.contentSize)` it collapses unless
/// something above it supplies a definite one.
struct MainWindow: View {

    let permissions: PermissionManager
    @Bindable var dictation: DictationCoordinator

    enum Tab: String, Hashable {
        case dictate, cleanup, setup
    }

    @State private var selection: Tab = .dictate

    static let size = CGSize(width: 400, height: 480)

    var body: some View {
        TabView(selection: $selection) {
            DictateTab(dictation: dictation, permissions: permissions)
                .tabItem { Label("Dictate", systemImage: "mic") }
                .tag(Tab.dictate)

            CleanupTab(coordinator: dictation)
                .tabItem { Label("Cleanup", systemImage: "sparkles") }
                .tag(Tab.cleanup)

            SetupTab(permissions: permissions, dictation: dictation)
                .tabItem { Label("Setup", systemImage: "gearshape") }
                .tag(Tab.setup)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear {
            // Land on Setup when something needs attention, so a broken permission or a
            // missing model isn't hidden behind a tab the user has no reason to open.
            if !permissions.allGranted { selection = .setup }
        }
    }
}
