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
    /// Called on every keystroke, debounced by the caller — the file is the only copy, so
    /// nothing waits for a button.
    var onEdited: (String) -> Void
    /// The task's position in the note, when its box was the thing clicked.
    var onToggleTask: ((Int) -> Void)?

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView()
        view.delegate = context.coordinator
        view.onToggleTask = { context.coordinator.parent.onToggleTask?($0) }
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
        view.string = text
        view.applyStyling()
        return view
    }

    func updateNSView(_ view: NoteTextView, context: Context) {
        view.onToggleTask = { context.coordinator.parent.onToggleTask?($0) }
        // Only when the text genuinely differs — assigning it back mid-typing would move
        // the insertion point to the end on every keystroke.
        guard view.string != text else { return }
        let selected = view.selectedRange()
        view.string = text
        view.applyStyling()
        view.setSelectedRange(
            NSRange(location: min(selected.location, (text as NSString).length), length: 0)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextEditor

        init(_ parent: NoteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NoteTextView else { return }
            view.applyStyling()
            parent.text = view.string
            parent.onEdited(view.string)
        }
    }
}

/// The text view itself: styling, a click that ticks a box, and a height that fits.
final class NoteTextView: NSTextView {

    var onToggleTask: ((Int) -> Void)?

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
        let heading = NSFont(name: Theme.Face.ui, size: 15) ?? .boldSystemFont(ofSize: 15)
        let mono = NSFont(name: Theme.Face.data, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)

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
                storage.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(heading, toHaveTrait: .boldFontMask),
                    range: range
                )
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
                    storage.addAttribute(
                        .foregroundColor,
                        value: NSColor(Theme.Palette.muted),
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
        storage.endEditing()
        invalidateIntrinsicContentSize()
    }
}
