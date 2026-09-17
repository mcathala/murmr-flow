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

        func toggleEmphasis(_ style: MarkdownEdit.EmphasisStyle) {
            view?.toggleEmphasis(style)
        }

        /// One door for every kind of line, so the caller never has to know that a heading
        /// is an attribute and a bullet is two characters.
        func setBlock(_ block: MarkdownEdit.Block) {
            guard let view else { return }
            if case .heading(let level) = block {
                // Pressing the level a line already is takes it off, the same as the rest.
                view.setHeading(view.headingLevel() == level ? nil : level)
                return
            }
            view.setHeading(nil)
            view.setBlock(block)
        }

        /// What the caret's line already is.
        func block(in text: String, at selection: NSRange) -> MarkdownEdit.Block {
            if let level = view?.headingLevel() { return .heading(level) }
            return MarkdownEdit.block(of: text as NSString, at: selection)
        }
        func isOn(_ style: MarkdownEdit.EmphasisStyle) -> Bool {
            view?.hasEmphasis(style) ?? false
        }
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

    /// Whether the caret is in here. The bar above appears with it, because a bar for
    /// shaping text is noise on a page nobody is typing on.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    /// Asks the window for the caret, out loud.
    ///
    /// A click on a text view normally does this by itself. Inside a SwiftUI window it
    /// does not always arrive: the click lands here, `super` handles the selection, and
    /// the window never makes this view first responder — so the caret blinks nowhere and
    /// the keyboard goes to whatever had it before. Asking plainly costs nothing when it
    /// was going to happen anyway.
    private func takeFocus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
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
            takeFocus()
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
        storage.removeAttribute(.obliqueness, range: whole)
        storage.removeAttribute(.underlineStyle, range: whole)

        text.enumerateSubstrings(in: whole, options: [.byLines]) { substring, range, _, _ in
            guard let line = substring else { return }


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
                return
            }

            if let digits = MarkdownEdit.numberPrefix(of: line) {
                storage.addAttributes(
                    [.foregroundColor: NSColor(Theme.Palette.faint), .font: mono],
                    range: NSRange(location: range.location, length: min(digits, range.length))
                )
            }
        }

        // Headings, from the line's own level rather than from any character in it. The
        // `#`s are not here to be counted — that is the point of them not being here.
        storage.enumerateAttribute(Self.headingKey, in: whole, options: []) { value, range, _ in
            guard let level = value as? Int, range.length > 0 else { return }
            storage.addAttribute(.font, value: headingFont(level), range: range)
        }

        // Emphasis last, over whatever font the line already earned, so bold inside a
        // heading is a bold heading rather than body text that happens to be bold.
        storage.enumerateAttribute(Self.emphasisKey, in: whole, options: []) { value, range, _ in
            let style = MarkdownEdit.EmphasisStyle(rawValue: (value as? Int) ?? 0)
            guard !style.isEmpty, range.length > 0 else { return }
            var font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                ?? body

            if style.contains(.bold) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if style.contains(.italic) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                // Mona Sans ships upright only — see `resources/fonts` — so asking the
                // font manager for an italic hands the same face back and the word stays
                // plain. Slanting it is how AppKit has always faked an italic that is not
                // drawn, and it beats a control that lights up and changes nothing.
                if !NSFontManager.shared.traits(of: font).contains(.italicFontMask) {
                    storage.addAttribute(.obliqueness, value: 0.2, range: range)
                }
            }
            storage.addAttribute(.font, value: font, range: range)

            if style.contains(.underline) {
                storage.addAttribute(
                    .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range
                )
            }
        }

        storage.endEditing()
        invalidateIntrinsicContentSize()
    }

    // MARK: - Emphasis, as weight rather than characters

    /// Weight, slant and underline ride on the text as an attribute of our own.
    ///
    /// Not the font, which `applyStyling` rewrites from scratch on every keystroke and
    /// would wipe. This survives that, and the look is computed from it.
    static let emphasisKey = NSAttributedString.Key("app.murmr.emphasis")

    /// A heading's level, on every character of the line.
    ///
    /// The `#`s are not on the page — you asked for them gone — so the line has to carry
    /// its level some other way, and that way is the same one the weight uses. Per
    /// character rather than per paragraph because `NSTextStorage` has no paragraphs: a
    /// line is the characters between two newlines and nothing more.
    static let headingKey = NSAttributedString.Key("app.murmr.heading")

    /// Replaces everything with the file's text, markers taken out and turned into weight.
    func setMarkdown(_ markdown: String) {
        // Headings first: their markers are whole-line, and taking them out moves every
        // offset the emphasis pass is about to work in.
        let (withoutHeadings, headings) = MarkdownEdit.stripHeadings(markdown)
        let (text, runs) = MarkdownEdit.stripEmphasis(withoutHeadings)
        string = text
        guard let storage = textStorage else { return }
        let length = (text as NSString).length

        storage.beginEditing()
        for run in runs where run.range.location + run.range.length <= length {
            storage.addAttribute(
                Self.emphasisKey, value: run.style.rawValue, range: run.range
            )
        }
        for heading in headings where heading.range.location <= length {
            // The whole line, so the level survives typing at either end of it.
            let line = (text as NSString).lineRange(
                for: NSRange(location: min(heading.range.location, max(length - 1, 0)), length: 0)
            )
            storage.addAttribute(Self.headingKey, value: heading.level, range: line)
        }
        storage.endEditing()
        applyStyling()
    }

    /// What the file should hold: the words, with the markers put back.
    var currentMarkdown: String {
        MarkdownEdit.markdown(
            text: string, emphasis: emphasisRuns(), headings: headingRuns()
        )
    }

    /// Which lines are headings, as the file needs them: one entry per line, anchored to
    /// where that line starts.
    private func headingRuns() -> [MarkdownEdit.HeadingRun] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let text = string as NSString
        var runs: [MarkdownEdit.HeadingRun] = []
        storage.enumerateAttribute(
            Self.headingKey, in: NSRange(location: 0, length: storage.length), options: []
        ) { value, range, _ in
            guard let level = value as? Int, range.length > 0 else { return }
            // An attribute can span several lines once someone has pressed Return inside
            // one; each line is its own heading in the file.
            var index = range.location
            while index < range.location + range.length {
                let line = text.lineRange(for: NSRange(location: index, length: 0))
                runs.append(MarkdownEdit.HeadingRun(range: line, level: level))
                index = line.location + max(line.length, 1)
            }
        }
        return runs
    }

    /// The heading level of the line the caret is on, or nil when it is not one.
    func headingLevel() -> Int? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = min(max(selectedRange().location, 0), storage.length - 1)
        return storage.attribute(Self.headingKey, at: index, effectiveRange: nil) as? Int
    }

    /// Return ends a heading.
    ///
    /// The level rides on the characters of the line, and a new character takes the
    /// attributes of the one before it — so pressing Return at the end of a heading made
    /// the next line a heading, and the one after that, until the whole note was set in
    /// 15-point bold. Every editor behaves this way; ours has to say so.
    override func insertNewline(_ sender: Any?) {
        super.insertNewline(sender)
        guard let storage = textStorage, storage.length > 0 else { return }

        let caret = min(selectedRange().location, storage.length - 1)
        let line = (string as NSString).lineRange(for: NSRange(location: caret, length: 0))
        guard storage.attribute(Self.headingKey, at: caret, effectiveRange: nil) != nil else {
            return
        }
        storage.removeAttribute(Self.headingKey, range: line)
        typingAttributes[Self.headingKey] = nil
        applyStyling()
        didChangeText()
    }

    /// Makes the caret's lines a heading, or plain text when they already are that level.
    func setHeading(_ level: Int?) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let text = string as NSString
        let lines = MarkdownEdit.lineRange(in: text, covering: selectedRange())
        guard lines.length > 0 else { return }

        guard shouldChangeText(in: lines, replacementString: nil) else { return }
        storage.beginEditing()
        storage.removeAttribute(Self.headingKey, range: lines)
        if let level {
            storage.addAttribute(Self.headingKey, value: level, range: lines)
        }
        storage.endEditing()
        applyStyling()
        didChangeText()
    }

    private func emphasisRuns() -> [MarkdownEdit.EmphasisRun] {
        guard let storage = textStorage else { return [] }
        var runs: [MarkdownEdit.EmphasisRun] = []
        storage.enumerateAttribute(
            Self.emphasisKey,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, _ in
            guard let raw = value as? Int, raw != 0 else { return }
            runs.append(
                MarkdownEdit.EmphasisRun(
                    range: range, style: MarkdownEdit.EmphasisStyle(rawValue: raw)
                )
            )
        }
        return runs
    }

    private func style(at index: Int) -> MarkdownEdit.EmphasisStyle {
        guard let storage = textStorage, index >= 0, index < storage.length else { return [] }
        let raw = storage.attribute(Self.emphasisKey, at: index, effectiveRange: nil) as? Int
        return MarkdownEdit.EmphasisStyle(rawValue: raw ?? 0)
    }

    /// Whether every character of the selection already carries this style, which is what
    /// lights the button and what makes pressing it take the style off.
    func hasEmphasis(_ style: MarkdownEdit.EmphasisStyle) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let range = selectedRange()
        guard range.length > 0 else {
            // Nothing picked: the answer is about the character behind the caret, which is
            // what the next thing typed would inherit.
            return self.style(at: min(max(range.location - 1, 0), storage.length - 1))
                .contains(style)
        }
        var all = true
        storage.enumerateAttribute(Self.emphasisKey, in: range, options: []) { value, _, stop in
            let raw = MarkdownEdit.EmphasisStyle(rawValue: (value as? Int) ?? 0)
            if !raw.contains(style) {
                all = false
                stop.pointee = true
            }
        }
        return all
    }

    /// Adds a style to the selection, or takes that one off when every character has it.
    ///
    /// One style at a time, and the others are left exactly as they were: a word can be
    /// bold and italic and underlined at once, and the first version replaced the lot on
    /// every press, so turning on italic quietly took the bold off.
    func toggleEmphasis(_ style: MarkdownEdit.EmphasisStyle) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        let removing = hasEmphasis(style)

        // Announced before it happens, so ⌘Z knows there was something to undo. A text
        // view only records what it is told about; changing the storage behind its back
        // leaves the undo stack describing a document that no longer exists.
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(Self.emphasisKey, in: range, options: []) { value, sub, _ in
            var current = MarkdownEdit.EmphasisStyle(rawValue: (value as? Int) ?? 0)
            if removing { current.remove(style) } else { current.insert(style) }
            if current.isEmpty {
                storage.removeAttribute(Self.emphasisKey, range: sub)
            } else {
                storage.addAttribute(Self.emphasisKey, value: current.rawValue, range: sub)
            }
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
        guard shouldChangeText(
            inRanges: edits.map { NSValue(range: $0.range) },
            replacementStrings: edits.map(\.replacement)
        ) else { return }

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
