import Foundation
import Testing

@testable import MurmrFlow

/// The turn-by-turn round trip that meeting clean-up rests on.
///
/// Worth testing rather than eyeballing: the note is the only copy of a meeting — the
/// audio is deleted the moment it is written — so a parsing slip here does not produce
/// slightly worse wording, it loses what somebody said.
@Suite("Note clean-up round trip")
struct NoteCleanupTests {

    private func turns(_ pairs: [(String, String)]) -> [CleanupService.Turn] {
        pairs.map { CleanupService.Turn(speaker: $0.0, text: $0.1) }
    }

    @Test("turns are numbered from their real position, not from zero in each batch")
    func numberingUsesGlobalIndex() {
        let block = CleanupService.numbered(
            turns([("You", "hello"), ("Them", "hi")]), startingAt: 7
        )
        #expect(block == "[7] You: hello\n[8] Them: hi")
    }

    @Test("a clean reply maps straight back onto its turns")
    func parsesPlainReply() {
        let parsed = CleanupService.parseNumbered("[0] You: Hello.\n[1] Them: Hi there.")
        #expect(parsed == [0: "Hello.", 1: "Hi there."])
    }

    @Test("bold speakers, bullets and stray blank lines still parse")
    func parsesModelHabits() {
        let reply = """
            - [0] **You**: Shall we ship on Friday?

            * [1] Them: Friday works.
            """
        let parsed = CleanupService.parseNumbered(reply)
        #expect(parsed[0] == "Shall we ship on Friday?")
        #expect(parsed[1] == "Friday works.")
    }

    @Test("a colon inside the sentence stays in the sentence")
    func colonInBody() {
        let parsed = CleanupService.parseNumbered("[3] You: One thing: we need the key.")
        #expect(parsed[3] == "One thing: we need the key.")
    }

    @Test("a preamble line is ignored rather than swallowing a turn")
    func ignoresPreamble() {
        let parsed = CleanupService.parseNumbered(
            "Here is the cleaned transcript:\n[0] You: Right.\n"
        )
        #expect(parsed == [0: "Right."])
    }

    @Test("a turn the model split keeps its first line")
    func duplicateNumber() {
        let parsed = CleanupService.parseNumbered("[2] You: First half.\n[2] You: Second half.")
        #expect(parsed[2] == "First half.")
    }

    @Test("batching covers every turn exactly once, in order")
    func batchesCoverEverything() {
        let long = String(repeating: "a sentence that goes on. ", count: 60)  // ~1500 chars
        let conversation = turns((0..<20).map { ("You", "\($0) \(long)") })

        let ranges = CleanupService.batches(of: conversation)
        #expect(ranges.count > 1)  // it genuinely split
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == conversation.count)
        // No gap and no overlap: a gap would drop turns and an overlap would clean the
        // same turn twice, which costs a request and can disagree with itself.
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(previous.upperBound == next.lowerBound)
        }
    }

    @Test("one turn always makes one batch")
    func singleTurn() {
        let ranges = CleanupService.batches(of: turns([("You", "short")]))
        #expect(ranges == [0..<1])
    }
}

/// Merging cleaned text back into a transcript.
@Suite("Applying clean-up to a transcript")
struct TranscriptCleanupTests {

    private func transcript(_ texts: [String]) -> MeetingTranscript {
        MeetingTranscript(
            title: "Standup",
            startedAt: Date(timeIntervalSince1970: 1_775_000_000),
            duration: 120,
            utterances: texts.enumerated().map { index, text in
                Utterance(
                    speaker: index.isMultiple(of: 2) ? .you : .them,
                    start: TimeInterval(index),
                    end: TimeInterval(index) + 1,
                    text: text
                )
            }
        )
    }

    @Test("cleaned text replaces the wording and keeps speakers and timings")
    func applies() {
        let original = transcript(["um so friday", "yeah ok"])
        let cleaned = original.applying(
            texts: ["So, Friday.", "Yeah, OK."], cleanedBy: "Meeting"
        )

        #expect(cleaned.utterances.map(\.text) == ["So, Friday.", "Yeah, OK."])
        #expect(cleaned.utterances.map(\.speaker) == [.you, .them])
        #expect(cleaned.utterances.map(\.start) == [0, 1])
        #expect(cleaned.cleanedBy == "Meeting")
    }

