import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// The prompt rows as the Styles tab shows them, rendered so they can be looked at.
@MainActor
@Suite("Prompt rows")
struct PromptRowsSnapshotTests {

    @Test("render closed rows with their assignments")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }
        _ = PanelSnapshotTests.fontsRegistered

        let suite = UserDefaults(suiteName: "murmr-prompt-rows-\(UUID().uuidString)")!
        let prompts = PromptStore(defaults: suite)
        prompts.dictationPromptID = PromptStore.builtIns[1].id

        let view = VStack(spacing: 8) {
            PromptsSection(prompts: prompts)
        }
        .frame(width: 640)
        .padding(24)
        .background(Theme.Palette.deep)

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("prompts.png"))

        // The shipped wording as the model receives it, one file each, for reading.
        for preset in PromptStore.builtIns {
            let rendered = PromptLibrary(template: preset.template)
                .render(.init(transcript: "…", hints: ["Kovalee"]))
            try rendered.write(
                to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("prompt-\(preset.name.lowercased()).txt"),
                atomically: true, encoding: .utf8
            )
        }
    }
}
