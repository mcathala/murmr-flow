import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MurmrFlow

/// Renders the panel at *exactly* the window's size, over a bright ground.
///
/// Every other panel snapshot pads the view before rendering, which is why they all looked
/// correct while the running app did not: padding gives the pill's own `.shadow()` somewhere
/// to fall off. The real window is exactly the height of its contents, so there is nowhere.
@MainActor
@Suite("Panel clipping")
struct PanelClipTests {

    /// The two desktops that pull the panel in opposite directions.
    ///
    /// Saturated is where a weak tint let the wallpaper choose the colour — the pill came out
    /// brown on red. Near-black is the opposite risk: with no shadow at all, a panel tinted
    /// dark enough to survive the first can disappear into the second.
    private static let grounds: [(String, [UInt32])] = [
        ("hot", [0xE01B00, 0xF5C400, 0xE01B00]),
        ("dark", [0x14171C, 0x0B0D10, 0x14171C]),
    ]

    @Test("render the panel at the window's exact size, on both extremes")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        for (name, hexes) in Self.grounds {
            let model = PanelModel()
            model.set(.armed)
            let size = model.size

            let ground = LinearGradient(
                colors: hexes.map { Color(hex: $0) },
                startPoint: .leading, endPoint: .trailing
            )

            // `.clipped()` at exactly the window's size is the part that matters. A window's
            // backing store ends at its frame, so anything SwiftUI draws outside — a shadow,
            // most of all — is simply cut off. `ImageRenderer` has no window and happily
            // draws past the frame, which is why every existing panel snapshot looked right.
            let view = ZStack {
                ground
                PanelView(model: model)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            // 40pt of ground around the window, so anything escaping it would still show.
            .frame(width: size.width + 80, height: size.height + 80)

            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { continue }

            try png.write(
                to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("panel-exact-\(name).png")
            )
        }
    }
}
