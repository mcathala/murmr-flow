import Foundation

/// The providers we ship.
///
/// This is the **only** place a provider name appears. If `"groq"` shows up anywhere in
/// the call path, the abstraction has leaked.
enum ProviderCatalog {

    struct Entry: Identifiable, Sendable, Equatable {
        let id: String
        let displayName: String
        let defaultBaseURL: String
        let defaultModel: String
        /// Where the user gets a key, shown next to the field.
        let keyURL: String?
        /// Whether the endpoint needs one at all. A local model served on this machine
        /// does not, so demanding a key before letting you use it would be wrong.
        let requiresKey: Bool
        /// Whether the base URL is expected to be edited.
        let requiresCustomBaseURL: Bool
        let suggestedModels: [String]
    }

    static let groq = Entry(
        id: "groq",
        displayName: "Groq",
        defaultBaseURL: "https://api.groq.com/openai/v1",
        defaultModel: "openai/gpt-oss-120b",
        keyURL: "https://console.groq.com/keys",
        requiresKey: true,
        requiresCustomBaseURL: false,
        suggestedModels: [
            "openai/gpt-oss-120b",
            "openai/gpt-oss-20b",
        ]
    )

    /// Same code path with an editable URL. Near-zero work, and it covers OpenRouter,
    /// Ollama, LM Studio and anything self-hosted without provider-specific code — as
    /// well as keeping the abstraction honest.
    static let custom = Entry(
        id: "custom",
        displayName: "Custom (OpenAI-compatible)",
        defaultBaseURL: "",
        defaultModel: "",
        keyURL: nil,
        // Covers Ollama and LM Studio as well as hosted endpoints, and those want no key.
        requiresKey: false,
        requiresCustomBaseURL: true,
        suggestedModels: [
            "http://localhost:11434/v1 — Ollama",
            "https://openrouter.ai/api/v1 — OpenRouter",
        ]
    )

    static let all: [Entry] = [groq, custom]

    static func entry(id: String) -> Entry {
        all.first { $0.id == id } ?? groq
    }

    static func defaultConfig(for entry: Entry) -> ProviderConfig {
        ProviderConfig(
            providerID: entry.id,
            baseURL: entry.defaultBaseURL,
            model: entry.defaultModel
        )
    }
}
