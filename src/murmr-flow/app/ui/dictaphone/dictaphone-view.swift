import SwiftUI

/// Dictation, and what it produced.
///
/// The Cleaned/Raw toggle is the point of this screen. Until the raw transcript was kept,
/// there was no way to tell whether the model had improved your words or mangled them —
/// and no way to try a different prompt without saying it all again.
struct DictaphoneView: View {

    let dictation: DictationCoordinator
    let history: HistoryStore
    let prompts: PromptStore

    @State private var showingRaw = false
    @State private var selected: UUID?
    @State private var isRerunning = false

    var body: some View {
        PaneScroll {
            recordCard

            if let record = current {
                SectionLabel(title: selected == nil ? "Last dictation" : "Dictation")
                transcript(record)
            }

            if history.dictations.count > 1 {
                SectionLabel(title: "Earlier")
                list
            }

            if history.dictations.isEmpty {
                EmptyPane(
                    symbol: "mic",
                    title: "Nothing yet",
                    hint: "Hold \(dictation.settings.hotkey.displayName) anywhere and speak. "
                        + "The text lands wherever your cursor is."
                )
                .frame(minHeight: 220)
            }
        }
    }

    private var current: DictationRecord? {
        if let selected { return history.dictations.first { $0.id == selected } }
        return history.dictations.first
    }

    // MARK: - Record

    /// A button as well as the key — discoverable, and it still works if Accessibility
    /// isn't granted, when the global hotkey can't fire at all.
    private var recordCard: some View {
        Card(highlighted: dictation.stage.isRecording) {
            HStack(spacing: 12) {
                Button {
                    if dictation.stage.isRecording {
                        Task { await dictation.endDictation() }
                    } else {
                        dictation.beginDictation()
                    }
                } label: {
                    Label(
                        dictation.stage.isRecording ? "Stop" : "Dictate",
                        systemImage: dictation.stage.isRecording ? "stop.fill" : "mic.fill"
                    )
                    .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(dictation.stage.isRecording ? .red : .accentColor)
                .disabled(dictation.stage.isBusy && !dictation.stage.isRecording)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.callout.weight(.medium))
                    Text(subhead).font(.caption).foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Menu(prompts.dictationPrompt.name) {
                    ForEach(prompts.presets) { preset in
                        Button(preset.name) { prompts.dictationPromptID = preset.id }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var headline: String {
        if dictation.stage.isRecording {
            return String(format: "Listening — %.1fs", dictation.elapsed)
        }
        if dictation.stage.isBusy { return dictation.stage.label }
        return "Hold \(dictation.settings.hotkey.displayName) anywhere"
    }

    private var subhead: String {
        if dictation.stage.isRecording, !dictation.preview.isEmpty {
            return dictation.preview
        }
        if case .failed(let message) = dictation.stage { return message }
        return dictation.settings.holdToTalk
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
                    .disabled(isRerunning)
                    Spacer(minLength: 0)
                    Button {
                        history.delete(record)
                        selected = nil
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
                ForEach(Array(history.dictations.dropFirst().prefix(20))) { record in
                    Button {
                        selected = record.id
                    } label: {
                        HStack(spacing: 10) {
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

                    if record.id != history.dictations.dropFirst().prefix(20).last?.id {
                        Divider()
                    }
                }
            }
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
