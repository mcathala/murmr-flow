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
        let destination = root.appendingPathComponent("MurmurNotes", isDirectory: true)
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
        let destination = root.appendingPathComponent("MurmurNotes", isDirectory: true)
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

    @Test("a built-in nobody edited follows the wording we ship now")
    func upgradesUntouchedBuiltIns() {
        let store = defaults()
        // Word for word the Default of an earlier version, as it sat in stored JSON.
        let old = """
            [{"id":"8B1F0C4A-0000-4000-A000-000000000001","name":"Default",
              "template":"You clean up dictated speech. Rewrite the transcript below applying only these changes:\\n\\n- Fix punctuation and capitalization.\\n- Remove filler words (um, uh, like, you know) and false starts.\\n- Break into paragraphs where the speaker clearly changed topic.\\n\\nDo not rephrase, summarize, translate, answer questions, or add anything. Keep the speaker's own words and meaning. If the transcript is already clean, return it unchanged.\\n\\nReply with the cleaned text only — no preamble, no quotes, no explanation.\\n",
              "isBuiltIn":true},
             {"id":"8B1F0C4A-0000-4000-A000-000000000003","name":"Formal",
              "template":"Be formal, my way.","isBuiltIn":true}]
            """
        store.set(Data(old.utf8), forKey: "prompts.presets")
        store.set(true, forKey: "prompts.strippedPlaceholders")

        let prompts = PromptStore(defaults: store)
        #expect(prompts.dictationPrompt.template == ShippedPrompts.standard)
        // An edited one is the user's.
        let formal = prompts.presets.first { $0.name == "Formal" }
        #expect(formal?.template == "Be formal, my way.")
    }

    @Test("every shipped prompt keeps the shared rules and ends with the output contract")
    func shippedPromptsShareTheirSkeleton() {
        for preset in PromptStore.builtIns {
            #expect(preset.template.contains("RULE ZERO"), "\(preset.name)")
            #expect(preset.template.contains("CORRECTIONS —"), "\(preset.name)")
            #expect(preset.template.contains("CONVERT —"), "\(preset.name)")
            #expect(preset.template.contains("OUTPUT —"), "\(preset.name)")
            #expect(!preset.template.contains("\\("), "\(preset.name) has an unrendered interpolation")
        }
    }

    @Test("a deleted built-in stays deleted, and Casual leaves on its own if untouched")
    func deletesBuiltIns() {
        let store = defaults()
        var prompts = PromptStore(defaults: store)
        let count = prompts.presets.count
        #expect(!prompts.presets.contains { $0.name == "Casual" })
        #expect(prompts.presets.contains { $0.name == "Notes" })

        let formal = prompts.presets.first { $0.name == "Formal" }!
        prompts.delete(formal)
        #expect(prompts.presets.count == count - 1)

        prompts = PromptStore(defaults: store)
        #expect(!prompts.presets.contains { $0.id == formal.id })

        // Down to one, it cannot go.
        while prompts.presets.count > 1 { prompts.delete(prompts.presets[0]) }
        prompts.delete(prompts.presets[0])
        #expect(prompts.presets.count == 1)
        #expect(prompts.dictationPrompt.id == prompts.presets[0].id)
    }

    @Test("an install with Meeting and an edited Casual comes up with Notes and Casual as its own")
    func retiresAndRenames() {
        let store = defaults()
        let stored = """
            [{"id":"8B1F0C4A-0000-4000-A000-000000000005","name":"Meeting",
              "template":"You tidy the transcript of a spoken conversation, turn by turn.\\n\\n- Fix punctuation, capitalization and obvious mis-transcriptions.\\n- Remove filler words (um, uh, like, you know), false starts and repeated words.\\n- Leave every substantive point in place, in the speaker's own words.\\n\\nDo not summarise, rephrase, translate, or add anything. Do not move what one person said onto another speaker's turn, and do not answer questions in the transcript — they were asked of somebody in the room, not of you. A turn that is already clean is returned unchanged.\\n",
              "isBuiltIn":true},
             {"id":"8B1F0C4A-0000-4000-A000-000000000004","name":"Casual",
              "template":"My relaxed one.","isBuiltIn":true}]
            """
        store.set(Data(stored.utf8), forKey: "prompts.presets")
        store.set(true, forKey: "prompts.strippedPlaceholders")

        let prompts = PromptStore(defaults: store)
        // The tidier retired with the pass it existed for, so an install still pointed at
        // it lands on the style that writes the note — the output they were getting anyway.
        let notes = prompts.preset(id: PromptStore.meetingPreset.id)
        #expect(notes?.name == "Notes")
        #expect(notes?.template == ShippedPrompts.summary)
        let casual = prompts.presets.first { $0.name == "Casual" }
        #expect(casual?.isBuiltIn == false)
        #expect(prompts.notetakerPrompt?.name == "Notes")
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
        #expect(prompts.notetakerPrompt?.name == "Notes")
    }

    @Test("deleting the prompt Notetaker used stops the note rather than picking another")
    func deleteStopsTheNote() {
        let prompts = PromptStore(defaults: defaults())
        let mine = prompts.addNew()
        prompts.notetakerPromptID = mine.id

        // Falling back would write the meeting's note in whatever style happened to be
        // next — a dictation style, most likely, asked to summarise a conversation.
        prompts.delete(mine)
        #expect(prompts.notetakerPromptID == nil)
    }
}
