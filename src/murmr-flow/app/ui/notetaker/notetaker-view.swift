import SwiftUI

/// The missing half of the note-taking replacement.
///
/// We recorded meetings and wrote files, then abandoned them — the only thing the app
/// offered afterwards was "Show in Finder". This is where you read them.
struct NotetakerView: View {

    let notes: NoteStore
    let meetings: MeetingCoordinator
    let settings: SettingsStore
    let prompts: PromptStore
    let permissions: PermissionManager

    /// A set, so several notes can be cleared out in one go. Deleting one at a time is
    /// fine for a mistake and useless for a clear-out.
    @State private var selection: Set<NoteFile> = []
    /// Where a ⇧-click extends from.
    @State private var anchor: NoteFile?
    @State private var query = ""
    @State private var renaming: String?
    /// The note being edited, and which file it belongs to. Two pieces of state rather
    /// than one, so switching notes mid-edit saves to the file the words came from
    /// instead of to whichever one is now on screen.
    @State private var editing: String?
    @State private var editingURL: URL?
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            // Matches `PaneScroll`'s inset exactly, so the card lands in the same place
            // as Dictation's — 20 all round, 14 of rhythm before what follows.
            recordBar
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    .glassColumn(.thin)
                detail
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
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
        // A rename typed for one note must not open on the next: without this, starting
        // to rename A and clicking B showed B in edit mode holding A's title, and Save
        // gave B that title.
        .onChange(of: selection) {
            // Save before the pane changes under the edit. `commitEdit` writes to the file
            // the text came from, so this is safe even though the selection has moved on.
            commitEdit()
            renaming = nil
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
        // The panel deliberately offers no discard for a meeting — one stray click on a
        // floating window should not be able to throw away forty minutes. This is the
        // place that can ask first, so this is where discarding lives.
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { meetings.discard() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("Nothing is transcribed and no note is written. This cannot be undone.")
        }
    }

    private var results: [NoteFile] { notes.search(query) }

    // MARK: - Record

