import SwiftUI

/// Dictation and meeting notes, on this machine.
///
/// Startup lives in `AppDelegate` / `AppServices`, not here — see `AppServices` for why.
@main
struct MurmrFlowApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    private var services: AppServices { AppServices.shared }

    init() {
        // Before `AppServices.shared` exists: its stores read their defaults as they are
        // made, so a wipe after that would be a wipe of nothing.
        FreshStart.applyIfRequested()
    }

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
        // macOS 26.0 draws the title bar's own background even with
        // `titlebarAppearsTransparent` set — a grey band across the top of a navy window
        // that nothing the app draws could cover, because it is painted above the content
        // view. Apple's radar for it (FB20341654) is fixed in 26.1, and its reproduction
        // is a horizontal stack of a narrow view beside a scroll view with a vertical
        // scroller, which is this window exactly.
        //
        // Asking for the style up front is what avoids it: the window is built without a
        // title bar to draw rather than being told to stop drawing one afterwards. The
        // traffic lights and `TitleBarControls` are unaffected — they are the title bar's
        // accessories, not its background.
        .windowStyle(.hiddenTitleBar)
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

            // The keyboard route to the same thing the title bar's glyph does. ⌘\ is what
            // the apps that hide a sidebar have settled on, and it is not taken here.
            CommandGroup(after: .sidebar) {
                Button(services.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    services.toggleSidebar()
                }
                .keyboardShortcut("\\", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent(services: services)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    /// The icon carries the state, since the menu bar is often all that's visible.
    ///
    /// It is the mark in every state it can express — ready, dimmed for the hotkey being
    /// off, red while dictating, a dot for a missing grant — so the thing in the menu bar is
    /// the same thing as the app icon and the panel's meter. Two states swap to a symbol: a
    /// meeting being recorded, which must not be mistaken for dictation, and the pipeline
    /// working, which the mark has no face for.
    @ViewBuilder
    private var menuBarLabel: some View {
        let dictation = services.dictation
        // A meeting outranks everything: it is the one thing that can be running with no
        // other sign of it on screen.
        if services.meetings.stage.isRecording {
            Image(systemName: "record.circle.fill")
        } else if dictation.stage.isRecording {
            Image(nsImage: MurmrMark.menuBarImage(.recording))
        } else if dictation.stage.isBusy {
            Image(systemName: "ellipsis.circle.fill")
        } else if !services.permissions.allGranted {
            Image(nsImage: MurmrMark.menuBarImage(.permissionMissing))
        } else {
            Image(nsImage: MurmrMark.menuBarImage(dictation.hotkeyActive ? .ready : .hotkeyOff))
        }
    }

    /// Renamed from "panel", which now means the floating panel — one name for two very
    /// different windows was going to cause a mistake sooner or later.
    ///
    /// It doubles as the autosave key for the window's position, so the rename also
    /// discards the frame saved when the window was 400×480.
    static let mainWindowID = "main"
}
