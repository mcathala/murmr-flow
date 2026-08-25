import Foundation

/// Swaps spoken triggers for their replacements, and keeps them safe while clean-up runs.
///
/// **The ordering problem.** Substituting *before* clean-up sends your email address to a
/// provider that may reformat it. Substituting *after* means the trigger phrase has to
/// survive clean-up intact, and a prompt like "Formal" will happily reword it. So neither
/// end works, and the answer is to do it before with a **marker**: the model sees
/// `send it to [[MF0]]`, the value is spliced back in afterwards, and it never has the
/// chance to touch what it cannot see.
///
/// If a marker does not come back, `restore` returns nil rather than dropping the value.
/// The caller then uses `resolved` — the raw transcript with the replacements already in
/// it — which is worse than cleaned text and enormously better than losing the address.
///
/// Matching is **leftmost-longest over normalised word tokens**, so `my email address`
/// wins over `my email`, and "My email address," matches with its capital and its comma.
/// Tokens are compared lowercased with punctuation dropped, because that is the difference
/// between what you said and what a speech model wrote down.
enum DictionaryExpander {

    /// Bracketed and short, so a model treats it as opaque rather than as prose to tidy.
    static func marker(_ index: Int) -> String { "[[MF\(index)]]" }

    struct Expansion: Sendable {
        /// The text with each match swapped for its marker.
        var text: String
        /// Each marker and what it stands for, in the order they were found.
        var markers: [Marker]

        struct Marker: Sendable {
            let token: String
            let value: String
        }

        var isEmpty: Bool { markers.isEmpty }

        /// The text with every marker already resolved — what to use when clean-up is not
        /// going to run, or when it dropped one.
        var resolved: String {
            markers.reduce(text) {
                $0.replacingOccurrences(of: $1.token, with: $1.value)
            }
        }

        /// Puts the values back into cleaned text, or nil if the model lost a marker.
        func restore(into cleaned: String) -> String? {
            var output = cleaned
            for marker in markers {
                guard output.contains(marker.token) else { return nil }
                output = output.replacingOccurrences(of: marker.token, with: marker.value)
            }
            return output
        }
    }

    /// Replaces every `swap` entry found in `text`. A `spelling` entry is ignored here —
    /// it is a hint for the prompt, not something to match on.
    static func expand(_ text: String, using entries: [DictionaryEntry]) -> Expansion {
        let candidates = entries
            .filter { $0.kind == .swap && $0.isUsable }
            .map { (tokens: normalisedTokens(of: $0.trigger), value: $0.replacement) }
            .filter { !$0.tokens.isEmpty }
            // Longest first, so a longer trigger is never shadowed by a shorter one that
            // happens to be its opening words.
            .sorted { $0.tokens.count > $1.tokens.count }

        guard !candidates.isEmpty else { return Expansion(text: text, markers: []) }

        let spoken = tokens(of: text)
        guard !spoken.isEmpty else { return Expansion(text: text, markers: []) }

        var matches: [(range: Range<String.Index>, value: String)] = []
        var index = 0
        while index < spoken.count {
            var matched = false
            for candidate in candidates {
                let end = index + candidate.tokens.count
                guard end <= spoken.count else { continue }
                let slice = spoken[index..<end].map(\.normalised)
                guard slice == candidate.tokens else { continue }

                matches.append(
                    (
                        range: spoken[index].range.lowerBound..<spoken[end - 1].range.upperBound,
                        value: candidate.value
                    )
                )
                index = end
                matched = true
                break
            }
            if !matched { index += 1 }
        }

        guard !matches.isEmpty else { return Expansion(text: text, markers: []) }

        var output = ""
        var markers: [Expansion.Marker] = []
        var cursor = text.startIndex
        for (position, match) in matches.enumerated() {
            output += text[cursor..<match.range.lowerBound]
            let token = marker(position)
            output += token
            markers.append(Expansion.Marker(token: token, value: match.value))
            cursor = match.range.upperBound
        }
        output += text[cursor...]

        return Expansion(text: output, markers: markers)
    }

    /// The words a prompt is told to spell a particular way.
    static func hints(from entries: [DictionaryEntry]) -> [String] {
        entries
            .filter { $0.kind == .spelling && $0.isUsable }
            .map(\.replacement)
    }

    // MARK: - Tokens

    private struct Token {
        let range: Range<String.Index>
        let normalised: String
    }

    /// Words, with where each one sits in the original — the ranges are what makes it
    /// possible to splice a replacement back into text that still has its own punctuation
    /// and capitals.
    private static func tokens(of text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, !isWordCharacter(text[index]) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            let start = index
            while index < text.endIndex, isWordCharacter(text[index]) || isApostrophe(text[index]) {
                index = text.index(after: index)
            }
            // A trailing apostrophe belongs to the punctuation, not to the word.
            var end = index
            while end > start, isApostrophe(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            guard end > start else { continue }

            result.append(Token(range: start..<end, normalised: normalise(text[start..<end])))
        }
        return result
    }

    private static func normalisedTokens(of text: String) -> [String] {
        tokens(of: text).map(\.normalised)
    }

    private static func normalise(_ slice: Substring) -> String {
        // The curly apostrophe a speech model writes and the straight one you type are the
        // same word.
        slice.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}"
    }
}