    /// Starting a meeting from the section that holds them.
    ///
    /// There was a "Start meeting" button, but only inside the empty state — so the way to
    /// record your second meeting was to already know about the menu bar or the panel.
    /// Deliberately the same shape as Dictation's record card: one primary button,
    /// state in words next to it, and the prompt this mode will use on the right.
    private var recordBar: some View {
        RecordCard(
            title: recordHeadline,
            subtitle: recordSubhead,
            // "Notetaker", the sidebar's word — the same thing had four names.
            buttonTitle: meetings.stage.isRecording ? "Stop" : "Start Notetaker",
            buttonSymbol: meetings.stage.isRecording ? "stop.fill" : "record.circle.fill",
            isActive: meetings.stage.isRecording,
            // Busy but not recording means transcribing: there is nothing useful to stop
            // into, and starting a second meeting over the top of it is worse.
            isDisabled: meetings.stage.isBusy && !meetings.stage.isRecording,
            action: { meetings.toggle() }
        ) {
            if meetings.stage.isRecording {
                // Both levels, because a tap that started cleanly and is recording
                // silence looks exactly like a working meeting until you read the note.
                LevelMeter(label: "You", level: meetings.youLevel)
                LevelMeter(label: "Them", level: meetings.themLevel)
                Button("Discard") { confirmingDiscard = true }
                    .controlSize(.small)
            } else if case .failed(let kind, _) = meetings.stage,
                      kind == .systemAudio || kind == .microphone {
                // The one failure with a door to open. The message already names the
                // pane; this walks there.
                Button("Open System Settings") { permissions.openSystemAudioSettings() }
                    .controlSize(.small)
            } else if meetings.stage.isBusy {
                ProgressView().controlSize(.small)
            } else {
                // Same as the Dictation card: the two settings stay in view with clean-up
                // off, dimmed, with the switch beside them. Hiding them here while the
                // other card showed them live was the one difference between the twins.
                HStack(spacing: 12) {
                    translateMenu
                    Menu {
                        ForEach(prompts.presets) { preset in
                            Button(preset.name) { prompts.notetakerPromptID = preset.id }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").font(.system(size: 10, weight: .medium))
                            Text(prompts.notetakerPrompt?.name ?? "As spoken")
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .opacity(settings.notetakerCleanupEnabled ? 1 : 0.45)
                .disabled(!settings.notetakerCleanupEnabled)

                if !settings.notetakerCleanupEnabled {
                    Button("Turn on") { settings.notetakerCleanupEnabled = true }
                        .controlSize(.small)
                        .help("Write notes with the AI")
                }
            }
        }
    }

    /// The language the note is written in, as a value beside the style's value. Lives
    /// with the style menu because they are the same kind of promise — both need the
    /// clean-up pass, which is why both hide when it is off.
    private var translateMenu: some View {
        TranslateMenu(
            translates: Binding(
                get: { settings.notetakerTranslates },
                set: { settings.notetakerTranslates = $0 }
            ),
            language: Binding(
                get: { settings.notetakerOutputLanguage },
                set: { settings.notetakerOutputLanguage = $0 }
            )
        )
    }

    private var recordHeadline: String {
        switch meetings.stage {
        case .recording:
            "Recording — \(MeetingTranscript.clock(meetings.elapsed))"
        case .transcribing(let step):
            step.label
        case .failed:
            "Couldn't record that"
        case .idle, .saved:
            // Dictation's headline names the key you'd hold. A meeting key is
            // optional, so when there isn't one this says where things stand instead —
            // repeating the button's own word back at it tells you nothing.
            settings.meetingHotkey.map { "Press \($0.displayName) anywhere" }
                ?? "Ready to record"
        }
    }

    private var recordSubhead: String {
        switch meetings.stage {
        case .failed(_, let message):
            message
        case .transcribing:
            "This runs faster than the meeting did — a moment for a long one."
        case .idle, .saved where !settings.notetakerCleanupEnabled:
            "Clean-up is off. Notes are saved exactly as transcribed."
        default:
            "Your microphone is \u{201C}You\u{201D}; everything this Mac plays is \u{201C}Them\u{201D}."
        }
    }

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
            ? "Move \(selection.count) notes to Trash"
            : "Move to Trash"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        // A meeting that is running takes the pane, whatever was selected. Writing while
        // you listen is the thing the pane is for at that moment, and the note you were
        // reading a minute ago is not.
        if meetings.stage.isRecording {
            liveNotes
        } else if selection.count > 1 {
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
                    // Only on the note it concerns, and only until another meeting
                    // replaces it. A clean-up that didn't run is worth saying once, in
                    // front of the note it didn't run on — not in a banner that outlives
                    // the thing it's about.
                    if let message = cleanupWarning(for: note) {
                        WarningRow(message: message)
                    }
                    Divider()
                    transcript(of: note)
                }
                .padding(20)
            }
        } else {
            // No "Start meeting" button here any more, and no explanation of You and
            // Them: the record bar directly above says both, permanently, and repeating
            // it inside the empty state put two start buttons a few points apart.
            EmptyPane(
                symbol: "text.document",
                title: notes.notes.isEmpty ? "No notes yet" : "No note selected",
                hint: notes.notes.isEmpty
                    ? "Record a meeting and it lands here as a Markdown file you own."
                    : "Pick one from the list to read it."
            )
        }
    }

    // MARK: - Writing while it records

