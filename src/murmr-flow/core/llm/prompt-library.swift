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

    /// Placeholders available in the template.
    ///
    /// None of them are the user's responsibility. `${transcript}` is required by the
    /// pipeline, so `render` appends it when a template leaves it out rather than asking
    /// the user to know that — a prompt that reads like instructions to a person should
    /// work, and a template variable is not something anyone should have to remember.
    static let placeholders = [
        "${transcript}", "${custom_words}", "${current_app}", "${language}", "${time_local}",
    ]

    /// Appended to the user's prompt when cleaning a conversation turn by turn.
    ///
    /// The line-per-turn shape is what lets the result be merged back into the transcript
    /// with each speaker and timestamp intact, and a turn the model drops fall back to
    /// its raw wording instead of vanishing. It is a requirement of the machinery, not a
    /// preference, so the app states it — the user's prompt only has to say how to tidy
    /// the words.
    static let turnContract = """
        Output format. This is required by the app and is not affected by anything above: \
        the transcript is a numbered list of turns. Reply with exactly one line per \
        numbered turn, in the same order, each in the form

        [n] Speaker: tidied text

        Keep each line's own number and speaker. Never merge, split, drop, reorder or \
        renumber turns, and never add a line of your own. A turn that needs no change is \
        repeated unchanged. No preamble, no blank lines, no explanation.
        """

    struct Context {
        var transcript: String
        var customWords: [String] = []
        var frontmostApp: String?
        var language: String?
    }

    func render(_ context: Context) -> String {
        var output = template

        let vocabulary = context.customWords.isEmpty
            ? ""
            : "Spell these correctly if you hear them: "
                + context.customWords.joined(separator: ", ")

        // A prompt written as instructions to a person, with no template syntax in it at
        // all, has to work — so anything the request cannot go without is added here
        // rather than being a rule the user was expected to have read. Without the
        // transcript the model is asked to clean nothing; without the vocabulary line the
        // custom words the user typed in Settings quietly do nothing.
        if !vocabulary.isEmpty, !output.contains("${custom_words}") {
            output += "\n\n${custom_words}"
        }
        if !output.contains("${transcript}") {
            output += "\n\nTranscript:\n${transcript}"
        }

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
