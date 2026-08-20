import AppKit
import Foundation

/// The cleanup prompt and its placeholders.
///
/// Stored separately from provider configuration on purpose — switching provider must
/// never lose the user's prompt.
struct PromptLibrary {

    static let defaultsKey = "cleanupPrompt"

    /// Deliberately narrow instructions. The job is punctuation, capitalization and
    /// filler removal — not rewriting. A model given licence to "improve" the text will
    /// quietly change the user's meaning.
    static let defaultCleanupPrompt = """
        You clean up dictated speech. Rewrite the transcript below applying only these \
        changes:

        - Fix punctuation and capitalization.
        - Remove filler words (um, uh, like, you know) and false starts.
        - Break into paragraphs where the speaker clearly changed topic.

        Do not rephrase, summarize, translate, answer questions, or add anything. Keep \
        the speaker's own words and meaning. If the transcript is already clean, return \
        it unchanged.

        Reply with the cleaned text only — no preamble, no quotes, no explanation.

        ${custom_words}

        Transcript:
        ${transcript}
        """

    var template: String

    init(template: String = PromptLibrary.defaultCleanupPrompt) {
        self.template = template
    }

    /// Placeholders available in the template. `${transcript}` is the only required one.
    static let placeholders = [
        "${transcript}", "${custom_words}", "${current_app}", "${language}", "${time_local}",
    ]

    struct Context {
        var transcript: String
        var customWords: [String] = []
        var frontmostApp: String?
        var language: String?
    }

    func render(_ context: Context) -> String {
        var output = template

        // If the template has no ${transcript}, the transcript would silently vanish
        // and the model would be asked to clean nothing. Append instead of losing it.
        if !output.contains("${transcript}") {
            output += "\n\nTranscript:\n${transcript}"
        }

        let vocabulary = context.customWords.isEmpty
            ? ""
            : "Spell these correctly if you hear them: "
                + context.customWords.joined(separator: ", ")

        let replacements: [String: String] = [
            "${transcript}": context.transcript,
            "${custom_words}": vocabulary,
            "${current_app}": context.frontmostApp ?? "",
            "${language}": context.language ?? "",
            "${time_local}": Self.timestampFormatter.string(from: Date()),
        ]

        for (token, value) in replacements {
            output = output.replacingOccurrences(of: token, with: value)
        }
        // Placeholders that resolved to nothing leave blank lines behind; collapse them
        // so an empty vocabulary list doesn't pad the prompt with whitespace.
        return output.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
