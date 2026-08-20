import Foundation

/// Everything the HTTP client needs to talk to one provider.
///
/// `LLMClient` takes this and nothing else. It has no idea which provider it is
/// calling, which is what makes adding a provider later a config entry rather than a
/// code change.
struct ProviderConfig: Sendable, Equatable {

    let providerID: String
    var baseURL: String
    /// Free text on purpose. Provider model names change monthly, so a hardcoded enum
    /// goes stale within weeks.
    var model: String

    /// Keychain account holding this provider's API key.
    var keychainAccount: String { KeychainStore.account(forProvider: providerID) }

    var apiKey: String? { KeychainStore.read(account: keychainAccount) }

    /// Endpoint for chat completions, tolerating a trailing slash in `baseURL`.
    var chatCompletionsURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: trimmed + "/chat/completions")
    }

    /// Reasoning models spend tokens thinking before answering. For cleanup that is
    /// pure latency, so effort is pinned low where the provider supports it.
    var reasoningEffort: String? = "low"

    /// gpt-oss returns reasoning in a separate field by default; this makes sure none
    /// of it can reach the text we type into the user's document.
    var suppressReasoning: Bool = true
}
