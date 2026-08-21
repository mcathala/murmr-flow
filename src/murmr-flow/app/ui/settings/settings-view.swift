import SwiftUI

/// Settings, in five panes.
///
/// A real Settings scene rather than two of four tabs, so ⌘, works and configuration
/// stops competing for space with the things you actually made.
///
/// The rule every pane follows: **a healthy install shows almost nothing.** No captions
/// restating what a toggle does, no rows confirming that something is fine.
struct SettingsView: View {

    let services: AppServices

    enum Pane: String, Hashable, CaseIterable, Identifiable {
        case voice, cleanup, keys, prompts, permissions

        var id: String { rawValue }

        var label: String {
            switch self {
            case .voice: "Voice transcription"
            case .cleanup: "AI clean-up"
            case .keys: "Key binds"
            case .prompts: "Prompts"
            case .permissions: "Permissions"
            }
        }

        var symbol: String {
            switch self {
            case .voice: "waveform"
            case .cleanup: "sparkles"
            case .keys: "keyboard"
            case .prompts: "text.quote"
            case .permissions: "lock.shield"
            }
        }
    }

    @State private var pane: Pane = .voice

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 190, max: 230)
        } detail: {
            content.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 540)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .voice:
            VoicePane(models: services.dictation.models, dictation: services.dictation)
        case .cleanup:
            CleanupPane(settings: services.settings, dictation: services.dictation)
        case .keys:
            KeysPane(settings: services.settings, dictation: services.dictation)
        case .prompts:
            PromptsPane(prompts: services.prompts)
        case .permissions:
            PermissionsPane(
                permissions: services.permissions,
                settings: services.settings,
                notes: services.notes
            )
        }
    }
}
