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
    /// True when cleanup did not produce anything and the raw text was inserted instead.
    let usedRawFallback: Bool
    /// Why, when it did not run.
    ///
    /// The flag above says *that* it didn't; this says whether that was the point. Four
    /// things produce the same raw text — clean-up switched off, an app you set to Off, no
    /// provider connected, a provider that failed — and two of them are the app doing what
    /// you asked. Without this the screen has to warn about all four in the same colour,
    /// which teaches you to ignore the colour.
    ///
    /// Nil on a record written before this existed, which is neither.
    let notCleaned: NotCleaned?

    enum NotCleaned: Codable, Sendable, Equatable {
        /// You asked for this: clean-up is off, or the app you were in is set to Off.
        case byChoice
        /// Something to fix, with what went wrong.
        case failed(String)

        var failure: String? {
            switch self {
            case .byChoice: nil
            case .failed(let why): why
            }
        }
    }
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
        notCleaned: NotCleaned? = nil,
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
        self.notCleaned = notCleaned
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

    /// The dictation as one line, for a list row. The whole of it: where to stop is the
    /// row's business, not this type's.
    ///
    /// It used to be cut here, at a character count — 70 on Home, 90 in the history. A
    /// count is a guess about a width, and the guess was made for the window the app
    /// opened at. Widen the window and the guess stays put: the text ended in an ellipsis
    /// with half the row empty after it, which reads as missing data rather than as a
    /// line that did not fit. `lineLimit(1)` already truncates at whatever width the row
    /// turns out to have, which is the width that actually exists.
    var singleLine: String {
        finalText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
