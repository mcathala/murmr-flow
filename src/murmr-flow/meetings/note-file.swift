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
        let spoken = turns(in: body).first?.text
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
