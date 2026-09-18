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
        window.appearance = NSAppearance(named: .darkAqua)
        // The content view runs the full height of the window, title bar included, so the
        // sidebar's ground reaches the top edge rather than starting below a bar.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // The app draws its own name — see `SidebarHeader` and `TitleBarControls`. The
        // title string stays: it is how this window is found.
        window.titleVisibility = .hidden
        // Two more surfaces AppKit draws across the top if it is left to: a toolbar's
        // platter, and the hairline under the bar. Neither belongs on a window whose
        // ground is meant to be continuous from the traffic lights down.
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        removeTitlebarMaterial(window)
        installControls(window)
        // Opened from the menu bar while the window sits on another Space, macOS would
        // otherwise switch the whole screen over to it. The window comes to the user
        // instead: the menu bar is where they are, so that is where the app should be.
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    // MARK: - The bar across the top

    /// Removes the blurred bar macOS draws across the top of the window.
    ///
    /// `titlebarAppearsTransparent` clears the title bar's *background colour* and nothing
    /// else. The bar is also an `NSVisualEffectView`, and it sits in the frame view —
    /// above the content view, not behind it. So the sidebar's glass stopped a title
    /// bar's height short of the window's top edge, and the mark and the name drawn up
    /// there came out grey on navy. That was the washed-out header: not ink that was too
    /// dark, but a surface laid over it.
    ///
    /// The material is a view, so it can be found and hidden. Only `NSVisualEffectView`s
    /// are touched — the traffic lights are plain buttons alongside them and are left
    /// exactly where AppKit put them. Nothing here is load-bearing: if the hierarchy ever
    /// changes shape the search finds nothing, says so in the log, and the window is the
    /// one we had before.
    /// Separate from `dress(_:)`, and not private, so a test can put a real `NSWindow`
    /// through it and count what is left. This is the one part of the window that cannot
    /// be caught in a snapshot, because it is not SwiftUI that draws it.
    @MainActor
    static func removeTitlebarMaterial(_ window: NSWindow) {
        guard let frame = window.contentView?.superview else {
            log.notice("no frame view; the bar across the top is left alone")
            return
        }
        for container in frame.subviews where isTitlebarContainer(container) {
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            for effect in materials(in: container) { effect.isHidden = true }
        }
        if !visibleTitlebarMaterials(in: window).isEmpty {
            log.notice("a title bar material is still showing")
        }
    }

    /// What `removeTitlebarMaterial(_:)` is meant to leave behind: nothing.
    @MainActor
    static func visibleTitlebarMaterials(in window: NSWindow) -> [NSVisualEffectView] {
        guard let frame = window.contentView?.superview else { return [] }
        return frame.subviews
            .filter(isTitlebarContainer)
            .flatMap(materials(in:))
            .filter { !$0.isHidden }
    }

    private static func isTitlebarContainer(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("TitlebarContainerView")
    }

    /// Only `NSVisualEffectView`s. The traffic lights are plain buttons alongside them, so
    /// a search that reached for their superviews would take the buttons with it.
    private static func materials(in view: NSView) -> [NSVisualEffectView] {
        var found: [NSVisualEffectView] = []
        if let effect = view as? NSVisualEffectView { found.append(effect) }
        for subview in view.subviews { found += materials(in: subview) }
        return found
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
        let controller = NSTitlebarAccessoryViewController()
        controller.view = hosting
        controller.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(controller)
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
        .frame(height: 28)
        .animation(.easeInOut(duration: 0.18), value: services.isSidebarCollapsed)
    }
}
