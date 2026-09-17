import AppKit
import Testing

@testable import MurmrFlow

/// The page itself: what it holds after reading a file, and what it gives back.
@MainActor
@Suite("Note page")
struct NoteEditorTests {

    @Test("the family's plain face is what body text gets")
    func picksTheRightFace() throws {
        _ = PanelSnapshotTests.fontsRegistered
        try #require(Theme.Face.isAvailable, "the bundled fonts did not register")

        // `NSFont(name:)` wants a font's own name, not a family's. Handed a family it
        // answers with whichever face it feels like — and for this one that is the bold.
        let byName = try #require(NSFont(name: Theme.Face.ui, size: 13))
        let weight = NSFontManager.shared.weight(of: byName)
        // Regular is 5 on AppKit's scale. Anything heavier and every word on the page is
        // set in it, which is how a note came out looking bold from end to end.
        #expect(weight == 5, "NSFont(name:) gave back \(byName.fontName), weight \(weight)")
    }

    @Test("a real note's own summary does not come out bold")
    func realNoteIsNotBold() throws {
        _ = PanelSnapshotTests.fontsRegistered
        let source = """
            ### Where the app stands

            - Speech-to-text runs on the machine with Parakeet, about 600 MB.
            - Dictation is close to Wispr Flow on the core loop.

            ### Why a transcript was not enough

            - Forty turns is a faithful record nobody rereads.
            """
        let view = page(source)
        let storage = try #require(view.textStorage)
        let bullet = (view.string as NSString).range(of: "Speech-to-text")
        let font = try #require(
            storage.attribute(.font, at: bullet.location, effectiveRange: nil) as? NSFont
        )
        let heading = storage.attribute(NoteTextView.headingKey, at: bullet.location, effectiveRange: nil)

        #expect(heading == nil, "the bullet is carrying a heading level")
        #expect(
            !NSFontManager.shared.traits(of: font).contains(.boldFontMask),
            "bullet font is \(font.fontName)"
        )
        #expect(view.currentMarkdown == source)
    }

    @Test("render the page, so it can be looked at")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }
        _ = PanelSnapshotTests.fontsRegistered

        let view = page("""
            ### Where the app stands

            - Speech-to-text runs on the machine with Parakeet, about 600 MB.
            - The style a dictation uses can follow the app in front.

            ### Why a transcript was not enough

            - Forty turns is a faithful record nobody rereads.
            - A note keeps every figure exactly, **including this one**.

            1. first
            2. second

            - [ ] a task
            - [x] a done task
            """)
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 420)
        view.layoutSubtreeIfNeeded()
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))

        let backing = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: backing)
        let png = try #require(backing.representation(using: .png, properties: [:]))
        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("note-page.png")
        )
    }

    @Test("Return at the end of a heading starts an ordinary line")
    func returnEndsAHeading() throws {
        let view = page("### A heading")
        let storage = try #require(view.textStorage)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        view.insertNewline(nil)
        view.insertText("a plain sentence", replacementRange: view.selectedRange())

        // Without this the next line is a heading, and so is the one after it, until the
        // whole note is set in 15-point bold.
        let plain = (view.string as NSString).range(of: "a plain sentence")
        #expect(
            storage.attribute(NoteTextView.headingKey, at: plain.location, effectiveRange: nil)
                == nil
        )
        #expect(view.currentMarkdown == "### A heading\na plain sentence")
    }

    @Test("a task is a box on the page and brackets in the file")
    func taskIsABox() {
        let source = "- [ ] send the runbook\n- [x] check the ceiling"
        let view = page(source)

        #expect(view.string == "\u{2610} send the runbook\n\u{2611} check the ceiling")
        #expect(!view.string.contains("["))
        #expect(view.currentMarkdown == source)
    }

    @Test("ticking a box on the page ticks the brackets in the file")
    func tickingWritesThrough() {
        let view = page("- [ ] first\n- [ ] second")
        view.toggleTask(1)

        #expect(view.string.contains("\u{2611} second"))
        #expect(view.currentMarkdown == "- [ ] first\n- [x] second")

        // And back.
        view.toggleTask(1)
        #expect(view.currentMarkdown == "- [ ] first\n- [ ] second")
    }

    @Test("a box in a note with headings and weight still round-trips")
    func boxAmongEverythingElse() {
        let source = "### Next steps\n- [x] send the **runbook**\n- a plain bullet"
        let view = page(source)
        #expect(view.currentMarkdown == source)
    }

    private func page(_ markdown: String) -> NoteTextView {
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        _ = view.layoutManager
        view.setMarkdown(markdown)
        return view
    }

    @Test("a heading is carried by its own line and no other")
    func headingStaysOnItsLine() throws {
        let view = page("### A heading\n- a bullet\n- another")
        let storage = try #require(view.textStorage)

        let level = storage.attribute(
            NoteTextView.headingKey, at: 0, effectiveRange: nil
        ) as? Int
        #expect(level == 3)

        // The bullet below it is not a heading.
        let bullet = (view.string as NSString).range(of: "a bullet")
        #expect(
            storage.attribute(
                NoteTextView.headingKey, at: bullet.location, effectiveRange: nil
            ) == nil
        )
    }

    @Test("the hashes are off the page and back in the file")
    func roundTrip() {
        let source = "### A heading\n- a bullet\n\n## Another\ntext"
        let view = page(source)
        #expect(!view.string.contains("#"))
        #expect(view.currentMarkdown == source)
    }

    @Test("body text keeps the body weight")
    func bodyIsNotBold() throws {
        let view = page("### A heading\n- a bullet")
        let storage = try #require(view.textStorage)
        let bullet = (view.string as NSString).range(of: "a bullet")

        let bodyFont = try #require(
            storage.attribute(.font, at: bullet.location, effectiveRange: nil) as? NSFont
        )
        let headingFont = try #require(
            storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        let bodySize = bodyFont.pointSize
        let headingSize = headingFont.pointSize

        #expect(!NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
        #expect(headingSize > bodySize)
    }
}
