import AppKit
import CoreGraphics
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
        // One style with a key of its own and two apps with rules, so the row's key slot
        // and the By app list are both in the picture rather than in their empty states.
        prompts.setHotkey(
            Hotkey(
                keyCode: 58, modifierRawValue: CGEventFlags.maskSecondaryFn.rawValue,
                isModifierOnly: true
            ),
            for: PromptStore.builtIns[2].id
        )
        prompts.setRule(
            AppStyleRule(
                bundleID: "com.apple.mail", appName: "Mail",
                outcome: .style(PromptStore.builtIns[2].id)
            )
        )
        prompts.setRule(
            AppStyleRule(
                bundleID: "com.apple.Terminal", appName: "Terminal", outcome: .off
            )
        )

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

        // The pane's header row above the rows, so the two pills can be seen lined up with
        // the rows' — that alignment is the reason they are pills. Composed here rather
        // than rendering `AICleanupPane`: `ImageRenderer` draws a `ScrollView` as nothing.
        let pane = VStack(alignment: .leading, spacing: 14) {
            SettingRow(title: "Activate for") {
                HStack(spacing: 8) {
                    Color.clear.frame(
                        width: PromptsSection.editWidth + PromptsSection.keyWidth + 8,
                        height: 1
                    )
                    AssignmentToggle(
                        title: "Dictation", symbol: "mic.fill", isOn: true, togglesOff: true
                    ) {}
                    AssignmentToggle(
                        title: "Notetaker", symbol: "text.document", isOn: false, togglesOff: true
                    ) {}
                }
            }
            PromptsSection(prompts: prompts, bindKey: { _, _ in nil })
            AppStylesSection(prompts: prompts)
        }
        .frame(width: 640)
        .padding(24)
        .background(Theme.Palette.deep)
        .font(Theme.Text.body)
        .foregroundStyle(Theme.Palette.text)
        .tint(Theme.Palette.gold)
        let paneRenderer = ImageRenderer(content: pane.environment(\.colorScheme, .dark))
        paneRenderer.scale = 2
        if let image = paneRenderer.nsImage,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("ai-cleanup.png")
            )
        }

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
