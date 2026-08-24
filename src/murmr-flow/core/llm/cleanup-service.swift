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

    /// A meeting is not. Transcribing an hour already took a visible while, nobody is
    /// waiting with a cursor in a document, and the request is far larger — so the budget
    /// is minutes rather than seconds.
    static let noteTimeout: TimeInterval = 120

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

    // MARK: - Conversations

    /// One person's turn, as cleanup sees it.
    struct Turn: Sendable, Equatable {
        let speaker: String
        let text: String
    }

    /// Cleaned text, positionally matched to the turns that went in.
    ///
    /// `texts` always has the same count as the input, in the same order. Anything the
    /// model failed to return keeps its raw wording, which is the whole point: a meeting
    /// note is the only copy — the audio is deleted — so a turn must never be able to
    /// disappear because a request came back short.
    struct TurnsOutcome: Sendable {
        let texts: [String]
        let cleanedCount: Int
        let note: String?
        let latency: TimeInterval

        var usedRawFallback: Bool { cleanedCount == 0 }

        static func raw(_ turns: [Turn], note: String?) -> TurnsOutcome {
            TurnsOutcome(texts: turns.map(\.text), cleanedCount: 0, note: note, latency: 0)
        }
    }

    /// Roughly how much transcript goes in one request.
    ///
    /// Whole-conversation-in-one-call is better for context but worse for everything else:
    /// a long meeting overruns the context window, and one refusal or one truncated reply
    /// then costs the entire note. Batching bounds the damage to a few turns.
    private static let batchCharacters = 6000

    /// Cleans a conversation while keeping who said what.
    ///
    /// The user's prompt says how to tidy the words; the app appends the line-per-turn
    /// contract itself, so a prompt written for dictation works here unchanged.
    func cleanTurns(
        _ turns: [Turn],
        config: ProviderConfig?,
        prompt: PromptLibrary,
        context: PromptLibrary.Context,
        timeout: TimeInterval = CleanupService.noteTimeout
    ) async -> TurnsOutcome {
        guard !turns.isEmpty else { return .raw(turns, note: nil) }
        guard let config else {
            return .raw(turns, note: "No cleanup provider configured.")
        }
        guard config.apiKey != nil else {
            return .raw(turns, note: "No API key saved — add one in Settings.")
        }

        var texts = turns.map(\.text)
        var cleanedCount = 0
        var latency: TimeInterval = 0
        var failure: String?

        for batch in Self.batches(of: turns) {
            var rendered = context
            rendered.transcript = Self.numbered(turns[batch], startingAt: batch.lowerBound)

            let body = prompt.render(rendered) + "\n\n" + PromptLibrary.turnContract
            do {
                let completion = try await client.complete(
                    prompt: body, config: config, timeout: timeout
                )
                latency += completion.latency

                for (index, cleaned) in Self.parseNumbered(completion.text) {
                    guard batch.contains(index) else { continue }  // not a line we asked for
                    let original = turns[index].text
                    guard isPlausibleCleanup(original: original, cleaned: cleaned) else {
                        continue
                    }
                    texts[index] = cleaned
                    cleanedCount += 1
                }
            } catch {
                // One failure usually means the provider is unreachable or the key is
                // wrong, and the remaining batches would fail the same way. Stop rather
                // than spending a dozen more requests to learn it again.
                failure = error.localizedDescription
                break
            }
        }

        return TurnsOutcome(
            texts: texts,
            cleanedCount: cleanedCount,
            note: Self.note(cleaned: cleanedCount, of: turns.count, failure: failure),
            latency: latency
        )
    }

    /// Ranges of turns small enough to send in one request. Always at least one turn, so
    /// a single very long turn is attempted rather than silently skipped.
    static func batches(of turns: [Turn]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var length = 0

        for (index, turn) in turns.enumerated() {
            length += turn.text.count + turn.speaker.count + 8  // the `[n] Speaker: ` shape
            let isLast = index == turns.count - 1
            if length >= Self.batchCharacters || isLast {
                ranges.append(start..<(index + 1))
                start = index + 1
                length = 0
            }
        }
        return ranges
    }

    /// `[7] You: what they said`, one line per turn, numbered from their real position so
    /// the numbers stay meaningful across batches.
    static func numbered(_ turns: some Collection<Turn>, startingAt offset: Int) -> String {
        turns.enumerated()
            .map { "[\($0.offset + offset)] \($0.element.speaker): \($0.element.text)" }
            .joined(separator: "\n")
    }

    /// Reads the model's reply back into turn positions.
    ///
    /// Lenient on purpose — leading bullets, bold speakers and stray blank lines are all
    /// things models add, and none of them are a reason to throw away a cleaned turn.
    /// Anything genuinely unparseable is simply absent, and the caller keeps the original.
    static func parseNumbered(_ reply: String) -> [Int: String] {
        guard let pattern = try? Regex(#"^\W{0,4}\[(\d{1,5})\]\s*\**([^:\n]{0,40}?)\**\s*:\s*(.*)$"#)
        else { return [:] }

        var found: [Int: String] = [:]
        for raw in reply.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = try? pattern.wholeMatch(in: line),
                  let index = Int(match.output[1].substring ?? "")
            else { continue }

            let text = String(match.output[3].substring ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // A repeated number means the model split a turn. Keep the first, which is
            // the one that lines up with what was asked for.
            if found[index] == nil { found[index] = text }
        }
        return found
    }

    private static func note(cleaned: Int, of total: Int, failure: String?) -> String? {
        if cleaned == 0 { return failure ?? "Cleanup didn't return anything usable." }
        guard cleaned < total else { return failure }
        let kept = total - cleaned
        let detail = "\(kept) of \(total) turns kept their raw wording."
        return failure.map { "\($0) \(detail)" } ?? detail
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
