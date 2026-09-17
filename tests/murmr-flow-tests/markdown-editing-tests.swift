import Foundation
import Testing

@testable import MurmrFlow

/// Turning a line into a heading, a bullet or a task, and back.
///
/// The toolbar is one button per kind and no "remove formatting" anywhere, which only
/// works because pressing a kind a line already is takes it off. That, and where the caret
/// lands afterwards, is what is easy to get quietly wrong.
@Suite("Markdown editing")
struct MarkdownEditingTests {

    private func at(_ location: Int, _ length: Int = 0) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test("a line says what it already is")
    func readsTheBlock() {
        #expect(MarkdownEdit.block(ofLine: "plain words") == .body)
        #expect(MarkdownEdit.block(ofLine: "# Title") == .heading(1))
        #expect(MarkdownEdit.block(ofLine: "### Topic") == .heading(3))
        #expect(MarkdownEdit.block(ofLine: "- a point") == .bullet)
        #expect(MarkdownEdit.block(ofLine: "- [ ] a task") == .task)
        #expect(MarkdownEdit.block(ofLine: "- [x] a done task") == .task)
        // A hash with no space is a word, not a heading.
        #expect(MarkdownEdit.block(ofLine: "#hashtag") == .body)
    }

    @Test("a heading replaces whatever the line was, rather than stacking on it")
    func replacesThePrefix() {
        let (text, _) = MarkdownEdit.setBlock(.heading(2), in: "- a point", selection: at(3))
        #expect(text == "## a point")

        let (again, _) = MarkdownEdit.setBlock(.heading(1), in: text, selection: at(3))
        #expect(again == "# a point")
    }

    @Test("pressing the kind a line already is takes it off")
    func togglesOff() {
        let (text, _) = MarkdownEdit.setBlock(.heading(2), in: "## a heading", selection: at(4))
        #expect(text == "a heading")
    }

    @Test("every line the selection touches changes, whole lines at a time")
    func appliesToEveryLine() {
        let source = "first\nsecond\nthird"
        // From inside "first" to inside "second".
        let (text, _) = MarkdownEdit.setBlock(.bullet, in: source, selection: at(2, 8))
        #expect(text == "- first\n- second\nthird")
    }

    @Test("the caret lands at the end of what changed")
    func caretFollows() {
        let (text, selection) = MarkdownEdit.setBlock(.task, in: "a task", selection: at(0))
        #expect(text == "- [ ] a task")
        #expect(selection == at((text as NSString).length))
    }

    @Test("bold wraps a selection, and unwraps it when pressed again")
    func wrapsAndUnwraps() {
        let (bold, selection) = MarkdownEdit.wrap("**", in: "one two", selection: at(4, 3))
        #expect(bold == "one **two**")
        #expect((bold as NSString).substring(with: selection) == "two")

        // Pressing it again with the same word selected takes it off.
        let (plain, _) = MarkdownEdit.wrap("**", in: bold, selection: selection)
        #expect(plain == "one two")
    }

    @Test("bold with nothing selected leaves the pair with the caret between them")
    func wrapsNothing() {
        let (text, selection) = MarkdownEdit.wrap("**", in: "one ", selection: at(4))
        #expect(text == "one ****")
        #expect(selection == at(6))
    }

    @Test("wrapping a whole marked word is read as unwrapping it")
    func unwrapsFromOutside() {
        let source = "a **word** here"
        // "word" selected, without the asterisks.
        let (text, _) = MarkdownEdit.wrap("**", in: source, selection: at(4, 4))
        #expect(text == "a word here")
    }

    @Test("an empty note takes a heading without falling over")
    func emptyText() {
        let (text, _) = MarkdownEdit.setBlock(.heading(1), in: "", selection: at(0))
        #expect(text == "# ")
    }

