import AppKit
import SwiftUI

/// The note, always editable, styled as you type.
///
/// **There is no edit mode.** Reading a note and fixing a wrong figure in it are the same
/// act, and a button between them is a question nobody wants to answer — which is what the
/// Edit / Done pair had become.
///
/// So the text is what is on disk, Markdown and all, with the markup *styled rather than
/// hidden*: a `###` line is set as a heading with its hashes dimmed, a `-` sits in the
/// margin, a `[ ]` reads as a box. Hiding the markers would mean guessing where they went
/// the moment somebody typed one, and the file has to stay something any other editor
/// opens — this is the same choice Obsidian and Bear make for the same reason.
///
/// `NSTextView` rather than `TextEditor`: SwiftUI's has no way to style ranges as they are
/// typed, and no way to answer a click on one particular character — which is how a box
/// gets ticked without leaving the page.
struct NoteTextEditor: NSViewRepresentable {

    @Binding var text: String
    /// What is selected, so the toolbar above knows which lines it is about to change and
    /// can put the caret back where it belongs afterwards.
    @Binding var selection: NSRange
    /// Called on every keystroke, debounced by the caller — the file is the only copy, so
    /// nothing waits for a button.
    var onEdited: (String) -> Void
    /// Whether the caret is in here. The bar above appears with it, because a bar for
    /// shaping text is noise on a page nobody is typing on.
    var onFocusChange: ((Bool) -> Void)?
    /// The task's position in the note, when its box was the thing clicked.
    var onToggleTask: ((Int) -> Void)?

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView()
        view.delegate = context.coordinator
        view.onToggleTask = { context.coordinator.parent.onToggleTask?($0) }
        view.onFocusChange = { context.coordinator.parent.onFocusChange?($0) }
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        // Smart quotes turn a Markdown quote into a curly one, and the file has to stay
        // something another editor reads the same way.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.layoutManager?.delegate = view
        view.string = text
        view.applyStyling()
        return view
    }

    func updateNSView(_ view: NoteTextView, context: Context) {
        view.onToggleTask = { context.coordinator.parent.onToggleTask?($0) }
        view.onFocusChange = { context.coordinator.parent.onFocusChange?($0) }
        context.coordinator.parent = self

        // Only when the text genuinely differs — assigning it back mid-typing would move
        // the insertion point to the end on every keystroke.
        if view.string != text {
            view.string = text
            view.applyStyling()
        }
        let length = (view.string as NSString).length
        let wanted = NSRange(
            location: min(selection.location, length),
            length: min(selection.length, max(length - min(selection.location, length), 0))
        )
        if view.selectedRange() != wanted {
            view.setSelectedRange(wanted)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor

        init(_ parent: NoteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NoteTextView else { return }
            view.applyStyling()
            parent.selection = view.selectedRange()
            parent.text = view.string
            parent.onEdited(view.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NoteTextView else { return }
            // Markers are shown on the line the caret is on, so moving the caret is a
            // reason to lay the text out again.
            view.applyStyling()
            guard parent.selection != view.selectedRange() else { return }
            parent.selection = view.selectedRange()
        }
    }
}

/// The text view itself: styling, a click that ticks a box, and a height that fits.
final class NoteTextView: NSTextView, @MainActor NSLayoutManagerDelegate {

    var onToggleTask: ((Int) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// Character ranges that are in the text but not drawn: the `**` around a bold word,
    /// on every line except the one being edited.
    private var hiddenRanges: [NSRange] = []

    /// Glyphs are generated once and cached, so a range that has just become hidden — or
    /// just stopped being — has to be asked for again.
    private func setHidden(_ ranges: [NSRange]) {
        guard ranges != hiddenRanges else { return }
        hiddenRanges = ranges
        guard let manager = layoutManager else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        manager.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
        manager.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
        invalidateIntrinsicContentSize()
    }

    /// Where the markers are dropped on the floor.
    ///
    /// `.null` is the layout manager's own way of saying "this character takes no glyph
    /// and no width". The alternative — deleting the markers from the text and putting
    /// them back on save — would mean the file and the page holding different strings,
    /// and every offset in this file would have to be translated between them.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }

        var changed = false
        var updated = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        for offset in 0..<glyphRange.length {
            let index = characterIndexes[offset]
            if hiddenRanges.contains(where: { NSLocationInRange(index, $0) }) {
                updated[offset] = .null
                changed = true
            } else {
                updated[offset] = properties[offset]
            }
        }
        guard changed else { return 0 }

        updated.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(
                glyphs,
                properties: buffer.baseAddress!,
                characterIndexes: characterIndexes,
                font: font,
                forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// Where the box sits on a task line: `- [ ] `.
    private static let boxRange = 2..<5

    /// Sized to its content rather than scrolling on its own, so the pane's one scroll
    /// bar covers the note, what you typed and the transcript together.
    override var intrinsicContentSize: NSSize {
        guard let manager = layoutManager, let container = textContainer else {
            return super.intrinsicContentSize
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        return NSSize(width: NSView.noIntrinsicMetric, height: max(used.height, 120))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    /// A click on a task's box ticks it, without putting the caret in the middle of the
    /// markup. Anywhere else is an ordinary click and places the caret.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = string as NSString

        guard index <= text.length else {
            super.mouseDown(with: event)
            return
        }
        let lineRange = text.lineRange(for: NSRange(location: min(index, max(text.length - 1, 0)), length: 0))
        let line = text.substring(with: lineRange)
        let column = index - lineRange.location

        guard line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] "),
              Self.boxRange.contains(column)
        else {
            super.mouseDown(with: event)
            return
        }

        // Count the tasks above this one; the file ticks by position.
        var position = 0
        var scanned = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: lineRange.location), options: [.byLines]) { substring, _, _, _ in
            guard let substring else { return }
            if substring.hasPrefix("- [ ] ") || substring.hasPrefix("- [x] ") { scanned += 1 }
        }
        position = scanned
        onToggleTask?(position)
    }

    /// Markdown styled where it stands. Applied whole on every change: a note is a page,
    /// not a document, and the cost does not register against a keystroke.
    func applyStyling() {
        guard let storage = textStorage else { return }
        let text = string as NSString
        let whole = NSRange(location: 0, length: text.length)

        let body = NSFont(name: Theme.Face.ui, size: 13) ?? .systemFont(ofSize: 13)
        let mono = NSFont(name: Theme.Face.data, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)

        /// One size per level, so the outline of a note can be read at a glance rather
        /// than counted in hashes. Anything past three is the same as three: a note with
        /// four levels of heading has a different problem.
        func headingFont(_ level: Int) -> NSFont {
            let size: CGFloat = switch level {
            case 1: 21
            case 2: 17
            default: 15
            }
            let face = NSFont(name: Theme.Face.ui, size: size) ?? .systemFont(ofSize: size)
            return NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4

        storage.beginEditing()
        storage.setAttributes(
            [
                .font: body,
                .foregroundColor: NSColor(Theme.Palette.text),
                .paragraphStyle: paragraph,
            ],
            range: whole
        )

        text.enumerateSubstrings(in: whole, options: [.byLines]) { substring, range, _, _ in
            guard let line = substring else { return }

            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                storage.addAttribute(.font, value: headingFont(hashes), range: range)
                // The hashes stay — the file is Markdown — but they recede, so the line
                // reads as a heading rather than as a heading with punctuation on it.
                storage.addAttributes(
                    [.foregroundColor: NSColor(Theme.Palette.faint), .font: mono],
                    range: NSRange(location: range.location, length: min(hashes + 1, range.length))
                )
                return
            }

            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                let done = line.hasPrefix("- [x] ")
                storage.addAttributes(
                    [
                        .font: mono,
                        .foregroundColor: NSColor(
                            done ? Theme.Palette.gold : Theme.Palette.faint
                        ),
                    ],
                    range: NSRange(location: range.location, length: min(6, range.length))
                )
                if done, range.length > 6 {
                    // Struck through as well as dimmed. Colour alone reads as "less
                    // important"; a line through it reads as "done", which is the claim.
                    storage.addAttributes(
                        [
                            .foregroundColor: NSColor(Theme.Palette.faint),
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: NSColor(Theme.Palette.faint),
                        ],
                        range: NSRange(location: range.location + 6, length: range.length - 6)
                    )
                }
                return
            }

            if line.hasPrefix("- ") || line.hasPrefix("• ") {
                storage.addAttributes(
                    [.foregroundColor: NSColor(Theme.Palette.faint), .font: mono],
                    range: NSRange(location: range.location, length: min(2, range.length))
                )
            }
        }

        // Inline emphasis: the weight goes on, the asterisks come off.
        //
        // The line the caret is on keeps its markers. They are the only way to take a
        // bold off by hand, and text that silently rearranges itself as the caret arrives
        // is worse than a pair of visible asterisks.
        let caretLine = text.length > 0
            ? text.lineRange(for: NSRange(location: min(selectedRange().location, text.length - 1), length: 0))
            : NSRange(location: 0, length: 0)

        var hide: [NSRange] = []
        for span in MarkdownEdit.emphasis(in: text) {
            let existing = span.inner.length > 0
                ? storage.attribute(.font, at: span.inner.location, effectiveRange: nil) as? NSFont
                : nil
            let base = existing ?? body
            let trait: NSFontTraitMask = span.isBold ? .boldFontMask : .italicFontMask
            storage.addAttribute(
                .font,
                value: NSFontManager.shared.convert(base, toHaveTrait: trait),
                range: span.inner
            )
            guard !isEditing || NSIntersectionRange(span.whole, caretLine).length == 0 else { continue }
            hide.append(span.opening)
            hide.append(span.closing)
        }

        storage.endEditing()
        setHidden(hide)
        invalidateIntrinsicContentSize()
    }

    /// Whether the caret is in this view. Markers stay hidden on a page nobody is typing
    /// on, so a note reads as a note until the moment it is being written.
    private var isEditing: Bool {
        window?.firstResponder === self
    }
}
