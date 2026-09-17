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

/// What the file holds and what the page holds, and getting between them.
///
/// The page never contains a marker, which is the whole point: there is then nothing to
/// hide, nothing to step the caret over, and nothing to half delete. So the one thing
/// these have to prove is that a file survives being opened and written back.
@Suite("Markdown round trip")
struct MarkdownRoundTripTests {

    private func style(_ text: String, _ word: String) -> MarkdownEdit.EmphasisStyle {
        let (stripped, runs) = MarkdownEdit.stripEmphasis(text)
        let range = (stripped as NSString).range(of: word)
        return runs.first { NSIntersectionRange($0.range, range).length > 0 }?.style ?? []
    }

    @Test("the markers come out and the style is recorded where the words are")
    func strips() {
        let (text, runs) = MarkdownEdit.stripEmphasis("a **word** here")
        #expect(text == "a word here")
        #expect(runs.count == 1)
        #expect(runs[0].style == .bold)
        #expect((text as NSString).substring(with: runs[0].range) == "word")
    }

    @Test("all three styles are read, together and apart")
    func readsEveryStyle() {
        #expect(style("a **b** c", "b") == .bold)
        #expect(style("a *b* c", "b") == .italic)
        #expect(style("a <u>b</u> c", "b") == .underline)
        #expect(style("a ***b*** c", "b") == [.bold, .italic])
        #expect(style("a <u>**b**</u> c", "b") == [.bold, .underline])
        #expect(style("a <u>***b***</u> c", "b") == [.bold, .italic, .underline])
    }

    @Test("the file is unchanged by a round trip")
    func roundTrips() {
        for source in [
            "a **word** here",
            "**one** and *two* end",
            "a ***both*** here",
            "a <u>line</u> under",
            "a <u>***everything***</u> at once",
            "### A heading with **weight**\n- a bullet\n- [ ] a task",
            "nothing special at all",
            "",
        ] {
            let (text, runs) = MarkdownEdit.stripEmphasis(source)
            #expect(MarkdownEdit.markdown(text: text, runs: runs) == source, "\(source)")
        }
    }

    @Test("a marker has to sit against a word, so arithmetic is left alone")
    func ignoresLooseMarkers() {
        // An editor that silently italicised this would be worse than one doing nothing.
        #expect(MarkdownEdit.stripEmphasis("4 * 3 * 2").runs.isEmpty)
        #expect(MarkdownEdit.stripEmphasis("**half a thought").runs.isEmpty)
        #expect(MarkdownEdit.stripEmphasis("a * b").runs.isEmpty)
    }

    @Test("emphasis does not run across a line break")
    func staysOnItsLine() {
        #expect(MarkdownEdit.stripEmphasis("*one\ntwo*").runs.isEmpty)
    }

    @Test("styles that touch but differ stay two runs")
    func coalescesOnlyWhatMatches() {
        let (text, runs) = MarkdownEdit.stripEmphasis("**a***b*")
        #expect(text == "ab")
        #expect(runs.count == 2)
        #expect(runs[0].style == .bold)
        #expect(runs[1].style == .italic)
    }

    @Test("emphasis inside a heading survives, block marker and all")
    func insideAHeading() {
        let (text, runs) = MarkdownEdit.stripEmphasis("### Where **we** are")
        // The block marker stays on the page; only the inline one comes out.
        #expect(text == "### Where we are")
        #expect(runs.count == 1)
        #expect(MarkdownEdit.markdown(text: text, runs: runs) == "### Where **we** are")
    }

    @Test("a run that no longer fits the text is dropped rather than crashing")
    func toleratesStaleRuns() {
        let stale = [
            MarkdownEdit.EmphasisRun(range: NSRange(location: 40, length: 4), style: .bold)
        ]
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
