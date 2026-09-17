import SwiftUI

/// The missing half of the note-taking replacement.
///
/// We recorded meetings and wrote files, then abandoned them — the only thing the app
/// offered afterwards was "Show in Finder". This is where you read them.
struct NotetakerView: View {

    let notes: NoteStore
    let meetings: MeetingCoordinator
    /// Only for the "show me this one" request; the pane owns everything else it needs.
    let settings: SettingsStore
    let prompts: PromptStore
    let permissions: PermissionManager
    let services: AppServices

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
    /// Which pane the person chose, or nil to let the note decide.
    @State private var chosenPane: NotePane?
    @State private var showingTranscript = false
    @State private var enhanceFailure: String?
    /// Bumped when a note is written for a meeting that had none, so the page is rebuilt
    /// around words it has never seen.
    @State private var enhanceStamp = 0
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
            showRequestedNote()
        }
        // A row on Home, or in the menu bar, asking for one note by name. Taken and put
        // back to nil here, because the request is answered the moment this pane is
        // looking at it and a stale one would hijack the next visit.
        .onChange(of: services.noteToOpen) { showRequestedNote() }
        // A rename typed for one note must not open on the next: without this, starting
        // to rename A and clicking B showed B in edit mode holding A's title, and Save
        // gave B that title.
        .onChange(of: selection) {
            // Each page saves itself as it goes and once more on its way out, so nothing
            // has to be committed here.
            renaming = nil
            // A pane chosen for one note says nothing about the next one, which may not
            // even have that half.
            chosenPane = nil
            showingTranscript = false
            enhanceFailure = nil
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
                    reading(note)
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
                        // Clear of the caret, which sits at the text origin. Level with
                        // it the caret is drawn through the first letter.
                        .padding(.leading, 3)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The note, as two ways of looking at the same meeting.
    ///
    /// **The transcript is folded away.** It is the evidence, not the note: it is there so
    /// a claim can be checked and so the file is the whole record, and a reader who wanted
    /// forty turns would not have asked for a note. Granola hides it for the same reason.
    @ViewBuilder
    private func reading(_ note: NoteFile) -> some View {
        // This pane's content comes from the file rather than from anything SwiftUI can
        // see change, so it says out loud that it depends on the folder having been
        // re-read. Without it, ticking a task rewrote the file and the box stayed
        // unticked until you left the note and came back.
        let _ = notes.revision
        let body = notes.body(of: note)
        let summary = NoteFile.summary(in: body)
        let own = NoteFile.ownNotes(in: body)
        let turns = NoteFile.turns(in: body)
        let pane = shownPane(summary: summary, own: own)

        switch pane {
        case .enhanced:
            NoteEditorPane(
                text: NoteFile.summaryMarkdown(in: body) ?? "",
                placeholder: "Type here, or use ### and - to shape it.",
                // The page is its own empty state: a note that can be written for you and
                // a note you can write are the same blank sheet.
                emptyAction: turns.isEmpty ? nil : (
                    title: meetings.isWritingNote ? "Writing\u{2026}" : "Enhance note now",
                    run: { enhance(note) }
                ),
                onSave: { text in
                    notes.saveSummary(text, in: note)
                    resyncSelection()
                },
                tabs: { paneTabs(pane) }
            )
            // Deliberately not keyed on the revision: our own saves bump that, and
            // rebuilding the page on each one would pull the text out from under the
            // caret. It is keyed on the things that genuinely mean "different words":
            // another note, another tab, or a note written for this one just now.
            .id("enhanced:\(note.url.path):\(enhanceStamp)")

        case .mine:
            NoteEditorPane(
                text: own ?? "",
                placeholder: "Nothing you wrote during this meeting. Type here to add some.",
                onSave: { text in
                    notes.saveOwnNotes(text, in: note)
                    resyncSelection()
                },
                tabs: { paneTabs(pane) }
            )
            .id("mine:\(note.url.path)")
        }

        if let enhanceFailure {
            WarningRow(message: enhanceFailure)
        }

        // A file somebody wrote by hand, and only that.
        //
        // The test is whether the file has any of our headings, not whether it has any
        // content: a meeting that transcribed nothing has no note, no turns and nothing
        // typed, and printing its raw body put `## Transcript` and the front matter on
        // screen under an empty page — markup in the one place the app is meant to be
        // reading to you, and twice over.
        if NoteFile.summaryMarkdown(in: body) == nil, own == nil, turns.isEmpty {
            Text(body)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.muted)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !turns.isEmpty {
            DisclosureGroup(isExpanded: $showingTranscript) {
                TranscriptView(turns: turns)
                    .padding(.top, 10)
            } label: {
                Text("Transcript · \(turns.count) turns")
                    .font(Theme.Text.label)
                    .tracking(Theme.labelTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Palette.faint)
            }
            .padding(.top, 20)
        }
    }

    /// Writes a note for a meeting that has none, then rebuilds the page around words it
    /// has never seen.
    private func enhance(_ note: NoteFile) {
        Task {
            enhanceFailure = await meetings.writeNote(for: note)
            resyncSelection()
            if enhanceFailure == nil { enhanceStamp += 1 }
        }
    }

    /// The two halves, as a control that shares its line with the edit bar.
    private func paneTabs(_ pane: NotePane) -> some View {
        PaneTabs(
            tabs: NotePane.allCases,
            title: \.title,
            selection: Binding(get: { pane }, set: { chosenPane = $0 }),
            alignment: .leading
        )
        .fixedSize()
    }

    /// Which of the two panes is showing. The stored choice when there is one, and
    /// otherwise the one with something in it — landing on an empty pane when the other
    /// holds the whole meeting is the app being right and useless at once.
    private func shownPane(summary: [NoteFile.SummaryLine], own: String?) -> NotePane {
        if let chosenPane { return chosenPane }
        if summary.isEmpty, own != nil { return .mine }
        return .enhanced
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

    /// Opens whichever note something else asked for.
    private func showRequestedNote() {
        guard let url = services.noteToOpen else { return }
        services.noteToOpen = nil
        notes.reload()
        guard let note = notes.notes.first(where: { $0.url == url }) else { return }
        selection = [note]
        anchor = note
        chosenPane = nil
        showingTranscript = false
    }

    /// Points the selection back at the reloaded files.
    ///
    /// A `NoteFile` carries the row's snippet, and the snippet is the note's first line —
    /// so editing the note changes the value the selection holds, and the pane that was
    /// showing it decided nothing was selected any more. Selection is by file, not by the
    /// contents of one.
    private func resyncSelection() {
        let urls = Set(selection.map(\.url))
        guard !urls.isEmpty else { return }
        let reloaded = notes.notes.filter { urls.contains($0.url) }
        guard !reloaded.isEmpty else { return }
        selection = Set(reloaded)
        if let anchor, let moved = reloaded.first(where: { $0.url == anchor.url }) {
            self.anchor = moved
        }
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
