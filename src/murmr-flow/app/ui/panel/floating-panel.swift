import AppKit
import SwiftUI

/// Hosts the floating panel.
///
/// Replaces the old status pill, which was a fixed 240×52, ignored every click, and could
/// only report. This one acts — which means it has to take mouse events **without ever
/// becoming key**, because dictation pastes into whatever app you were typing in. If this
/// window steals focus, the text lands in the wrong place.
@MainActor
final class FloatingPanel {

    let model = PanelModel()

    private var panel: NSPanel?
    private var host: NSView?

    /// The display the panel is currently sitting on, so a change of screen can be
    /// noticed without repositioning the window ten times a second.
    ///
    /// Compared by frame rather than by identity: `NSScreen` instances are recreated when
    /// the display arrangement changes, so holding one and testing `===` would report a
    /// move that never happened.
    private var currentScreenFrame: CGRect?


    init() {
        model.onPickPrompt = { [weak self] point in self?.showPromptMenu(at: point) }
        // The phase decides the size, and hover changes the phase from inside the view.
        // Without this the window never resized for the states the pointer triggers.
        model.onPhaseChange = { [weak self] in
            guard let self else { return }
            self.apply()
            self.onPhaseChanged?(self.model.phase)
        }
    }

    // MARK: - Lifecycle

    /// Whether `window` is the pill itself — the one window whose clicks must not
    /// resurrect a pill that is being hidden.
    func owns(_ window: NSWindow?) -> Bool {
        window != nil && window === panel
    }

    func present() {
        if panel == nil { build() }
        apply()
        panel?.orderFrontRegardless()
    }

    /// The window's current size, for tests that need to check it followed the phase.
    var windowSize: CGSize? { panel?.frame.size }

    func dismiss() {
        panel?.orderOut(nil)
    }

    /// Called on every state change. Resizes and repositions, keeping the bottom edge
    /// anchored so growing never moves the panel out from under the pointer.
    func apply() {
        guard let panel else { return }

        if model.isHidden && !model.phase.isBusy {
            panel.orderOut(nil)
            return
        }

        let size = model.size
        let origin = self.origin(for: size)

        // The flag has to wrap `setFrame` itself. It used to be set and cleared inside the
        // origin calculation, which meant it was already false by the time the window
        // moved — so every resize we performed was recorded as a user drag, and the panel
        // pinned itself on first launch and then crept off centre.
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        currentScreenFrame = pointerScreen()?.frame

        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: - Building

    private func build() {
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: model.size),
            // No `.fullSizeContentView`: it only means anything on a window that *has* a
            // title bar, and pairing it with `.borderless` asks AppKit to fit chrome into a
            // window that has none. That is enough for it to install a frame view, which
            // draws a hairline rectangle at the window's bounds — visible around the pill
            // as an edge that belongs to no part of the design.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No shadow at all — not the window server's, and not one of our own drawn inside
        // the frame. The pill separates from the desktop on its rim light and its navy base,
        // both of which stay inside the window where nothing can clip them.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Interactive, unlike its predecessor. Safe only because the window never becomes
        // key — see NonActivatingPanel.
        panel.ignoresMouseEvents = false
        // Not movable. Position is derived from where the pointer is, so a dragged
        // position would be overwritten the moment you crossed to another display — and
        // a window that quietly undoes your drag is worse than one that never offered.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        // Ink is a dark design, and SwiftUI's `Material` resolves against the *environment's*
        // colour scheme — so on a Mac in Light Mode every pane would come out white. This
        // has to be set on the window as well as in SwiftUI: AppKit resolves materials at
        // its own level, and the two must agree or the blur and the tint disagree.
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(
            rootView: PanelView(model: model).environment(\.colorScheme, .dark)
        )
        host.frame = NSRect(origin: .zero, size: model.size)
        // Without this the hosting view keeps its original size while the window resizes
        // around it, so the contents stop being centred the first time the panel grows.
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
        self.host = host

    }

