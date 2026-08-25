import SwiftUI

/// Getting rid of things in bulk.
///
/// Deleting one at a time is fine for a mistake and useless for a clear-out, so the
/// per-item controls stay and this exists alongside them.
///
/// The two halves are not equally recoverable, and the pane says so rather than treating
/// them as the same action: a note is a file and goes to the Trash, while a dictation is a
/// row in a log with nowhere to go.
struct DataPane: View {

    let history: HistoryStore
    let notes: NoteStore

    private enum Pending: Identifiable {
        case dictations, notes, everything

        var id: String { String(describing: self) }
    }

    @State private var pending: Pending?

    var body: some View {
        PaneScroll(title: "Data") {
            SectionLabel(title: "Dictation history")
            Card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count(history.dictations.count, "dictation"))
                            .font(.callout.weight(.medium))
                        Text("Deleted permanently — a dictation has no file of its own, so "
                             + "there is nowhere to recover it from.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Delete all") { pending = .dictations }
                        .disabled(history.dictations.isEmpty)
                }
            }

            SectionLabel(title: "Meeting notes")
            Card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count(notes.notes.count, "note"))
                            .font(.callout.weight(.medium))
                        Text("Moved to the Trash, so you can put them back.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Delete all") { pending = .notes }
                        .disabled(notes.notes.isEmpty)
                }
            }

            Divider().padding(.vertical, 4)

            Card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete everything").font(.callout.weight(.medium))
                        Text("Both, in one go. Settings and prompts are kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Delete everything", role: .destructive) { pending = .everything }
                        .disabled(isEmpty)
                }
            }

            Text("Deleting a note here does not remove the audio — that was already "
                 + "discarded when the note was written.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A single confirmation for all three, because they differ only in what they name.
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button(confirmationVerb, role: .destructive) { perform() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var isEmpty: Bool {
        history.dictations.isEmpty && notes.notes.isEmpty
    }

    // MARK: - Confirmation

    /// Names the exact count, so the dialog is never vaguer than the action.
    private var confirmationTitle: String {
        switch pending {
        case .dictations:
            "Delete \(count(history.dictations.count, "dictation"))?"
        case .notes:
            "Delete \(count(notes.notes.count, "note"))?"
        case .everything:
            "Delete \(count(history.dictations.count, "dictation")) "
                + "and \(count(notes.notes.count, "note"))?"
        case nil:
            ""
        }
    }

    private var confirmationVerb: String {
        pending == .notes ? "Move to Trash" : "Delete"
    }

    private var confirmationMessage: String {
        switch pending {
        case .dictations:
            "This cannot be undone."
        case .notes:
            "The notes go to the Trash and can be put back from there."
        case .everything:
            "Notes go to the Trash. The dictation history cannot be undone."
        case nil:
            ""
        }
    }

    private func perform() {
        switch pending {
        case .dictations: history.deleteAll()
        case .notes: notes.deleteAll()
        case .everything:
            history.deleteAll()
            notes.deleteAll()
        case nil: break
        }
        pending = nil
    }

    private func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
