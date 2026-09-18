import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// The two things about this window that no snapshot can catch, because AppKit draws them
/// rather than SwiftUI: the bar across the top, and the slot the toggle sits in.
///
/// Both were bugs. The bar washed out the mark and the name drawn under it. The slot was
/// installed in the right place at zero width, so the toggle was simply not there and the
/// sidebar could not be put away at all.
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

    // MARK: - The bar across the top

    @Test("a plain window has a material across its top")
    func materialIsThereToBeginWith() {
        // The premise. If macOS ever stops putting one there, `applyStyle` is no longer
        // load-bearing and this suite should say so here rather than pass quietly.
        #expect(!WindowChrome.visibleTitlebarMaterials(in: window()).isEmpty)
    }

    /// Transparency alone was not the fix, which is what made the first attempt at this
    /// misleading: the window was missing `.fullSizeContentView`, so its content began
    /// below the bar and the bar still had a surface of its own to paint.
    @Test("transparency on its own does not remove it")
    func transparencyIsNotEnough() {
        let window = window()
        window.titlebarAppearsTransparent = true
        #expect(!WindowChrome.visibleTitlebarMaterials(in: window).isEmpty)
    }

    @Test("full-size content on its own does not remove it")
    func fullSizeIsNotEnough() {
        let window = window()
        window.styleMask.insert(.fullSizeContentView)
        #expect(!WindowChrome.visibleTitlebarMaterials(in: window).isEmpty)
    }

    /// The subtle one, and the reason `applyStyle` reads in the order it does. Changing
    /// the style mask rebuilds the title bar, and the rebuild only drops the background
    /// material if the window was already transparent when it happened.
    @Test("the order the two are set in decides whether the bar goes")
    func orderDecidesIt() {
        let maskFirst = window()
        maskFirst.styleMask.insert(.fullSizeContentView)
        maskFirst.titlebarAppearsTransparent = true
        #expect(
            !WindowChrome.visibleTitlebarMaterials(in: maskFirst).isEmpty,
            "the wrong order has stopped mattering; `applyStyle`'s comment is now wrong"
        )

        let transparentFirst = window()
        transparentFirst.titlebarAppearsTransparent = true
        transparentFirst.styleMask.insert(.fullSizeContentView)
        #expect(WindowChrome.visibleTitlebarMaterials(in: transparentFirst).isEmpty)
    }

    @Test("the app's own styling leaves nothing painting up there")
    func styleRemovesIt() {
        let window = window()
        WindowChrome.applyStyle(to: window)
        #expect(WindowChrome.visibleTitlebarMaterials(in: window).isEmpty)
    }

    @Test("the traffic lights survive it")
    func buttonsAreLeftAlone() {
        let window = window()
        WindowChrome.applyStyle(to: window)

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(kind)
            #expect(button != nil, "\(kind) is gone")
            #expect(button?.isHidden == false, "\(kind) was hidden with the material")
        }
    }

    @Test("styling twice is the same as styling once")
    func styleIsIdempotent() {
        let window = window()
        WindowChrome.applyStyle(to: window)
        WindowChrome.applyStyle(to: window)
        #expect(WindowChrome.visibleTitlebarMaterials(in: window).isEmpty)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
    }

    // MARK: - The slot the toggle sits in

    /// The regression that shipped: an `NSHostingView` given straight to a title bar
    /// accessory arrives with a zero frame, AppKit sizes the slot from the frame rather
    /// than the fitting size, and the toggle came out 0 pt wide — present, in the right
    /// place, and invisible.
    @Test("an accessory view is zero-width until it is sized")
    func accessoryNeedsSizing() {
        let hosting = NSHostingView(rootView: Text("Home").frame(height: 28))
        #expect(hosting.frame.width == 0, "the premise of `size(_:)` no longer holds")
        #expect(hosting.fittingSize.width > 0)

        WindowChrome.size(hosting)
        #expect(hosting.frame.width == hosting.fittingSize.width)
        #expect(hosting.frame.width > 0)
    }

    /// The slot is measured once and never again, so it is sized for the longest name the
    /// app can show rather than the one it happens to be showing.
    @Test("the slot fits every section name, not just the short ones")
    func slotFitsTheLongestName() {
        let names = MainWindow.Route.top.map(\.label) + SettingsPane.allCases.map(\.label)
        let font =
            NSFont(name: Theme.Face.ui, size: 13)
            ?? NSFont.systemFont(ofSize: 13, weight: .medium)

        for name in names {
            let text = (name as NSString).size(withAttributes: [.font: font]).width
            // The glyph, the mark, the gaps and the padding around them.
            #expect(
                TitleBarControls.width >= text + 77,
                "\(name) would be cut off in the title bar"
            )
        }
    }
}
