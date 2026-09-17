import SwiftUI

/// One half of a note — the written one or your own — as a page you can type on.
///
/// Holds the draft itself. The file is re-read whenever anything writes to it, and a pane
/// bound straight to the file would have the text replaced under the caret every time a
/// save landed. So the draft lives here, is seeded once, and is saved *out*: give the view
/// an `.id` that changes with the note and the tab, and switching either builds a fresh one
/// from the file.
///
/// Saving is debounced rather than triggered by a button. The file is the only copy, and a
/// note nobody remembered to save is worse than a note saved a beat late.
struct NoteEditorPane<Tabs: View>: View {

    let placeholder: String
    /// Offered on an empty page, where the page itself is the empty state — a note that
    /// can be written for you and a note you can write are the same blank sheet.
    var emptyAction: (title: String, run: () -> Void)?
    let onSave: (String) -> Void
    /// Which half of the note is showing. Handed in rather than built here so it can share
    /// a line with the bar, which is the one row the pane has to spare.
    @ViewBuilder let tabs: Tabs

    /// The file's text, which is what gets saved.
    @State private var draft: String
    /// The same words as the page shows them, with no markers in them — which is what the
    /// bar reasons about, because a line's kind is a fact about the page.
    @State private var display: String
    @State private var selection = NSRange(location: 0, length: 0)
    /// Bumped after a change the text does not show, so the bar's lit buttons follow.
    @State private var stamp = 0
    private let commands = NoteTextEditor.NoteEditorCommands()
    @State private var saving: Task<Void, Never>?
    @State private var focused = false
    /// Whether anything has been typed here. Leaving an untouched pane must write
    /// nothing: the file may have been changed by something else since this was seeded,
    /// and saving a draft nobody edited would quietly undo that.
    @State private var dirty = false

    /// How long typing has to stop before the file is written. Long enough that a sentence
    /// is one write, short enough that nothing is lost to a closed lid.
    private var settle: Duration { .milliseconds(700) }

    init(
        text: String,
        placeholder: String,
        emptyAction: (title: String, run: () -> Void)? = nil,
        onSave: @escaping (String) -> Void,
        @ViewBuilder tabs: () -> Tabs
    ) {
        _draft = State(initialValue: text)
        _display = State(initialValue: MarkdownEdit.stripEmphasis(text).text)
        self.placeholder = placeholder
        self.emptyAction = emptyAction
        self.onSave = onSave
        self.tabs = tabs()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                tabs
                toolbar
            }
            editor
        }
    }

    /// What the line the caret is on already is, which is what the menu shows as chosen.
    ///
    /// Asked of the page rather than worked out from the text, because a heading leaves no
    /// mark in the text any more — it is a property of the line, like the weight on a word.
    private var block: MarkdownEdit.Block {
        _ = stamp
        return commands.block(in: display, at: selection)
    }

    /// The controls for shaping a line, because the Markdown is visible but knowing to
    /// type `###` is not something anyone should have to be told.
    ///
    /// Three things here are deliberate, and each was wrong in the first version.
    ///
    /// **It is only there while you are typing.** A bar for shaping text sitting over a
    /// page nobody has clicked into is chrome, and it was the first thing under the tabs
    /// on every note. Its space is held rather than collapsed, so the note does not jump
    /// when the caret arrives.
    ///
    /// **The menu offers every kind of line, including bullet and task.** It read the
    /// line it was on and could name a kind — "Bullet" — that it then did not list, so
    /// opening it showed nothing chosen. The two buttons are shortcuts to the two most
    /// used, not a second half of the same control.
    ///
    /// **Everything lights when it is on, or nothing should.** Bullet and task lit and
    /// bold and italic never did, on the same bar. And the menu was gold while saying
    /// "Normal text", which is the accent claiming something is set when nothing is.
    private var toolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Style", selection: Binding(
                    get: { block },
                    set: { set($0) }
                )) {
                    ForEach(MarkdownEdit.Block.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(block.title).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(minWidth: 96, alignment: .leading)
            .foregroundStyle(block == .body ? Theme.Palette.muted : Theme.Palette.gold)

            Divider().frame(height: 14)

            // Three independent switches, not a choice of one: a word can be all three.
            command("bold", help: "Bold", on: isOn(.bold)) { emphasise(.bold) }
            command("italic", help: "Italic", on: isOn(.italic)) { emphasise(.italic) }
            command("underline", help: "Underline", on: isOn(.underline)) {
                emphasise(.underline)
            }

            Divider().frame(height: 14)

            command("list.bullet", help: "Bullet", on: block == .bullet) { set(.bullet) }
            command("list.number", help: "Numbered", on: block == .numbered) { set(.numbered) }
            command("checklist", help: "Task", on: block == .task) { set(.task) }

        }
        .font(Theme.Text.small)
        .foregroundStyle(Theme.Palette.muted)
        .opacity(focused ? 1 : 0)
        // Kept out of the way when it is invisible, so a click meant for the first line
        // of the note cannot land on a control nobody can see.
        .allowsHitTesting(focused)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    /// Read through the stamp, so pressing Bold relights the button — the text is
    /// unchanged by it, and nothing else would tell the bar to look again.
    private func isOn(_ style: MarkdownEdit.EmphasisStyle) -> Bool {
        _ = stamp
        return commands.isOn(style)
    }

    private func emphasise(_ style: MarkdownEdit.EmphasisStyle) {
        commands.toggleEmphasis(style)
        stamp += 1
    }

    private func set(_ block: MarkdownEdit.Block) {
        commands.setBlock(block)
        stamp += 1
    }

    private func command(
        _ symbol: String, help: String, on: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 18)
                .foregroundStyle(on ? Theme.Palette.gold : Theme.Palette.muted)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.Palette.gold.opacity(0.14))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var editor: some View {
        NoteTextEditor(
            markdown: $draft,
            displayText: $display,
            selection: $selection,
            onEdited: { text in
                dirty = true
                saving?.cancel()
                saving = Task {
                    try? await Task.sleep(for: settle)
                    guard !Task.isCancelled else { return }
                    onSave(text)
                }
            },
            commands: commands,
            onFocusChange: { focused = $0 },
            onToggleTask: { index in
                // Ticked here rather than through the file: the box has to fill the
                // instant it is clicked, and a round trip through disk and back would
                // replace the text under the caret to do it.
                saving?.cancel()
                dirty = true
                commands.toggleTask(index)
                stamp += 1
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if display.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(placeholder)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Palette.faint)
                        .padding(.leading, 3)
                        .allowsHitTesting(false)
                    if let emptyAction {
                        Button(emptyAction.title, action: emptyAction.run)
                            .controlSize(.small)
                    }
                }
            }
        }
        .onDisappear {
            // Whatever the debounce was still holding. Clicking another note must not be
            // the thing that loses a sentence.
            saving?.cancel()
            guard dirty else { return }
            onSave(draft)
        }
    }
}
