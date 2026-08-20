import AppKit

/// Window handling for an accessory (`LSUIElement`) app.
///
/// Two things go wrong without this, both of which look like "the app didn't launch":
///
///  1. An accessory app does not order its windows on screen or take focus by itself.
///     The `Window` scene is created but never displayed — `CGWindowListCopyWindowInfo`
///     reports it with `onscreen=nil`. It has to be ordered front explicitly.
///  2. Closing the window would otherwise be a dead end: the process keeps running
///     with nothing on screen, and `open` just reactivates it without restoring the
///     window.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { presentMainWindow() }
        return true
    }

    /// SwiftUI creates the window slightly after `didFinishLaunching`, so poll briefly
    /// rather than assuming it already exists.
    private func presentMainWindow() {
        Task { @MainActor in
            for _ in 0..<20 {
                if let window = NSApp.windows.first(where: \.canBecomeMain) {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
