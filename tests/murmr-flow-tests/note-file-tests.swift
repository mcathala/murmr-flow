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
