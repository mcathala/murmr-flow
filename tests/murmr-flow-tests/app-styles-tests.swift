import CoreGraphics
import Foundation
import Testing

@testable import MurmrFlow

/// Which style a dictation runs, and what chose it.
///
/// The precedence — key, then app rule, then the standing style — is the whole feature,
/// and it is the kind of rule that reads as obvious and goes wrong quietly: a rule left
/// behind by a deleted style, a key bound to two styles, a rule that survives a relaunch
/// pointing at nothing. Each of those is a test here.
@MainActor
@Suite("Styles by app and by key")
struct AppStylesTests {

    /// A store with the shipped built-ins, on defaults of its own.
    private func store(_ name: String = "styles") -> (PromptStore, UserDefaults) {
        let defaults = Scratch.defaults(name)
        return (PromptStore(defaults: defaults), defaults)
    }

    private func formal(_ prompts: PromptStore) -> PromptPreset {
        prompts.presets.first { $0.name == "Formal" }!
    }

    private let fnOption = Hotkey(
        keyCode: 58, modifierRawValue: CGEventFlags.maskSecondaryFn.rawValue,
        isModifierOnly: true
    )

    @Test("With no rule and no key, the standing style applies")
    func standing() {
        let (prompts, _) = store()
        let choice = prompts.choice(forApp: "com.apple.mail")
        #expect(choice.preset?.id == prompts.dictationPromptID)
        #expect(choice.source == .standing)
        #expect(choice.detail == nil)
    }

    @Test("A rule for the app in front beats the standing style")
    func ruleWins() {
        let (prompts, _) = store()
        prompts.setRule(
            AppStyleRule(
                bundleID: "com.apple.mail", appName: "Mail",
                outcome: .style(formal(prompts).id)
            )
        )
        let choice = prompts.choice(forApp: "com.apple.mail")
        #expect(choice.preset?.name == "Formal")
        #expect(choice.detail == "Mail")
        // And only for that app.
        #expect(prompts.choice(forApp: "com.tinyspeck.slackmacgap").source == .standing)
    }

    @Test("A key beats a rule, because pressing it is the more deliberate act")
    func keyWins() {
        let (prompts, _) = store()
        let structure = prompts.presets.first { $0.name == "Structure" }!
        prompts.setRule(
            AppStyleRule(
                bundleID: "com.apple.mail", appName: "Mail",
                outcome: .style(formal(prompts).id)
            )
        )
        prompts.setHotkey(fnOption, for: structure.id)

        let choice = prompts.choice(forApp: "com.apple.mail", heldStyleID: structure.id)
        #expect(choice.preset?.name == "Structure")
        #expect(choice.source == .key(fnOption.displayName))
    }

    @Test("A rule can say Off, which is not a style")
    func off() {
        let (prompts, _) = store()
        prompts.setRule(
            AppStyleRule(bundleID: "com.apple.Terminal", appName: "Terminal", outcome: .off)
        )
        let choice = prompts.choice(forApp: "com.apple.Terminal")
        #expect(choice.preset == nil)
        #expect(choice.displayName == "Off")
        #expect(choice.detail == "Terminal")
    }

    @Test("One rule per app: setting it again replaces rather than stacks")
    func oneRulePerApp() {
        let (prompts, _) = store()
        let rule = AppStyleRule(
            bundleID: "com.apple.mail", appName: "Mail", outcome: .style(formal(prompts).id)
        )
        prompts.setRule(rule)
        prompts.setRule(AppStyleRule(bundleID: "com.apple.mail", appName: "Mail", outcome: .off))
        #expect(prompts.appRules.count == 1)
        #expect(prompts.choice(forApp: "com.apple.mail").preset == nil)
    }

    @Test("Rules and keys come back after a relaunch")
    func persists() {
        let (prompts, defaults) = store()
        let formalID = formal(prompts).id
        prompts.setRule(
            AppStyleRule(bundleID: "com.apple.mail", appName: "Mail", outcome: .style(formalID))
        )
        prompts.setHotkey(fnOption, for: formalID)

        let reopened = PromptStore(defaults: defaults)
        #expect(reopened.choice(forApp: "com.apple.mail").preset?.id == formalID)
        #expect(reopened.hotkey(for: formalID) == fnOption)
    }

    @Test("Deleting a style takes its rules and its key with it")
    func deleteCleansUp() {
        let (prompts, _) = store()
        let target = formal(prompts)
        prompts.setRule(
            AppStyleRule(
                bundleID: "com.apple.mail", appName: "Mail", outcome: .style(target.id)
            )
        )
        prompts.setHotkey(fnOption, for: target.id)

        prompts.delete(target)
        #expect(prompts.appRules.isEmpty)
        #expect(prompts.hotkey(for: target.id) == nil)
        // And the app is back on the standing style rather than on nothing.
        #expect(prompts.choice(forApp: "com.apple.mail").source == .standing)
    }

    @Test("A stored rule for a style that no longer exists is dropped on load")
    func staleRuleDropped() {
        let (prompts, defaults) = store()
        let stale = UUID()
        prompts.setRule(
            AppStyleRule(bundleID: "com.apple.mail", appName: "Mail", outcome: .style(stale))
        )
        // Written straight to defaults, as a build that shipped the style would have left
        // it — the store's own delete would have cleaned up after itself.
        defaults.set(
            try? JSONEncoder().encode([stale.uuidString: fnOption]),
            forKey: "prompts.styleHotkeys"
        )

        let reopened = PromptStore(defaults: defaults)
        #expect(reopened.appRules.isEmpty)
        #expect(reopened.styleHotkeys.isEmpty)
        #expect(reopened.choice(forApp: "com.apple.mail").source == .standing)
    }

    @Test("An Off rule survives a style being deleted — it names no style")
    func offRuleSurvivesDelete() {
        let (prompts, _) = store()
        prompts.setRule(
            AppStyleRule(bundleID: "com.apple.Terminal", appName: "Terminal", outcome: .off)
        )
        prompts.delete(formal(prompts))
        #expect(prompts.choice(forApp: "com.apple.Terminal").preset == nil)
    }

    @Test("A key already held by another style is reported, not silently shared")
    func keyClash() {
        let (prompts, _) = store()
        let target = formal(prompts)
        prompts.setHotkey(fnOption, for: target.id)

        let other = prompts.presets.first { $0.name == "Structure" }!
        #expect(prompts.style(usingHotkey: fnOption, excluding: other.id)?.id == target.id)
        // Re-recording the key a style already has is not a clash with itself.
        #expect(prompts.style(usingHotkey: fnOption, excluding: target.id) == nil)
    }

    @Test("Summary starts on the shipped style, and cleared stays cleared")
    func summaryAssignment() {
        let (prompts, defaults) = store()
        #expect(prompts.summaryPrompt?.name == "Summary")

        prompts.summaryPromptID = nil
        #expect(PromptStore(defaults: defaults).summaryPrompt == nil)
    }

    @Test("Deleting the Summary style stops the note rather than picking another")
    func deletingSummaryStyle() {
        let (prompts, _) = store()
        let summary = prompts.presets.first { $0.name == "Summary" }!
        prompts.delete(summary)
        // Anything else would write the note with a style meant for tidying turns.
        #expect(prompts.summaryPromptID == nil)
    }
}
