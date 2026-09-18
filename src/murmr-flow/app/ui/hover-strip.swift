import AppKit
import SwiftUI

/// Reports the pointer entering and leaving a region, without taking the mouse from what
/// is underneath it.
///
/// SwiftUI's `.onHover` was what the edge strip used first, and it never fired: the strip
/// is a clear rectangle laid over the content pane, and hover did not reach it. An
/// `NSTrackingArea` is the mechanism AppKit uses for this itself, and it does not depend
/// on anything being drawn.
///
/// `hitTest` returns nil, so this is invisible to clicks. That is what lets it be laid
/// over the peek card — the card's rows stay clickable, and the strip still hears the
/// pointer arrive and leave.
struct HoverStrip: NSViewRepresentable {

    /// Called with `true` on entering and `false` on leaving.
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {

        var onChange: ((Bool) -> Void)?

        /// Rebuilt whenever the view's geometry changes — the window is resizable, and a
        /// tracking area cut for the old size is a strip in the wrong place.
        /// `.inVisibleRect` makes the rect argument moot, and correct after every resize.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    // In the key window only: the sidebar sliding out of a window behind
                    // the one being worked in is movement where none was asked for.
                    options: [
                        .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
                    ],
                    owner: self
                )
            )
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }

        /// Never the target of a click. Tracking areas report the pointer whatever this
        /// returns, so the view hears everything and swallows nothing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
