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
            Self.stripSyntheticToolbar()
        }
    }

    /// SwiftUI creates the window some time after launch, so poll rather than assuming
    /// it already exists. Three seconds because the window arrives later once there is
    /// more to build than an empty view.
    private func presentMainWindow() {
        Task { @MainActor in
            for _ in 0..<60 {
                if let window = Self.mainWindow() {
                    Self.makeDark(window)
                    Self.stripSyntheticToolbarWhenReady()
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

    /// Empties the toolbar SwiftUI builds for us.
    ///
    /// `NavigationSplitView` installs three items nobody asked for — a flexible space, a
    /// sidebar toggle and a split-view separator — and a toolbar with items has a clipped
    /// items indicator: `NSToolbarClippedItemsIndicator`, accessibility label
    /// "more toolbar items", the round `»` AppKit parks at the trailing edge. Collapsing the
    /// sidebar takes its titlebar region to nothing, so the toggle no longer fits, so the
    /// indicator appeared — and went again once the animation settled. A button flashing in
    /// and out at the top right of the window.
    ///
    /// Found by logging every change in the title bar's view tree while the fault was
    /// reproduced. Worth remembering that this is what it took: five SwiftUI APIs claim to
    /// control this and none of them do anything —`.toolbar(removing: .sidebarToggle)`,
    /// `.toolbar(.hidden, for: .windowToolbar)`, `CommandGroup(replacing: .sidebar) {}`,
    /// a constant `columnVisibility` binding, and `NSSplitViewItem.canCollapse = false`.
    /// Removing the items from the `NSToolbar` is the one thing that works, and SwiftUI does
    /// not put them back.
    ///
    /// What goes with them is the toggle *button*. Collapsing still works — it is the split
    /// view controller's behaviour, not the toolbar's — so View ▸ Toggle Sidebar and ⌃⌘S are
    /// unaffected.
    ///
    /// Removes everything, because the app has no toolbar items of its own. Adding one means
    /// sparing it here.
    @MainActor
    private static func stripSyntheticToolbar() {
        guard let toolbar = mainWindow()?.toolbar, !toolbar.items.isEmpty else { return }
        for index in toolbar.items.indices.reversed() {
            toolbar.removeItem(at: index)
        }
    }

    /// Waits for the items to exist before removing them.
    ///
    /// The window is on screen before SwiftUI has populated its toolbar, so stripping once
    /// at that moment finds nothing and does nothing — then the items arrive. Keeps checking
    /// for a few seconds, which also covers them being rebuilt during that window.
    @MainActor
    private static func stripSyntheticToolbarWhenReady() {
        Task { @MainActor in
            for _ in 0..<60 {
                stripSyntheticToolbar()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Ink commits, and `.preferredColorScheme(.dark)` only reaches what SwiftUI draws.
    ///
    /// The title bar's background, the toolbar, and the rounded platter AppKit parks behind
    /// a toolbar item are all AppKit's own, and they resolve against the *window's*
    /// appearance. Without this they follow the system setting, so on a Mac in Light Mode
    /// they came out pale grey against a navy window — which is what made the strip above
    /// the sidebar read as a different panel, and the sidebar toggle as a grey pill. The
    /// floating panel already sets this, for the same reason.
    @MainActor
    private static func makeDark(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        // Nothing of ours draws up there, so let the window's own ground fill the title bar
        // rather than having AppKit paint a second surface that then has to match it.
        window.titlebarAppearsTransparent = true
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
