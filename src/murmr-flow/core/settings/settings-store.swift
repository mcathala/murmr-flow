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
        static let providerID = "cleanup.providerID"
        static let baseURL = "cleanup.baseURL"
        static let model = "cleanup.model"
        static let enabled = "cleanup.enabled"
        static let prompt = "cleanup.prompt"
        static let customWords = "cleanup.customWords"
        static let hotkey = "dictation.hotkey"
        static let pauseMedia = "dictation.pauseMedia"
        static let speechModel = "stt.model"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let providerID = defaults.string(forKey: Key.providerID) ?? ProviderCatalog.groq.id
        let entry = ProviderCatalog.entry(id: providerID)

        self.providerID = providerID
        self.baseURL = defaults.string(forKey: Key.baseURL) ?? entry.defaultBaseURL
        self.model = defaults.string(forKey: Key.model) ?? entry.defaultModel
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
    }

    // MARK: - Cleanup

    var providerID: String {
        didSet {
            defaults.set(providerID, forKey: Key.providerID)
            // Adopt the new provider's defaults, but keep whatever the user typed if
            // they had customised it for this provider already.
            let entry = ProviderCatalog.entry(id: providerID)
            if oldValue != providerID {
                baseURL = entry.defaultBaseURL
                model = entry.defaultModel
            }
        }
    }

    var baseURL: String { didSet { defaults.set(baseURL, forKey: Key.baseURL) } }
    var model: String { didSet { defaults.set(model, forKey: Key.model) } }
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

    // MARK: - Derived

    var providerEntry: ProviderCatalog.Entry { ProviderCatalog.entry(id: providerID) }

    /// `nil` when cleanup is off or unusable, which callers treat as "type the raw
    /// transcript".
    var providerConfig: ProviderConfig? {
        guard cleanupEnabled, !model.isEmpty, !baseURL.isEmpty else { return nil }
        return ProviderConfig(providerID: providerID, baseURL: baseURL, model: model)
    }

    var hasAPIKey: Bool {
        KeychainStore.hasKey(account: KeychainStore.account(forProvider: providerID))
    }

    func saveAPIKey(_ key: String) throws {
        try KeychainStore.write(key, account: KeychainStore.account(forProvider: providerID))
    }

    func deleteAPIKey() throws {
        try KeychainStore.delete(account: KeychainStore.account(forProvider: providerID))
    }

    func resetPrompt() {
        promptTemplate = PromptLibrary.defaultCleanupPrompt
    }
}
