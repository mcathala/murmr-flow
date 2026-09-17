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

    private let client: any LLMCompleting

    /// The real client by default. Tests hand in one that answers from a script, which is
    /// the only way to exercise the fallback rules below without paying a provider.
    init(client: any LLMCompleting = LLMClient()) {
        self.client = client
    }

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
        dictionary: [DictionaryEntry] = [],
        timeout: TimeInterval = CleanupService.dictationTimeout
    ) async -> Outcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .raw(transcript, note: nil) }

        // The dictionary is applied here rather than in the caller, because this is the one
        // seam every path goes through — and because an exact replacement has to survive
        // `config == nil`. Swapping a spoken phrase for stored text is local string work
        // that needs no provider, so clean-up being off must not switch it off too.
        let expansion = DictionaryExpander.expand(trimmed, using: dictionary)

        guard let config else {
            return .raw(expansion.resolved, note: "No cleanup provider configured.")
        }
        guard config.apiKey != nil else {
            return .raw(expansion.resolved, note: "No API key saved — add one in Settings.")
        }

        var rendered = context
        rendered.transcript = expansion.text
        rendered.hints = DictionaryExpander.hints(from: dictionary)
        rendered.hasMarkers = !expansion.isEmpty

        do {
            let completion = try await client.complete(
                prompt: prompt.render(rendered),
                config: config,
                timeout: timeout
            )

            // A model that returns something wildly longer than the input has ignored
            // the instructions and started answering or explaining. Typing that into the
            // user's document would be worse than typing the raw transcript. Measured
            // against what was actually sent, markers and all.
            guard isPlausibleCleanup(original: expansion.text, cleaned: completion.text) else {
                return .raw(
                    expansion.resolved,
                    note: "Cleanup returned something unexpected; used the raw transcript."
                )
            }

            // A marker that did not come back means the model swallowed something the user
            // asked for exactly. Their words are never lost, so this falls back to the
            // uncleaned text *with* the replacements in it — unpunctuated beats missing an
            // email address.
            guard let restored = expansion.restore(into: completion.text) else {
                return Outcome(
                    text: expansion.resolved,
                    usedRawFallback: true,
                    note: "Clean-up dropped a dictionary marker, so the raw transcript "
                        + "was used.",
                    latency: completion.latency
                )
            }

            return Outcome(
                text: restored,
                usedRawFallback: false,
                note: nil,
                latency: completion.latency
            )
        } catch {
            return .raw(expansion.resolved, note: error.localizedDescription)
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
        dictionary: [DictionaryEntry] = [],
        timeout: TimeInterval = CleanupService.noteTimeout
    ) async -> TurnsOutcome {
        guard !turns.isEmpty else { return .raw(turns, note: nil) }

        // Per turn, not per batch: a marker must never straddle a batch boundary, and a
        // turn the model never returns still deserves its replacements.
        let expansions = turns.map { DictionaryExpander.expand($0.text, using: dictionary) }
        let masked = zip(turns, expansions).map {
            Turn(speaker: $0.speaker, text: $1.text)
        }

        guard let config else {
            return TurnsOutcome(
                texts: expansions.map(\.resolved),
                cleanedCount: 0,
                note: "No cleanup provider configured.",
                latency: 0
            )
        }
        guard config.apiKey != nil else {
            return TurnsOutcome(
                texts: expansions.map(\.resolved),
                cleanedCount: 0,
                note: "No API key saved — add one in Settings.",
                latency: 0
            )
        }

        var texts = expansions.map(\.resolved)
        var cleanedCount = 0
        var latency: TimeInterval = 0
        var failure: String?
        let hints = DictionaryExpander.hints(from: dictionary)

        for batch in Self.batches(of: masked) {
            var rendered = context
            rendered.transcript = Self.numbered(masked[batch], startingAt: batch.lowerBound)
            rendered.hints = hints
            rendered.hasMarkers = expansions[batch].contains { !$0.isEmpty }

            let body = prompt.render(rendered) + "\n\n" + PromptLibrary.turnContract
            do {
                let completion = try await client.complete(
                    prompt: body, config: config, timeout: timeout
                )
                latency += completion.latency

                for (index, cleaned) in Self.parseNumbered(completion.text) {
                    guard batch.contains(index) else { continue }  // not a line we asked for
                    let original = masked[index].text
                    guard isPlausibleCleanup(original: original, cleaned: cleaned) else {
                        continue
                    }
                    // A turn whose marker the model lost keeps the resolved raw wording it
                    // already has, and does not count as cleaned.
                    guard let restored = expansions[index].restore(into: cleaned) else {
                        continue
                    }
                    texts[index] = restored
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

    // MARK: - The note above the transcript

    /// What one note-writing request produced.
    struct NoteOutcome: Sendable {
        /// The note, or nil when none could be written. Nil is not a failure to hide: the
        /// transcript is saved either way, and a half-written note would be worse than
        /// none.
        let text: String?
        /// Why there is no note, or what was odd about the one there is.
        let note: String?
        let latency: TimeInterval
    }

    /// Writes the note that goes above a meeting's transcript.
    ///
    /// Deliberately **not** `clean`. That path guards against a reply wildly different in
    /// length from what went in, because for a dictation such a reply means the model
    /// answered the transcript instead of tidying it. Here a tenth of the length is the
    /// whole point, so the same guard would reject every good answer.
    ///
    /// The whole conversation goes in one request. Grouping by topic needs the whole
    /// meeting in view, and a note stitched from batches that never saw each other would
    /// repeat itself and contradict itself. The cost is that a long meeting can exceed
    /// what a provider will take in one go — which comes back as that provider's own
    /// error, and costs the note rather than the transcript.
    func writeNote(
        from turns: [Turn],
        config: ProviderConfig?,
        prompt: PromptLibrary,
        context: PromptLibrary.Context,
        dictionary: [DictionaryEntry] = [],
        timeout: TimeInterval = CleanupService.noteTimeout
    ) async -> NoteOutcome {
        guard !turns.isEmpty else { return NoteOutcome(text: nil, note: nil, latency: 0) }
        guard let config else {
            return NoteOutcome(text: nil, note: "No cleanup provider configured.", latency: 0)
        }
        guard config.apiKey != nil else {
            return NoteOutcome(
                text: nil, note: "No API key saved — add one in Settings.", latency: 0
            )
        }

        var rendered = context
        rendered.transcript = turns
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        // The dictionary's spelling hints are what let the note write Kwartz where the
        // speech model heard "quartz". No expansion pass: a marker spliced into prose
        // nobody can position is not something to restore, and the turns below carry the
        // replacements already.
        rendered.hints = DictionaryExpander.hints(from: dictionary)

        do {
            let completion = try await client.complete(
                prompt: prompt.render(rendered), config: config, timeout: timeout
            )
            let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A model that answers with one line has not written notes; saving that above
            // the transcript would make the file look finished when it is not.
            guard text.count > 40 else {
                return NoteOutcome(
                    text: nil,
                    note: "The note came back too short to keep.",
                    latency: completion.latency
                )
            }
            return NoteOutcome(text: text, note: nil, latency: completion.latency)
        } catch {
            return NoteOutcome(text: nil, note: error.localizedDescription, latency: 0)
        }
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
