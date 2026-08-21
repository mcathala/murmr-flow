import AppKit

/// Process lifecycle: window presentation and app-level startup.
///
/// Startup lives here rather than in a view's `.task` because the hotkey and the model
/// must be ready regardless of which windows happen to exist.
///
/// Two window problems are handled, both of which look like "the app didn't launch":
///
///  1. An accessory (`LSUIElement`) app does not order its windows on screen or take
///     focus by itself. The `Window` scene is created but never displayed —
///     `CGWindowListCopyWindowInfo` reports it with `onscreen=nil`.
///  2. Closing the window would otherwise be a dead end: the process keeps running with
///     nothing on screen, and `open` merely reactivates it without restoring the window.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppServices.shared.start(trigger: "didFinishLaunching")
        }
        presentMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { presentMainWindow() }
        return true
    }

    /// Re-check the hotkey whenever the app comes forward: the usual way Accessibility
    /// gets granted is the user leaving to System Settings and coming back.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AppServices.shared.armHotkeyIfPossible()
        }
    }

    /// SwiftUI creates the window some time after launch, so poll rather than assuming
    /// it already exists. Three seconds because the window arrives later once there is
    /// more to build than an empty view.
    private func presentMainWindow() {
        Task { @MainActor in
            for _ in 0..<60 {
                if let window = Self.mainWindow() {
                    Self.moveOnScreenIfNeeded(window)
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The main window, specifically.
    ///
    /// Matching the title we set is exact. `canBecomeMain` alone was never specific —
    /// any future scene would answer yes to it too — so the fallbacks are there only for
    /// the case where SwiftUI hasn't applied the title yet.
    @MainActor
    private static func mainWindow() -> NSWindow? {
        let windows = NSApp.windows
        if let titled = windows.first(where: { $0.title == "Murmr Flow" }) { return titled }
        if let identified = windows.first(where: {
            $0.identifier?.rawValue.contains(MurmrFlowApp.mainWindowID) == true
        }) { return identified }
        return windows.first { $0.canBecomeMain && $0.title != "Settings" }
    }

    /// macOS restores the last window position, which may be on a display that is no
    /// longer attached or arranged the same way. The window is then genuinely invisible
    /// and the app looks broken. Recentre it if its saved frame is not really on a screen.
    @MainActor
    private static func moveOnScreenIfNeeded(_ window: NSWindow) {
        let frame = window.frame
        let isVisibleSomewhere = NSScreen.screens.contains { screen in
            // Require a meaningful overlap, not a one-pixel corner.
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width > 80 && overlap.height > 80
        }
        guard !isVisibleSomewhere, let screen = NSScreen.main else { return }

        let visible = screen.visibleFrame
        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            )
        )
    }
}
