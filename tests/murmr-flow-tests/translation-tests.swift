import Foundation
import Testing

@testable import MurmrFlow

/// Speaking in one language, landing in another — a clean-up concern, tested where it
/// lives: the prompt, and the settings that feed it.
@MainActor
@Suite("Translation")
struct TranslationTests {

    @Test("the prompt is told the output language, over its own instructions")
    func promptCarriesTheLanguage() {
        let prompt = PromptLibrary()
        let rendered = prompt.render(
            PromptLibrary.Context(transcript: "bonjour tout le monde", outputLanguage: "English")
        )
        #expect(rendered.contains("Write the result in English"))
        #expect(rendered.contains("overrides anything above"))
        // The transcript still goes in untouched — translating is the model's job.
        #expect(rendered.contains("bonjour tout le monde"))
    }

    @Test("no language means no instruction")
    func offByDefault() {
        let rendered = PromptLibrary().render(PromptLibrary.Context(transcript: "hello"))
        #expect(!rendered.contains("Write the result in"))
    }

    /// Markers carry the user's exact text — an email address, a snippet — and the
    /// instruction to leave them alone has to survive the instruction to translate.
    @Test("the marker instruction still follows the translation instruction")
    func markersStillProtected() {
        var context = PromptLibrary.Context(transcript: "voir [[MF1]]", outputLanguage: "English")
        context.hasMarkers = true
        let rendered = PromptLibrary().render(context)
        let translate = rendered.range(of: "Write the result in English")
        let markers = rendered.range(of: "Leave any [[MF")
        #expect(translate != nil && markers != nil)
        #expect(translate!.lowerBound < markers!.lowerBound)
    }

    @Test("the target is nil while the toggle is off, and the language survives it")
    func toggleKeepsTheLanguage() {
        let defaults = UserDefaults(suiteName: "murmr-translate-\(UUID())")!
        let store = SettingsStore(defaults: defaults)
        #expect(store.dictationTargetLanguage == nil)

        store.dictationOutputLanguage = "French"
        store.dictationTranslates = true
        #expect(store.dictationTargetLanguage == "French")

        store.dictationTranslates = false
        #expect(store.dictationTargetLanguage == nil)

        // Back on: same language, one click, and it survives a relaunch.
        let again = SettingsStore(defaults: defaults)
        #expect(again.dictationOutputLanguage == "French")
        #expect(again.notetakerTargetLanguage == nil)
    }

    @Test("every offered language has a short code that isn't a guess")
    func shortCodes() {
        // Estonian and Spanish both start "Es" — the map has to answer, not the prefix.
        #expect(OutputLanguage.shortCode(for: "Estonian") == "ET")
        #expect(OutputLanguage.shortCode(for: "Spanish") == "ES")
        for language in OutputLanguage.choices {
            #expect(OutputLanguage.shortCode(for: language).count == 2, "\(language)")
        }
    }
}
