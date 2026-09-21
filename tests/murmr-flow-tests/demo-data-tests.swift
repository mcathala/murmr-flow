import Foundation
import Testing

@testable import MurmrFlow

/// The demo data exists to be photographed, which means it has to be read by the same
/// code that reads real data — otherwise the screenshots show a format the app no
/// longer writes, and nobody finds out until someone downloads the app and it looks
/// nothing like the README.
///
/// `scripts/demo-data.py` reimplements `NoteFile.frontMatter`, the transcript headings
/// and the history record's JSON in Python. That duplication is the price of seeding a
/// running app from the outside; this suite is what keeps the copy honest. Change a
/// format and this goes red, which is the reminder to change the script too.
@Suite("Demo data")
struct DemoDataTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // murmr-flow-tests
        .deletingLastPathComponent()   // tests
        .deletingLastPathComponent()   // repo root

    /// Runs the generator into a scratch folder and hands back where it put things.
    private static func generate() throws -> (notes: URL, history: URL)? {
        let script = root.appendingPathComponent("scripts/demo-data.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-demo-\(UUID().uuidString)", isDirectory: true)
        let notes = scratch.appendingPathComponent("notes", isDirectory: true)
        let history = scratch.appendingPathComponent("dictations.jsonl")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["NOTES_DIR"] = notes.path
        environment["HISTORY_FILE"] = history.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (notes, history)
    }

    @MainActor
    @Test("every demo note parses, and the titles survive the front matter")
    func notesParse() throws {
        guard let (notes, _) = try Self.generate() else { return }

        let store = NoteStore(folder: notes)
        store.reload()

        #expect(store.notes.count == 6, "the generator writes six meetings")

        // A title with a colon is the case the YAML escaping exists for, and the one a
        // naive generator gets wrong. It is in the set on purpose.
        let titles = Set(store.notes.map(\.title))
        #expect(titles.contains("1:1"))
        #expect(titles.contains("Design review — onboarding"))
        #expect(!titles.contains(where: { $0.hasPrefix("\"") }), "a quote leaked into a title")

        // A note whose date fell back to the file's modification time would sort wrong
        // and show today's date on every row.
        for note in store.notes {
            #expect(note.duration > 0, "\(note.title) lost its duration")
            #expect(!note.snippet.isEmpty, "\(note.title) has no snippet to show in a row")
        }

        // Newest first is what the list shows, so the dates have to be distinct and
        // ordered rather than all landing on the same second.
        let dates = store.notes.map(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @MainActor
    @Test("every demo dictation decodes")
    func historyDecodes() throws {
        guard let (_, history) = try Self.generate() else { return }

        let store = HistoryStore(url: history)

        #expect(store.dictations.count == 12, "a row that fails to decode is skipped silently")

        for record in store.dictations {
            #expect(!record.finalText.isEmpty)
            #expect(record.targetAppName != nil, "Home draws an app icon per row")
            #expect(record.targetBundleID != nil)
            // Insights divides by this. A zero would show an infinite words-per-minute.
            #expect(record.audioDuration > 0)
            // Plausible speech, not a number that gives the game away in a screenshot.
            #expect((60...260).contains(record.wordsPerMinute), "\(record.wordsPerMinute) wpm")
        }
    }
}
