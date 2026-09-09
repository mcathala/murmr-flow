import SwiftUI

/// Dictation, and what it produced.
///
/// The Cleaned/Raw toggle is the point of this screen. Until the raw transcript was kept,
/// there was no way to tell whether the model had improved your words or mangled them —
/// and no way to try a different prompt without saying it all again.
struct DictationView: View {

    let dictation: DictationCoordinator
    let history: HistoryStore
    let prompts: PromptStore

    private var settings: SettingsStore { dictation.settings }

    @State private var showingRaw = false
    /// A set, so a batch can go at once. Same reasoning as Notes: one-at-a-time is fine
    /// for a mistake and useless for a clear-out.
    @State private var selection: Set<UUID> = []
    @State private var isRerunning = false
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
                    if selection.count < history.dictations.count {
                        Button("Select all") { selection = Set(history.dictations.map(\.id)) }
                            .controlSize(.small)
                    }
                    if !selection.isEmpty {
                        Button("Clear") { selection = [] }
                            .controlSize(.small)
                    }
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

    /// Why Re-run cannot run, or nil when it can. The button used to be live in exactly
    /// the cases where pressing it did nothing.
    private var rerunBlocker: String? {
        if !settings.cleanupEnabled { return "Clean-up is off for dictation" }
        if !dictation.providers.isUsable(dictation.providers.activeID) {
            return "No AI is connected"
        }
        return nil
    }

    // MARK: - Transcript

    private func transcript(_ record: DictationRecord) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(Self.stamp(record.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let app = record.targetAppName {
                        Text("· \(app)").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Picker("", selection: $showingRaw) {
                        Text("Cleaned").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                Text(showingRaw ? record.rawText : record.finalText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if record.usedRawFallback {
                    Text("Clean-up didn't run for this one, so both views are the same.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

                HStack(spacing: 8) {
                    Button("Copy") {
                        TextInjector.copyToClipboard(
                            showingRaw ? record.rawText : record.finalText
                        )
                    }
                    Button("Insert again") {
                        try? TextInjector.inject(showingRaw ? record.rawText : record.finalText)
                    }
                    Button(isRerunning ? "Re-running…" : "Re-run clean-up") {
                        isRerunning = true
                        Task {
                            await dictation.rerunCleanup(on: record)
                            isRerunning = false
                        }
                    }
                    .disabled(isRerunning || rerunBlocker != nil)
                    .help(rerunBlocker ?? "Clean this transcript up again with the current style")
                    Spacer(minLength: 0)
                    Button {
                        selection = [record.id]
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
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
                                Text(subtitle(record))
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

    private func subtitle(_ record: DictationRecord) -> String {
        [
            Self.stamp(record.date),
            String(format: "%.0fs", record.audioDuration),
            record.targetAppName,
            record.promptName,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
