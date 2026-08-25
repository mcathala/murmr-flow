import SwiftUI

/// Dictation and meeting notes, on this machine.
///
/// Startup lives in `AppDelegate` / `AppServices`, not here — see `AppServices` for why.
@main
struct MurmrFlowApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    private var services: AppServices { AppServices.shared }

    var body: some Scene {
        // A window as well as a menu-bar item. On a notched MacBook with a busy menu bar,
        // new items land in the hidden overflow region and are simply invisible; with
        // external displays they only appear on whichever screen owns the menu bar.
        Window("Murmr Flow", id: Self.mainWindowID) {
            MainWindow(services: services)
                // Backstop: see AppServices.start() for why this is not the only trigger.
                .task { services.start(trigger: "window.task") }
                // Ink commits. Following the system appearance would mean the palette only
                // works for half the users, and materials resolving light against a navy
                // ground looks like a bug rather than a choice.
                .preferredColorScheme(.dark)
        }
        // Resizable now, not sized to its contents: Notes is a list beside a reading pane
        // and has to be able to grow.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 680)
        .commands {
            // Replaces the standard Settings item so ⌘, moves the sidebar rather than
            // opening a second window. A separate Settings scene also made
            // `canBecomeMain` ambiguous, which is how the main window ended up competing
            // with it for presentation.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    services.openSettings()
                    openWindow(id: Self.mainWindowID)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent(services: services)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    /// The icon carries the state, since the menu bar is often all that's visible.
    private var menuBarSymbol: String {
        let dictation = services.dictation
        // A meeting outranks everything: it is the one thing that can be running with no
        // other sign of it on screen.
        if services.meetings.stage.isRecording { return "record.circle.fill" }
        if dictation.stage.isRecording { return "waveform.circle.fill" }
        if dictation.stage.isBusy { return "ellipsis.circle.fill" }
        if !services.permissions.allGranted { return "exclamationmark.circle" }
        return dictation.hotkeyActive ? "waveform.circle" : "waveform.circle.badge.xmark"
    }

    /// Renamed from "panel", which now means the floating panel — one name for two very
    /// different windows was going to cause a mistake sooner or later.
    ///
    /// It doubles as the autosave key for the window's position, so the rename also
    /// discards the frame saved when the window was 400×480.
    static let mainWindowID = "main"
}
