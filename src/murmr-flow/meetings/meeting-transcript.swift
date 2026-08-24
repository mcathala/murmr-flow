import Foundation

/// One person's turn in the conversation.
struct Utterance: Sendable, Identifiable, Equatable {

    enum Speaker: String, Sendable {
        case you = "You"
        case them = "Them"
    }

    let id = UUID()
    let speaker: Speaker
    /// Seconds from the start of the meeting.
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    /// `mm:ss`, or `h:mm:ss` once a meeting runs past an hour.
    var timestamp: String { MeetingTranscript.clock(start) }
}

/// A finished meeting: who said what, when.
struct MeetingTranscript: Sendable {

    let title: String
    let startedAt: Date
    let duration: TimeInterval
    let utterances: [Utterance]
    /// The prompt an LLM tidied this transcript with, or nil when nothing did. Recorded
    /// in the note's front matter so the file says which it is.
    var cleanedBy: String?

    var isEmpty: Bool { utterances.isEmpty }

    /// The same conversation with tidied wording, one text per utterance in order.
    ///
    /// A count mismatch returns the transcript untouched. Zipping shorter would silently
    /// drop the tail of a meeting, which is the one failure a note must not have.
    func applying(texts: [String], cleanedBy prompt: String) -> MeetingTranscript {
        guard texts.count == utterances.count else { return self }

        let rewritten = zip(utterances, texts).map { utterance, text in
            Utterance(
                speaker: utterance.speaker,
                start: utterance.start,
                end: utterance.end,
                text: text.isEmpty ? utterance.text : text
            )
        }
        return MeetingTranscript(
            title: title,
            startedAt: startedAt,
            duration: duration,
            utterances: rewritten,
            cleanedBy: prompt
        )
    }

    /// Weaves two independently transcribed streams into one conversation, ordered by
    /// when each phrase was actually said.
    ///
    /// Both streams began within milliseconds of each other and share the same clock, so
    /// sorting by start time is enough — no alignment pass, no drift correction.
    ///
    /// Where the two overlap almost exactly, the microphone copy is dropped. That is
    /// acoustic bleed: on speakers the microphone hears the other party too, and without
    /// this the same sentence appears twice, once under each label.
    static func weave(
        you: [TranscriptionService.Segment],
        them: [TranscriptionService.Segment],
        startedAt: Date,
        duration: TimeInterval,
        title: String
    ) -> MeetingTranscript {
        let theirs = them.map {
            Utterance(speaker: .them, start: $0.start, end: $0.end, text: $0.text)
        }
        let mine = you
            .filter { segment in !isEcho(segment, of: them) }
            .map { Utterance(speaker: .you, start: $0.start, end: $0.end, text: $0.text) }

        let merged = (theirs + mine).sorted { left, right in
            // Ties broken in favour of the other party: if both start at the same instant
            // it is almost always them being interrupted, not the reverse.
            if left.start == right.start { return left.speaker == .them }
            return left.start < right.start
        }

        return MeetingTranscript(
            title: title,
            startedAt: startedAt,
            duration: duration,
            utterances: merged
        )
    }

    /// True when a microphone segment looks like the speakers playing the other party.
    ///
    /// Requires both a time overlap and near-identical text. Overlap alone is not enough:
    /// people genuinely talk over each other, and that is worth keeping.
    private static func isEcho(
        _ segment: TranscriptionService.Segment,
        of others: [TranscriptionService.Segment]
    ) -> Bool {
        let mine = normalised(segment.text)
        guard mine.count > 8 else { return false }  // too short to judge

        return others.contains { other in
            let overlaps = segment.start < other.end && other.start < segment.end
            guard overlaps else { return false }
            let theirs = normalised(other.text)
            return theirs.contains(mine) || mine.contains(theirs)
        }
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Rendering

    /// The saved note. Markdown because it opens in anything and stays readable as plain
    /// text, which matters for something the user owns rather than something we host.
    var markdown: String {
        var lines: [String] = []
        // Front matter first: it is what lets the app read this file back as a note
        // rather than keeping a second copy of the truth in a database.
        lines.append(
            NoteFile.frontMatter(
                title: title, date: startedAt, duration: duration, cleanup: cleanedBy
            )
        )
        lines.append("")
        lines.append("# \(title)")
        lines.append("")

        if utterances.isEmpty {
            lines.append("_Nothing was transcribed. Check that the meeting audio was "
                + "playing through this Mac and that the microphone was not muted._")
        } else {
            for utterance in utterances {
                lines.append("**\(utterance.speaker.rawValue)** · `\(utterance.timestamp)`")
                lines.append("")
                lines.append(utterance.text)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Speaker-prefixed plain text, for pasting somewhere that is not a Markdown editor.
    var plainText: String {
        utterances
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - Formatting

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}
