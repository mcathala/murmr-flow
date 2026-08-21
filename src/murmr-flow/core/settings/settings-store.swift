import Foundation
import Observation

/// Typed, `UserDefaults`-backed settings.
///
/// API keys are **not** here — those live in the Keychain. This holds only what is safe
/// in a plist.
@MainActor
@Observable
final class SettingsStore {

    private enum Key {
        static let enabled = "cleanup.enabled"
        static let prompt = "cleanup.prompt"
        static let customWords = "cleanup.customWords"
        static let hotkey = "dictation.hotkey"
        static let pauseMedia = "dictation.pauseMedia"
        static let holdToTalk = "dictation.holdToTalk"
        static let speechModel = "stt.model"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.cleanupEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        self.promptTemplate =
            defaults.string(forKey: Key.prompt) ?? PromptLibrary.defaultCleanupPrompt
        self.customWords = defaults.stringArray(forKey: Key.customWords) ?? []
        self.hotkey =
            HotkeyMonitor.Trigger(rawValue: defaults.integer(forKey: Key.hotkey))
            ?? .rightOption
        self.speechModel =
            SpeechModel(rawValue: defaults.string(forKey: Key.speechModel) ?? "")
            ?? .parakeetV3
        self.pauseMediaWhileDictating =
            defaults.object(forKey: Key.pauseMedia) as? Bool ?? true
        self.holdToTalk = defaults.object(forKey: Key.holdToTalk) as? Bool ?? true
    }

    // MARK: - Cleanup

    /// Provider identity, endpoint, model and verification all live in `ProviderStore`,
    /// per provider. They used to be three single values here, which is what made
    /// switching provider destroy the one you left.
    var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: Key.enabled) } }

    var promptTemplate: String {
        didSet { defaults.set(promptTemplate, forKey: Key.prompt) }
    }

    var customWords: [String] {
        didSet { defaults.set(customWords, forKey: Key.customWords) }
    }

    // MARK: - Dictation

    var hotkey: HotkeyMonitor.Trigger {
        didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey) }
    }

    var speechModel: SpeechModel {
        didSet { defaults.set(speechModel.rawValue, forKey: Key.speechModel) }
    }

    /// Pause whatever is playing while dictating, then put it back.
    var pauseMediaWhileDictating: Bool {
        didSet { defaults.set(pauseMediaWhileDictating, forKey: Key.pauseMedia) }
    }

    /// Hold the key to talk, or press once to start and once to stop. Was a hardcoded
    /// assumption; some people would rather not hold a key for a long dictation.
    var holdToTalk: Bool {
        didSet { defaults.set(holdToTalk, forKey: Key.holdToTalk) }
    }

    // MARK: - Derived

    func resetPrompt() {
        promptTemplate = PromptLibrary.defaultCleanupPrompt
    }
}
