import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// The parts of this window AppKit draws rather than SwiftUI, so no snapshot reaches them.
///
/// What is asserted here is the app's own configuration, not how a given macOS chooses to
/// paint a title bar. An earlier version of this suite asserted the latter — that the title
/// bar had no material left in it after styling — and it was wrong twice over: it passed on
/// 26.0 and failed on the 15 that CI runs, and the band it claimed to be about was never
/// the material anyway. That one is Apple's, FB20341654, and the answer to it is
/// `.windowStyle(.hiddenTitleBar)` on the scene, which is a scene modifier and not
/// something a window can be asked about afterwards.
@Suite("The window's title bar", .serialized)
@MainActor
struct WindowChromeTests {

    private func window() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    // MARK: - How the window is set up

    @Test("styling leaves the window the way the app draws into")
    func styleSetsTheWindowUp() {
        let window = window()
        WindowChrome.applyStyle(to: window)

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.toolbar == nil, "a toolbar draws a platter across the top")
        // So a frame before SwiftUI has drawn is the app's navy, not the system's grey.
        #expect(window.backgroundColor != .windowBackgroundColor)
    }

    @Test("the traffic lights survive it")
    func buttonsAreLeftAlone() {
        let window = window()
        WindowChrome.applyStyle(to: window)

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)
            #expect(button != nil, "\(kind) is gone")
            #expect(button?.isHidden == false, "\(kind) was hidden")
        }
    }

    /// It runs on every window the scene makes, and again whenever the title comes back.
    @Test("styling twice is the same as styling once")
    func styleIsIdempotent() {
        let window = window()
        WindowChrome.applyStyle(to: window)
        WindowChrome.applyStyle(to: window)

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
    }

    // MARK: - The slot the toggle sits in

    /// The regression that shipped to the running app: an `NSHostingView` given straight
    /// to a title bar accessory arrives with a zero frame, AppKit sizes the slot from the
    /// frame rather than the fitting size, and the toggle came out 0 pt wide — present, in
    /// the right place, and invisible, so the sidebar could not be put away at all.
    @Test("an accessory view is zero-width until it is sized")
    func accessoryNeedsSizing() {
        let hosting = NSHostingView(rootView: Text("Home").frame(height: 28))
        #expect(hosting.frame.width == 0, "the premise of `size(_:)` no longer holds")
        #expect(hosting.fittingSize.width > 0)

        WindowChrome.size(hosting)
        #expect(hosting.frame.width == hosting.fittingSize.width)
        #expect(hosting.frame.width > 0)
    }

}
