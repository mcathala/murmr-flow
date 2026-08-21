import AppKit
import Foundation
import Observation
import OSLog

/// The meeting notes folder, treated as the database.
///
/// Plain `.md` files in a visible place. The notes are the product, and you should be able
/// to open, search, sync or delete them without this app — the point of not paying a
/// subscription is not being locked into one either.
///
/// Consequences we accept on purpose: listing means reading files, renaming edits a file,
/// and a note deleted in Finder simply disappears. Reloading on demand is what keeps the
/// app honest about that.
@MainActor
@Observable
final class MeetingStore {

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "notes")

    /// Newest first.
    private(set) var notes: [NoteFile] = []

    init() {
        reload()
    }

    /// `~/Documents/Murmr Flow/Meetings`. Documents rather than Application Support,
    /// because these are the user's own notes and not our state.
    static var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
        return documents
            .appendingPathComponent("Murmr Flow", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    // MARK: - Reading

    func reload() {
        let folder = Self.folder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            notes = []
            return
        }

        notes = names
            .filter { $0.hasSuffix(".md") }
            .compactMap { NoteFile.read(folder.appendingPathComponent($0)) }
            .sorted { $0.date > $1.date }
    }

    /// The full note, front matter removed — what the reading pane shows.
    func body(of note: NoteFile) -> String {
        guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { return "" }
        return NoteFile.split(text).body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-insensitive search over titles *and* transcript text. Reading every file is
    /// the cost of the files being the truth; at personal scale it doesn't register.
    func search(_ query: String) -> [NoteFile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return notes }

        return notes.filter { note in
            if note.title.lowercased().contains(needle) { return true }
            guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { return false }
            return text.lowercased().contains(needle)
        }
    }

    // MARK: - Writing

    @discardableResult
    func save(_ transcript: MeetingTranscript) throws -> NoteFile {
        try FileManager.default.createDirectory(
            at: Self.folder, withIntermediateDirectories: true
        )

        let url = uniqueURL(for: transcript.startedAt)
        try transcript.markdown.write(to: url, atomically: true, encoding: .utf8)
        reload()

        guard let note = notes.first(where: { $0.url == url }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return note
    }

    /// Renames the note by editing its front matter, **not** its filename.
    ///
    /// The filename stays date-first so the folder sorts chronologically in Finder no
    /// matter what a note is called, and so renaming can never collide with an existing
    /// file or break a link someone made to it.
    func rename(_ note: NoteFile, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note.title else { return }

        guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { return }
        let updated = NoteFile.rewritingTitle(in: text, to: trimmed, fallbackDate: note.date)
        do {
            try updated.write(to: note.url, atomically: true, encoding: .utf8)
            reload()
        } catch {
            Self.log.error("rename failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Moves the note to the Trash rather than unlinking it, so a mis-click is recoverable
    /// by the means the user already knows.
    func delete(_ note: NoteFile) {
        do {
            try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
            reload()
        } catch {
            Self.log.error("delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Shell

    func reveal(_ note: NoteFile) {
        NSWorkspace.shared.activateFileViewerSelecting([note.url])
    }

    func open(_ note: NoteFile) {
        NSWorkspace.shared.open(note.url)
    }

    func openFolder() {
        try? FileManager.default.createDirectory(
            at: Self.folder, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(Self.folder)
    }

    // MARK: - Naming

    static func defaultTitle(for date: Date) -> String {
        "Meeting — \(titleFormatter.string(from: date))"
    }

    /// `2026-08-21 14-32 Meeting.md`. Hyphens rather than colons, because a colon is not
    /// usable in a filename.
    private func uniqueURL(for date: Date) -> URL {
        let base = Self.fileFormatter.string(from: date)
        var candidate = Self.folder.appendingPathComponent("\(base) Meeting.md")

        // Two meetings inside one minute is unlikely but not impossible, and silently
        // overwriting a note would be the worst failure available here.
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = Self.folder.appendingPathComponent("\(base) Meeting \(suffix).md")
            suffix += 1
        }
        return candidate
    }

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()
}
