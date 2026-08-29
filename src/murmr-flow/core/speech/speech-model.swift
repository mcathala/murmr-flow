import FluidAudio

/// The local speech-to-text models we offer.
///
/// Onboarding picks between these with a single question — English only, or multiple
/// languages — and downloads just the one chosen. v2 is not a lesser v3: it ships a
/// tighter vocabulary and has better recall on English, so it is the right answer for
/// an English-only user rather than a fallback.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case parakeetV3
    case parakeetV2

    var id: String { rawValue }

    /// What the choice actually is, from the user's side. The model's real name is
    /// trivia; "multiple languages or just English" is the decision.
    var headline: String {
        switch self {
        case .parakeetV3: "Multiple languages"
        case .parakeetV2: "English only"
        }
    }

    var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet TDT v3"
        case .parakeetV2: "Parakeet TDT v2"
        }
    }

    var summary: String {
        switch self {
        case .parakeetV3: "25 European languages + Japanese, auto-detected"
        case .parakeetV2: "English only — best accuracy for English"
        }
    }

    /// Rough on-disk size, for the download prompt.
    var approximateSizeMB: Int { 600 }

    /// The size as it is shown: "0.6 GB", not "600 MB". Same number, and the one people
    /// read as the smaller download.
    var approximateSizeLabel: String {
        String(format: "%.1f GB", Double(approximateSizeMB) / 1000)
    }

    /// The HuggingFace repo backing this model. Needed to resolve the on-disk cache
    /// location, because `AsrModels.modelsExist(at:)` expects a directory that already
    /// includes the repo folder — it calls `deletingLastPathComponent()` internally, so
    /// handing it the models *root* silently looks one level too high.
    var repo: Repo {
        switch self {
        case .parakeetV3: .parakeetV3
        case .parakeetV2: .parakeetV2
        }
    }

    var asrVersion: AsrModelVersion {
        switch self {
        case .parakeetV3: .v3
        case .parakeetV2: .v2
        }
    }

    /// The model for a set of languages someone speaks.
    ///
    /// The question onboarding asks is about the person, not the model. English on its own
    /// gets v2 — not a fallback, the better model for English — and anything else gets v3,
    /// which covers every language offered and picks between them by itself.
    static func covering(_ languages: Set<String>) -> SpeechModel {
        languages == ["English"] ? .parakeetV2 : .parakeetV3
    }

    /// The two most people will tap, on a row of their own at the top.
    static let featuredLanguages = ["English", "French"]

    /// Everything else, A to Z.
    static var otherLanguages: [String] {
        parakeetV3.languages.filter { !featuredLanguages.contains($0) }.sorted()
    }

    /// Every language on offer, in the order it is shown.
    static var languageChoices: [String] { featuredLanguages + otherLanguages }

    /// A flag to recognise the language by, faster than reading its name.
    ///
    /// Languages are not countries, so each is the flag people expect rather than a claim:
    /// English gets the UK, Portuguese gets Portugal, Spanish gets Spain.
    static func flag(for language: String) -> String? {
        flags[language]
    }

    private static let flags: [String: String] = [
        "Bulgarian": "\u{1F1E7}\u{1F1EC}", "Croatian": "\u{1F1ED}\u{1F1F7}",
        "Czech": "\u{1F1E8}\u{1F1FF}", "Danish": "\u{1F1E9}\u{1F1F0}",
        "Dutch": "\u{1F1F3}\u{1F1F1}", "English": "\u{1F1EC}\u{1F1E7}",
        "Estonian": "\u{1F1EA}\u{1F1EA}", "Finnish": "\u{1F1EB}\u{1F1EE}",
        "French": "\u{1F1EB}\u{1F1F7}", "German": "\u{1F1E9}\u{1F1EA}",
        "Greek": "\u{1F1EC}\u{1F1F7}", "Hungarian": "\u{1F1ED}\u{1F1FA}",
        "Italian": "\u{1F1EE}\u{1F1F9}", "Japanese": "\u{1F1EF}\u{1F1F5}",
        "Latvian": "\u{1F1F1}\u{1F1FB}", "Lithuanian": "\u{1F1F1}\u{1F1F9}",
        "Maltese": "\u{1F1F2}\u{1F1F9}", "Polish": "\u{1F1F5}\u{1F1F1}",
        "Portuguese": "\u{1F1F5}\u{1F1F9}", "Romanian": "\u{1F1F7}\u{1F1F4}",
        "Russian": "\u{1F1F7}\u{1F1FA}", "Slovak": "\u{1F1F8}\u{1F1F0}",
        "Slovenian": "\u{1F1F8}\u{1F1EE}", "Spanish": "\u{1F1EA}\u{1F1F8}",
        "Swedish": "\u{1F1F8}\u{1F1EA}", "Ukrainian": "\u{1F1FA}\u{1F1E6}",
    ]

    /// Languages the model covers. v3 auto-detects, so once chosen there is nothing more
    /// for the user to select.
    var languages: [String] {
        switch self {
        case .parakeetV2:
            ["English"]
        case .parakeetV3:
            [
                "Bulgarian", "Croatian", "Czech", "Danish", "Dutch", "English", "Estonian",
                "Finnish", "French", "German", "Greek", "Hungarian", "Italian", "Japanese",
                "Latvian", "Lithuanian", "Maltese", "Polish", "Portuguese", "Romanian",
                "Russian", "Slovak", "Slovenian", "Spanish", "Swedish", "Ukrainian",
            ]
        }
    }
}
