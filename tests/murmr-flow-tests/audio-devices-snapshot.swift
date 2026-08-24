import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// Renders the Home audio card so its layout can be looked at.
///
/// It reads the real hardware — this Mac's actual microphones and outputs — because the
/// thing most likely to be wrong is how a long device name behaves next to a menu, and a
/// fixture called "Test Device 1" would never show it.
///
/// **`ImageRenderer` cannot draw a `Menu`**, so both pickers come out as yellow
/// placeholder blocks. What this checks is the rest: the rows, the icons, the wording, and
/// whether the Bluetooth warning appears when it should. The menus themselves have to be
/// looked at in the running app. It caught the warning silently never firing, which is
/// exactly the sort of thing that reads as correct in the source.
@MainActor
@Suite("Audio devices snapshot")
struct AudioDevicesSnapshotTests {

    @Test("render the microphone and output rows")
    func render() throws {
        #expect(
            PanelSnapshotTests.fontsRegistered,
            "bundled fonts did not register — snapshots would lie"
        )
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        let view = VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Audio")
            AudioDevicesCard(services: .shared)
        }
        .frame(width: 560)
        .padding(16)
        .background(InkGround())

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("audio-devices.png")
        )
    }
}
