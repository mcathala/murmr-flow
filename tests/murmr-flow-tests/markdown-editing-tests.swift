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

/// What the file holds and what the page holds, and getting between them.
///
/// The page never contains a marker, which is the whole point: there is then nothing to
/// hide, nothing to step the caret over, and nothing to half delete.
@Suite("Markdown round trip")
struct MarkdownRoundTripTests {

    @Test("the markers come out and the emphasis is recorded where the words are")
    func strips() {
        let (text, runs) = MarkdownEdit.stripEmphasis("a **word** here")
        #expect(text == "a word here")
        #expect(runs == [MarkdownEdit.EmphasisRun(range: NSRange(location: 2, length: 4), isBold: true)])
        #expect((text as NSString).substring(with: runs[0].range) == "word")
    }

    @Test("several runs on one line keep their places as the text shortens")
    func stripsSeveral() {
        let (text, runs) = MarkdownEdit.stripEmphasis("**one** and *two* end")
        #expect(text == "one and two end")
        #expect(runs.count == 2)
        #expect((text as NSString).substring(with: runs[0].range) == "one")
        #expect((text as NSString).substring(with: runs[1].range) == "two")
        #expect(runs[0].isBold)
        #expect(!runs[1].isBold)
    }

    @Test("and go back in, so the file is unchanged by a round trip")
    func roundTrips() {
        for source in [
            "a **word** here",
            "**one** and *two* end",
            "### A heading with **weight**\n- a bullet\n- [ ] a task",
            "nothing special at all",
            "",
        ] {
            let (text, runs) = MarkdownEdit.stripEmphasis(source)
            #expect(MarkdownEdit.markdown(text: text, runs: runs) == source, "\(source)")
        }
    }

    @Test("emphasis inside a heading survives, markers and all")
    func insideAHeading() {
        let (text, runs) = MarkdownEdit.stripEmphasis("### Where **we** are")
        // The block marker stays on the page; only the inline one comes out.
        #expect(text == "### Where we are")
        #expect(runs.count == 1)
        #expect(MarkdownEdit.markdown(text: text, runs: runs) == "### Where **we** are")
    }

    @Test("a run that no longer fits the text is dropped rather than crashing")
    func toleratesStaleRuns() {
        let stale = [MarkdownEdit.EmphasisRun(range: NSRange(location: 40, length: 4), isBold: true)]
        #expect(MarkdownEdit.markdown(text: "short", runs: stale) == "short")
    }

    @Test("a block change is a prefix edit, so everything else keeps its place")
    func editsOnlyThePrefix() {
        let (edits, selection) = MarkdownEdit.blockEdits(
            .heading(2), in: "one\ntwo", selection: NSRange(location: 5, length: 0)
        )
        #expect(edits.count == 1)
        #expect(edits[0].range == NSRange(location: 4, length: 0))
        #expect(edits[0].replacement == "## ")
        #expect(selection.location == 8)
    }

    @Test("every line the selection touches is edited, last first")
    func editsEveryLineBackwards() {
        let (edits, _) = MarkdownEdit.blockEdits(
            .bullet, in: "one\ntwo\nthree", selection: NSRange(location: 1, length: 5)
        )
        #expect(edits.count == 2)
        // Applying them in order must never invalidate the next one.
        #expect(edits[0].range.location > edits[1].range.location)
    }
}
