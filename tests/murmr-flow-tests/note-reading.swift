import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MurmrFlow

/// The reading pane showed `**Them** · `0:00`` on screen, and every row showed its date
/// twice. Both were the same root cause: the note body was treated as opaque text when it
/// has a structure the app itself wrote.
@Suite("Reading a note back")
struct NoteReadingTests {

    /// A real file, copied verbatim from ~/Documents/Murmr Flow/Meetings.
    private static let real = """
        # Meeting — 22 August 2026 at 11:14

        **Them** · `0:00`

        Sur l'extérieur, sur la touche. Tamarc, la prise initiale.

        **You** · `0:04`

        Yes, exactly that.
        """

    @Test("speaker, time and text come back apart")
    func parsesTurns() {
        let turns = NoteFile.turns(in: Self.real)

        #expect(turns.count == 2)
        #expect(turns[0].speaker == "Them")
        #expect(turns[0].time == "0:00")
        #expect(turns[0].text == "Sur l'extérieur, sur la touche. Tamarc, la prise initiale.")
        #expect(turns[0].isYou == false)
        #expect(turns[1].isYou == true)
    }

    /// The bug the user saw: markup rendered as content.
    @Test("no markup survives into a turn")
    func stripsMarkup() {
        for turn in NoteFile.turns(in: Self.real) {
            #expect(!turn.text.contains("**"))
            #expect(!turn.text.contains("`"))
            #expect(!turn.text.hasPrefix("#"))
        }
    }

    /// A note somebody typed themselves has no speaker lines. Files are the source of
    /// truth, so that has to keep working — an empty result is the signal to fall back.
    @Test("a hand-written note yields no turns rather than nonsense")
    func handWritten() {
        #expect(NoteFile.turns(in: "# Groceries\n\nMilk, and a new kettle.").isEmpty)
    }

    /// Multiple lines under one speaker belong to that speaker.
    @Test("a turn spanning lines stays one turn")
    func joinsWrappedLines() {
        let turns = NoteFile.turns(in: "**You** · `1:20`\n\nFirst part.\nSecond part.")
        #expect(turns.count == 1)
        #expect(turns[0].text == "First part. Second part.")
    }
}

/// The list rows.
@Suite("Note list rows")
struct NoteSnippetTests {

    private func snippet(_ body: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snippet-\(UUID().uuidString).md")
        let file = """
            ---
            title: "Meeting"
            date: 2026-08-22T09:14:44Z
            duration: 3
            ---

            \(body)
            """
        try file.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(NoteFile.read(url)).snippet
    }

    /// What the user saw: a row reading "22 Aug 2026 at 11:14 · 0:03" and then, underneath,
    /// "Saturday 22 August 2026 at 11:14 · 0:02" — the same date, formatted twice, once
    /// disagreeing with the other.
    @Test("the snippet is speech, not the note's own date line")
    func skipsDateLine() throws {
        let text = try snippet("""
            # Meeting — 22 August 2026 at 11:14

            Saturday 22 August 2026 at 11:14 · 0:02

            **Them** · `0:00`

            Sur l'extérieur, sur la touche.
            """)

        #expect(text == "Sur l'extérieur, sur la touche.")
        #expect(!text.contains("Saturday"))
        #expect(!text.contains("·"))
    }

    @Test("a long turn is cut with an ellipsis")
    func truncates() throws {
        let text = try snippet("**You** · `0:00`\n\n" + String(repeating: "word ", count: 60))
        #expect(text.count <= 101)
        #expect(text.hasSuffix("…"))
    }
}

/// The file the app writes.
@Suite("Writing a note")
struct NoteWritingTests {

    /// The pane draws the title and the date itself, so the body restating them put the
    /// same information on screen three times over.
    @Test("the body does not restate the date")
    func noDuplicateDate() {
        let transcript = MeetingTranscript(
            title: "Meeting — 22 August 2026 at 11:14",
            startedAt: Date(timeIntervalSince1970: 1_755_853_484),
            duration: 182,
            utterances: [Utterance(speaker: .them, start: 0, end: 2, text: "Hello there.")]
        )
        let markdown = transcript.markdown

        // Once in the front matter, once as the heading — and nowhere else.
        #expect(markdown.components(separatedBy: "2026").count - 1 <= 2)
        #expect(!markdown.contains("· 3:02"))
    }
}

// MARK: - Looking at it

@MainActor
@Suite("Transcript snapshot")
struct TranscriptSnapshotTests {