    /// Bottom-centre of whichever display the pointer is on, always.
    ///
    /// Not a remembered position. The panel is a target you throw the pointer at, so it
    /// has to be on the screen the pointer is already on — a pill parked on the other
    /// monitor is a pill you cannot reach. That rules out dragging it somewhere else,
    /// which is why the window is no longer movable: "wherever you left it" and "wherever
    /// you are" cannot both be true.
    ///
    /// `frame.midX` for the horizontal centre, not `visibleFrame.midX`: a Dock on the left
    /// or right shifts the visible area sideways, and centring against that would put the
    /// panel visibly off the middle of the screen. The bottom comes from `visibleFrame`,
    /// which is what clears a bottom Dock.
    private func origin(for size: CGSize) -> CGPoint {
        guard let screen = pointerScreen() else { return .zero }
        let visible = screen.visibleFrame
        let inset = Self.screenInset

        var x = screen.frame.midX - size.width / 2
        var y = visible.minY + inset

        // Clamped fully inside the visible area. A floating window at status-bar level is
        // entitled to overlap the Dock, so nothing stops it but this: the resting pill
        // cleared the Dock only because it is 18 points tall, and the hover state grew
        // tall enough to draw its buttons over the Dock icons.
        //
        // max(min:) rather than min(max:) so a panel wider than the screen ends up flush
        // left instead of flipping to a negative position.
        x = max(visible.minX + inset, min(x, visible.maxX - size.width - inset))
        y = max(visible.minY + inset, min(y, visible.maxY - size.height - inset))

        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// Kept clear of the screen edges — and of the Dock, since `visibleFrame` excludes it.
    private static let screenInset: CGFloat = 10

    private func pointerScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Moves the panel if the pointer has crossed to another display.
    ///
    /// Polled rather than driven by a global mouse monitor, which would want Input
    /// Monitoring permission for something this cosmetic. Reading the pointer position is
    /// cheap; the window is only touched when the screen actually changes.
    func followPointerIfNeeded() {
        guard let panel, panel.isVisible else { return }
        guard let screen = pointerScreen() else { return }
        guard screen.frame != currentScreenFrame else { return }
        currentScreenFrame = screen.frame
        apply()
    }

    // MARK: - Prompt menu

    /// A real `NSMenu` rather than a SwiftUI `Menu`.
    ///
    /// SwiftUI's menus want their window to become key to open, and this one never does.
    /// `NSMenu.popUp` has no such expectation.
    private func showPromptMenu(at point: NSPoint) {
        guard !model.promptOptions.isEmpty else { return }

        let menu = NSMenu()
        for option in model.promptOptions {
            let item = NSMenuItem(
                title: option.name, action: #selector(PromptTarget.pick(_:)), keyEquivalent: ""
            )
            item.state = option.name == model.activePromptName ? .on : .off
            item.representedObject = option.id
            let target = PromptTarget { [weak self] id in
                self?.onPromptChosen?(id)
            }
            item.target = target
            // The menu item holds the only strong reference to its target, so it has to
            // outlive the pop-up — parking it on the item does exactly that.
            targets.append(target)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: nil)
        targets.removeAll()
    }

    /// Set by the app; receives the chosen preset.
    var onPromptChosen: (@MainActor (UUID) -> Void)?

    /// Set by the app; fires after the window has been resized for a new phase.
    var onPhaseChanged: (@MainActor (PanelModel.Phase) -> Void)?

    private var targets: [PromptTarget] = []
}

/// Never becomes key, so clicking the panel cannot pull focus away from the app you were
/// typing into. Buttons still work: they act on mouse events, which do not require key
/// status.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Bridges an `NSMenuItem` action back to a closure.
@MainActor
private final class PromptTarget: NSObject {
    private let handler: (UUID) -> Void

    init(handler: @escaping (UUID) -> Void) {
        self.handler = handler
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        handler(id)
    }
}