    @Test("a count mismatch changes nothing at all")
    func countMismatchIsRefused() {
        let original = transcript(["one", "two", "three"])
        let result = original.applying(texts: ["one cleaned"], cleanedBy: "Meeting")

        // Zipping would have silently dropped two thirds of the meeting.
        #expect(result.utterances.map(\.text) == ["one", "two", "three"])
        #expect(result.cleanedBy == nil)
    }

    @Test("an empty replacement falls back to what was said")
    func emptyKeepsOriginal() {
        let result = transcript(["kept", "also kept"])
            .applying(texts: ["", "tidied"], cleanedBy: "Meeting")
        #expect(result.utterances.map(\.text) == ["kept", "tidied"])
    }

    @Test("the note records which prompt cleaned it, and only when one did")
    func frontMatterRecordsCleanup() {
        let raw = transcript(["said something"]).markdown
        #expect(!raw.contains("cleanup:"))

        let cleaned = transcript(["said something"])
            .applying(texts: ["Said something."], cleanedBy: "Meeting")
            .markdown
        #expect(cleaned.contains("cleanup: Meeting"))

        // And it survives a rename, which rebuilds the header from scratch.
        let renamed = NoteFile.rewritingTitle(
            in: cleaned, to: "Pricing", fallbackDate: Date()
        )
        #expect(renamed.contains("cleanup: Meeting"))
        #expect(renamed.contains("title: Pricing"))
    }
}

/// The folder rename. Notes written under the old name have to arrive under the new one,
/// or renaming a constant in code is indistinguishable from deleting somebody's notes.
@MainActor
@Suite("Adopting the old notes folder")
struct LegacyFolderTests {

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-folder-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("notes move across and the emptied folder goes away")
    func moves() throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("Murmr Flow/Meetings", isDirectory: true)
        let destination = root.appendingPathComponent("MurmrNotes", isDirectory: true)
        try write("# One", to: legacy.appendingPathComponent("one.md"))
        try write("# Two", to: legacy.appendingPathComponent("two.md"))

        NoteStore.adoptLegacyFolder(from: legacy, to: destination)

        let moved = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(Set(moved) == ["one.md", "two.md"])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Finder's .DS_Store doesn't keep the old folder alive, nor its empty parent")
    func pruneIgnoresFinderLeftovers() throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("Murmr Flow/Meetings", isDirectory: true)
        let destination = root.appendingPathComponent("MurmrNotes", isDirectory: true)
        try write("# One", to: legacy.appendingPathComponent("one.md"))
        try write("", to: legacy.appendingPathComponent(".DS_Store"))
        try write("", to: root.appendingPathComponent("Murmr Flow/.DS_Store"))