    @Test("render a conversation")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        let body = """
            # Meeting — 22 August 2026 at 11:14

            **Them** · `0:00`

            Sur l'extérieur, sur la touche. Tamarc, la prise initiale, et \
            ensuite on regarde ce que ça donne côté production.

            **You** · `0:07`

            Right — so the plan is to ship the reading pane first, then come back \
            to the empty states once we know how the transcript actually reads.

            **Them** · `0:14`

            Exactly.
            """

        let turns = NoteFile.turns(in: body)
        #expect(turns.count == 3)

        let view = VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meeting — 22 August 2026 at 11:14")
                    .font(Theme.Text.title)
                    .foregroundStyle(Theme.Palette.text)
                Text("Saturday 22 August 2026 at 11:14 · 0:18")
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.faint)
            }
            Divider().overlay(Theme.Palette.hairline)
            TranscriptView(turns: turns)
        }
        .frame(width: 560, alignment: .leading)
        .padding(20)
        .background(InkGround())

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("transcript.png")
        )
    }

    // MARK: - The written note

    private static let withSummary = """
        ---
        title: Weekly sync
        date: 2026-09-16T15:42:00+02:00
        duration: 842
        note: Summary
        ---

        # Weekly sync

        ### Where we are
        - The model runs on the machine, about 600 MB.
        - Only text reaches a provider.

        ### Next steps
        - [ ] Record a real meeting (You)
        - [x] Check the token ceiling (Them)

        ## Transcript

        **You** · `0:00`

        Right, can you hear me?

        **Them** · `0:11`

        Yeah, go for it.
        """

    @Test("the note reads as headings, bullets and tasks")
    func parsesTheSummary() {
        let (_, body) = NoteFile.split(Self.withSummary)
        let lines = NoteFile.summary(in: body)

        #expect(lines == [
            .heading("Where we are"),
            .bullet("The model runs on the machine, about 600 MB."),
            .bullet("Only text reaches a provider."),
            .heading("Next steps"),
            .task(done: false, "Record a real meeting (You)"),
            .task(done: true, "Check the token ceiling (Them)"),
        ])
    }

    @Test("the note stops at the transcript, and the turns still parse under it")
    func summaryAndTurnsAreSeparate() {
        let (_, body) = NoteFile.split(Self.withSummary)
        let turns = NoteFile.turns(in: body)

        #expect(turns.count == 2)
        #expect(turns.first?.text == "Right, can you hear me?")
        // Nothing from the note leaked into the conversation.
        #expect(!turns.contains { $0.text.contains("600 MB") })
    }

    @Test("a file with no transcript heading has no note, whatever it starts with")
    func noHeadingNoSummary() {
        let handWritten = """
            # Some thoughts

            - a bullet somebody typed
            - and another
            """
        // Reading these as a note would claim the file said something it never said.
        #expect(NoteFile.summary(in: handWritten).isEmpty)
    }

    @Test("the row's snippet is what the note says, not the first hello")
    func snippetPrefersTheNote() throws {
        let folder = Scratch.folder("summary-snippet")
        let url = folder.appendingPathComponent("2026-09-16 15-42 Meeting.md")
        try Self.withSummary.write(to: url, atomically: true, encoding: .utf8)

        let note = try #require(NoteFile.read(url))
        #expect(note.snippet == "The model runs on the machine, about 600 MB.")
    }
}

/// Editing the note, which is the half of the file anyone is allowed to revise.
@MainActor
@Suite("Editing a note")
struct NoteEditingTests {

    private static let file = """
        ---
        title: Weekly sync
        date: 2026-09-16T15:42:00+02:00
        duration: 842
        note: Summary
        ---

        # Weekly sync

        ### Where we are
        - The model runs on the machine.

        ## Transcript

        **You** · `0:00`

        Right, can you hear me?
        """

    @Test("the note comes out as the Markdown that is in the file")
    func readsTheMarkdown() throws {
        let (_, body) = NoteFile.split(Self.file)
        let markdown = try #require(NoteFile.summaryMarkdown(in: body))
        #expect(markdown == "### Where we are\n- The model runs on the machine.")
    }

    @Test("an edit replaces the note and leaves everything else byte for byte")
    func replacesOnlyTheNote() {
        let edited = NoteFile.replacingSummary(
            in: Self.file, with: "### Where we are\n- The model runs on the machine, 600 MB."
        )
        #expect(edited.contains("600 MB"))
        #expect(edited.contains("title: Weekly sync"))
        #expect(edited.contains("# Weekly sync"))
        // The record of what was said is not anyone's to revise.
        #expect(edited.contains("**You** · `0:00`"))
        #expect(edited.contains("Right, can you hear me?"))
        #expect(!edited.contains("runs on the machine."))
    }

