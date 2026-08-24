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
        static let noteEnabled = "cleanup.noteEnabled"
        static let prompt = "cleanup.prompt"
        static let customWords = "cleanup.customWords"
        static let hotkey = "dictation.hotkey"
        static let meetingHotkey = "meeting.hotkey"
        static let pauseMedia = "dictation.pauseMedia"
        static let holdToTalk = "dictation.holdToTalk"
        static let inputDevice = "audio.inputDeviceUID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.cleanupEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        self.noteCleanupEnabled = defaults.object(forKey: Key.noteEnabled) as? Bool ?? true
        self.promptTemplate =
            defaults.string(forKey: Key.prompt) ?? PromptLibrary.defaultCleanupPrompt
        self.customWords = defaults.stringArray(forKey: Key.customWords) ?? []
        self.hotkey = Self.decode(defaults.data(forKey: Key.hotkey)) ?? .default
        self.meetingHotkey = Self.decode(defaults.data(forKey: Key.meetingHotkey))
        self.pauseMediaWhileDictating =
            defaults.object(forKey: Key.pauseMedia) as? Bool ?? true
        self.holdToTalk = defaults.object(forKey: Key.holdToTalk) as? Bool ?? true
        self.inputDeviceUID = defaults.string(forKey: Key.inputDevice)
    }

    // MARK: - Cleanup

    /// Provider identity, endpoint, model and verification all live in `ProviderStore`,
    /// per provider. They used to be three single values here, which is what made
    /// switching provider destroy the one you left.
    var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: Key.enabled) } }

    /// Meeting notes are a separate switch from dictation.
    ///
    /// The two are not the same trade. Dictation cleanup costs six seconds before text
    /// appears; a meeting is already finished, nobody is waiting on a cursor, and the
    /// request is the whole conversation — so someone may reasonably want one and not the
    /// other, in either direction.
    var noteCleanupEnabled: Bool {
        didSet { defaults.set(noteCleanupEnabled, forKey: Key.noteEnabled) }
    }

    var promptTemplate: String {
        didSet { defaults.set(promptTemplate, forKey: Key.prompt) }
    }

    var customWords: [String] {
        didSet { defaults.set(customWords, forKey: Key.customWords) }
    }

    // MARK: - Dictation

    /// The key that starts a dictation.
    var hotkey: Hotkey {
        didSet { defaults.set(Self.encode(hotkey), forKey: Key.hotkey) }
    }

    /// The key that starts a meeting. Optional, because there is no sensible default to
    /// impose — a global key that begins recording everything you hear should be one you
    /// asked for.
    var meetingHotkey: Hotkey? {
        didSet { defaults.set(meetingHotkey.flatMap(Self.encode), forKey: Key.meetingHotkey) }
    }

    private static func encode(_ hotkey: Hotkey) -> Data? {
        try? JSONEncoder().encode(hotkey)
    }

    private static func decode(_ data: Data?) -> Hotkey? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
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

    // MARK: - Audio

    /// UID of the microphone to record from, or nil to follow the system default.
    ///
    /// A UID rather than the numeric `AudioDeviceID`, which Core Audio reassigns on every
    /// connect and reuses across different hardware — saving one would eventually point
    /// the preference at whatever device happened to inherit the number.
    var inputDeviceUID: String? {
        didSet {
            if let inputDeviceUID {
                defaults.set(inputDeviceUID, forKey: Key.inputDevice)
            } else {
                defaults.removeObject(forKey: Key.inputDevice)
            }
        }
    }

    // MARK: - Derived

    func resetPrompt() {
        promptTemplate = PromptLibrary.defaultCleanupPrompt
    }
}
