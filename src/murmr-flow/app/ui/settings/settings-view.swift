import SwiftUI

/// The four settings sections.
///
/// They are sidebar rows in the main window rather than a separate Settings scene: one
/// window means one place to be, and listing the sections shows what is configurable
/// instead of hiding it behind ⌘,.
///
/// There were six, one per subject the code happened to have a file for, which made
/// configuration outweigh the app itself in the sidebar. Four sections named after
/// **what you are trying to do** hold the same controls: the prompts moved in beside the
/// provider that runs them, and Permissions stopped being a junk drawer for a music
/// toggle, a folder path and a version string.
///
/// The rule every section follows: **a healthy install shows almost nothing.** No captions
/// restating what a toggle does, no rows confirming that something is fine.
enum SettingsPane: String, Hashable, CaseIterable, Identifiable {
    case speechModel, aiCleanup, hotkeys, privacyData

    var id: String { rawValue }

    /// The same words the rest of the app uses, and the same words the section's own
    /// heading uses — see the vocabulary table in `docs/11-conventions.md`. A section
    /// called one thing in the sidebar and another at the top of itself was most of what
    /// made the old naming hard to follow.
    ///
    /// **"AI clean-up", not "AI provider".** The provider is the engine and keeps that
    /// name — on the cards inside this section, on Home's status chip, in the panel's
    /// failure message. The section is the *job*: whether clean-up runs, what runs it,
    /// what instructions it follows and the words it must spell your way. Naming a job
    /// after its verb is the convention, not a breach of it — see the two-layer rule in
    /// `docs/11-conventions.md`.
    ///
    /// All four fit the sidebar at its default width. "Voice transcription" did not: it
    /// truncated to "Voice transcri…", which is what a label and a heading disagreeing
    /// bought us.
    var label: String {
        switch self {
        case .speechModel: "Speech model"
        case .aiCleanup: "AI clean-up"
        case .hotkeys: "Hotkeys"
        case .privacyData: "Privacy & data"
        }
    }

    var symbol: String {
        switch self {
        case .speechModel: "waveform"
        case .aiCleanup: "sparkles"
        case .hotkeys: "keyboard"
        case .privacyData: "lock.shield"
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
        case .aiCleanup:
            AICleanupPane(
                settings: services.settings,
                dictation: services.dictation,
                prompts: services.prompts
            )
        case .hotkeys:
            HotkeysPane(services: services)
        case .privacyData:
            PrivacyDataPane(
                permissions: services.permissions,
                notes: services.notes,
                history: services.history
            )
        }
    }
}