    @Test("a task keeps its tick when it is made a bullet and back")
    func stripsTheWholeTaskMarker() {
        let (bullet, _) = MarkdownEdit.setBlock(.bullet, in: "- [x] done thing", selection: at(8))
        #expect(bullet == "- done thing")
    }
}

/// Whether a button on the bar should be lit, which is the same question as whether
/// pressing it would take the formatting off.
@Suite("Markdown state")
struct MarkdownStateTests {

    private func at(_ location: Int, _ length: Int = 0) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test("a wrapped selection is wrapped, with or without the markers picked")
    func readsWrapping() {
        let text = "a **word** here"
        #expect(MarkdownEdit.isWrapped("**", in: text, selection: at(4, 4)))
        #expect(MarkdownEdit.isWrapped("**", in: text, selection: at(2, 8)))
        #expect(!MarkdownEdit.isWrapped("**", in: text, selection: at(11, 4)))
    }

    @Test("bold wins over italic, so one word never lights both")
    func boldBeatsItalic() {
        let text = "a **word** here"
        #expect(MarkdownEdit.isWrapped("**", in: text, selection: at(4, 4)))
        #expect(!MarkdownEdit.isWrapped("*", in: text, selection: at(4, 4)))

        let italic = "a *word* here"
        #expect(MarkdownEdit.isWrapped("*", in: italic, selection: at(3, 4)))
    }

    @Test("a selection at the very start is not read as wrapped from outside it")
    func noUnderflow() {
        #expect(!MarkdownEdit.isWrapped("**", in: "word", selection: at(0, 4)))
    }

    @Test("the menu offers every kind a line can be")
    func menuCoversWhatALineCanBe() {
        // It named lines it did not then list, so opening it showed nothing chosen.
        let named = MarkdownEdit.Block.allCases
        #expect(named.contains(.bullet))
        #expect(named.contains(.task))
        #expect(named.contains(.body))
        #expect(named.contains(.heading(1)))
    }
}

/// Finding the emphasis in a line, which is what decides where the markers are hidden and
/// where the weight goes.
@Suite("Markdown emphasis")
struct MarkdownEmphasisTests {

    private func spans(_ text: String) -> [MarkdownEdit.Emphasis] {
        MarkdownEdit.emphasis(in: text as NSString)
    }

    @Test("a bold run gives its markers and its words apart")
    func findsBold() throws {
        let text = "a **word** here"
        let found = try #require(spans(text).first)
        #expect(found.isBold)
        #expect((text as NSString).substring(with: found.inner) == "word")
        #expect((text as NSString).substring(with: found.opening) == "**")
        #expect((text as NSString).substring(with: found.closing) == "**")
    }

    @Test("the outer asterisk of a bold pair is never read as an italic one")
    func boldIsNotTwoItalics() {
        let found = spans("a **word** here")
        #expect(found.count == 1)
        #expect(found[0].isBold)
    }

    @Test("italics are found on their own")
    func findsItalic() throws {
        let text = "a *word* here"
        let found = try #require(spans(text).first)
        #expect(!found.isBold)
        #expect((text as NSString).substring(with: found.inner) == "word")
    }

    @Test("both kinds in one line, in the order they appear")
    func findsBoth() {
        let found = spans("**one** and *two*")
        #expect(found.count == 2)
        #expect(found[0].isBold)
        #expect(!found[1].isBold)
    }

    @Test("a marker has to sit against a word, so arithmetic is left alone")
    func ignoresLooseAsterisks() {
        // An editor that silently italicised this would be worse than one doing nothing.
        #expect(spans("4 * 3 * 2").isEmpty)
        #expect(spans("a ** b").isEmpty)
    }

    @Test("an unclosed marker is not emphasis")
    func ignoresUnclosed() {
        #expect(spans("**half a thought").isEmpty)
        #expect(spans("a * b").isEmpty)
    }

    @Test("emphasis does not run across a line break")
    func staysOnItsLine() {
        #expect(spans("*one\ntwo*").isEmpty)
    }
}
