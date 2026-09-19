import AppKit
import SwiftUI

/// Every number the pill is built from, in one place — and the text measurement that turns
/// a label into one of them.
///
/// The model sizes the *window* and the view lays out the *contents*, so the two have to
/// agree to the point on how wide a keycap or a message comes out. They used to disagree:
/// the model carried a hard-coded 240pt for the armed row while its contents came to 143,
/// and the 97pt of nothing in between was the bug that started this redesign. Nothing here
/// is guessed from a character count — a keycap reading `right ⌥` is a different width from
/// one reading `fn`, and only the font knows by how much.
enum PanelLayout {

    // MARK: - The grid

    /// One slot. Everything in the row is this tall, and anything round is this wide.
    ///
    /// The row used to hold five things at five heights — a 22pt disc, an 18pt icon, a
    /// 17pt keycap, a 26pt button and a 1pt rule — which reads as clutter before it reads
    /// as controls. Only a slot carrying text may stretch, because text has a length.
    static let slot: CGFloat = 28
    static let rowHeight: CGFloat = 40

    /// Between two things in the same group.
    static let gap: CGFloat = 6
    /// Between a group and the capsule's edge.
    static let pad: CGFloat = 10
    /// A row that is only a message has no shoulder to widen it, so it gets its breathing
    /// room directly. Without this, `notice` came out tight beside `working`, whose width
    /// is set by the shoulder above it.
    static let messagePad: CGFloat = 25
    /// Added on top of `gap` at a group boundary — 12 against 6 is what makes a running
    /// meeting read as three groups (how long · who is speaking · how to stop) rather than
    /// as six evenly spaced things.
    static let groupGap: CGFloat = 6

    // MARK: - The shoulder

    /// The settings deck, docked to the top edge rather than floating above it.
    ///
    /// Two capsules hovering over the pill made the panel a constellation of five separate
    /// objects. Grown out of the row it is one object with two decks, and the deck costs
    /// 16pt instead of the 24 the floating version needed for clearance.
    static let shoulder: CGFloat = 16
    static let shoulderPad: CGFloat = 11
    static let shoulderGap: CGFloat = 7
    /// How much wider than the shoulder the row has to be for the dock to read as a dock.
    /// A shoulder overhanging the thing it is attached to looks broken.
    static let shoulderClearance: CGFloat = 16

    // MARK: - Orbit

    static let satellite: CGFloat = 28
    static let satelliteGap: CGFloat = 11
    static var satelliteReach: CGFloat { satellite + satelliteGap }

    // MARK: - The well

    /// The recessed slot holding what the row *knows* — where the text lands, which key
    /// fires it. Sunken because nothing in it is pressable; raised things are pressed.
    static let wellPad: CGFloat = 7
    static let wellGap: CGFloat = 5
    static let wellIcon: CGFloat = 16
    static let wellRadius: CGFloat = 11

    /// The mark's width at a given height, from its own geometry rather than a guess:
    /// five bars of `barWidth` with four gaps of `pitch - barWidth`.
    static func markWidth(_ height: CGFloat) -> CGFloat {
        let scale = height / MurmrMark.bounds.height
        return MurmrMark.bounds.width * scale
    }

    static let markHeight: CGFloat = 18
    static let meterHeight: CGFloat = 14
    static let workingMarkHeight: CGFloat = 20

    // MARK: - Measuring

    /// The width of a string in the face it will actually be drawn in.
    ///
    /// Rounded up, because a fractional point of overflow is a clipped glyph and a
    /// fractional point of slack is invisible.
    static func width(_ string: String, face: String, size: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let font = NSFont(name: face, size: size) ?? .monospacedSystemFont(
            ofSize: size, weight: .regular
        )
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Keycaps, clocks and anything else set in the data face.
    static func mono(_ string: String, size: CGFloat = 10.5) -> CGFloat {
        width(string, face: Theme.Face.data, size: size)
    }

    /// The tracked-out small caps used for the shoulder and the meter labels. `Theme`
    /// tracks them out by hand, so the tracking has to be added back here or the
    /// measurement comes out short by one gap per character.
    static func label(_ string: String) -> CGFloat {
        mono(string, size: 9.5) + Theme.labelTracking * CGFloat(string.count)
    }

    /// Sentences: notices and failure headlines, in the UI face.
    static func body(_ string: String, size: CGFloat = 11.5, weight: NSFont.Weight = .regular)
        -> CGFloat
    {
        guard !string.isEmpty else { return 0 }
        let font = NSFont(name: Theme.Face.ui, size: size)
            ?? .systemFont(ofSize: size, weight: weight)
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - Composing

    /// A row from its parts: padding, then each part with a gap between, then padding.
    /// Extra widths — a group boundary — are passed in already added to the part.
    static func row(_ parts: [CGFloat], pad: CGFloat = PanelLayout.pad) -> CGFloat {
        guard !parts.isEmpty else { return pad * 2 }
        return parts.reduce(0, +) + gap * CGFloat(parts.count - 1) + pad * 2
    }

    /// The well around an optional icon and an optional keycap.
    static func well(icon: Bool, cap: String?) -> CGFloat {
        var inner: CGFloat = 0
        if icon { inner += wellIcon }
        if let cap, !cap.isEmpty {
            if icon { inner += wellGap }
            inner += mono(cap)
        }
        return inner + wellPad * 2
    }
}
