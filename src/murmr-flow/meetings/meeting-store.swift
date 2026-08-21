import Foundation

/// Where meeting notes live on disk.
///
/// Plain `.md` files in a visible folder, not a database. The notes are the product, and
/// the user should be able to open, search, sync, or delete them without this app — the
/// whole point of not paying a subscription is not being locked in to one either.
enum MeetingStore {

    /// `~/Documents/Murmr Flow/Meetings`. Documents rather than Application Support
    /// because these are the user's own notes, not our state.
    static var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
        return documents
            .appendingPathComponent("Murmr Flow", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    /// Writes the note and returns where it landed.
    static func save(_ transcript: MeetingTranscript) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = uniqueURL(for: transcript.startedAt)
        try transcript.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A default title from the date, since v1 has nothing better to name a meeting after.
    static func defaultTitle(for date: Date) -> String {
        "Meeting — \(titleFormatter.string(from: date))"
    }

    // MARK: - Naming

    /// `2026-08-21 14-32 Meeting.md`. Date first so the folder sorts chronologically, and
    /// hyphens instead of colons because a colon is not usable in a filename.
    private static func uniqueURL(for date: Date) -> URL {
        let base = fileFormatter.string(from: date)
        var candidate = folder.appendingPathComponent("\(base) Meeting.md")

        // Two meetings in the same minute is unlikely but not impossible, and silently
        // overwriting a note would be the worst possible failure here.
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) Meeting \(suffix).md")
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
