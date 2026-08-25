import Foundation
import Testing

@testable import MurmrFlow

@Suite("Dictionary matching")
struct DictionaryExpanderTests {

    private func entry(
        _ trigger: String, _ replacement: String, scope: DictionaryEntry.Scope = .both
    ) -> DictionaryEntry {
        DictionaryEntry(kind: .swap, trigger: trigger, replacement: replacement, scope: scope)
    }

    @Test("a trigger becomes a marker, and resolves to its replacement")
    func basic() {
        let result = DictionaryExpander.expand(
            "send it to my email address please",
            using: [entry("my email address", "name@example.com")]
        )

        #expect(result.text == "send it to [[MF0]] please")
        #expect(result.resolved == "send it to name@example.com please")
        #expect(result.markers.count == 1)
    }

    @Test("capitals and punctuation around the trigger do not stop it matching")
    func normalisation() {
        let result = DictionaryExpander.expand(
            "My Email Address, then.",
            using: [entry("my email address", "name@example.com")]
        )

        #expect(result.resolved == "name@example.com, then.")
    }

    @Test("a curly apostrophe matches a straight one")
    func apostrophes() {
        let result = DictionaryExpander.expand(
            "that\u{2019}s acme\u{2019}s line",
            using: [entry("that's acme's", "ACME:")]
        )

        #expect(result.resolved == "ACME: line")
    }

    @Test("the longest trigger wins over one that is its opening words")
    func longestWins() {
        let result = DictionaryExpander.expand(
            "my email address is here",
            using: [entry("my email", "WRONG"), entry("my email address", "RIGHT")]
        )

        #expect(result.resolved == "RIGHT is here")
    }

    @Test("the same trigger twice gets a marker each")
    func repeated() {
        let result = DictionaryExpander.expand(
            "ping me ping me",
            using: [entry("ping me", "hello")]
        )

        #expect(result.markers.count == 2)
        #expect(result.resolved == "hello hello")
    }

    @Test("a multi-line snippet keeps its line breaks")
    func multiline() {
        let body = "Hey,\n\nWould love to chat.\n\nA."
        let result = DictionaryExpander.expand(
            "intro email",
            using: [entry("intro email", body)]
        )

        #expect(result.resolved == body)
    }

    @Test("nothing to match leaves the text alone")
    func noMatch() {
        let result = DictionaryExpander.expand(
            "just some words",
            using: [entry("my email address", "name@example.com")]
        )

        #expect(result.isEmpty)
        #expect(result.text == "just some words")
        #expect(result.resolved == "just some words")
    }

    @Test("a spelling entry is a hint, never a match")
    func hintsAreNotMatched() {
        let hint = DictionaryEntry(kind: .spelling, replacement: "Acme")
        let result = DictionaryExpander.expand("acme is the company", using: [hint])

        #expect(result.isEmpty)
        #expect(DictionaryExpander.hints(from: [hint]) == ["Acme"])
    }

    @Test("a swap is never offered to the prompt as a hint")
    func swapsAreNotHints() {
        #expect(DictionaryExpander.hints(from: [entry("my email", "a@b.com")]).isEmpty)
    }

    @Test("a swap with no trigger yet matches nothing and hints nothing")
    func halfFilledSwap() {
        let half = DictionaryEntry(kind: .swap, replacement: "a@b.com")

        #expect(!half.isUsable)
        #expect(DictionaryExpander.expand("anything at all", using: [half]).isEmpty)
        #expect(DictionaryExpander.hints(from: [half]).isEmpty)
    }

    @Test("an empty replacement is not applied")
    func emptyReplacement() {
        let result = DictionaryExpander.expand(
            "say the thing",
            using: [entry("the thing", "   ")]
        )

        #expect(result.isEmpty)
    }

    // MARK: - Restoring after clean-up

    @Test("markers left intact are spliced back into the cleaned text")
    func restore() {
        let expansion = DictionaryExpander.expand(
            "send it to my email address",
            using: [entry("my email address", "name@example.com")]
        )

        #expect(expansion.restore(into: "Send it to [[MF0]].") == "Send it to name@example.com.")
    }

    @Test("a dropped marker refuses to restore, so the caller can fall back")
    func droppedMarker() {
        let expansion = DictionaryExpander.expand(
            "send it to my email address",
            using: [entry("my email address", "name@example.com")]
        )

        // The value must never be silently lost — nil is what makes the caller use
        // `resolved` instead.
        #expect(expansion.restore(into: "Send it to.") == nil)
        #expect(expansion.resolved == "send it to name@example.com")
    }

