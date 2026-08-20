import SwiftUI

/// Phase 1: microphone in, transcribed text out.
///
/// There is no hotkey and no text injection yet — the transcript is displayed rather
/// than typed at the cursor. Those arrive in Phase 2, along with AI cleanup.
@main
struct MurmrFlowApp: App {

    @State private var permissions = PermissionManager()
    @State private var dictation = DictationCoordinator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A real window, not only a menu-bar item.
        //
        // The menu bar is not a reliable place to *find* something: on a notched
        // MacBook with a busy menu bar, new items get pushed into the hidden overflow
        // region and are simply invisible. With external displays the item also only
        // appears on whichever screen currently owns the menu bar.
        //
        // This window also becomes the Settings window later, so it isn't throwaway
        // scaffolding.
        Window("Murmr Flow", id: Self.panelWindowID) {
            // No ScrollView here: it has no intrinsic height, so
            // `windowResizability(.contentSize)` would collapse the window to the first
            // subview. Stack the panels and let the content size the window.
            VStack(spacing: 0) {
                PermissionsPanel(permissions: permissions)
                Divider()
                DictationPanel(coordinator: dictation)
            }
            .frame(width: 380)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            PermissionsPanel(permissions: permissions)
        } label: {
            // Filled icon once everything is granted, hollow while something is missing.
            Image(systemName: permissions.allGranted ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }

    static let panelWindowID = "panel"
}
