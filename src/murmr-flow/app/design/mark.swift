import AppKit
import SwiftUI

/// The mark: five capsule bars whose inner three trace the V of an M between two stems.
///
/// The same alphabet as a sound-level meter, which is the point — the panel's live level
/// is drawn with these bars, and when the room goes quiet they settle into the letter.
///
/// One geometry, in code, for every in-app use; `resources/brand/` holds the same numbers
/// as SVG for the app icon and anything outside the app. Both are documented in
/// `resources/brand/README.md`; change one and change the other.
enum MurmrMark {

    /// The bars on a 1024 grid, left to right: `x` is the bar's centre, `top`/`bottom` its
    /// extent. The stems are 223–773, the block sits just below the midline.
    static let bars: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] = [
        (252, 223, 773), (382, 340, 610), (512, 450, 670), (642, 340, 610), (772, 223, 773),
    ]
    static let barWidth: CGFloat = 90
    static let pitch: CGFloat = 130

    /// The tight box around the bars, on the same grid. Everything in the app draws the
    /// mark into its own frame, so it is this box — not the 1024 canvas — that scales.
    static let bounds = CGRect(x: 252 - 45, y: 223, width: 772 - 252 + 90, height: 773 - 223)

    /// Each bar's height as a fraction of the tallest, for views that animate the bars.
    static var relativeHeights: [CGFloat] {
        bars.map { ($0.bottom - $0.top) / bounds.height }
    }

    /// The mark as a path, fitted inside `rect` and centred — uniform scale, so a square
    /// frame gets a little horizontal margin and a wide one gets vertical.
    static func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let drawn = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let origin = CGPoint(
            x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2
        )
        var path = Path()
        for bar in bars {
            let w = barWidth * scale
            let frame = CGRect(
                x: origin.x + (bar.x - bounds.minX) * scale - w / 2,
                y: origin.y + (bar.top - bounds.minY) * scale,
                width: w,
                height: (bar.bottom - bar.top) * scale
            )
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: w / 2, height: w / 2))
        }
        return path
    }

    /// What the menu bar has to say with the one glyph.
    enum MenuBarState {
        /// The hotkey is armed and everything is granted.
        case ready
        /// The hotkey is off: the mark, dimmed.
        case hotkeyOff
        /// Dictation is being recorded: the mark in the app's red.
        case recording
        /// A grant is missing: the mark with a dot at the corner, where the "!" used to be.
        case permissionMissing
    }

    /// The menu-bar glyph, at the state's face.
    ///
    /// A template image for every state but recording, so the system paints it in
    /// whatever the menu bar's ink is, light or dark. Recording is drawn in colour and left
    /// alone, since red is the point. `hotkeyOff` bakes its alpha into the image because a
    /// status item's label does not honour `.opacity` reliably.
    static func menuBarImage(_ state: MenuBarState = .ready) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let ink: NSColor = switch state {
            case .recording: NSColor(Theme.Palette.danger)
            case .hotkeyOff: .black.withAlphaComponent(0.45)
            case .ready, .permissionMissing: .black
            }
            ink.setFill()
            context.addPath(path(in: inset).cgPath)
            context.fillPath()

            if state == .permissionMissing {
                // A ring of clear around the dot, so it reads as a badge on the stem rather
                // than a lump grown out of it.
                let centre = CGPoint(x: rect.maxX - 2.5, y: rect.minY + 2.5)
                let dot = CGRect(x: centre.x - 2, y: centre.y - 2, width: 4, height: 4)
                context.setBlendMode(.clear)
                context.fillEllipse(in: dot.insetBy(dx: -1, dy: -1))
                context.setBlendMode(.normal)
                ink.setFill()
                context.fillEllipse(in: dot)
            }
            return true
        }
        image.isTemplate = state != .recording
        return image
    }
}

private extension CGPath {
    func fill(in context: CGContext?) {
        guard let context else { return }
        context.addPath(self)
        context.fillPath()
    }
}

/// The mark as a SwiftUI shape, for anything that wants to tint or animate it.
struct MurmrMarkShape: Shape {
    func path(in rect: CGRect) -> Path { MurmrMark.path(in: rect) }
}
