import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// Renders the panel's states to PNGs so the layout can be *looked at* rather than
/// reasoned about. Writes to `MURMR_SNAPSHOT_DIR` when set; otherwise does nothing.
///
/// Every layout bug in this panel so far was found by eye and missed by arithmetic. The
/// numbers were right and the result was still wrong, which means the numbers were
/// answering the wrong question.
@MainActor
@Suite("Panel snapshots")
struct PanelSnapshotTests {

    /// Stand-in for the Dock, drawn at its real height on this Mac, so the panel's
    /// relationship to it is visible rather than inferred.
    private static let dockHeight: CGFloat = 41
    private static let windowGap: CGFloat = 10

    @Test("render every state")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        let cases: [(String, PanelModel.Phase)] = [
            ("resting", .resting),
            ("hovering", .hovering),
            ("armed", .armed),
            ("dictating", .dictating),
            ("meeting", .meeting),
        ]

        for (name, phase) in cases {
            let model = PanelModel()
            model.set(phase)
            model.promptName = "Default"
            model.elapsed = 64
            model.micLevel = 0.6
            model.youLevel = 0.1
            model.themLevel = 0.7
            if phase == .dictating { model.preview = "okay so I want to see that" }

            let renderer = ImageRenderer(content: PanelView(model: model))
            renderer.scale = 2
            guard let panel = renderer.nsImage else { continue }

            let canvas = composite(panel: panel, size: model.size)
            guard let tiff = canvas.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { continue }

            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try png.write(to: url)
        }
    }

    /// Places the panel where it really sits: horizontally centred, its bottom edge
    /// `windowGap` above the top of the Dock.
    private func composite(panel: NSImage, size: CGSize) -> NSImage {
        let width: CGFloat = 520
        let height: CGFloat = 190
        let canvas = NSImage(size: CGSize(width: width, height: height))

        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // The Dock.
        NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: Self.dockHeight).fill()
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        NSRect(x: 0, y: Self.dockHeight, width: width, height: 1).fill()

        // The panel's window bounds, so its own frame is visible too.
        let origin = CGPoint(
            x: (width - size.width) / 2,
            y: Self.dockHeight + Self.windowGap
        )
        NSColor(calibratedRed: 1, green: 0.3, blue: 0.3, alpha: 0.35).setFill()
        NSRect(origin: origin, size: size).frame(withWidth: 1)

        panel.draw(in: NSRect(origin: origin, size: size))
        return canvas
    }
}

/// The window must track the phase's size. Hover changes the phase from inside the view,
/// so nothing outside sees it unless the model says so — and a cluster laid out inside a
/// window still sized for the resting pill spills out of the bottom of it.
@MainActor
@Suite("Panel window")
struct PanelWindowTests {

    @Test("the window resizes for every phase")
    func windowFollowsPhase() {
        let panel = FloatingPanel()
        panel.present()

        for phase in [
            PanelModel.Phase.resting, .hovering, .armed, .dictating, .meeting,
            .working("Tidying up…"), .failed(.cleanup),
        ] {
            panel.model.set(phase)
            #expect(
                panel.windowSize == panel.model.size,
                "window \(String(describing: panel.windowSize)) != \(panel.model.size) for \(phase)"
            )
        }
    }

    @Test("hovering resizes without anyone calling apply")
    func hoverResizes() {
        let panel = FloatingPanel()
        panel.present()
        let resting = panel.windowSize

        // Exactly what the view does when the pointer arrives.
        panel.model.hover(true)

        #expect(panel.windowSize != resting)
        #expect(panel.windowSize == panel.model.size)
    }
}
