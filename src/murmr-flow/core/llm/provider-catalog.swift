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
        /// The provider's own mark, a file under `Resources/Providers`. Nil draws a
        /// monogram. Sources and licences: `resources/providers/SOURCES.md`.
        var logo: String? = nil
        /// Whether the mark is a full tile with its own background, to be shown edge to
        /// edge, rather than a glyph to be centred in ours.
        var logoIsTile: Bool = false
        /// Addresses worth offering as chips when the endpoint is the user's to type.
        var suggestedEndpoints: [String] = []
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
        ],
        logo: "groq.svg",
        logoIsTile: true
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
        ],
        logo: "cerebras.png"
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
        ],
        logo: "ollama.svg"
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
        ],
        logo: "openrouter.svg"
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
        ],
        logo: "gemini.svg"
    )

    /// Same code path with an editable URL. Near-zero work, and it covers a local Ollama or
    /// LM Studio and anything self-hosted without provider-specific code — as well as
    /// keeping the abstraction honest.
    ///
    /// Just "Custom" to the user. It was "Custom (OpenAI-compatible)", which named the
    /// protocol in the one place nobody can act on it; what it means — any server that
    /// speaks the OpenAI chat API, and nothing else — is said in the editor instead.
    static let custom = Entry(
        id: "custom",
        displayName: "Custom",
        defaultBaseURL: "",
        defaultModel: "",
        keyURL: nil,
        // A model served on this machine wants no key.
        requiresKey: false,
        requiresCustomBaseURL: true,
        suggestedModels: [],
        suggestedEndpoints: [
            "http://localhost:11434/v1",
            "http://localhost:1234/v1",
        ]
    )

    /// One sentence on what Custom takes, for the editor and onboarding. The answer to
    /// "what if my server is not OpenAI-compatible" is that it will not work: the app
    /// speaks that one API, and so do all five providers above.
    static let customExplanation =
        "Any server that speaks the OpenAI chat API: Ollama, LM Studio, vLLM and most "
        + "hosted providers. Anything else won\u{2019}t work. Ollama on this Mac is the "
        + "first address, LM Studio the second."

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
