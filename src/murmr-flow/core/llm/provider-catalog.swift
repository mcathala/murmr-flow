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

    /// Hosts the same gpt-oss-120b as Groq with a free tier five times the size — 1M
    /// tokens a day against 200K — which is what made it the second entry.
    static let cerebras = Entry(
        id: "cerebras",
        displayName: "Cerebras",
        defaultBaseURL: "https://api.cerebras.ai/v1",
        defaultModel: "gpt-oss-120b",
        keyURL: "https://cloud.cerebras.ai/",
        requiresKey: true,
        requiresCustomBaseURL: false,
        suggestedModels: [
            "gpt-oss-120b",
            "qwen-3.8-27b",
        ]
    )

    /// Ollama's hosted models, not the local server — that one is a Custom endpoint at
    /// localhost. The good models are too big for a laptop, so "Ollama" here means their
    /// cloud, with a key. Model names keep Ollama's colon form.
    static let ollama = Entry(
        id: "ollama",
        displayName: "Ollama Cloud",
        defaultBaseURL: "https://ollama.com/v1",
        defaultModel: "gpt-oss:120b",
        keyURL: "https://ollama.com/settings/keys",
        requiresKey: true,
        requiresCustomBaseURL: false,
        suggestedModels: [
            "gpt-oss:120b",
            "gpt-oss:20b",
        ]
    )

    /// One key, every model. The free routes are rationed to 50 requests a day unless the
    /// account has ever bought $10 of credit, so it is the power user's entry, not the default.
    static let openRouter = Entry(
        id: "openrouter",
        displayName: "OpenRouter",
        defaultBaseURL: "https://openrouter.ai/api/v1",
        defaultModel: "openai/gpt-oss-120b",
        keyURL: "https://openrouter.ai/settings/keys",
        requiresKey: true,
        requiresCustomBaseURL: false,
        suggestedModels: [
            "openai/gpt-oss-120b",
            "openai/gpt-oss-20b",
        ]
    )

    /// The one most people already have an account for. Google's OpenAI-compatible
    /// endpoint; Flash-Lite because it is the fastest and the free tier's most generous.
    /// The free tier may use what is sent to improve Google's models; worth a line in the
    /// onboarding when that is designed.
    static let gemini = Entry(
        id: "gemini",
        displayName: "Google Gemini",
        defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        defaultModel: "gemini-3.5-flash-lite",
        keyURL: "https://aistudio.google.com/apikey",
        requiresKey: true,
        requiresCustomBaseURL: false,
        suggestedModels: [
            "gemini-3.5-flash-lite",
            "gemini-3.8-flash",
        ]
    )

    /// Same code path with an editable URL. Near-zero work, and it covers a local Ollama or
    /// LM Studio and anything self-hosted without provider-specific code — as well as
    /// keeping the abstraction honest.
    static let custom = Entry(
        id: "custom",
        displayName: "Custom (OpenAI-compatible)",
        defaultBaseURL: "",
        defaultModel: "",
        keyURL: nil,
        // A model served on this machine wants no key.
        requiresKey: false,
        requiresCustomBaseURL: true,
        suggestedModels: [
            "http://localhost:11434/v1 — Ollama on this Mac",
            "http://localhost:1234/v1 — LM Studio",
        ]
    )

    static let all: [Entry] = [groq, cerebras, ollama, openRouter, gemini, custom]

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
