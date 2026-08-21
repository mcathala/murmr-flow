import Foundation

/// One finished dictation, as it goes on the record.
///
/// Both the raw transcript and the final text are kept. Until now the raw one was thrown
/// away the moment cleanup finished, which meant there was no way to see whether the
/// model had improved your words or mangled them — and no way to re-run cleanup after
/// changing a prompt without saying the whole thing again.
struct DictationRecord: Codable, Identifiable, Sendable, Equatable {

    let id: UUID
    let date: Date
    /// Length of what you said, not how long the machine took.
    let audioDuration: TimeInterval
    /// Straight from the speech model, before any tidying.
    let rawText: String
    /// What was actually inserted.
    let finalText: String
    /// True when cleanup failed and the raw text was inserted instead.
    let usedRawFallback: Bool
    /// Which prompt was in force, so a re-run can start from the same place.
    let promptName: String?
    /// Where the text landed. Name for display, bundle id for the icon.
    let targetAppName: String?
    let targetBundleID: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        audioDuration: TimeInterval,
        rawText: String,
        finalText: String,
        usedRawFallback: Bool = false,
        promptName: String? = nil,
        targetAppName: String? = nil,
        targetBundleID: String? = nil
    ) {
        self.id = id
        self.date = date
        self.audioDuration = audioDuration
        self.rawText = rawText
        self.finalText = finalText
        self.usedRawFallback = usedRawFallback
        self.promptName = promptName
        self.targetAppName = targetAppName
        self.targetBundleID = targetBundleID
    }

    // MARK: - Derived

    var wordCount: Int { Self.words(in: finalText) }

    /// How fast you actually speak. Real arithmetic on two numbers we already have —
    /// unlike "time saved", which needs an assumption about typing.
    var wordsPerMinute: Double {
        guard audioDuration > 0 else { return 0 }
        return Double(wordCount) / (audioDuration / 60)
    }

    /// A single line for a list row. Long dictations get an ellipsis rather than a wrap.
    func summary(limit: Int = 80) -> String {
        let text = finalText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
