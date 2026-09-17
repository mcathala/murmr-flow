import Foundation

/// A meeting note as it exists on disk.
///
/// **The file is the source of truth, not a database.** Edit a note in any editor and the
/// app re-reads it; delete one in Finder and it's gone. That costs us cheap search and
/// instant renames, and buys the thing that made us stop paying for a hosted notes app in
/// the first place — the notes outlive the tool.
///
/// The machine-readable part lives in YAML front matter, which is the convention every
/// Markdown editor already understands, so making the file parseable also made it more
/// portable rather than less.
struct NoteFile: Identifiable, Sendable, Hashable {

    let url: URL
    let title: String
    let date: Date
    let duration: TimeInterval
    /// First line or two of the transcript, for a list row.
    let snippet: String

    var id: URL { url }

    // MARK: - Front matter

    static let fence = "---"

    /// Builds the header that makes a note re-readable.
    ///
    /// `cleanup` names the prompt an LLM tidied this note with, and is omitted when
    /// nothing did. Recorded because a reader six months later should be able to tell
    /// whether they are looking at what was said or at a machine's version of it.
    static func frontMatter(
        title: String, date: Date, duration: TimeInterval, cleanup: String? = nil,
        note: String? = nil
    ) -> String {
        var lines = [
            fence,
            "title: \(escape(title))",
            "date: \(iso.string(from: date))",
            "duration: \(Int(duration.rounded()))",
        ]
        if let cleanup, !cleanup.isEmpty {
            lines.append("cleanup: \(escape(cleanup))")
        }
        if let note, !note.isEmpty {
            lines.append("note: \(escape(note))")
        }
        lines.append(fence)
        return lines.joined(separator: "\n")
    }

    /// Parses a note. Returns nil only if the file can't be read at all.
    ///
    /// A file with no front matter still parses — the filename and modification date
    /// stand in. Someone dropping a hand-written Markdown file into the folder should see
    /// it in the list, not have it silently ignored.
    static func read(_ url: URL, prefixBytes: Int? = 4096) -> NoteFile? {
        guard let full = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let text = prefixBytes.map { String(full.prefix($0)) } ?? full

        let (fields, body) = split(text)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date) ?? Date()

        let title = fields["title"]?.trimmingCharacters(in: .whitespaces)
        let date = fields["date"].flatMap { iso.date(from: $0) }
        let duration = fields["duration"].flatMap { TimeInterval($0) }

