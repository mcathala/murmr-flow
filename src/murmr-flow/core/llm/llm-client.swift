import Foundation

/// One HTTP client for every provider.
///
/// All of Groq, OpenAI, OpenRouter, Gemini, Ollama and LM Studio speak the OpenAI
/// `POST /chat/completions` shape, so there is a single request builder and a single
/// response decoder rather than one adapter per provider.
///
/// Note on gzip: `URLSession` negotiates and decodes `Content-Encoding` transparently,
/// so no explicit handling is needed here — that is only a problem for HTTP clients
/// that require opting in.
actor LLMClient {

    enum ClientError: LocalizedError {
        case notConfigured
        case invalidBaseURL(String)
        case missingAPIKey
        case http(status: Int, body: String)
        case emptyCompletion
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "No cleanup provider is configured."
            case .invalidBaseURL(let url):
                "That base URL isn't valid: \(url)"
            case .missingAPIKey:
                "No API key saved for this provider."
            case .http(let status, let body):
                switch status {
                case 401, 403: "The API key was rejected (\(status)). Check it in Settings."
                case 429: "Rate limited by the provider (429). Try again shortly."
                case 500...599: "The provider had a server error (\(status))."
                default: "The provider returned \(status): \(body.prefix(200))"
                }
            case .emptyCompletion:
                "The provider returned an empty response."
            case .timedOut:
                "The cleanup request timed out."
            }
        }
    }

    struct Completion: Sendable {
        let text: String
        let latency: TimeInterval
        /// Token counts as the provider reports them, when it does. Prompt tokens are the
        /// cost of the prompt's wording on every single clean-up, which is why they are
        /// worth knowing.
        var promptTokens: Int?
        var completionTokens: Int?
    }

    // MARK: - Request / response shapes

    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        var reasoning_effort: String?
        var include_reasoning: Bool?
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                /// gpt-oss puts chain-of-thought here rather than in `content`. We read
                /// it only to be certain we are *not* using it.
                let reasoning: String?
            }
            let message: Message
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
        }
        let choices: [Choice]
        let usage: Usage?
    }

    private struct Reply {
        let text: String
        let usage: Response.Usage?
    }

    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let message: String?
            let code: String?
            let param: String?
        }
        let error: Payload?
    }

    // MARK: - Call

    func complete(
        prompt: String,
        config: ProviderConfig,
        timeout: TimeInterval
    ) async throws -> Completion {
        guard !config.model.isEmpty else { throw ClientError.notConfigured }
        guard let url = config.chatCompletionsURL else {
            throw ClientError.invalidBaseURL(config.baseURL)
        }
        guard let key = config.apiKey, !key.isEmpty else { throw ClientError.missingAPIKey }

        // Groq's guidance for reasoning models is to avoid system prompts and put every
        // instruction in the user message, so there is deliberately only one message.
        var body = Request(
            model: config.model,
            messages: [.init(role: "user", content: prompt)],
            temperature: 0.2,
            reasoning_effort: config.reasoningEffort,
            include_reasoning: config.suppressReasoning ? false : nil
        )

        let clock = ContinuousClock()
        let started = clock.now

        do {
            let reply = try await send(body, to: url, key: key, timeout: timeout)
            return completion(reply, since: started, clock)
        } catch ClientError.http(let status, let responseBody) where status == 400
            && mentionsReasoningParameter(responseBody)
        {
            // Not every OpenAI-compatible endpoint accepts the reasoning controls.
            // Retry once without them rather than failing the dictation.
            body.reasoning_effort = nil
            body.include_reasoning = nil
            let reply = try await send(body, to: url, key: key, timeout: timeout)
            return completion(reply, since: started, clock)
        }
    }

    private func completion(
        _ reply: Reply, since started: ContinuousClock.Instant, _ clock: ContinuousClock
    ) -> Completion {
        Completion(
            text: reply.text,
            latency: (clock.now - started).seconds,
            promptTokens: reply.usage?.prompt_tokens,
            completionTokens: reply.usage?.completion_tokens
        )
    }

    private func send(
        _ body: Request,
        to url: URL,
        key: String,
        timeout: TimeInterval
    ) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ClientError.timedOut
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.emptyCompletion
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?
                .error?.message
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw ClientError.http(status: http.statusCode, body: detail)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let raw = decoded.choices.first?.message.content else {
            throw ClientError.emptyCompletion
        }

        let text = Self.stripLeakedReasoning(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClientError.emptyCompletion }
        return Reply(text: text, usage: decoded.usage)
    }

    // MARK: - Defensive cleanup

    private func mentionsReasoningParameter(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("reasoning_effort")
            || lowered.contains("include_reasoning")
            || lowered.contains("reasoning_format")
    }

    /// Some endpoints inline chain-of-thought in `<think>` tags instead of splitting it
    /// into a separate field. This text gets typed into the user's document, so strip
    /// them rather than trusting every provider to behave.
    static func stripLeakedReasoning(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var result = text
        while let open = result.range(of: "<think>"),
              let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex)
        {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // An unterminated tag means everything after it is reasoning.
        if let open = result.range(of: "<think>") {
            result.removeSubrange(open.lowerBound..<result.endIndex)
        }
        return result
    }
}
