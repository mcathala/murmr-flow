import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// The menu in the states it has to handle best, rendered so they can be looked at.
@MainActor
@Suite("Menu bar panel")
struct MenuBarPanelTests {

    @Test("relative times are the width of a shortcut")
    func relative() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(MenuBarPanel.relative(now.addingTimeInterval(-30), now: now) == "now")
        #expect(MenuBarPanel.relative(now.addingTimeInterval(-12 * 60), now: now) == "12 m")
        #expect(MenuBarPanel.relative(now.addingTimeInterval(-2 * 3600), now: now) == "2 h")
        #expect(MenuBarPanel.relative(now.addingTimeInterval(-3 * 86400), now: now) == "3 d")
    }

    @Test("render the menu's states")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }
        _ = PanelSnapshotTests.fontsRegistered

        let notes = [
            NoteFile(
                url: URL(fileURLWithPath: "/tmp/a.md"), title: "Weekly sync",
                date: .now.addingTimeInterval(-2 * 3600), duration: 1800, snippet: ""
            ),
            NoteFile(
                url: URL(fileURLWithPath: "/tmp/b.md"), title: "Call with Anna",
                date: .now.addingTimeInterval(-30 * 3600), duration: 900, snippet: ""
            ),
        ]
        func panel(_ status: MenuBarPanel.Status, _ actions: [MenuBarPanel.Action]) -> some View {
            MenuBarPanel(
                status: status, actions: actions, notes: notes,
                openNote: { _ in }, openWindow: {}, openSettings: {}, quit: {}
            )
        }
        let view = HStack(alignment: .top, spacing: 16) {
            panel(
                .init(tone: .ready, title: "Ready", detail: "Hold fn to dictate"),
                [
                    .init(title: "Dictation", symbol: "mic") {},
                    .init(title: "Notetaker", symbol: "text.document") {},
                ]
            )
            panel(
                .init(
                    tone: .attention, title: "Permissions needed",
                    detail: "Microphone and Accessibility are off", fix: {}
                ),
                [
                    .init(title: "Dictation", symbol: "mic") {},
                    .init(title: "Notetaker", symbol: "text.document") {},
                ]
            )
            panel(
                .init(
                    tone: .recording, title: "Notetaker recording", detail: "12:04",
                    levels: (0.05, 0.01)
                ),
                [
                    .init(
                        title: "Stop Notetaker", symbol: "text.document", tone: .recording,
                        trailing: "12:04"
                    ) {},
                ]
            )
        }
        .padding(24)
        .background(Color(white: 0.12))

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("menu.png"))
    }
}
