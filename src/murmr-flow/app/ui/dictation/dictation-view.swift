import SwiftUI

/// Dictation, and what it produced.
///
/// The card shows the finished text, which is the text you dictated for. The raw
/// transcript is still kept and is what Re-run clean-up works from — it was once shown
/// beside the cleaned one, behind a switch, and the switch turned out to be answering a
/// question nobody asks twice.
struct DictationView: View {

    let dictation: DictationCoordinator
    let history: HistoryStore
    let prompts: PromptStore
    /// Only for the "show me this one" request; the pane owns everything else it needs.
    let services: AppServices

    private var settings: SettingsStore { dictation.settings }

    /// A set, so a batch can go at once. Same reasoning as Notes: one-at-a-time is fine
    /// for a mistake and useless for a clear-out.
    @State private var selection: Set<UUID> = []
    @State private var isRerunning = false
    @State private var rerunNote: String?
    @State private var confirmingDelete = false

    var body: some View {
        PaneScroll {
            recordCard

            if selection.count > 1 {
                SectionLabel(title: "\(selection.count) selected")
                batchCard
            } else if let record = current {
                SectionLabel(title: selection.isEmpty ? "Last dictation" : "Dictation")
                transcript(record)
            }

            if history.dictations.count > 1 {
                HStack(spacing: 8) {
                    SectionLabel(title: "History")
                    Spacer(minLength: 0)
                    // One control, two states. It was Select all beside Clear, and Clear
                    // emptied the *selection* — sitting in a list header next to Select
                    // all, it read as "clear the history", which is the one reading that
                    // would have cost somebody their dictations.
                    let all = selection.count == history.dictations.count
                    Button(all ? "Deselect all" : "Select all") {
                        selection = all ? [] : Set(history.dictations.map(\.id))
                    }
                    .controlSize(.small)
                }
                list
            }

            if history.dictations.isEmpty {
                EmptyPane(
                    symbol: "mic",
                    title: "Nothing yet",
                    hint: "\(settings.hotkeyPhrase) anywhere and speak. The text lands "
                        + "wherever your cursor is."
                )
                .frame(minHeight: 220)
            }
        }
        .onAppear { showRequested() }
        // A row on Home asking for one dictation by name.
        .onChange(of: services.dictationToOpen) { showRequested() }
        .confirmationDialog(
            "Delete \(selection.count) dictation\(selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                history.delete(ids: selection)
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// Opens whichever dictation something else asked for. Taken and put back to nil,
    /// because the request is answered the moment this pane is looking at it.
    private func showRequested() {
        guard let id = services.dictationToOpen else { return }
        services.dictationToOpen = nil
        guard history.dictations.contains(where: { $0.id == id }) else { return }
        selection = [id]
    }

    private var current: DictationRecord? {
        if let one = selection.first, selection.count == 1 {
            return history.dictations.first { $0.id == one }
        }
        return history.dictations.first
    }

    private var selectedRecords: [DictationRecord] {
        history.dictations.filter { selection.contains($0.id) }
    }

    /// Shown instead of a transcript when several are picked — there is no single one to
    /// read, and the only useful thing to offer is getting rid of them.
    private var batchCard: some View {
        Card(highlighted: true) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selection.count) dictations selected")
                        .font(.callout.weight(.medium))
                    Text("\(selectedRecords.reduce(0) { $0 + $1.wordCount }) words in total.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Delete", role: .destructive) { confirmingDelete = true }
            }
        }
    }

    // MARK: - Record

    /// A button as well as the key — discoverable, and it still works if Accessibility
    /// isn't granted, when the global hotkey can't fire at all.
    ///
    /// Shape and styling live in `RecordCard`, which Notes uses too.
    private var recordCard: some View {
        RecordCard(
            title: headline,
            subtitle: subhead,
            buttonTitle: dictation.stage.isRecording ? "Stop" : "Dictate",
            buttonSymbol: dictation.stage.isRecording ? "stop.fill" : "mic.fill",
            isActive: dictation.stage.isRecording,
            isDisabled: dictation.stage.isBusy && !dictation.stage.isRecording,
            action: {
                if dictation.stage.isRecording {
                    Task { await dictation.endDictation() }
                } else {
                    dictation.beginDictation()
                }
            }
        ) {
            // The two settings stay in view with clean-up off, dimmed, so the card
            // still shows what it *would* do — and the way to make it do it sits beside
            // them. Notes does the same; the two cards used to disagree, one hiding the
            // menus and the other showing live controls that did nothing.
            HStack(spacing: 12) {
                translateMenu
                Menu {
                    ForEach(prompts.presets) { preset in
                        Button(preset.name) { prompts.dictationPromptID = preset.id }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10, weight: .medium))
                        Text(prompts.dictationPrompt.name)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .opacity(settings.cleanupEnabled ? 1 : 0.45)
            .disabled(!settings.cleanupEnabled)

            if !settings.cleanupEnabled {
                Button("Turn on") { settings.cleanupEnabled = true }
                    .controlSize(.small)
                    .help("Clean up dictation with the AI")
            }
        }
    }

    /// The language the text lands in, as a value beside the style's value. The language
    /// survives being switched off, so turning it back on is one click, not a search.
    private var translateMenu: some View {
        TranslateMenu(
            translates: Binding(
                get: { settings.dictationTranslates },
                set: { settings.dictationTranslates = $0 }
            ),
            language: Binding(
                get: { settings.dictationOutputLanguage },
                set: { settings.dictationOutputLanguage = $0 }
            )
        )
    }

    private var headline: String {
        if dictation.stage.isRecording {
            return String(format: "Listening — %.1fs", dictation.elapsed)
        }
        if dictation.stage.isBusy { return dictation.stage.label }
        return "\(settings.hotkeyPhrase) anywhere"
    }

    private var subhead: String {
        if dictation.stage.isRecording, !dictation.preview.isEmpty {
            return dictation.preview
        }
        if case .failed(_, let message) = dictation.stage { return message }
        if !settings.cleanupEnabled {
            return "Clean-up is off. Style and language don\u{2019}t apply."
        }
        return settings.holdToTalk
            ? "Hold the key while you speak."
            : "Press once to start, once to stop."
    }


    // MARK: - Transcript

    private func transcript(_ record: DictationRecord) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(Self.stamp(record.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let icon = AppIconCache.icon(forBundleID: record.targetBundleID) {
                        // The icon, not the name: it is recognised rather than read, and
                        // the app is the one thing on this row you know at a glance.
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 15, height: 15)
                            .help(record.targetAppName ?? "")
                    } else if let app = record.targetAppName {
                        Text("· \(app)").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }

                // Always the finished text. There was a Cleaned / Raw switch here, and it
                // was answering a question nobody asks twice: the cleaned text is the one
                // you dictated *for*, and when clean-up did not run the finished text and
                // the raw one are the same words anyway. The raw transcript is still kept
                // — it is what Re-run clean-up works from.
                Text(record.finalText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Nothing at all when this is what you asked for. A dictation you set an
                // app to Off for does not need a warning about being off, and the row's
                // own style column already says so — one orange line for all four reasons
                // taught you to ignore the colour.
                if let why = record.notCleaned?.failure {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if record.usedRawFallback, record.notCleaned == nil {
                    // Written before the app kept the reason. Neither a fault nor a
                    // choice, so it is stated without alarm.
                    Text("Not cleaned up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // What the pill said in passing, kept here where there is room to read
                // it: the latest run's note, only while this is the latest record.
                if record.id == history.dictations.first?.id,
                   let note = dictation.lastRun?.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Why the last Re-run left the text as it was. Cleared by the next one.
                if let rerunNote {
                    Text(rerunNote)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Copy") {
                        TextInjector.copyToClipboard(record.finalText)
                    }
                    // "Insert again" was here. The text already went where it was meant
                    // to; pressing this later put it wherever the cursor happened to be
                    // by then, which is rarely what anyone wanted and occasionally
                    // landed a paragraph in the wrong document.
                    Button(isRerunning ? "Re-running…" : "Re-run clean-up") {
                        isRerunning = true
                        rerunNote = nil
                        Task {
                            rerunNote = await dictation.rerunCleanup(on: record)
                            isRerunning = false
                        }
                    }
                    .disabled(isRerunning || dictation.rerunBlocker != nil)
                    .help(dictation.rerunBlocker
                          ?? "Clean this transcript up again with the current style")
                    Spacer(minLength: 0)
                    // One word for deleting, everywhere. A trash icon here and the word
                    // Delete on the card for several was two shapes for one action — and
                    // an icon floating at the right edge stacked into a column with
                    // Select all below it, which reads as one group and is three scopes.
                    //
                    // And no dialog. One dictation is a line of text that is still in the
                    // log a keystroke ago; asking costs more than losing it does.
                    Button("Delete", role: .destructive) {
                        history.delete(ids: [record.id])
                        selection = []
                    }
                    .help("Delete this dictation")
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - History

    private var list: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(rows) { record in
                    Button {
                        toggle(record)
                    } label: {
                        HStack(spacing: 10) {
                            Image(
                                systemName: selection.contains(record.id)
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                selection.contains(record.id)
                                    ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.summary(limit: 90))
                                    .font(.callout)
                                    .lineLimit(1)
                                // The app's mark sits in the line, beside its name rather
                                // than instead of it: down a list of twenty this is the
                                // column the eye runs along, and a name is read where a
                                // mark is recognised.
                                HStack(spacing: 4) {
                                    Text(subtitle(record, upToApp: true))
                                    if let icon = AppIconCache.icon(
                                        forBundleID: record.targetBundleID
                                    ) {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 11, height: 11)
                                    }
                                    Text(subtitle(record, upToApp: false))
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            selection = [record.id]
                            confirmingDelete = true
                        }
                    }

                    if record.id != rows.last?.id { Divider() }
                }
            }
        }
    }

    private var rows: [DictationRecord] {
        Array(history.dictations.prefix(50))
    }

    /// Click to select, click again to deselect. A visible circle rather than a modifier
    /// key, because these rows are cards rather than a `List` and there is nothing to
    /// teach you that ⌘-click would work.
    private func toggle(_ record: DictationRecord) {
        if selection.contains(record.id) {
            selection.remove(record.id)
        } else {
            selection.insert(record.id)
        }
    }

    /// The row's second line, in two halves so the app's mark can sit between them.
    ///
    /// `upToApp` is everything before the mark — when, and how long — and the rest is the
    /// app's name and the style it was cleaned with.
    private func subtitle(_ record: DictationRecord, upToApp: Bool) -> String {
        let parts = upToApp
            ? [Self.stamp(record.date), String(format: "%.0fs", record.audioDuration)]
            : [record.targetAppName, record.promptName]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        // The separator belongs to whichever half is not last, so a row with no app and
        // no style does not trail one.
        guard upToApp, !text.isEmpty else { return text }
        let rest = [record.targetAppName, record.promptName].compactMap { $0 }
        return rest.isEmpty ? text : text + " ·"
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