    @Test("an emptied note leaves the transcript standing on its own")
    func emptyEdit() {
        let edited = NoteFile.replacingSummary(in: Self.file, with: "   \n  ")
        #expect(NoteFile.summary(in: NoteFile.split(edited).body).isEmpty)
        #expect(edited.contains("Right, can you hear me?"))
        #expect(edited.contains("title: Weekly sync"))
    }

    @Test("a file with no transcript heading is left exactly as it was")
    func refusesWhatItCannotPlace() {
        let handWritten = "# Some thoughts\n\n- a bullet somebody typed"
        #expect(NoteFile.replacingSummary(in: handWritten, with: "### New") == handWritten)
        #expect(NoteFile.summaryMarkdown(in: handWritten) == nil)
    }

    @Test("an edit survives being written and read back")
    func roundTrips() throws {
        let folder = Scratch.folder("note-editing")
        let url = folder.appendingPathComponent("2026-09-16 15-42 Meeting.md")
        try Self.file.write(to: url, atomically: true, encoding: .utf8)

        let store = NoteStore(folder: folder)
        let note = try #require(store.notes.first)
        store.saveSummary("### Decided\n- Ship on Friday.", in: note)

        let reloaded = try #require(store.notes.first)
        let body = store.body(of: reloaded)
        #expect(NoteFile.summary(in: body) == [.heading("Decided"), .bullet("Ship on Friday.")])
        #expect(NoteFile.turns(in: body).count == 1)
    }
}

/// What the person typed while the meeting ran: kept whole, kept apart, and handed to the
/// style that writes the note.
@MainActor
@Suite("Notes typed during a meeting")
struct OwnNotesTests {

    private static let file = """
        ---
        title: Weekly sync
        date: 2026-09-16T15:42:00+02:00
        duration: 842
        note: Summary
        ---

        # Weekly sync

        ### Where we are
        - The model runs on the machine.

        ## My notes

        ask about the token ceiling
        - friday deploy rule?

        ## Transcript

        **You** · `0:00`

        Right, can you hear me?
        """

    @Test("what was typed comes back exactly as it was typed")
    func readsOwnNotes() throws {
        let (_, body) = NoteFile.split(Self.file)
        let own = try #require(NoteFile.ownNotes(in: body))
        #expect(own == "ask about the token ceiling\n- friday deploy rule?")
    }

    @Test("the written note stops at Your notes rather than swallowing them")
    func summaryStopsFirst() {
        let (_, body) = NoteFile.split(Self.file)
        #expect(NoteFile.summary(in: body) == [
            .heading("Where we are"),
            .bullet("The model runs on the machine."),
        ])
        #expect(NoteFile.turns(in: body).count == 1)
    }

    @Test("editing the note leaves what you typed and what was said alone")
    func editingKeepsTheRest() {
        let edited = NoteFile.replacingSummary(in: Self.file, with: "### Decided\n- Ship it.")
        #expect(edited.contains("### Decided"))
        #expect(edited.contains("ask about the token ceiling"))
        #expect(edited.contains("Right, can you hear me?"))
        #expect(!edited.contains("The model runs on the machine."))
    }

    @Test("a task is ticked by position, and only inside the note")
    func ticksByPosition() {
        let file = """
            # Weekly sync

            ### Next steps
            - [ ] first
            - [ ] second

            ## Transcript

            **You** · `0:00`

            - [ ] this was said out loud, not a task
            """
        let ticked = NoteFile.togglingTask(in: file, at: 1)
        #expect(ticked.contains("- [ ] first"))
        #expect(ticked.contains("- [x] second"))
        // The transcript is the record of what was said; nothing in it is a checkbox.
        #expect(ticked.contains("- [ ] this was said out loud"))

        // And back again.
        #expect(NoteFile.togglingTask(in: ticked, at: 1) == file)
    }

    @Test("an index past the end changes nothing")
    func outOfRange() {
        #expect(NoteFile.togglingTask(in: Self.file, at: 7) == Self.file)
    }

    @Test("what was typed reaches the prompt, in the person's own words")
    func reachesThePrompt() {
        let rendered = PromptLibrary(template: "Write the notes.").render(
            .init(transcript: "You: hello", ownNotes: "ask about the token ceiling")
        )
        #expect(rendered.contains("ask about the token ceiling"))
        #expect(rendered.contains("typed these notes while it was running"))
    }

    @Test("nothing typed adds nothing to the prompt")
    func emptyAddsNothing() {
        let rendered = PromptLibrary(template: "Write the notes.").render(
            .init(transcript: "You: hello", ownNotes: "   \n ")
        )
        #expect(!rendered.contains("typed these notes"))
    }
}
