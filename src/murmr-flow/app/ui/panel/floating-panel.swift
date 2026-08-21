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
    private var host: NSHostingView<PanelView>?

    /// Where the user dragged it to: the **centre** of its bottom edge, not a corner.
    ///
    /// Storing a corner meant every resize had to guess how to compensate, and the guess
    /// drifted a few points each time the panel grew or shrank. An anchor the panel is
    /// laid out *around* stays correct at any size.
    ///
    /// Nil means bottom-centre of whichever screen the pointer is on.
    private var pinnedAnchor: CGPoint? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: Self.anchorKey) else {
                return nil
            }
            let parts = stored.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Self.anchorKey)
                return
            }
            UserDefaults.standard.set("\(newValue.x),\(newValue.y)", forKey: Self.anchorKey)
        }
    }

    /// Deliberately a new key. The previous one accumulated a position saved from our own
    /// resizes, so anything stored under it is wrong.
    private static let anchorKey = "panel.anchor"

    init() {
        model.onPickPrompt = { [weak self] point in self?.showPromptMenu(at: point) }
    }

    // MARK: - Lifecycle

    func present() {
        if panel == nil { build() }
        apply()
        panel?.orderFrontRegardless()
    }

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
        let origin = self.origin(for: size, current: panel.frame)

        // The flag has to wrap `setFrame` itself. It used to be set and cleared inside the
        // origin calculation, which meant it was already false by the time the window
        // moved — so every resize we performed was recorded as a user drag, and the panel
        // pinned itself on first launch and then crept off centre.
        isAdjusting = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        isAdjusting = false

        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: - Building

    private func build() {
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: model.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Interactive, unlike its predecessor. Safe only because the window never becomes
        // key — see NonActivatingPanel.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: PanelView(model: model))
        host.frame = NSRect(origin: .zero, size: model.size)
        // Without this the hosting view keeps its original size while the window resizes
        // around it, so the contents stop being centred the first time the panel grows.
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        // Remember a drag. `didMove` also fires for our own resizes, so only a move that
        // isn't ours counts — hence the flag around setFrame.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !self.isAdjusting else { return }
                let frame = panel.frame
                self.pinnedAnchor = CGPoint(x: frame.midX, y: frame.minY)
            }
        }

        self.panel = panel
        self.host = host
    }

    private var isAdjusting = false

    /// Lays the panel out around its anchor, so growing is symmetrical and repeatable.
    private func origin(for size: CGSize, current: NSRect) -> CGPoint {
        let anchor = pinnedAnchor ?? defaultAnchor()
        return CGPoint(x: (anchor.x - size.width / 2).rounded(), y: anchor.y.rounded())
    }

    /// Bottom-centre of whichever screen holds the pointer, so on a multi-display setup it
    /// appears where you are actually working.
    ///
    /// `frame`, not `visibleFrame`: a Dock on the left or right shifts the visible area
    /// sideways, and centring against that puts the panel visibly off the middle of the
    /// screen. The bottom inset is taken from `visibleFrame` so a bottom Dock is cleared.
    private func defaultAnchor() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let screen else { return .zero }
        return CGPoint(x: screen.frame.midX, y: screen.visibleFrame.minY + 10)
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
            item.state = option.name == model.promptName ? .on : .off
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
