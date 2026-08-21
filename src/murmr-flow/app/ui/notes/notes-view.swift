import SwiftUI

/// The missing half of the note-taking replacement.
///
/// We recorded meetings and wrote files, then abandoned them — the only thing the app
/// offered afterwards was "Show in Finder". This is where you read them.
struct NotesView: View {

    let notes: MeetingStore
    let meetings: MeetingCoordinator

    @State private var selected: NoteFile?
    @State private var query = ""
    @State private var renaming: String?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            detail
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .onAppear {
            notes.reload()
            if selected == nil { selected = notes.notes.first }
        }
        .onChange(of: meetings.stage) { _, stage in
            // A meeting that just finished should appear without being asked for.
            if stage == .saved {
                notes.reload()
                selected = notes.notes.first
            }
        }
    }

    private var results: [NoteFile] { notes.search(query) }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search notes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "No notes yet" : "Nothing matches")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results, selection: $selected) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(
                            "\(Self.stamp(note.date)) · \(MeetingTranscript.clock(note.duration))"
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        if !note.snippet.isEmpty {
                            Text(note.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(note)
                    .contextMenu {
                        Button("Show in Finder") { notes.reveal(note) }
                        Button("Open in editor") { notes.open(note) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { delete(note) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let note = selected, notes.notes.contains(note) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(note)
                    Divider()
                    Text(notes.body(of: note))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        } else {
            EmptyPane(
                symbol: "text.document",
                title: "No note selected",
                hint: "Start a meeting from the toolbar. Your microphone becomes \u{201C}You\u{201D} "
                    + "and everything this Mac plays becomes \u{201C}Them\u{201D}.",
                action: ("Start meeting", { meetings.toggle() })
            )
        }
    }

    private func header(_ note: NoteFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if renaming != nil {
                    TextField("Title", text: Binding(
                        get: { renaming ?? note.title },
                        set: { renaming = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit { commitRename(note) }

                    Button("Save") { commitRename(note) }.controlSize(.small)
                    Button("Cancel") { renaming = nil }.controlSize(.small)
                } else {
                    Text(note.title).font(.title2.weight(.semibold))
                    Button {
                        renaming = note.title
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Rename")

                    Spacer(minLength: 0)

                    Button("Copy") {
                        TextInjector.copyToClipboard(notes.body(of: note))
                    }
                    .controlSize(.small)

                    Menu {
                        Button("Show in Finder") { notes.reveal(note) }
                        Button("Open in editor") { notes.open(note) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { delete(note) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Text("\(Self.longStamp(note.date)) · \(MeetingTranscript.clock(note.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    /// Renaming edits the note's front matter, not its filename — the filename stays
    /// date-first so the folder sorts chronologically whatever a note is called.
    private func commitRename(_ note: NoteFile) {
        guard let title = renaming else { return }
        notes.rename(note, to: title)
        renaming = nil
        selected = notes.notes.first { $0.url == note.url }
    }

    private func delete(_ note: NoteFile) {
        notes.delete(note)
        if selected == note { selected = notes.notes.first }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func longStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
