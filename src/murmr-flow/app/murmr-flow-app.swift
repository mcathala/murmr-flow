import SwiftUI

/// Phase 0: a menu-bar stub whose only job is to prove that macOS permission grants
/// survive a rebuild.
///
/// There is deliberately no audio capture, no hotkey, and no transcription yet. If
/// signing is wrong, every one of those features becomes miserable to develop, so the
/// signing harness is proven first.
@main
struct MurmrFlowApp: App {

    @State private var permissions = PermissionManager()
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
            PermissionsPanel(permissions: permissions)
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
