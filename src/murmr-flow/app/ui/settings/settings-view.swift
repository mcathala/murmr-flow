import SwiftUI

/// The six settings panes.
///
/// They are sidebar rows in the main window rather than a separate Settings scene: one
/// window means one place to be, and listing the panes shows what is configurable instead
/// of hiding it behind ⌘,.
///
/// The rule every pane follows: **a healthy install shows almost nothing.** No captions
/// restating what a toggle does, no rows confirming that something is fine.
enum SettingsPane: String, Hashable, CaseIterable, Identifiable {
    case speechModel, aiProvider, hotkeys, prompts, permissions, data

    var id: String { rawValue }

    /// The same words the rest of the app uses, and the same words the pane's own heading
    /// uses — see the vocabulary table in `docs/11-conventions.md`. A pane called one thing
    /// in the sidebar and another at the top of itself was most of what made the old naming
    /// hard to follow.
    ///
    /// All six fit the sidebar at its default width. "Voice transcription" did not: it
    /// truncated to "Voice transcri…", which is what the label and the heading disagreeing
    /// bought us.
    var label: String {
        switch self {
        case .speechModel: "Speech model"
        case .aiProvider: "AI provider"
        case .hotkeys: "Hotkeys"
        case .prompts: "Prompts"
        case .permissions: "Permissions"
        case .data: "Data"
        }
    }

    var symbol: String {
        switch self {
        case .speechModel: "waveform"
        case .aiProvider: "sparkles"
        case .hotkeys: "keyboard"
        case .prompts: "text.quote"
        case .permissions: "lock.shield"
        case .data: "externaldrive"
        }
    }
}

struct SettingsPaneView: View {

    let pane: SettingsPane
    let services: AppServices

    var body: some View {
        switch pane {
        case .speechModel:
            SpeechModelPane(loader: services.dictation.loader, dictation: services.dictation)
        case .aiProvider:
            AIProviderPane(settings: services.settings, dictation: services.dictation)
        case .hotkeys:
            HotkeysPane(services: services)
        case .prompts:
            PromptsPane(prompts: services.prompts)
        case .permissions:
            PermissionsPane(
                permissions: services.permissions,
                settings: services.settings,
                notes: services.notes
            )
        case .data:
            DataPane(history: services.history, notes: services.notes)
        }
    }
}
