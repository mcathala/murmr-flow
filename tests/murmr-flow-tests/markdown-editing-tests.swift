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
            .bullet, in: "one\ntwo", selection: NSRange(location: 5, length: 0)
        )
        #expect(edits.count == 1)
        #expect(edits[0].range == NSRange(location: 4, length: 0))
        #expect(edits[0].replacement == "- ")
        #expect(selection.location == 7)
    }

    @Test("a heading changes no text at all — it is a property of the line")
    func headingIsNotAPrefix() {
        let (edits, _) = MarkdownEdit.blockEdits(
            .heading(2), in: "one\ntwo", selection: NSRange(location: 5, length: 0)
        )
        #expect(edits.isEmpty)
    }

    @Test("a numbered list counts rather than repeating itself")
    func numbersTheLines() {
        let (edits, _) = MarkdownEdit.blockEdits(
            .numbered, in: "one\ntwo\nthree", selection: NSRange(location: 0, length: 12)
        )
        // Applied last line first, so the numbers read 1, 2, 3 down the page.
        #expect(edits.map(\.replacement) == ["3. ", "2. ", "1. "])
    }

    @Test("a numbered line is recognised however long the number is")
    func readsAnyNumber() {
        #expect(MarkdownEdit.block(ofLine: "1. first") == .numbered)
        #expect(MarkdownEdit.block(ofLine: "12. twelfth") == .numbered)
        #expect(MarkdownEdit.stripPrefix("12. twelfth") == "twelfth")
        // A year is not a list.
        #expect(MarkdownEdit.block(ofLine: "2026 was busy") == .body)
    }

    @Test("headings come off the page and go back on the file")
    func headingsRoundTrip() {
        for source in [
            "# Title\n\nsome words",
            "### Where we are\n- a bullet",
            "no headings here",
            "## One\n## Two",
        ] {
            let (text, headings) = MarkdownEdit.stripHeadings(source)
            #expect(!text.contains("#"), "\(source)")
            let (stripped, emphasis) = MarkdownEdit.stripEmphasis(text)
            #expect(
                MarkdownEdit.markdown(text: stripped, emphasis: emphasis, headings: headings)
                    == source,
                "\(source)"
            )
        }
    }

    @Test("a heading with weight in it survives both passes")
    func headingWithEmphasis() {
        let source = "### Where **we** are"
        let (text, headings) = MarkdownEdit.stripHeadings(source)
        #expect(text == "Where **we** are")
        let (stripped, emphasis) = MarkdownEdit.stripEmphasis(text)
        #expect(stripped == "Where we are")
        #expect(
            MarkdownEdit.markdown(text: stripped, emphasis: emphasis, headings: headings) == source
        )
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

/// The ways a style applied on the page could fail to survive the file.
///
/// Everything here starts from the page — a range someone selected and a button they
/// pressed — rather than from Markdown, because that is the direction that loses things:
/// the file is written from it and read back, and anything the writing cannot express is
/// gone by the next launch.
@Suite("Emphasis written from the page")
struct EmphasisWritingTests {

    private func round(_ text: String, _ runs: [MarkdownEdit.EmphasisRun]) -> (String, [MarkdownEdit.EmphasisRun]) {
        let file = MarkdownEdit.markdown(text: text, runs: runs)
        let (back, read) = MarkdownEdit.stripEmphasis(file)
        return (back, read)
    }

    @Test("a style applied across two lines survives")
    func acrossALineBreak() {
        // Select two lines, press bold. Nothing stops anyone doing this.
        let runs = [MarkdownEdit.EmphasisRun(range: NSRange(location: 0, length: 3), style: .bold)]
        let (text, read) = round("a\nb", runs)
        #expect(text == "a\nb")
        #expect(read.count == 2)
        #expect(read.allSatisfy { $0.style == .bold })
    }

    @Test("a style with a space at its edge survives")
    func trailingSpace() {
        // Double-clicking a word and dragging one character further is enough.
        let runs = [MarkdownEdit.EmphasisRun(range: NSRange(location: 0, length: 5), style: .bold)]
        let (text, read) = round("word here", runs)
        #expect(text == "word here")
        #expect(read.first?.style == .bold)
        #expect((text as NSString).substring(with: read[0].range) == "word")
    }

    @Test("a style on nothing but spaces is dropped rather than written")
    func onlySpaces() {
        let runs = [MarkdownEdit.EmphasisRun(range: NSRange(location: 1, length: 1), style: .bold)]
        #expect(MarkdownEdit.markdown(text: "a b", runs: runs) == "a b")
    }

    @Test("an emoji is not cut in half on the way through")
    func keepsEmoji() {
        // The text is walked to take the markers out, and a two-unit character split down
        // the middle comes back as a replacement glyph.
        let (text, _) = MarkdownEdit.stripEmphasis("a **🎙 note** here")
        #expect(text == "a 🎙 note here")
    }

    @Test("styles that meet across a line keep to their own lines")
    func runsAreSplitPerLine() {
        let runs = [MarkdownEdit.EmphasisRun(range: NSRange(location: 0, length: 7), style: [.bold, .underline])]
        let (text, read) = round("one\ntwo", runs)
        #expect(text == "one\ntwo")
        #expect(read.count == 2)
        #expect(read.allSatisfy { $0.style == [.bold, .underline] })
    }
}

/// Shapes the reader cannot take apart. None of them may lose a character.
@Suite("Emphasis it cannot read")
struct EmphasisLimitTests {

    @Test("nested emphasis is read as far as it can be, and loses nothing")
    func nested() {
        let source = "**a *b* c**"
        let (text, runs) = MarkdownEdit.stripEmphasis(source)
        // The inner one is understood; the outer markers stay as text.
        #expect(runs.count == 1)
        #expect(runs[0].style == .italic)
        #expect((text as NSString).substring(with: runs[0].range) == "b")
        // The file is what matters, and it comes back exactly.
        #expect(MarkdownEdit.markdown(text: text, runs: runs) == source)
    }

    @Test("an unclosed tag is text, not an underline to the end of the note")
    func unclosedTag() {
        let source = "a <u>start and no finish"
        let (text, runs) = MarkdownEdit.stripEmphasis(source)
        #expect(runs.isEmpty)
        #expect(text == source)
    }

    @Test("markers with nothing between them are left alone")
    func emptyMarkers() {
        for source in ["****", "**", "<u></u>", "* *"] {
            let (text, runs) = MarkdownEdit.stripEmphasis(source)
            #expect(runs.isEmpty, "\(source)")
            #expect(text == source, "\(source)")
        }
    }

    @Test("a note of nothing but emoji comes back whole")
    func emojiOnly() {
        let source = "🎙 **🎧 notes** 📝"
        let (text, runs) = MarkdownEdit.stripEmphasis(source)
        #expect(text == "🎙 🎧 notes 📝")
        #expect((text as NSString).substring(with: runs[0].range) == "🎧 notes")
        #expect(MarkdownEdit.markdown(text: text, runs: runs) == source)
    }
}
