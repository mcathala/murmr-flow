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

            HStack(spacing: 10) {
                SectionLabel(title: "History")
                Button("Delete all", role: .destructive) { pending = .everything }
                    .controlSize(.small)
                    .disabled(isEmpty)
                Spacer(minLength: 0)
            }
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
        if permissions.allGranted, permissions.systemAudio == .granted {
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
            // The third of the three onboarding asks. It used to be unmentionable — no
            // API to query — but the probe remembers its answer now, so there is
            // something honest to show and a button that acts on it.
            if permissions.systemAudio != .granted {
                WarningRow(
                    message: "System audio is off, so meeting notes only hear your side.",
                    action: (
                        permissions.systemAudio == .notDetermined ? "Ask" : "Open Settings",
                        {
                            if permissions.systemAudio == .notDetermined {
                                Task { await permissions.requestSystemAudio() }
                            } else {
                                permissions.openSystemAudioSettings()
                            }
                        }
                    )
                )
            }
        }
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

    /// Two halves side by side, each naming its count and its fate — the one distinction
    /// that matters is which half can come back, and one shared sentence kept muddling it.
    /// The button lives up beside the section title; per-item deletion stays in Dictation
    /// and Notetaker for the surgical case.
    private var deletion: some View {
        HStack(spacing: 10) {
            historyHalf(
                count(history.dictations.count, "dictation"),
                fate: "Deleted permanently — nowhere to recover them from.",
                isEmpty: history.dictations.isEmpty,
                delete: .dictations
            )
            historyHalf(
                count(notes.notes.count, "note"),
                fate: "Moved to the Trash, so they can come back.",
                isEmpty: notes.notes.isEmpty,
                delete: .notes
            )
        }
    }

    /// Each half keeps its own small Delete, so one kind can be cleared without the
    /// other; the header's Delete all is the both-at-once.
    private func historyHalf(
        _ title: String, fate: String, isEmpty: Bool, delete: Pending
    ) -> some View {
        Card {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(fate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Delete") { pending = delete }
                    .controlSize(.small)
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
            "Notes go to the Trash. The dictation history cannot be undone. Settings "
                + "and prompts are kept."
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
