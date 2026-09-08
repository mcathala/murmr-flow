import AppKit
import OSLog
import SwiftUI

/// The AppKit side of the main window, applied to every window the scene ever makes.
///
/// `AppDelegate` dresses the window once at launch. But closing the window and reopening
/// it — from the menu, from ⌘, — hands SwiftUI a fresh `NSWindow` that has none of that,
/// so the system title came back and sat on top of the sidebar's own header, two names
/// printed over each other. A view that lives inside the window hears about every window
/// it is ever put in, which is the only hook that cannot miss one.
struct WindowChrome: NSViewRepresentable {

    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) {}

    final class ChromeView: NSView {
        private var titleWatch: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titleWatch = nil
            guard let window else { return }
            WindowChrome.dress(window)
            // The title also came back on switching to the Notetaker, whose split view and
            // list make SwiftUI reconsider the toolbar. Dressing every window this view
            // lands in fixed that in testing; the observer is the backstop for any path
            // that shows the title again, and says so in the log when it fires, so the
            // mechanism can be confirmed rather than guessed. The guard keeps it from
            // observing its own change.
            titleWatch = window.observe(\.titleVisibility, options: [.new]) { window, _ in
                guard window.titleVisibility != .hidden else { return }
                WindowChrome.log.notice("title shown again by the scene; hiding it")
                WindowChrome.dress(window)
            }
        }
    }

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "window")

    /// Ink commits, and `.preferredColorScheme(.dark)` only reaches what SwiftUI draws.
    ///
    /// The title bar's background, the toolbar, and the rounded platter AppKit parks
    /// behind a toolbar item are all AppKit's own, and they resolve against the *window's*
    /// appearance. Without this they follow the system setting, so on a Mac in Light Mode
    /// they came out pale grey against a navy window.
    @MainActor
    static func dress(_ window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        // Nothing of ours draws up there, so let the window's own ground fill the title
        // bar rather than having AppKit paint a second surface that then has to match it.
        window.titlebarAppearsTransparent = true
        // The sidebar draws the name itself, with the mark in front — see `SidebarHeader`.
        // The title string stays: it is how this window is found.
        window.titleVisibility = .hidden
        // Opened from the menu bar while the window sits on another Space, macOS would
        // otherwise switch the whole screen over to it. The window comes to the user
        // instead: the menu bar is where they are, so that is where the app should be.
        window.collectionBehavior.insert(.moveToActiveSpace)
    }
}
