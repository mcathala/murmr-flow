import SwiftUI

/// Permissions, where things are kept, and getting rid of them.
///
/// One section, because it is one question: what does this app have access to, what has
/// it written down, and how do I take it back. Permissions and Data were two sidebar rows,
/// and the folder path telling you where your notes live sat in the first while the button
/// deleting them sat in the second.
///
/// Permissions had also collected everything with nowhere else to go — a music toggle,
/// which is what the hotkey does and now lives with it, and the version string, which is
/// still here because About is one line and does not earn a section.
///
/// Two rules carried over from the panes this replaces. **Anything granted collapses to a
/// single line**; anything that needs attention is at the top, outlined, with the button
/// that fixes it. And **the two halves of Delete are not equally recoverable**, so it says
/// so rather than treating them as the same action: a note is a file and goes to the
/// Trash, while a dictation is a row in a log with nowhere to go.
///
/// Two captions were dropped on purpose, and one of them was a real claim: audio is
/// discarded once a note is written, which was said here as a footnote to a delete button —
/// *"deleting a note here does not remove the audio"* — phrased so defensively it invited
/// the question it answered. The fact is still true (`MeetingCoordinator` discards the
/// recording either way) and is worth stating as a feature somewhere it reads as one. It is
/// not currently stated anywhere a user can see.
struct PrivacyDataPane: View {

    let permissions: PermissionManager
    let notes: NoteStore
    let history: HistoryStore

    private enum Pending: Identifiable {
        case dictations, notes, everything

        var id: String { String(describing: self) }
    }

    @State private var pending: Pending?

    var body: some View {
        PaneScroll(title: "Privacy & data") {
            SectionLabel(title: "Permissions")
            permissionsBlock

            SectionLabel(title: "Where notes are saved")
            notesFolder

            SectionLabel(title: "Delete")
            deletion

            SectionLabel(title: "About")
            Text("Murmr Flow \(Self.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .onAppear { permissions.refresh() }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsBlock: some View {
        if permissions.allGranted {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("All permissions granted.").font(.callout)
                Spacer(minLength: 0)
                Button("Re-check") { permissions.refresh() }
                    .controlSize(.small)
            }
        } else {
            if permissions.accessibility != .granted {
                WarningRow(
                    message: "Accessibility is off, so dictation copies to the "
                        + "clipboard instead of inserting it.",
                    action: ("Open Settings", { permissions.openAccessibilitySettings() })
                )
            }
            if permissions.microphone != .granted {
                WarningRow(
                    message: "The microphone isn't available.",
                    action: (
                        permissions.microphone == .notDetermined ? "Ask" : "Open Settings",
                        {
                            if permissions.microphone == .notDetermined {
                                Task { await permissions.requestMicrophone() }
                            } else {
                                permissions.openMicrophoneSettings()
                            }
                        }
                    )
                )
            }
        }

        // System audio is deliberately not mentioned. It has no API to query, so there was
        // never anything honest to show — and the line that used to say it would be asked
        // for later was a promise about the future in a pane whose rule is that anything
        // fine collapses to one line. `SystemAudioRecorder` already produces the real
        // message at the moment it fails, which is the only place it can be acted on.
    }

    // MARK: - Where notes are saved

    /// The path is the whole content, so it carries no heading of its own — the section
    /// label above it already said what this is.
    private var notesFolder: some View {
        Card {
            HStack(spacing: 10) {
                Text(NoteStore.folder.path(percentEncoded: false))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Open") { notes.openFolder() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Delete

    /// Deleting one at a time is fine for a mistake and useless for a clear-out, so the
    /// per-item controls stay and this exists alongside them. Each card names its own
    /// count, which is why the two halves need no headings of their own.
    @ViewBuilder
    private var deletion: some View {
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

    // MARK: - About

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
