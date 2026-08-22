import SwiftUI

/// The one place a colour, a size or a radius is decided.
///
/// Everything before this used SwiftUI's semantic styles — `.secondary`, `.quaternary`,
/// `.accentColor` — which was right while the structure was being settled and is wrong now.
/// Those resolve against the system's palette, so "make it blue and gold" is not something
/// they can express.
enum Theme {

    // MARK: - Ink

    /// Deep navy ground, glass above it, gold as a light rather than a fill.
    ///
    /// Taken from the reference image and then held to two rules. **Gold means live or
    /// chosen** — never a surface, never a border, one gold per screen. And **the deepest
    /// part of the ground goes wherever text goes**, so brightness lives at the edges where
    /// nothing is read.
    enum Palette {
        /// Bottom of the window gradient.
        static let abyss = Color(hex: 0x04101F)
        /// Top of it.
        static let deep = Color(hex: 0x0A1E38)
        /// The wash that gives glass something to refract. Without colour beneath it,
        /// glass is only grey blur.
        static let wash = Color(hex: 0x2E86C1)
        /// "You" in a transcript, and any non-gold highlight.
        static let tide = Color(hex: 0x5EA6D0)

        static let text = Color(hex: 0xEDF4FB)
        static let muted = Color(hex: 0x9BB2CA)
        static let faint = Color(hex: 0x61758E)

        /// The accent. Scarcity is what makes it read as expensive.
        static let gold = Color(hex: 0xEBCE83)

        /// Solid surface used when the system asks for reduced transparency, and behind
        /// long-form text where glass costs contrast for nothing.
        static let solid = Color(hex: 0x0A1A30)

        static let hairline = Color.white.opacity(0.11)
        /// The bright inset along a pane's upper edge — the single detail that makes glass
        /// read as an object with thickness rather than as opacity.
        static let rim = Color.white.opacity(0.30)

        static let danger = Color(hex: 0xFF6B5E)
        static let ok = Color(hex: 0x6FCF97)
    }

    // MARK: - Type

    /// Mona Sans for everything, JetBrains Mono for anything that is data.
    ///
    /// Bundled rather than assumed installed — see `resources/fonts/VENDORED.md`. The
    /// fallback is deliberately the system face rather than a similar-looking third choice:
    /// if bundling ever breaks, it should look plainly different rather than subtly off.
    enum Face {
        static let ui = "Mona Sans"
        static let data = "JetBrains Mono"

        /// True once the bundled fonts have registered. Checked at launch, because silently
        /// falling back for the whole session is exactly the failure that goes unnoticed.
        static var isAvailable: Bool {
            NSFontManager.shared.availableFontFamilies.contains(ui)
        }
    }

    /// One scale, in the sizes the app actually uses. A type scale you can list is a type
    /// scale you can keep.
    enum Text {
        /// Note titles, and anything that is a heading.
        static let title = Font.custom(Face.ui, size: 21).weight(.semibold)
        /// Section headings inside a pane.
        static let heading = Font.custom(Face.ui, size: 15).weight(.semibold)
        /// The default. Transcripts, list rows, most labels.
        static let body = Font.custom(Face.ui, size: 13)
        /// Body, emphasised.
        static let bodyStrong = Font.custom(Face.ui, size: 13).weight(.medium)
        /// Secondary lines under a row.
        static let small = Font.custom(Face.ui, size: 11.5)

        /// Insights. Large enough that the grotesque's flat terminals show.
        static let figure = Font.custom(Face.ui, size: 30).weight(.medium)

        /// Timestamps, keycaps, durations — anything where digits should line up.
        static let mono = Font.custom(Face.data, size: 10.5)
        static let monoLarge = Font.custom(Face.data, size: 12)
        /// Small uppercase labels. Tracked out, because a grotesque set in caps without
        /// extra letter-spacing reads as a shout.
        static let label = Font.custom(Face.data, size: 9.5).weight(.medium)
    }

    /// Letter-spacing for the tracked-out uppercase labels.
    static let labelTracking: CGFloat = 0.9

    // MARK: - Shape

    /// Concentric: corners flow outward to inward, so a nested box reads as contained
    /// rather than pasted on top.
    enum Radius {
        static let window: CGFloat = 16
        static let pane: CGFloat = 12
        static let row: CGFloat = 9
        static let inner: CGFloat = 6
        /// The floating panel, which is a capsule at rest.
        static let panel: CGFloat = 22
    }

