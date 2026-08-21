import Foundation
import Testing

@testable import MurmrFlow

@Suite("Note files")
struct NoteFileTests {

    private func write(_ contents: String, name: String = "note.md") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("front matter round-trips")
    func roundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_775_000_000)
        let header = NoteFile.frontMatter(title: "Standup", date: date, duration: 754)
        let url = try write("\(header)\n\n# Standup\n\nSomeone said something.\n")

        let note = try #require(NoteFile.read(url))
        #expect(note.title == "Standup")
        #expect(note.duration == 754)
        // Seconds granularity is all the header stores.
        #expect(abs(note.date.timeIntervalSince(date)) < 1)
    }

    @Test("a colon in the title survives")
    func quotedTitle() throws {
        let header = NoteFile.frontMatter(
            title: "Pricing: round two", date: Date(), duration: 60
        )
        let url = try write("\(header)\n\n# Pricing: round two\n\nHello.\n")

        let note = try #require(NoteFile.read(url))
        #expect(note.title == "Pricing: round two")
    }

    @Test("a hand-written file with no front matter still lists")
    func noFrontMatter() throws {
        let url = try write("# Just notes\n\nI typed this myself.\n", name: "mine.md")

        let note = try #require(NoteFile.read(url))
        // Falls back to the filename rather than being skipped — someone dropping a
        // markdown file into the folder should see it.
        #expect(note.title == "mine")
        #expect(note.duration == 0)
    }

    @Test("renaming rewrites the header and the heading, keeping the body")
    func rename() throws {
        let date = Date(timeIntervalSince1970: 1_775_000_000)
        let header = NoteFile.frontMatter(title: "Old", date: date, duration: 42)
        let original = "\(header)\n\n# Old\n\n**Them** · `0:02`\n\nThe body.\n"

        let updated = NoteFile.rewritingTitle(in: original, to: "New", fallbackDate: date)

        #expect(updated.contains("title: New"))
        #expect(updated.contains("# New"))
        #expect(!updated.contains("# Old"))
        #expect(updated.contains("The body."))
        // Duration must survive a rename — it is not something the user retyped.
        #expect(updated.contains("duration: 42"))
    }

    @Test("splitting a file with no header returns everything as body")
    func splitPassthrough() {
        let (fields, body) = NoteFile.split("# Hello\n\nWorld")
        #expect(fields.isEmpty)
        #expect(body == "# Hello\n\nWorld")
    }
}

/// Bulk deletion, because doing it one at a time was the complaint.
@MainActor
@Suite("Bulk delete")
struct BulkDeleteTests {

    private func store() -> HistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-bulk-\(UUID().uuidString)")
            .appendingPathComponent("dictations.jsonl")
        return HistoryStore(url: url)
    }

    private func record(_ text: String) -> DictationRecord {
        DictationRecord(audioDuration: 3, rawText: text, finalText: text)
    }

    @Test("a batch goes in one operation")
    func batch() {
        let history = store()
        let all = (1...5).map { record("dictation \($0)") }
        all.forEach { history.add($0) }
        #expect(history.dictations.count == 5)

        history.delete(ids: Set(all.prefix(3).map(\.id)))
        #expect(history.dictations.count == 2)
    }

    @Test("deleting a batch survives a reload")
    func batchPersists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-bulk-\(UUID().uuidString)")
            .appendingPathComponent("dictations.jsonl")

        let first = HistoryStore(url: url)
        let all = (1...4).map { record("row \($0)") }
        all.forEach { first.add($0) }
        first.delete(ids: Set(all.prefix(2).map(\.id)))

        // The point of a rewrite rather than an in-memory removal: it has to be gone from
        // the file too, or it comes back on the next launch.
        let reopened = HistoryStore(url: url)
        #expect(reopened.dictations.count == 2)
    }

    @Test("an empty batch changes nothing")
    func emptyBatch() {
        let history = store()
        history.add(record("kept"))
        history.delete(ids: [])
        #expect(history.dictations.count == 1)
    }

    @Test("delete all empties the file")
    func deleteAll() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-bulk-\(UUID().uuidString)")
            .appendingPathComponent("dictations.jsonl")

        let first = HistoryStore(url: url)
        (1...3).forEach { first.add(record("row \($0)")) }
        first.deleteAll()

        #expect(HistoryStore(url: url).dictations.isEmpty)
    }
}