    /// The page you write on while the meeting runs.
    ///
    /// Whatever you type here is kept whole in the finished file, **and** handed to the
    /// style that writes the note — six words typed during a call say more about what you
    /// want out of it than the whole transcript does. Blank is a perfectly good answer; the
    /// note is written from the conversation either way.
    private var liveNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Your notes")
                    .font(Theme.Text.title)
                    .foregroundStyle(Theme.Palette.text)
                Spacer(minLength: 0)
                Circle()
                    .fill(Theme.Palette.danger)
                    .frame(width: 7, height: 7)
                Text(MeetingTranscript.clock(meetings.elapsed))
                    .font(Theme.Text.monoLarge)
                    .foregroundStyle(Theme.Palette.muted)
            }

            Divider()

            // `.plain` so the editor has no chrome and no insets of its own — which is
            // what lets the hint below sit exactly where the first character will, rather
            // than a few points off it.
            TextEditor(text: Binding(
                get: { meetings.liveNotes },
                set: { meetings.liveNotes = $0 }
            ))
            .textEditorStyle(.plain)
            .font(Theme.Text.body)
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if meetings.liveNotes.isEmpty {
                    Text("Write anything worth keeping. Headings and - bullets work.")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Palette.faint)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// You and Them as turns, which is what the file actually holds.
    ///
    /// This pane used to print the body verbatim, so it showed `**Them** · ` and backticks
    /// on screen — markup in the one place the app is meant to be reading to you.
    @ViewBuilder
    private func transcript(of note: NoteFile) -> some View {
        let body = notes.body(of: note)
        let summary = NoteFile.summary(in: body)
        let turns = NoteFile.turns(in: body)

        // The note first, then what was said. It is why the file was opened, and until it
        // was drawn here the reading pane showed only the turns — the one thing the
        // Notetaker now writes was visible in every editor except this app.
        if editing != nil, editingURL == note.url {
            // Markdown, in the app's mono face. The file is the source of truth and it is
            // Markdown, so an editor that hid that would be inventing a second format —
            // and the headings and bullets someone types here have to survive a trip
            // through any other editor unchanged.
            TextEditor(text: Binding(
                get: { editing ?? "" },
                set: { editing = $0 }
            ))
            .font(Theme.Text.monoLarge)
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 360)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: Theme.Radius.row))
        } else if !summary.isEmpty {
            NoteSummaryView(lines: summary) { index in
                notes.toggleTask(index, in: note)
            }
        }

        if let own = NoteFile.ownNotes(in: body) {
            SectionLabel(title: "Your notes")
                .padding(.top, summary.isEmpty && editing == nil ? 0 : 20)
                .padding(.bottom, 6)
            Text(own)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !summary.isEmpty || editing != nil || NoteFile.ownNotes(in: body) != nil {
            if !turns.isEmpty {
                SectionLabel(title: "Transcript")
                    .padding(.top, 20)
                    .padding(.bottom, 4)
            }
        }

        if turns.isEmpty, summary.isEmpty, editing == nil, NoteFile.ownNotes(in: body) == nil {
            // A note somebody wrote by hand, or one with nothing in it. Files are the
            // source of truth, so it still has to display.
            Text(body)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.muted)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if !turns.isEmpty {
            TranscriptView(turns: turns)
        }
    }

    /// What clean-up couldn't do to the meeting that just finished, if anything.
    private func cleanupWarning(for note: NoteFile) -> String? {
        guard let result = meetings.lastResult, result.note.url == note.url else { return nil }
        return result.cleanupNote
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

                    if let markdown = NoteFile.summaryMarkdown(in: notes.body(of: note)) {
                        Button(editing == nil ? "Edit note" : "Done") {
                            if editing == nil {
                                editing = markdown
                                editingURL = note.url
                            } else {
                                commitEdit()
                            }
                        }
                        .controlSize(.small)
                        .help(editing == nil
                              ? "Correct the note. The transcript below is left alone."
                              : "Save the note back to its file")
                    }

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

    /// Writes the edited note back, if anything is being edited.
    ///
    /// Called by Done and by anything that navigates away, because an edit lost to a click
    /// in the sidebar is an edit the person will not make twice.
    private func commitEdit() {
        defer {
            editing = nil
            editingURL = nil
        }
        guard let text = editing, let url = editingURL,
              let note = notes.notes.first(where: { $0.url == url })
        else { return }
        notes.saveSummary(text, in: note)
    }

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
