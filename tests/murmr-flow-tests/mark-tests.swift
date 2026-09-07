import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// The mark's geometry, and a look at it where it is smallest: the menu bar.
@MainActor
@Suite("Mark")
struct MarkTests {

    @Test("five bars, symmetric, inside the box")
    func geometry() {
        let bars = MurmrMark.bars
        #expect(bars.count == 5)
        for (left, right) in zip(bars, bars.reversed()) {
            #expect(left.top == right.top && left.bottom == right.bottom)
        }
        // The stems are the tallest; the middle bar is the shortest and sits lowest.
        let heights = bars.map { $0.bottom - $0.top }
        #expect(heights[0] == heights.max())
        #expect(heights[2] == heights.min())
        #expect(bars[2].bottom > bars[1].bottom)
        // The path fits the frame it is asked for, whatever the aspect.
        for rect in [CGRect(x: 0, y: 0, width: 18, height: 18), CGRect(x: 5, y: 7, width: 60, height: 20)] {
            let box = MurmrMark.path(in: rect).boundingRect
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(box))
        }
    }

    @Test("menu bar image is a template at 18 pt, except in red")
    func menuBarImage() {
        for state in [MurmrMark.MenuBarState.ready, .hotkeyOff, .permissionMissing] {
            let image = MurmrMark.menuBarImage(state)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
        }
        #expect(!MurmrMark.menuBarImage(.recording).isTemplate)
    }

    /// Writes the glyph at 4× on a light and a dark strip, the way it sits in the menu
    /// bar. Same contract as the other snapshots: `MURMR_SNAPSHOT_DIR` or nothing.
    @Test("render the menu bar glyph")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }
        let zoom: CGFloat = 4
        let states: [MurmrMark.MenuBarState] = [.ready, .hotkeyOff, .permissionMissing, .recording]
        let strip = NSSize(width: 170 * zoom, height: 24 * zoom)
        let canvas = NSImage(size: NSSize(width: strip.width, height: strip.height * 2))
        canvas.lockFocus()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: strip).fill()
        NSColor(white: 0.17, alpha: 1).setFill()
        NSRect(x: 0, y: strip.height, width: strip.width, height: strip.height).fill()
        for (row, ink) in [(0, NSColor.black), (1, NSColor.white)] {
            for (column, state) in states.enumerated() {
                let glyph = MurmrMark.menuBarImage(state)
                let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                    glyph.draw(in: rect)
                    // Templates take the bar's ink, as the system would give them.
                    if glyph.isTemplate {
                        ink.setFill()
                        rect.fill(using: .sourceAtop)
                    }
                    return true
                }
                let origin = NSPoint(
                    x: (12 + CGFloat(column) * 40) * zoom,
                    y: CGFloat(row) * strip.height + 3 * zoom
                )
                tinted.draw(
                    in: NSRect(origin: origin, size: NSSize(width: 18 * zoom, height: 18 * zoom)),
                    from: .zero, operation: .sourceOver, fraction: 1
                )
            }
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("mark-menubar.png")
        try png.write(to: url)
    }
}
