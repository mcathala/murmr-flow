import Foundation
import Testing

@testable import MurmrFlow

/// Which keys an install starts with, and which it keeps.
@MainActor
@Suite("Settings defaults")
struct SettingsStoreTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "murmr-settings-\(UUID())")!
    }

    @Test("a fresh install gets fn and fn + left shift, and holds to talk")
    func fresh() {
        let store = SettingsStore(defaults: defaults())
        #expect(store.hotkey == .default)
        #expect(store.meetingHotkey == .meetingDefault)
        #expect(store.holdToTalk)
    }

    /// The old default was never written to disk, so it is the onboarding flag — which
    /// only an install that already ran has — that says "keep what you had".
    @Test("an install from before fn keeps right option and no meeting key")
    func existingInstallKeepsItsKeys() {
        let defaults = defaults()
        defaults.set(true, forKey: OnboardingCoordinator.completedDefaultsKey)

        let store = SettingsStore(defaults: defaults)
        #expect(store.hotkey == .legacyDefault)
        #expect(store.meetingHotkey == nil)

        // Decided once: a second launch reads the same answer back rather than deciding
        // again, and Clear on the meeting key stays cleared.
        let again = SettingsStore(defaults: defaults)
        #expect(again.hotkey == .legacyDefault)
        #expect(again.meetingHotkey == nil)
    }

    @Test("a key the user chose is never overridden")
    func chosenKeyWins() {
        let defaults = defaults()
        defaults.set(true, forKey: OnboardingCoordinator.completedDefaultsKey)
        let first = SettingsStore(defaults: defaults)
        first.hotkey = .default
        first.meetingHotkey = .meetingDefault

        let second = SettingsStore(defaults: defaults)
        #expect(second.hotkey == .default)
        #expect(second.meetingHotkey == .meetingDefault)
    }
}