        NoteStore.adoptLegacyFolder(from: legacy, to: destination)

        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("one.md").path
        ))
        // Both levels go: requiring a truly empty directory left an empty "Murmr Flow"
        // next to the new folder for anyone who had opened it in Finder.
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Murmr Flow").path
        ))
        // And it stops there rather than walking up.
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a name already taken is left where it is rather than overwritten")
    func doesNotOverwrite() throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("old", isDirectory: true)
        let destination = root.appendingPathComponent("new", isDirectory: true)
        try write("old copy", to: legacy.appendingPathComponent("clash.md"))
        try write("the one being used", to: destination.appendingPathComponent("clash.md"))

        NoteStore.adoptLegacyFolder(from: legacy, to: destination)

        let kept = try String(
            contentsOf: destination.appendingPathComponent("clash.md"), encoding: .utf8
        )
        #expect(kept == "the one being used")
        // Still there, so nothing was lost — it just wasn't moved.
        #expect(FileManager.default.fileExists(
            atPath: legacy.appendingPathComponent("clash.md").path
        ))
    }

    @Test("a folder holding something else keeps it, and itself")
    func leavesForeignFiles() throws {
        let root = scratch()
        let legacy = root.appendingPathComponent("old", isDirectory: true)
        let destination = root.appendingPathComponent("new", isDirectory: true)
        try write("# Note", to: legacy.appendingPathComponent("note.md"))
        try write("mine", to: legacy.appendingPathComponent("audio.wav"))

        NoteStore.adoptLegacyFolder(from: legacy, to: destination)

        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("note.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: legacy.appendingPathComponent("audio.wav").path
        ))
    }

    @Test("no old folder is not a failure")
    func missingLegacyFolder() {
        let root = scratch()
        NoteStore.adoptLegacyFolder(
            from: root.appendingPathComponent("nothing-here", isDirectory: true),
            to: root.appendingPathComponent("new", isDirectory: true)
        )
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("new").path
        ))
    }

    @Test("the folder is spelled the way the app is, and both old names are still read")
    func spellingAndOrder() {
        #expect(NoteStore.folder.lastPathComponent == "MurmrNotes")
        #expect(
            NoteStore.legacyFolders.map(\.lastPathComponent) == ["MurmurNotes", "Meetings"]
        )
    }

    @Test("with a note in each old folder, the newer folder wins the clash")
    func newestLegacyWins() throws {
        let root = scratch()
        let destination = root.appendingPathComponent("MurmrNotes", isDirectory: true)
        let misspelled = root.appendingPathComponent("MurmurNotes", isDirectory: true)
        let nested = root.appendingPathComponent("Murmr Flow/Meetings", isDirectory: true)
        try write("the newer copy", to: misspelled.appendingPathComponent("clash.md"))
        try write("the older copy", to: nested.appendingPathComponent("clash.md"))
        try write("# Only here", to: nested.appendingPathComponent("older.md"))

        // The order `legacyFolders` declares, run against a scratch root.
        for legacy in [misspelled, nested] {
            NoteStore.adoptLegacyFolder(from: legacy, to: destination)
        }

        let kept = try String(
            contentsOf: destination.appendingPathComponent("clash.md"), encoding: .utf8
        )
        #expect(kept == "the newer copy")
        // The older copy is skipped rather than lost, and its folder stays for holding it.
        #expect(FileManager.default.fileExists(
            atPath: nested.appendingPathComponent("clash.md").path
        ))
        // Anything that does not clash still arrives, from either folder.
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("older.md").path
        ))
        // The misspelled folder emptied, so it goes.
        #expect(!FileManager.default.fileExists(atPath: misspelled.path))
    }
}

/// What the app adds to a prompt on the way out.
///
/// The rule being tested is that template syntax is never the user's problem: a prompt
/// written as plain instructions has to produce a working request.
@Suite("Appending what a request needs")
struct PromptRenderTests {

    @Test("a prompt with no placeholders still gets the transcript")
    func appendsTranscript() {
        let rendered = PromptLibrary(template: "Tidy this up.")
            .render(PromptLibrary.Context(transcript: "um hello"))
        #expect(rendered.hasSuffix("Transcript:\num hello"))
        #expect(!rendered.contains("${"))
    }

    @Test("dictionary hints reach a prompt that never mentions them")
    func appendsVocabulary() {
        let rendered = PromptLibrary(template: "Tidy this up.")
            .render(PromptLibrary.Context(transcript: "kovalee", hints: ["Kovalee"]))
        #expect(rendered.contains("Kovalee"))
        #expect(!rendered.contains("${"))
    }

    @Test("a transcript carrying markers asks the model to leave them alone")
    func markerInstruction() {
        let rendered = PromptLibrary(template: "Tidy this up.")
            .render(PromptLibrary.Context(transcript: "send it to [[MF0]]", hasMarkers: true))
        #expect(rendered.contains("[[MF"))
        #expect(rendered.lowercased().contains("exactly as they are"))
    }

    @Test("with no markers, nothing is said about them")
    func noMarkerInstruction() {
        let rendered = PromptLibrary(template: "Tidy this up.")
            .render(PromptLibrary.Context(transcript: "hello"))
        #expect(!rendered.contains("[[MF"))
    }

    @Test("with no dictionary hints, nothing is appended for them")
    func noVocabularyLine() {
        let rendered = PromptLibrary(template: "Tidy this up.")
            .render(PromptLibrary.Context(transcript: "hello"))
        #expect(!rendered.contains("Spell these correctly"))
    }

