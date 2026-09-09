import Foundation
import Testing

@testable import MurmrFlow

/// Writing, renaming and finding notes, against a scratch folder. The notes folder is the
/// database, so these are the database tests.
///
/// Deleting is not exercised: it moves files to the Trash, and a test that fills the
/// developer's Trash on every run is its own kind of bug.
@MainActor
@Suite("Note store")
struct NoteStoreTests {

    private func transcript(at date: Date, saying text: String) -> MeetingTranscript {
        MeetingTranscript(
            title: NoteStore.defaultTitle(for: date),
            startedAt: date,
            duration: 90,
            utterances: [Utterance(speaker: .you, start: 0, end: 2, text: text)]
        )
    }

    @Test("two meetings in one minute get two files, not one overwritten")
    func uniqueNames() throws {
        let folder = Scratch.folder("notes")
        let store = NoteStore(folder: folder)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try store.save(transcript(at: date, saying: "first"))
        let second = try store.save(transcript(at: date.addingTimeInterval(20), saying: "second"))

        #expect(first.url != second.url)
        #expect(first.url.lastPathComponent.hasSuffix(" Meeting.md"))
        #expect(second.url.lastPathComponent.hasSuffix(" Meeting 2.md"))
        #expect(store.notes.count == 2)
        #expect(store.body(of: first).contains("first"))
        #expect(store.body(of: second).contains("second"))
    }

    @Test("renaming edits the title and leaves the filename alone")
    func rename() throws {
        let store = NoteStore(folder: Scratch.folder("rename"))
        let note = try store.save(transcript(at: Date(), saying: "hello"))
        let url = note.url

        store.rename(note, to: "Kick-off with Sam")

        let renamed = store.notes.first { $0.url == url }
        #expect(renamed?.title == "Kick-off with Sam")
        #expect(store.notes.count == 1)
        // Blank and unchanged titles are ignored, so a stray Save cannot wipe a name.
        store.rename(renamed!, to: "   ")
        #expect(store.notes.first?.title == "Kick-off with Sam")
    }

    @Test("search reads titles and bodies, and ignores case")
    func search() throws {
        let store = NoteStore(folder: Scratch.folder("search"))
        let budget = try store.save(transcript(at: Date(), saying: "we agreed the Q4 budget"))
        store.rename(budget, to: "Finance sync")
        try store.save(transcript(at: Date().addingTimeInterval(-3600), saying: "hiring plan"))

        #expect(store.search("").count == 2)
        #expect(store.search("finance").map(\.url) == [budget.url])
        #expect(store.search("Q4 BUDGET").map(\.url) == [budget.url])
        #expect(store.search("nothing here").isEmpty)
    }

    @Test("reload sees files added and removed outside the app")
    func reload() throws {
        let folder = Scratch.folder("reload")
        let store = NoteStore(folder: folder)
        #expect(store.notes.isEmpty)

        let other = try NoteStore(folder: folder).save(transcript(at: Date(), saying: "elsewhere"))
        store.reload()
        #expect(store.notes.map(\.url) == [other.url])

        try FileManager.default.removeItem(at: other.url)
        store.reload()
        #expect(store.notes.isEmpty)
    }

    @Test("a folder that cannot be created makes save throw rather than lose the note quietly")
    func unwritableFolder() throws {
        let parent = Scratch.folder("unwritable")
        let blocker = parent.appendingPathComponent("file")
        try Data().write(to: blocker)
        // A "folder" whose parent is a plain file cannot be created.
        let store = NoteStore(folder: blocker.appendingPathComponent("notes", isDirectory: true))

        #expect(throws: (any Error).self) {
            try store.save(transcript(at: Date(), saying: "lost?"))
        }
    }
}
