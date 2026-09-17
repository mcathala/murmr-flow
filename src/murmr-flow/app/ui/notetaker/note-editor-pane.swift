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
    @State private var saving: Task<Void, Never>?
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
        NoteTextEditor(
            text: $draft,
            onEdited: { text in
                dirty = true
                saving?.cancel()
                saving = Task {
                    try? await Task.sleep(for: Self.settle)
                    guard !Task.isCancelled else { return }
                    onSave(text)
                }
            },
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