    @Test("a placeholder the user did write is used where they put it, not duplicated")
    func respectsExplicitPlaceholders() {
        let rendered = PromptLibrary(template: "Before ${transcript} after")
            .render(PromptLibrary.Context(transcript: "the words"))
        #expect(rendered == "Before the words after")
    }

}

/// Prompt storage across the change that removed the description field.
@MainActor
@Suite("Prompt presets")
struct PromptPresetTests {

    private func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "murmr-prompts-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.description)
        return suite
    }

    @Test("presets stored with the old description field still load")
    func decodesLegacyJSON() {
        let store = defaults()
        let legacy = """
            [{"id":"8B1F0C4A-0000-4000-A000-000000000001","name":"Default",
              "summary":"Light cleanup.","template":"Clean this: ${transcript}",
              "isBuiltIn":true}]
            """
        store.set(Data(legacy.utf8), forKey: "prompts.presets")

        let prompts = PromptStore(defaults: store)
        #expect(prompts.presets.contains { $0.name == "Default" })
        #expect(prompts.dictationPrompt.template.contains("${transcript}"))
    }

    @Test("a built-in shipped later is added without touching an edited one")
    func mergesNewBuiltIns() {
        let store = defaults()
        let edited = """
            [{"id":"8B1F0C4A-0000-4000-A000-000000000001","name":"My default",
              "template":"my own wording","isBuiltIn":true}]
            """
        store.set(Data(edited.utf8), forKey: "prompts.presets")

        let prompts = PromptStore(defaults: store)
        #expect(prompts.preset(id: PromptStore.defaultPreset.id)?.name == "My default")
        #expect(prompts.preset(id: PromptStore.meetingPreset.id) != nil)
    }

    @Test("no shipped prompt shows template syntax")
    func builtInsAreReadable() {
        for preset in PromptStore.builtIns {
            #expect(!preset.template.contains("${"), "\(preset.name) still has a placeholder")
        }
    }

    @Test("the boilerplate is taken off prompts that were already saved")
    func stripsStoredPlaceholders() {
        let store = defaults()
        let old = """
            [{"id":"8B1F0C4A-0000-4000-A000-000000000001","name":"Default",
              "template":"Tidy this.\\n\\n${custom_words}\\n\\nTranscript:\\n${transcript}",
              "isBuiltIn":true}]
            """
        store.set(Data(old.utf8), forKey: "prompts.presets")

        let prompts = PromptStore(defaults: store)
        #expect(prompts.dictationPrompt.template == "Tidy this.")

        // And a placeholder typed on purpose afterwards is left alone — the strip runs
        // once, not on every load.
        var edited = prompts.dictationPrompt
        edited.template = "Tidy this.\n\n${transcript}"
        prompts.update(edited)
        #expect(PromptStore(defaults: store).dictationPrompt.template.contains("${transcript}"))
    }

    @Test("a placeholder in the middle of a sentence is not touched")
    func keepsDeliberatePlaceholders() {
        let template = "Clean up ${transcript} and stop."
        #expect(PromptStore.stripTrailingPlaceholders(template) == template)
    }

    @Test("a new prompt starts as plain instructions, with no template syntax to keep")
    func starterIsPlainEnglish() {
        let prompts = PromptStore(defaults: defaults())
        #expect(!prompts.addNew().template.contains("${"))
    }

    @Test("Notetaker starts assigned, so meetings are cleaned up out of the box")
    func noteModeHasAPrompt() {
        let prompts = PromptStore(defaults: defaults())
        #expect(prompts.notetakerPromptID == PromptStore.meetingPreset.id)
        #expect(prompts.notetakerPrompt?.name == "Meeting")
    }

    @Test("deleting the prompt Notetaker used falls back rather than leaving nothing")
    func deleteFallsBack() {
        let prompts = PromptStore(defaults: defaults())
        let mine = prompts.addNew()
        prompts.notetakerPromptID = mine.id

        prompts.delete(mine)
        #expect(prompts.notetakerPromptID == PromptStore.meetingPreset.id)
    }
}
