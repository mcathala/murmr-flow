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
struct NoteEditorPane: View {

    let placeholder: String
    let onSave: (String) -> Void

    @State private var draft: String
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var saving: Task<Void, Never>?
    @State private var focused = false
    /// Whether anything has been typed here. Leaving an untouched pane must write
    /// nothing: the file may have been changed by something else since this was seeded,
    /// and saving a draft nobody edited would quietly undo that.
    @State private var dirty = false

    /// How long typing has to stop before the file is written. Long enough that a sentence
    /// is one write, short enough that nothing is lost to a closed lid.
    private static let settle: Duration = .milliseconds(700)

    init(text: String, placeholder: String, onSave: @escaping (String) -> Void) {
        _draft = State(initialValue: text)
        self.placeholder = placeholder
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            editor
        }
    }

    /// What the line the caret is on already is, which is what the menu shows as chosen.
    private var block: MarkdownEdit.Block {
        MarkdownEdit.block(of: draft as NSString, at: selection)
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
                    set: { apply(.setBlock($0)) }
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

            command("bold", help: "Bold", on: isWrapped("**")) { apply(.wrap("**")) }
            command("italic", help: "Italic", on: isWrapped("*")) { apply(.wrap("*")) }

            Divider().frame(height: 14)

            command(
                "list.bullet", help: "Bullet", on: block == .bullet
            ) { apply(.setBlock(.bullet)) }
            command(
                "checklist", help: "Task", on: block == .task
            ) { apply(.setBlock(.task)) }

            Spacer(minLength: 0)
        }
        .font(Theme.Text.small)
        .foregroundStyle(Theme.Palette.muted)
        .opacity(focused ? 1 : 0)
        // Kept out of the way when it is invisible, so a click meant for the first line
        // of the note cannot land on a control nobody can see.
        .allowsHitTesting(focused)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private func isWrapped(_ marker: String) -> Bool {
        MarkdownEdit.isWrapped(marker, in: draft, selection: selection)
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

    /// One way in and out for every toolbar action: change the text, move the caret, save.
    private enum Command {
        case setBlock(MarkdownEdit.Block)
        case wrap(String)
    }

    private func apply(_ command: Command) {
        let result = switch command {
        case .setBlock(let block):
            MarkdownEdit.setBlock(block, in: draft, selection: selection)
        case .wrap(let marker):
            MarkdownEdit.wrap(marker, in: draft, selection: selection)
        }
        guard result.text != draft else { return }
        dirty = true
        draft = result.text
        selection = result.selection
        saving?.cancel()
        onSave(result.text)
    }

    private var editor: some View {
        NoteTextEditor(
            text: $draft,
            selection: $selection,
            onEdited: { text in
                dirty = true
                saving?.cancel()
                saving = Task {
                    try? await Task.sleep(for: Self.settle)
                    guard !Task.isCancelled else { return }
                    onSave(text)
                }
            },
            onFocusChange: { focused = $0 },
            onToggleTask: { index in
                // Ticked here rather than through the file: the box has to fill the
                // instant it is clicked, and a round trip through disk and back would
                // replace the text under the caret to do it.
                saving?.cancel()
                dirty = true
                draft = NoteFile.togglingTask(in: draft, at: index)
                onSave(draft)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if draft.isEmpty {
                Text(placeholder)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.faint)
                    .padding(.leading, 3)
                    .allowsHitTesting(false)
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