    // MARK: - Material

    /// Apple's three weights, because one blur for everything flattens the interface.
    ///
    /// Chrome that floats over other applications should read as heavier than a card
    /// sitting inside a window.
    enum Glass {
        /// Rows and cards inside a window.
        case thin
        /// Windows and panes.
        case regular
        /// The sidebar, and the floating panel.
        case thick

        var material: Material {
            switch self {
            case .thin: .ultraThinMaterial
            case .regular: .regularMaterial
            case .thick: .thickMaterial
            }
        }

        /// The tint laid over the material. Brighter at the top, so every pane has the
        /// same direction of light.
        ///
        /// Warmed toward navy rather than pure white. A dark `Material` resolves to neutral
        /// grey, and a grey pane on a navy ground looks like a pane from a different app —
        /// the tint is what keeps it inside the palette.
        var tint: LinearGradient {
            let top: Double
            switch self {
            case .thin: top = 0.09
            case .regular: top = 0.12
            case .thick: top = 0.15
            }
            return LinearGradient(
                colors: [
                    .white.opacity(top),
                    Theme.Palette.deep.opacity(0.34),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Applying glass

extension View {

    /// A pane of glass: material, tint, rim light, hairline edge and a shadow that puts it
    /// above something.
    ///
    /// Honours **Reduce Transparency**. macOS has that setting and people turn it on; glass
    /// then has to become a solid surface rather than merely blur less, or the interface
    /// stops being readable for exactly the users who asked for help.
    func glass(
        _ weight: Theme.Glass = .regular,
        radius: CGFloat = Theme.Radius.pane,
        elevated: Bool = true
    ) -> some View {
        modifier(GlassPane(weight: weight, radius: radius, elevated: elevated))
    }

    /// A full-bleed glass column — a sidebar or a list pane. No corners and no shadow,
    /// because it runs to the window's edge.
    ///
    /// Separate from `glass()` so it cannot be reached for without the tint. A bare
    /// `Material` resolves to neutral grey on a dark ground, which is how the sidebar ended
    /// up looking slate beside a navy window.
    func glassColumn(_ weight: Theme.Glass = .thick) -> some View {
        modifier(GlassColumn(weight: weight))
    }
}

private struct GlassColumn: ViewModifier {
    let weight: Theme.Glass

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                Theme.Palette.solid
            } else {
                Rectangle().fill(weight.material)
                Rectangle().fill(weight.tint)
            }
        }
    }
}

private struct GlassPane: ViewModifier {
    let weight: Theme.Glass
    let radius: CGFloat
    let elevated: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        return content
            .background {
                if reduceTransparency {
                    shape.fill(Theme.Palette.solid)
                } else {
                    shape.fill(weight.material)
                    shape.fill(weight.tint)
                }
            }
            .overlay {
                // One stroke, bright at the top and fading down — the rim light and the
                // edge in the same pass.
                //
                // The first attempt drew the rim as a 1pt bar masked to the border, which
                // works on a large pane and leaves a stray line across small circles. A
                // gradient stroke has no such size dependence, and it also reads better:
                // light from above should fall off, not stop.
                shape.strokeBorder(
                    reduceTransparency
                        ? AnyShapeStyle(Theme.Palette.hairline)
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Theme.Palette.rim,
                                    Theme.Palette.hairline,
                                    .white.opacity(0.04),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        ),
                    lineWidth: 1
                )
            }
            .shadow(
                color: elevated ? .black.opacity(0.45) : .clear,
                radius: elevated ? 22 : 0, x: 0, y: elevated ? 12 : 0
            )
    }
}

// MARK: - The ground

/// The window's background: a navy gradient with two washes of colour for the glass to
/// refract, and the middle kept deep so text has somewhere to sit.
struct InkGround: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Theme.Palette.solid
        } else {
            LinearGradient(
                colors: [Theme.Palette.deep, Theme.Palette.abyss],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topLeading) {
                RadialGradient(
                    colors: [Theme.Palette.wash.opacity(0.42), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 520
                )
            }
            .overlay(alignment: .bottomTrailing) {
                RadialGradient(
                    colors: [Theme.Palette.deep.opacity(0.85), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 460
                )
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Hex

extension Color {
    /// `Color(hex: 0x0A1E38)` — the form the palette is written in everywhere else, so the
    /// code and the design notes say the same thing.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
