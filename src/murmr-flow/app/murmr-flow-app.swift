import SwiftUI

/// Phase 2: hold the key, speak, release, and cleaned-up text appears at the cursor.
///
/// Startup lives in `AppDelegate` / `AppServices`, not here — see `AppServices` for why.
@main
struct MurmrFlowApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var services: AppServices { AppServices.shared }

    var body: some Scene {
        // A window as well as a menu-bar item. On a notched MacBook with a busy menu bar,
        // new items land in the hidden overflow region and are simply invisible; with
        // external displays they only appear on whichever screen owns the menu bar.
        Window("Murmr Flow", id: Self.panelWindowID) {
            MainWindow(permissions: services.permissions, dictation: services.dictation)
                // Backstop: see AppServices.start() for why this is not the only trigger.
                .task { services.start(trigger: "window.task") }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent(permissions: services.permissions, dictation: services.dictation)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    /// The icon carries the state, since the menu bar is often all that's visible.
    private var menuBarSymbol: String {
        let dictation = services.dictation
        if dictation.stage.isRecording { return "waveform.circle.fill" }
        if dictation.stage.isBusy { return "ellipsis.circle.fill" }
        if !services.permissions.allGranted { return "exclamationmark.circle" }
        return dictation.hotkeyActive ? "waveform.circle" : "waveform.circle.badge.xmark"
    }

    static let panelWindowID = "panel"
}
