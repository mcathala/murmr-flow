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
struct NoteFile: Identifiable, Sendable, Equatable {

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
    static func frontMatter(title: String, date: Date, duration: TimeInterval) -> String {
        """
        \(fence)
        title: \(escape(title))
        date: \(iso.string(from: date))
        duration: \(Int(duration.rounded()))
        \(fence)
        """
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

        // The visible heading is regenerated too, so the file doesn't end up claiming two
        // different titles in two places.
        let stripped = body
            .components(separatedBy: "\n")
            .drop { $0.hasPrefix("# ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")

        return """
            \(frontMatter(title: title, date: date, duration: duration))

            # \(title)

            \(stripped)
            """
    }

    // MARK: - Helpers

    private static func snippet(from body: String) -> String {
        let interesting = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                // Skip headings, speaker labels and the italic empty-note placeholder.
                if line.hasPrefix("#") || line.hasPrefix("**") || line.hasPrefix("_") {
                    return false
                }
                return true
            }
        let joined = interesting.prefix(2).joined(separator: " ")
        guard joined.count > 100 else { return joined }
        return String(joined.prefix(100)).trimmingCharacters(in: .whitespaces) + "…"
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
