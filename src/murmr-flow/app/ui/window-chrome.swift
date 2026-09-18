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
                // KVO calls back on the thread that changed the value, which for a window
                // is the main thread — but the closure is typed `Sendable`, and the 6.1
                // compiler on CI (unlike 6.3 here) will not let it touch main-actor state
                // without being told that is where it runs.
                MainActor.assumeIsolated {
                    guard window.titleVisibility != .hidden else { return }
                    WindowChrome.log.notice("title shown again by the scene; hiding it")
                    WindowChrome.dress(window)
                }
            }
        }
    }

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "window")

    /// Ink commits, and `.preferredColorScheme(.dark)` only reaches what SwiftUI draws.
    ///
    /// The title bar's background, the toolbar, and the rounded platter AppKit parks
    /// behind a toolbar item are all AppKit's own, and they resolve against the *window's*
    /// appearance. Without this they followed the system setting, so on a Mac in Light
    /// Mode they came out pale grey against a navy window.
    @MainActor
    static func dress(_ window: NSWindow) {
        applyStyle(to: window)
        installControls(window)
        // Opened from the menu bar while the window sits on another Space, macOS would
        // otherwise switch the whole screen over to it. The window comes to the user
        // instead: the menu bar is where they are, so that is where the app should be.
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    /// Everything about how the window is drawn, and nothing about what is in it — so a
    /// test can put a plain `NSWindow` through it without standing up the whole app.
    ///
    /// **The first two lines are in that order on purpose.** Measured on macOS 26:
    /// changing the style mask rebuilds the title bar, and the rebuild leaves the
    /// background material out only if the window was already transparent when it
    /// happened. Set the other way round the material stayed. It costs nothing to keep
    /// them in the order that measured clean.
    ///
    /// Not asserted in the tests, because what a given macOS leaves in its title bar is
    /// that macOS's business and differs by version — the tests check that this window is
    /// configured the way the app draws into, which is the part that is ours. The grey
    /// band across the top is a separate matter and a bug of Apple's: FB20341654, fixed
    /// in 26.1, answered by `.windowStyle(.hiddenTitleBar)` on the scene in
    /// `MurmrFlowApp`, where the reasoning for it lives.
    @MainActor
    static func applyStyle(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        // The content view runs the window's full height, title bar included.
        window.styleMask.insert(.fullSizeContentView)

        window.appearance = NSAppearance(named: .darkAqua)
        // The app draws its own name — see `SidebarHeader` and `TitleBarControls`. The
        // title string stays: it is how this window is found.
        window.titleVisibility = .hidden
        // Two more surfaces AppKit draws across the top if it is left to: a toolbar's
        // platter, and the hairline under the bar. Neither belongs on a window whose
        // ground is meant to be continuous from the traffic lights down.
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        // Whatever shows through before or between SwiftUI's passes is the ground's own
        // colour rather than the system's grey. `deep` rather than `abyss`, because the
        // one place this is ever seen is the top of the window, and that is the end of
        // `InkGround`'s gradient that starts there.
        window.backgroundColor = NSColor(Theme.Palette.deep)
    }

    // MARK: - The controls in the title bar's row

    private static let controlsIdentifier =
        NSUserInterfaceItemIdentifier("murmr.titlebar.controls")

    /// Puts the sidebar toggle in the title bar's row, as a title bar accessory rather
    /// than as SwiftUI drawn underneath one.
    ///
    /// Two reasons it has to be AppKit's own. The title bar takes mouse events for
    /// dragging the window, so a button drawn under it is a button that moves the window
    /// instead of pressing. And `.leading` asks AppKit where the traffic lights end —
    /// which is the number `SidebarHeader` used to hardcode as 92, and which would have
    /// been wrong the first time macOS moved them.
    @MainActor
    private static func installControls(_ window: NSWindow) {
        let existing = window.titlebarAccessoryViewControllers.contains {
            $0.view.identifier == controlsIdentifier
        }
        guard !existing else { return }

        let hosting = NSHostingView(rootView: TitleBarControls(services: AppServices.shared))
        hosting.identifier = controlsIdentifier
        size(hosting)
        let controller = NSTitlebarAccessoryViewController()
        controller.view = hosting
        controller.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(controller)
    }

    /// Gives the accessory its width, which AppKit will not work out on its own.
    ///
    /// An `NSHostingView` handed straight to a `NSTitlebarAccessoryViewController` arrives
    /// with a zero frame, and AppKit sizes the slot from the frame rather than from the
    /// view's fitting size — so the toggle was installed, in the right place, 0 pt wide,
    /// and the title bar looked empty. Setting the frame is what fills the slot;
    /// `translatesAutoresizingMaskIntoConstraints` and `sizingOptions` were each measured
    /// and neither made any difference.
    @MainActor
    @discardableResult
    static func size(_ view: NSView) -> NSView {
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        return view
    }
}

/// The sidebar toggle, and — while the column is away — the mark and the section you are in.
///
/// The toggle is in the same place in both states. That is the point of putting it here:
/// the control that brings the navigation back cannot itself live somewhere that depends
/// on the navigation being there.
struct TitleBarControls: View {

    let services: AppServices

    @State private var isHovering = false

    private var toggleLabel: String {
        services.isSidebarCollapsed ? "Show sidebar" : "Hide sidebar"
    }

    /// Fixed, and as wide as the longest section name the app can put here.
    ///
    /// A title bar accessory does not follow its content. AppKit measures the slot once,
    /// from the view's frame, and never asks again — measured: the slot stayed at 85 pt
    /// while the content had grown to want 136, so "Privacy & data" would have been cut
    /// off where "Home" fitted. Sizing it for the worst case and leaving the row
    /// left-aligned inside costs nothing, because what is beside it is empty title bar.
    static let width: CGFloat = {
        let font =
            NSFont(name: Theme.Face.ui, size: 13)
            ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        let names =
            MainWindow.Route.top.map(\.label) + SettingsPane.allCases.map(\.label)
        let widest =
            names
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 90
        // leading 6, glyph 24, gap 9, mark 15, gap 9, the name, trailing 14. Two points
        // of slack, because the measured width is the face's and the rendered one is
        // SwiftUI's and they are not always the same to the pixel.
        return 6 + 24 + 9 + 15 + 9 + ceil(widest) + 14 + 2
    }()

    var body: some View {
        HStack(spacing: 9) {
            Button {
                services.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13))
                    .foregroundStyle(isHovering ? Theme.Palette.text : Theme.Palette.muted)
                    .frame(width: 24, height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHovering ? Color.white.opacity(0.09) : Color.clear)
                    }
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(toggleLabel)
            .accessibilityLabel(toggleLabel)

            // Only while the column is away. With it open the name is already at the top
            // of it, and 198 pt cannot hold "Murmr Flow" beside the traffic lights — which
            // is what made the old header illegible in the first place.
            if services.isSidebarCollapsed {
                MurmrMarkShape()
                    .fill(Theme.Palette.gold)
                    .frame(width: 15, height: 13.5)
                Text(services.route.label)
                    .font(Theme.Text.bodyStrong)
                    .foregroundStyle(Theme.Palette.text)
                    .fixedSize()
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(width: Self.width, height: 28, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: services.isSidebarCollapsed)
    }
}
