import Foundation

/// Turns a raw transcript into presentable text.
///
/// **This deliberately never throws.** The governing rule is that the user's words are
/// never lost, so every failure resolves to "use the raw transcript and say why" rather
/// than to an error the caller might forget to handle. Making that impossible to get
/// wrong is worth the slightly unusual signature.
actor CleanupService {

    struct Outcome: Sendable {
        /// What to type. Cleaned text on success, the raw transcript otherwise.
        let text: String
        /// True when cleanup failed and `text` is the raw transcript.
        let usedRawFallback: Bool
        /// Why cleanup was skipped or failed, for a non-blocking warning.
        let note: String?
        let latency: TimeInterval

        static func raw(_ transcript: String, note: String?) -> Outcome {
            Outcome(text: transcript, usedRawFallback: true, note: note, latency: 0)
        }
    }

    private let client = LLMClient()

    /// Dictation is latency-sensitive: past a few seconds the user would rather have
    /// unpolished text than keep waiting.
    static let dictationTimeout: TimeInterval = 6

    func clean(
        transcript: String,
        config: ProviderConfig?,
        prompt: PromptLibrary,
        context: PromptLibrary.Context,
        timeout: TimeInterval = CleanupService.dictationTimeout
    ) async -> Outcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .raw(transcript, note: nil) }

        guard let config else {
            return .raw(transcript, note: "No cleanup provider configured.")
        }
        guard config.apiKey != nil else {
            return .raw(transcript, note: "No API key saved — add one in Settings.")
        }

        var rendered = context
        rendered.transcript = trimmed

        do {
            let completion = try await client.complete(
                prompt: prompt.render(rendered),
                config: config,
                timeout: timeout
            )

            // A model that returns something wildly longer than the input has ignored
            // the instructions and started answering or explaining. Typing that into the
            // user's document would be worse than typing the raw transcript.
            guard isPlausibleCleanup(original: trimmed, cleaned: completion.text) else {
                return .raw(
                    transcript,
                    note: "Cleanup returned something unexpected; used the raw transcript."
                )
            }

            return Outcome(
                text: completion.text,
                usedRawFallback: false,
                note: nil,
                latency: completion.latency
            )
        } catch {
            return .raw(transcript, note: error.localizedDescription)
        }
    }

    /// Cleanup should reword punctuation, not change length dramatically. Filler removal
    /// can shrink text meaningfully, so the floor is generous; the ceiling is what
    /// catches a model that decided to answer the transcript instead of tidying it.
    private func isPlausibleCleanup(original: String, cleaned: String) -> Bool {
        let originalCount = original.count
        guard originalCount > 0 else { return false }
        let ratio = Double(cleaned.count) / Double(originalCount)
        // Very short utterances have noisy ratios, so only enforce this once there is
        // enough text for the ratio to mean anything.
        guard originalCount >= 40 else { return ratio < 4.0 }
        return ratio > 0.4 && ratio < 2.0
    }
}
