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

    /// The file's own text, markers and all. The page never holds this — it holds the
    /// words with weight on them — but this is what goes in and what comes back.
    @Binding var markdown: String
    /// The text as it is on the page, with no markers in it, for the things that reason
    /// about lines: which kind the caret's line is, and whether the page is empty.
    @Binding var displayText: String
    /// What is selected, so the toolbar above knows which lines it is about to change and
    /// can put the caret back where it belongs afterwards.
    @Binding var selection: NSRange
    /// Called on every keystroke with the file's text, debounced by the caller — the file
    /// is the only copy, so nothing waits for a button.
    var onEdited: (String) -> Void
    /// Handed the view, so the bar above can act on the selection.
    var commands: NoteEditorCommands
    /// Whether the caret is in here. The bar above appears with it, because a bar for
    /// shaping text is noise on a page nobody is typing on.
    var onFocusChange: ((Bool) -> Void)?
    /// The task's position in the note, when its box was the thing clicked.
    var onToggleTask: ((Int) -> Void)?

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView()
        // Asking for the layout manager is what puts this view on TextKit 1, and it has
        // to happen before anything measures it. The height comes from that manager's
        // used rect; on TextKit 2 it is nil, the view falls back to a default size, and a
        // page that is barely any points tall is a page you cannot click into.
        _ = view.layoutManager
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
        view.setMarkdown(markdown)
        commands.view = view
        return view
    }

    func updateNSView(_ view: NoteTextView, context: Context) {
        view.onToggleTask = { context.coordinator.parent.onToggleTask?($0) }
        view.onFocusChange = { context.coordinator.parent.onFocusChange?($0) }
        context.coordinator.parent = self

        commands.view = view
        // Only when the file's text genuinely differs — assigning it back mid-typing would
        // move the insertion point to the end on every keystroke.
        if view.currentMarkdown != markdown {
            view.setMarkdown(markdown)
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

    /// The way the bar above reaches the page.
    ///
    /// Bold is no longer something that can be done to a string — it is an attribute on a
    /// range of the page — so the controls have to speak to the view rather than hand back
    /// new text.
    @MainActor
    final class NoteEditorCommands {
        weak var view: NoteTextView?

        func toggleEmphasis(bold: Bool) { view?.toggleEmphasis(bold: bold) }
        func setBlock(_ block: MarkdownEdit.Block) { view?.setBlock(block) }
        func isOn(bold: Bool) -> Bool { view?.hasEmphasis(bold: bold) ?? false }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor

        init(_ parent: NoteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NoteTextView else { return }
            view.applyStyling()
            parent.selection = view.selectedRange()
            parent.displayText = view.string
            let markdown = view.currentMarkdown
            parent.markdown = markdown
            parent.onEdited(markdown)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NoteTextView else { return }
            guard parent.selection != view.selectedRange() else { return }
            parent.selection = view.selectedRange()
        }
    }
}

/// The text view itself: styling, a click that ticks a box, and a height that fits.
final class NoteTextView: NSTextView {

    var onToggleTask: ((Int) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// Where the box sits on a task line: `- [ ] `.
    private static let boxRange = 2..<5

    /// Sized to its content rather than scrolling on its own, so the pane's one scroll
    /// bar covers the note, what you typed and the transcript together.
    override var intrinsicContentSize: NSSize {
        guard let manager = layoutManager, let container = textContainer else {
            // Never `super`: an unmeasurable page must still be tall enough to click into.
            return NSSize(width: NSView.noIntrinsicMetric, height: 240)
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        // A floor, so an empty note is a page rather than a line — there has to be
        // somewhere to click before there is anything to click on.
        return NSSize(width: NSView.noIntrinsicMetric, height: max(used.height, 240))
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
        // Everything but the emphasis, which is ours and is the one attribute that
        // carries meaning rather than appearance.
        storage.addAttributes(
            [
                .font: body,
                .foregroundColor: NSColor(Theme.Palette.text),
                .paragraphStyle: paragraph,
            ],
            range: whole
        )
        storage.removeAttribute(.strikethroughStyle, range: whole)

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

        // Emphasis last, over whatever font the line already earned, so bold inside a
        // heading is a bold heading rather than body text that happens to be bold.
        storage.enumerateAttribute(Self.emphasisKey, in: whole, options: []) { value, range, _ in
            guard let kind = value as? String, range.length > 0 else { return }
            let base = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                ?? body
            storage.addAttribute(
                .font,
                value: NSFontManager.shared.convert(
                    base, toHaveTrait: kind == "bold" ? .boldFontMask : .italicFontMask
                ),
                range: range
            )
        }

        storage.endEditing()
        invalidateIntrinsicContentSize()
    }

    // MARK: - Emphasis, as weight rather than characters

    /// Bold and italic ride on the text as an attribute of our own.
    ///
    /// Not the font, which `applyStyling` rewrites from scratch on every keystroke and
    /// would wipe. This survives that, and the font is computed from it.
    static let emphasisKey = NSAttributedString.Key("app.murmr.emphasis")

    /// Replaces everything with the file's text, markers taken out and turned into weight.
    func setMarkdown(_ markdown: String) {
        let (text, runs) = MarkdownEdit.stripEmphasis(markdown)
        string = text
        guard let storage = textStorage else { return }
        storage.beginEditing()
        for run in runs where run.range.location + run.range.length <= (text as NSString).length {
            storage.addAttribute(
                Self.emphasisKey, value: run.isBold ? "bold" : "italic", range: run.range
            )
        }
        storage.endEditing()
        applyStyling()
    }

    /// What the file should hold: the words, with the markers put back.
    var currentMarkdown: String {
        MarkdownEdit.markdown(text: string, runs: emphasisRuns())
    }

    private func emphasisRuns() -> [MarkdownEdit.EmphasisRun] {
        guard let storage = textStorage else { return [] }
        var runs: [MarkdownEdit.EmphasisRun] = []
        storage.enumerateAttribute(
            Self.emphasisKey,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, _ in
            guard let kind = value as? String else { return }
            runs.append(MarkdownEdit.EmphasisRun(range: range, isBold: kind == "bold"))
        }
        return runs
    }

    /// Whether the whole selection already carries this weight, which is what lights the
    /// button and what makes pressing it take the weight off.
    func hasEmphasis(bold: Bool) -> Bool {
        guard let storage = textStorage else { return false }
        let range = selectedRange()
        let wanted = bold ? "bold" : "italic"
        guard range.length > 0 else {
            let index = min(max(range.location - 1, 0), max(storage.length - 1, 0))
            guard storage.length > 0 else { return false }
            return storage.attribute(Self.emphasisKey, at: index, effectiveRange: nil) as? String == wanted
        }
        var all = true
        storage.enumerateAttribute(Self.emphasisKey, in: range, options: []) { value, _, stop in
            if value as? String != wanted {
                all = false
                stop.pointee = true
            }
        }
        return all
    }

    /// Puts the weight on the selection, or takes it off when it is already there.
    func toggleEmphasis(bold: Bool) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        let on = !hasEmphasis(bold: bold)

        storage.beginEditing()
        storage.removeAttribute(Self.emphasisKey, range: range)
        if on {
            storage.addAttribute(Self.emphasisKey, value: bold ? "bold" : "italic", range: range)
        }
        storage.endEditing()
        applyStyling()
        didChangeText()
    }

    /// Makes the lines the selection touches a heading, a bullet, a task or plain text.
    ///
    /// Prefix edits rather than a new string, so every character that is not part of a
    /// marker — and the weight riding on it — stays exactly where it was.
    func setBlock(_ block: MarkdownEdit.Block) {
        guard let storage = textStorage else { return }
        let (edits, selection) = MarkdownEdit.blockEdits(
            block, in: string, selection: selectedRange()
        )
        guard !edits.isEmpty else { return }

        storage.beginEditing()
        for edit in edits where edit.range.location + edit.range.length <= storage.length {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        storage.endEditing()
        applyStyling()
        setSelectedRange(
            NSRange(location: min(selection.location, (string as NSString).length), length: 0)
        )
        didChangeText()
    }
}
