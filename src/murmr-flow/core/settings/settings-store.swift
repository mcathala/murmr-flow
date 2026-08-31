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
        static let hotkey = "dictation.hotkey"
        static let meetingHotkey = "meeting.hotkey"
        static let pauseMedia = "dictation.pauseMedia"
        static let holdToTalk = "dictation.holdToTalk"
        static let inputDevice = "audio.inputDeviceUID"
        static let dictationTranslates = "translate.dictation.on"
        static let dictationLanguage = "translate.dictation.language"
        static let notetakerTranslates = "translate.notetaker.on"
        static let notetakerLanguage = "translate.notetaker.language"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.cleanupEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        self.notetakerCleanupEnabled = defaults.object(forKey: Key.noteEnabled) as? Bool ?? true
        self.promptTemplate =
            defaults.string(forKey: Key.prompt) ?? PromptLibrary.defaultCleanupPrompt
        // An install from before fn was the default keeps the keys it had: right ⌥, and no
        // meeting key. A default that was never written cannot be told from a fresh install
        // by its absence — only by the onboarding flag, which an existing install has set
        // and a new one has not. Written back so the choice is made once and then shows
        // in Settings like any other.
        let isExistingInstall = defaults.bool(forKey: OnboardingCoordinator.completedDefaultsKey)

        if let hotkey = Self.decode(defaults.data(forKey: Key.hotkey)) {
            self.hotkey = hotkey
        } else if isExistingInstall {
            self.hotkey = .legacyDefault
            defaults.set(Self.encode(.legacyDefault), forKey: Key.hotkey)
        } else {
            self.hotkey = .default
        }
        // Three states on disk: never set (use the default), set (decode it), and cleared
        // (an empty blob — `nil` would read back as never set and the default would return
        // on the next launch, undoing the Clear button).
        if let data = defaults.data(forKey: Key.meetingHotkey) {
            self.meetingHotkey = data.isEmpty ? nil : Self.decode(data)
        } else if isExistingInstall {
            self.meetingHotkey = nil
            defaults.set(Data(), forKey: Key.meetingHotkey)
        } else {
            self.meetingHotkey = .meetingDefault
        }
        self.pauseMediaWhileDictating =
            defaults.object(forKey: Key.pauseMedia) as? Bool ?? true
        self.holdToTalk = defaults.object(forKey: Key.holdToTalk) as? Bool ?? true
        self.inputDeviceUID = defaults.string(forKey: Key.inputDevice)
        self.dictationTranslates = defaults.bool(forKey: Key.dictationTranslates)
        self.dictationOutputLanguage =
            defaults.string(forKey: Key.dictationLanguage) ?? "English"
        self.notetakerTranslates = defaults.bool(forKey: Key.notetakerTranslates)
        self.notetakerOutputLanguage =
            defaults.string(forKey: Key.notetakerLanguage) ?? "English"
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
    var notetakerCleanupEnabled: Bool {
        didSet { defaults.set(notetakerCleanupEnabled, forKey: Key.noteEnabled) }
    }

    var promptTemplate: String {
        didSet { defaults.set(promptTemplate, forKey: Key.prompt) }
    }

    // The custom words that used to live here are now `DictionaryStore`, which reads
    // `cleanup.customWords` once to seed itself and then owns the list. The key is still on
    // disk and deliberately untouched — see that store for why.

    // MARK: - Dictation

    /// The key that starts a dictation.
    var hotkey: Hotkey {
        didSet { defaults.set(Self.encode(hotkey), forKey: Key.hotkey) }
    }

    /// The key that starts a meeting. fn + left ⇧ by default — the dictation key with one
    /// more finger; still optional, because someone may not want a global key that begins
    /// recording everything they hear, and Clear must stay cleared.
    var meetingHotkey: Hotkey? {
        didSet {
            defaults.set(meetingHotkey.flatMap(Self.encode) ?? Data(), forKey: Key.meetingHotkey)
        }
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

    /// Hold the key to talk, or press once to start and once to stop. Hold is the default,
    /// as in Wispr Flow: a dictation is a sentence or two, letting go is the natural way to
    /// say "done", and a key that is held cannot be forgotten in the on position. The
    /// meeting key is press-to-toggle regardless — nobody holds a key for an hour.
    var holdToTalk: Bool {
        didSet { defaults.set(holdToTalk, forKey: Key.holdToTalk) }
    }

    // MARK: - Translation

    /// Whether dictation output is translated, and into what. Two values, not one
    /// optional: the toggle is flipped from the pill and the Dictation screen, and it
    /// must come back on remembering the language it had.
    var dictationTranslates: Bool {
        didSet { defaults.set(dictationTranslates, forKey: Key.dictationTranslates) }
    }
    var dictationOutputLanguage: String {
        didSet { defaults.set(dictationOutputLanguage, forKey: Key.dictationLanguage) }
    }
    /// What the clean-up is actually told, nil when translation is off.
    var dictationTargetLanguage: String? {
        dictationTranslates ? dictationOutputLanguage : nil
    }

    var notetakerTranslates: Bool {
        didSet { defaults.set(notetakerTranslates, forKey: Key.notetakerTranslates) }
    }
    var notetakerOutputLanguage: String {
        didSet { defaults.set(notetakerOutputLanguage, forKey: Key.notetakerLanguage) }
    }
    var notetakerTargetLanguage: String? {
        notetakerTranslates ? notetakerOutputLanguage : nil
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
