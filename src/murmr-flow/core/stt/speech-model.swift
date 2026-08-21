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

    /// Languages the model covers. Shown as information — v3 auto-detects, so there is
    /// nothing for the user to select.
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
