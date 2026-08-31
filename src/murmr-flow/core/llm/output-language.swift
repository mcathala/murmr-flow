import Foundation

/// The language the finished text is written in, when it isn't the one that was spoken.
///
/// Translation is a clean-up concern: speech becomes text on this Mac in whatever
/// language it was said, and the LLM pass — the only place text already goes through a
/// model that can translate — is told to write its reply in the target language. No
/// provider means no translation, the same honest deal as styles.
///
/// The list offered is the speech model's own, for consistency with onboarding — the LLM
/// could write languages Parakeet cannot hear, but a menu that matches the flags the user
/// picked from is one list to understand instead of two.
enum OutputLanguage {

    static var choices: [String] { SpeechModel.languageChoices }

    static func flag(for language: String) -> String? { SpeechModel.flag(for: language) }

    /// "EN", for the places a word doesn't fit — the pill, a menu label.
    static func shortCode(for language: String) -> String {
        codes[language] ?? String(language.prefix(2)).uppercased()
    }

    /// ISO 639-1, not the first two letters: Estonian and Spanish both start "Es".
    private static let codes: [String: String] = [
        "Bulgarian": "BG", "Croatian": "HR", "Czech": "CS", "Danish": "DA",
        "Dutch": "NL", "English": "EN", "Estonian": "ET", "Finnish": "FI",
        "French": "FR", "German": "DE", "Greek": "EL", "Hungarian": "HU",
        "Italian": "IT", "Japanese": "JA", "Latvian": "LV", "Lithuanian": "LT",
        "Maltese": "MT", "Polish": "PL", "Portuguese": "PT", "Romanian": "RO",
        "Russian": "RU", "Slovak": "SK", "Slovenian": "SL", "Spanish": "ES",
        "Swedish": "SV", "Ukrainian": "UK",
    ]
}
