import AppKit
import Testing

@testable import MurmrFlow

/// The bar macOS draws across the top of a window.
///
/// Every other surface in the app can be checked in a snapshot, because SwiftUI draws it.
/// This one is AppKit's, it sits above the content view rather than behind it, and the
/// only way to know it is gone is to ask a real window what is left in its title bar.
///
/// It is worth a test rather than a look, because it is the thing that broke: with the
/// material in place the sidebar's ground stopped a title bar's height short of the
/// window's top edge, and the mark and name drawn up there came out grey on navy.
@Suite("The bar across the top", .serialized)
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

    @Test("a titled window arrives with a material in its title bar")
    func materialIsThereToBeginWith() throws {
        let window = window()
        window.titlebarAppearsTransparent = true
        // The premise of the fix. If this ever stops holding, the removal below is
        // testing nothing and the test should say so here rather than pass quietly.
        let found = WindowChrome.visibleTitlebarMaterials(in: window)
        #expect(
            !found.isEmpty,
            "no material to remove: `titlebarAppearsTransparent` may now be enough on its own"
        )
    }

    @Test("removing it leaves no material showing")
    func removalLeavesNothing() throws {
        let window = window()
        WindowChrome.removeTitlebarMaterial(window)
        #expect(WindowChrome.visibleTitlebarMaterials(in: window).isEmpty)
    }

    @Test("the traffic lights survive it")
    func buttonsAreLeftAlone() throws {
        let window = window()
        WindowChrome.removeTitlebarMaterial(window)

        for kind in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            let button = window.standardWindowButton(kind)
            #expect(button != nil, "\(kind) is gone")
            #expect(button?.isHidden == false, "\(kind) was hidden with the material")
        }
    }

    @Test("running it twice is the same as running it once")
    func removalIsIdempotent() throws {
        let window = window()
        WindowChrome.removeTitlebarMaterial(window)
        WindowChrome.removeTitlebarMaterial(window)
        #expect(WindowChrome.visibleTitlebarMaterials(in: window).isEmpty)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
    }
}
