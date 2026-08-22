import SwiftUI

/// The missing half of the note-taking replacement.
///
/// We recorded meetings and wrote files, then abandoned them — the only thing the app
/// offered afterwards was "Show in Finder". This is where you read them.
struct NotesView: View {

    let notes: MeetingStore
    let meetings: MeetingCoordinator

    /// A set, so several notes can be cleared out in one go. Deleting one at a time is
    /// fine for a mistake and useless for a clear-out.
    @State private var selection: Set<NoteFile> = []
    /// Where a ⇧-click extends from.
    @State private var anchor: NoteFile?
    @State private var query = ""
    @State private var renaming: String?
    @State private var confirmingDelete = false

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                .glassColumn(.thin)
            detail
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        // Gold, not the system accent. A bright blue selection was the one thing on screen
        // that belonged to a different palette.
        .tint(Theme.Palette.gold)
        .onAppear {
            notes.reload()
            if selection.isEmpty, let first = notes.notes.first {
                selection = [first]
                anchor = first
            }
        }
        .onChange(of: meetings.stage) { _, stage in
            // A meeting that just finished should appear without being asked for.
            if stage == .saved {
                notes.reload()
                if let newest = notes.notes.first {
                    selection = [newest]
                    anchor = newest
                }
            }
        }
        .confirmationDialog(
            "Delete \(selection.count) note\(selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They go to the Trash and can be put back from there.")
        }
    }

    private var results: [NoteFile] { notes.search(query) }

    /// Read from `NSEvent` rather than a gesture modifier, because `onTapGesture` does not
    /// report which keys were held.
    private func select(_ note: NoteFile) {
        var modifiers: EventModifiers = []
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        RowClick.apply(
            note, in: results, selection: &selection, anchor: &anchor, modifiers: modifiers
        )
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search notes", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Text.body)
                .padding(10)

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "No notes yet" : "Nothing matches")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No `selection:` binding — the highlight is `SelectableRow`'s, because
                // the system one is `controlAccentColor` and cannot be recoloured per app.
                List(results) { note in
                    SelectableRow(isSelected: selection.contains(note)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.title)
                                .font(Theme.Text.bodyStrong)
                                .foregroundStyle(Theme.Palette.text)
                                .lineLimit(1)
                            Text("\(Self.stamp(note.date)) · \(MeetingTranscript.clock(note.duration))")
                                .font(Theme.Text.small)
                                .foregroundStyle(Theme.Palette.faint)
                            if !note.snippet.isEmpty {
                                Text(note.snippet)
                                    .font(Theme.Text.small)
                                    .foregroundStyle(Theme.Palette.muted)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onTapGesture { select(note) }
                    .contextMenu {
                        Button("Show in Finder") { notes.reveal(note) }
                        Button("Open in editor") { notes.open(note) }
                        Divider()
                        Button(contextDeleteTitle(for: note), role: .destructive) {
                            // Right-clicking outside the selection acts on that row,
                            // which is what every other Mac list does.
                            if !selection.contains(note) { selection = [note] }
                            confirmingDelete = true
                        }
                    }
                }
                .listStyle(.plain)
                // Hidden, or `List` paints its own opaque sidebar material and this one
                // column ends up showing the desktop through it while its neighbours do
                // not — which reads as a rendering fault rather than a design.
                .scrollContentBackground(.hidden)
                .onMoveCommand { direction in
                    RowClick.move(direction, in: results, selection: &selection, anchor: &anchor)
                }
                .onDeleteCommand { if !selection.isEmpty { confirmingDelete = true } }

                selectionFooter
            }
        }
    }

    /// Only present when there is a selection to act on, so the list is not permanently
    /// carrying a toolbar for something you are usually not doing.
    @ViewBuilder
    private var selectionFooter: some View {
        if !selection.isEmpty {
            Divider()
            HStack(spacing: 8) {
                Text("\(selection.count) selected")
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
                Spacer(minLength: 0)
                if selection.count < results.count {
                    Button("All") { selection = Set(results) }
                        .controlSize(.small)
                }
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Move to Trash")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func contextDeleteTitle(for note: NoteFile) -> String {
        selection.contains(note) && selection.count > 1
            ? "Move \(selection.count) Notes to Trash"
            : "Move to Trash"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if selection.count > 1 {
            EmptyPane(
                symbol: "checklist",
                title: "\(selection.count) notes selected",
                hint: "Move them to the Trash, or pick a single note to read it.",
                action: ("Move to Trash", { confirmingDelete = true })
            )
        } else if let note = selection.first, notes.notes.contains(note) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(note)
                    Divider()
                    transcript(of: note)
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

    /// You and Them as turns, which is what the file actually holds.
    ///
    /// This pane used to print the body verbatim, so it showed `**Them** · ` and backticks
    /// on screen — markup in the one place the app is meant to be reading to you.
    @ViewBuilder
    private func transcript(of note: NoteFile) -> some View {
        let body = notes.body(of: note)
        let turns = NoteFile.turns(in: body)

        if turns.isEmpty {
            // A note somebody wrote by hand, or one with nothing in it. Files are the
            // source of truth, so it still has to display.
            Text(body)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.muted)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            TranscriptView(turns: turns)
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
                    Text(note.title)
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.Palette.text)
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
                        Button("Move to Trash", role: .destructive) {
                            selection = [note]
                            confirmingDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Text("\(Self.longStamp(note.date)) · \(MeetingTranscript.clock(note.duration))")
                .font(Theme.Text.small)
                .foregroundStyle(Theme.Palette.faint)
        }
    }

    // MARK: - Actions

    /// Renaming edits the note's front matter, not its filename — the filename stays
    /// date-first so the folder sorts chronologically whatever a note is called.
    private func commitRename(_ note: NoteFile) {
        guard let title = renaming else { return }
        notes.rename(note, to: title)
        renaming = nil
        if let renamed = notes.notes.first(where: { $0.url == note.url }) {
            selection = [renamed]
        }
    }

    private func deleteSelected() {
        notes.delete(Array(selection))
        selection = notes.notes.first.map { [$0] } ?? []
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