    @Test("one dropped marker out of two still refuses")
    func partialDrop() {
        let expansion = DictionaryExpander.expand(
            "email me at my email address or my other address",
            using: [
                entry("my email address", "a@b.com"),
                entry("my other address", "c@d.com"),
            ]
        )

        #expect(expansion.markers.count == 2)
        #expect(expansion.restore(into: "Email me at [[MF0]].") == nil)
    }
}

@Suite("Dictionary scope")
struct DictionaryScopeTests {

    @Test("both answers to either job, and a narrow scope only to its own")
    func covers() {
        #expect(DictionaryEntry.Scope.both.covers(.dictation))
        #expect(DictionaryEntry.Scope.both.covers(.notetaker))
        #expect(DictionaryEntry.Scope.dictation.covers(.dictation))
        #expect(!DictionaryEntry.Scope.dictation.covers(.notetaker))
        #expect(!DictionaryEntry.Scope.notetaker.covers(.dictation))
    }
}

@MainActor
@Suite("Dictionary store")
struct DictionaryStoreTests {

    private func scratch(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "dictionary.tests.\(name)")!
        defaults.removePersistentDomain(forName: "dictionary.tests.\(name)")
        return defaults
    }

    @Test("the old custom words become spelling fixes scoped to both jobs")
    func seedsFromLegacyWords() {
        let defaults = scratch("seed")
        defaults.set(["Acme", "Murmr"], forKey: "cleanup.customWords")

        let store = DictionaryStore(defaults: defaults)

        #expect(store.entries.count == 2)
        #expect(store.entries.allSatisfy { $0.kind == .spelling })
        #expect(store.entries.allSatisfy { $0.scope == .both })
        #expect(store.entries.map(\.replacement) == ["Acme", "Murmr"])
    }

    @Test("entries stored before the kind existed keep the behaviour they had")
    func decodesWithoutKind() throws {
        let json = """
            [
              {"id":"F3F1A0C2-0000-4000-8000-000000000001","trigger":"",
               "replacement":"Acme","scope":"both"},
              {"id":"F3F1A0C2-0000-4000-8000-000000000002","trigger":"my email",
               "replacement":"a@b.com","scope":"dictation"}
            ]
            """
        let decoded = try JSONDecoder().decode(
            [DictionaryEntry].self, from: Data(json.utf8)
        )

        #expect(decoded[0].kind == .spelling)
        #expect(decoded[1].kind == .swap)
        #expect(decoded[1].scope == .dictation)
    }

    @Test("the words it seeded from are left on disk, not consumed")
    func doesNotDeleteLegacyKey() {
        let defaults = scratch("keep")
        defaults.set(["Acme"], forKey: "cleanup.customWords")

        _ = DictionaryStore(defaults: defaults)

        #expect(defaults.stringArray(forKey: "cleanup.customWords") == ["Acme"])
    }

    @Test("an edited list wins over the words it was seeded from")
    func storedListWins() {
        let defaults = scratch("stored")
        defaults.set(["Acme"], forKey: "cleanup.customWords")

        let first = DictionaryStore(defaults: defaults)
        first.remove(first.entries[0])
        first.add(
            kind: .swap, trigger: "my email", replacement: "a@b.com", scope: .dictation
        )

        let reopened = DictionaryStore(defaults: defaults)
        #expect(reopened.entries.count == 1)
        #expect(reopened.entries[0].trigger == "my email")
        #expect(reopened.entries[0].scope == .dictation)
    }

    @Test("nothing to seed from leaves an empty dictionary")
    func emptyStart() {
        #expect(DictionaryStore(defaults: scratch("empty")).entries.isEmpty)
    }

    @Test("entries are filtered by the job asking")
    func scopedReads() {
        let store = DictionaryStore(defaults: scratch("scope"))
        store.add(kind: .swap, trigger: "a", replacement: "1", scope: .dictation)
        store.add(kind: .swap, trigger: "b", replacement: "2", scope: .notetaker)
        store.add(kind: .swap, trigger: "c", replacement: "3", scope: .both)

        #expect(store.entries(usedIn: .dictation).map(\.replacement) == ["1", "3"])
        #expect(store.entries(usedIn: .notetaker).map(\.replacement) == ["2", "3"])
    }

    @Test("an entry with no replacement is never handed to a pipeline")
    func skipsUnusable() {
        let store = DictionaryStore(defaults: scratch("unusable"))
        store.add(kind: .swap, trigger: "a", replacement: "")

        #expect(store.entries.count == 1)
        #expect(store.entries(usedIn: .dictation).isEmpty)
    }
}
