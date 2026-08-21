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

    /// Where the user dragged it to, if they did. Nil means bottom-centre of whichever
    /// screen the pointer is on.
    private var pinnedOrigin: CGPoint? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: Self.originKey) else {
                return nil
            }
            let parts = stored.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Self.originKey)
                return
            }
            UserDefaults.standard.set("\(newValue.x),\(newValue.y)", forKey: Self.originKey)
        }
    }

    private static let originKey = "panel.origin"

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
        let origin = anchoredOrigin(for: size, current: panel.frame)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

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
        panel.contentView = host

        // Remember a drag. `didMove` also fires for our own resizes, so only a move that
        // isn't ours counts — hence the flag around setFrame.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !self.isAdjusting else { return }
                self.pinnedOrigin = panel.frame.origin
            }
        }

        self.panel = panel
        self.host = host
    }

    private var isAdjusting = false

    private func anchoredOrigin(for size: CGSize, current: NSRect) -> CGPoint {
        isAdjusting = true
        defer { isAdjusting = false }

        if let pinned = pinnedOrigin, current.width > 0 {
            // Grow upward and outward from where it sits, keeping the bottom-left corner
            // put unless that would push it off the top of the screen.
            return CGPoint(x: pinned.x - (size.width - current.width) / 2, y: pinned.y)
        }
        if current.width > 0, panel?.isVisible == true {
            return CGPoint(x: current.midX - size.width / 2, y: current.minY)
        }
        return defaultOrigin(for: size)
    }

    /// Bottom-centre of whichever screen holds the pointer, so on a multi-display setup it
    /// appears where you are actually working.
    private func defaultOrigin(for size: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        return CGPoint(x: frame.midX - size.width / 2, y: frame.minY + 10)
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