        return NoteFile(
            url: url,
            title: title?.isEmpty == false
                ? title!
                : url.deletingPathExtension().lastPathComponent,
            date: date ?? modified,
            duration: duration ?? 0,
            snippet: snippet(from: body)
        )
    }

    /// Separates front matter from the rest. Returns the whole text as body when there
    /// is no front matter.
    static func split(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == fence else {
            return ([:], text)
        }

        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == fence {
                index += 1
                break
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                fields[key] = unescape(value)
            }
            index += 1
        }

        let body = lines[index...].joined(separator: "\n")
        return (fields, body)
    }

    /// Rewrites just the title, leaving the transcript untouched.
    static func rewritingTitle(in text: String, to title: String, fallbackDate: Date) -> String {
        let (fields, body) = split(text)
        let date = fields["date"].flatMap { iso.date(from: $0) } ?? fallbackDate
        let duration = fields["duration"].flatMap { TimeInterval($0) } ?? 0
        // Carried across rather than regenerated: renaming a note says nothing about
        // whether it was cleaned up, and dropping the field would quietly claim it wasn't.
        let cleanup = fields["cleanup"]
        let note = fields["note"]

        // The visible heading is regenerated too, so the file doesn't end up claiming two
        // different titles in two places.
        let stripped = body
            .components(separatedBy: "\n")
            .drop { $0.hasPrefix("# ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")

        return """
            \(frontMatter(
                title: title, date: date, duration: duration, cleanup: cleanup, note: note
            ))

            # \(title)

            \(stripped)
            """
    }

    // MARK: - Reading a note back

    /// One person's turn, parsed back out of the file.
    struct Turn: Identifiable, Sendable, Equatable {
        let id = UUID()
        let speaker: String
        let time: String
        let text: String

        var isYou: Bool { speaker.caseInsensitiveCompare("You") == .orderedSame }
    }

    /// The heading the transcript starts under, and the boundary between the two halves
    /// of a note file.
    static let transcriptHeading = "## Transcript"

    /// Where what the person typed during the meeting is kept, whole.
    static let ownNotesHeading = "## My notes"

    /// The headings that end the written note. Either can be absent — a meeting nobody
    /// typed in has no My notes, and one that was never transcribed has no Transcript.
    static let sectionHeadings = [ownNotesHeading, transcriptHeading]

    /// Where a section of the file begins, by heading, or nil when it is not there.
    private static func index(of heading: String, in lines: [String]) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == heading }
    }

    /// The first heading that ends the written note, whichever comes first.
    private static func summaryEnd(in lines: [String]) -> Int? {
        sectionHeadings.compactMap { index(of: $0, in: lines) }.min()
    }

    /// What the person typed while the meeting ran, exactly as they typed it.
    static func ownNotes(in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = index(of: ownNotesHeading, in: lines) else { return nil }
        let end = index(of: transcriptHeading, in: lines) ?? lines.count
        guard start + 1 < end else { return nil }
        let text = lines[(start + 1)..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// One line of the written note, already told apart so a view can lay it out rather
    /// than print the markup.
    enum SummaryLine: Identifiable, Sendable, Equatable {
        case heading(String)
        case bullet(String)
        /// `index` is the task's position among the note's tasks, which is how the file
        /// counts them when one is ticked. Carried on the line rather than counted again
        /// by the view: a view that counts while it draws gets a different answer every
        /// time SwiftUI decides to draw it.
        case task(done: Bool, index: Int, String)
        case paragraph(String)

        var id: String {
            switch self {
            case .heading(let text): "h:\(text)"
            case .bullet(let text): "b:\(text)"
            case .task(let done, let index, let text): "t:\(done):\(index):\(text)"
            case .paragraph(let text): "p:\(text)"
            }
        }
    }

    /// The written note above the transcript, as lines to lay out.
    ///
    /// **Gated on the transcript heading being there.** Without it every older note — and
    /// every file somebody wrote by hand — would have its first paragraphs read as a note,
    /// which is a claim the file never made. No heading, no note.
    static func summary(in body: String) -> [SummaryLine] {
        let lines = body.components(separatedBy: "\n")
        guard let end = summaryEnd(in: lines) else { return [] }

        var out: [SummaryLine] = []
        var tasks = 0
        for raw in lines[0..<end] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // The file's own title. The pane draws it in its header already.
            if line.hasPrefix("# ") { continue }
            if line.hasPrefix("#") {
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                let done = line.hasPrefix("- [x] ")
                out.append(.task(done: done, index: tasks, String(line.dropFirst(6))))
                tasks += 1
            } else if line.hasPrefix("- ") || line.hasPrefix("• ") {
                out.append(.bullet(String(line.dropFirst(2))))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    /// The note's own Markdown, exactly as it sits in the file, for editing.
    ///
    /// `summary(in:)` returns lines already taken apart for a view to lay out; this is the
    /// text itself, which is what an editor has to hand back unchanged if the person
    /// touches nothing.
    static func summaryMarkdown(in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let end = summaryEnd(in: lines) else { return nil }

        let start = lines.prefix(end).firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("# ")
        }
        guard let start else { return "" }
        return lines[start..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts an edited note back into the file, leaving the front matter, the title and
    /// every word of the transcript exactly where they were.
    ///
    /// **The transcript is not editable and this is where that is enforced.** It is the
    /// record of what was said; the note above it is what someone made of it, and only the
    /// second is anyone's to revise. Rewriting the whole file from parsed pieces would put
    /// the first at risk of a parsing bug.
    static func replacingSummary(in text: String, with markdown: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var boundary = summaryEnd(in: lines)
        if boundary == nil, let firstTurn = lines.firstIndex(where: { isTurnLine($0) }) {
            // A note written before the app knew how to write one has no headings at all,
            // and its body *is* the transcript. Marking where that starts is what lets a
            // note be written for it afterwards, and it changes not a word of what is
            // already there.
            lines.insert(contentsOf: [transcriptHeading, ""], at: firstTurn)
            boundary = firstTurn
        }
        guard let end = boundary else { return text }

        // Everything up to and including the title line stays: front matter, blank lines,
        // and the `# Heading` the file repeats for portability.
        var head = 0
        var afterTitle = 0
        var fences = 0
        while head < end {
            let trimmed = lines[head].trimmingCharacters(in: .whitespaces)
            if trimmed == fence, fences < 2 {
                fences += 1
                afterTitle = head + 1
            } else if trimmed.hasPrefix("# ") {
                afterTitle = head + 1
                break
            } else if !trimmed.isEmpty, fences == 2 {
                break
            }
            head += 1
        }

        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = lines[0..<afterTitle].joined(separator: "\n")
        let rest = lines[end...].joined(separator: "\n")
        return body.isEmpty
            ? "\(kept)\n\n\(rest)"
            : "\(kept)\n\n\(body)\n\n\(rest)"
    }

    /// Puts edited own-notes back, leaving the written note and the transcript alone.
    ///
    /// The section is created when it is not there yet, because someone who writes their
    /// own notes into a meeting they forgot to type in during should not have to go and
    /// make a heading by hand.
    static func replacingOwnNotes(in text: String, with markdown: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = index(of: ownNotesHeading, in: lines) {
            let end = index(of: transcriptHeading, in: lines) ?? lines.count
            let head = lines[0..<start].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = end < lines.count
                ? lines[end...].joined(separator: "\n")
                : ""
            let section = body.isEmpty ? "" : "\(ownNotesHeading)\n\n\(body)\n\n"
            return rest.isEmpty ? "\(head)\n\n\(section)" : "\(head)\n\n\(section)\(rest)"
        }

        guard !body.isEmpty else { return text }
        // No section yet: it goes immediately above the transcript, which is where one
        // written during the meeting would have been.
        guard let end = index(of: transcriptHeading, in: lines) else {
            return "\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
                + "\(ownNotesHeading)\n\n\(body)\n"
        }
        let head = lines[0..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = lines[end...].joined(separator: "\n")
        return "\(head)\n\n\(ownNotesHeading)\n\n\(body)\n\n\(rest)"
    }

    /// Ticks or unticks the `n`th task in the note, counting from the top.
    ///
    /// By position rather than by text, because two tasks can legitimately read the same
    /// and matching on words would tick the wrong one. Only lines inside the note are
    /// counted: a `- [ ]` somebody said out loud and that ended up in the transcript is
    /// not a task, it is a quotation.
    static func togglingTask(in text: String, at index: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        let end = summaryEnd(in: lines) ?? lines.count

        var seen = 0
        for position in 0..<end {
            let line = lines[position]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") else { continue }
            if seen == index {
                let done = trimmed.hasPrefix("- [x] ")
                lines[position] = line.replacingOccurrences(
                    of: done ? "- [x] " : "- [ ] ",
                    with: done ? "- [ ] " : "- [x] "
                )
                return lines.joined(separator: "\n")
            }
            seen += 1
        }
        return text
    }

    /// Whether a line opens a turn: `**You** · `0:00``.
    static func isTurnLine(_ line: String) -> Bool {
        guard let pattern = try? Regex(#"^\*\*(.+?)\*\*\s+·\s+`(.+?)`\s*$"#) else { return false }
        return (try? pattern.wholeMatch(in: line.trimmingCharacters(in: .whitespaces))) != nil
    }

    /// Splits a note body into turns.
    ///
    /// The reading pane used to render the body as one block of raw text, so it showed
    /// `**Them** · \`0:00\`` literally — markup on the screen, in the one place the app is
    /// supposed to be *reading* to you.
    ///
    /// Returns an empty array for anything that has no speaker lines at all, which is the
    /// signal to fall back to plain paragraphs. Files are the source of truth, so a note
    /// somebody wrote by hand has to display too.
    static func turns(in body: String) -> [Turn] {
        guard let pattern = try? Regex(#"^\*\*(.+?)\*\*\s+·\s+`(.+?)`\s*$"#) else {
            return []
        }

        var turns: [Turn] = []
        var speaker: String?
        var time: String?
        var said: [String] = []

        func flush() {
            defer { said.removeAll() }
            guard let speaker, let time else { return }
            let text = said.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            turns.append(Turn(speaker: speaker, time: time, text: text))
        }

        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = try? pattern.wholeMatch(in: line) {
                flush()
                speaker = String(match.output[1].substring ?? "")
                time = String(match.output[2].substring ?? "")
                continue
            }
            // The heading and the date line are already shown by the pane's own header, so
            // they are skipped rather than repeated — the file keeps them for portability.
            if line.hasPrefix("#") || line.isEmpty { continue }
            if speaker != nil { said.append(line) }
        }
        flush()

        return turns
    }

    // MARK: - Helpers

    /// The first thing somebody actually said.
    ///
    /// Taking "the first line that isn't markup" instead put the note's own date line into
    /// every row — so each row showed its date twice, once formatted by the app and once
    /// copied out of the file.
    private static func snippet(from body: String) -> String {
        // The note's first line when there is one: a row saying what the meeting was
        // about beats one saying "right, can you hear me".
        let written = summary(in: body).compactMap { line -> String? in
            switch line {
            case .bullet(let text), .paragraph(let text): text
            case .heading, .task: nil
            }
        }.first

        let spoken = written
            ?? turns(in: body).first?.text
            ?? body.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("_") }
            ?? ""

        guard spoken.count > 100 else { return spoken }
        return String(spoken.prefix(100)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A colon or a leading quote would break the `key: value` shape, so quote when needed.
    private static func escape(_ value: String) -> String {
        let needsQuotes = value.contains(":") || value.hasPrefix("\"") || value.hasPrefix("'")
        guard needsQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func unescape(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Built per use rather than cached. `ISO8601DateFormatter` is not `Sendable`, and a
    /// shared instance would be a data race for the sake of microseconds.
    private static var iso: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
