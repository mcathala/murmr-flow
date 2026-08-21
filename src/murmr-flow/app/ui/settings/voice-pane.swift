import SwiftUI

/// Which model turns speech into text. Nothing else — the key binds moved out.
struct VoicePane: View {

    let models: ModelManager
    let dictation: DictationCoordinator

    var body: some View {
        PaneScroll(title: "Voice transcription") {
            SectionLabel(title: "Model")
            HStack(alignment: .top, spacing: 10) {
                ForEach(SpeechModel.allCases) { model in
                    modelCard(model)
                }
            }

            if case .failed(let message) = models.state {
                WarningRow(message: message)
            }

            SectionLabel(title: "Test")
            VoiceTestCard(dictation: dictation)

            SectionLabel(title: "Words to spell my way")
            CustomWordsCard(settings: dictation.settings)
        }
    }

    /// Phrased as a question about *you*, not about the model. "Multiple languages" is the
    /// choice being made; "Parakeet TDT v3" is trivia, and belongs in small text if
    /// anywhere.
    private func modelCard(_ model: SpeechModel) -> some View {
        let isSelected = models.selected == model
        return Button {
            dictation.changeSpeechModel(model)
        } label: {
            Card(highlighted: isSelected) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.headline).font(.callout.weight(.semibold))
                    Text(model.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    state(for: model, isSelected: isSelected)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func state(for model: SpeechModel, isSelected: Bool) -> some View {
        if isSelected {
            switch models.state {
            case .downloading(let fraction):
                ProgressView(value: fraction).controlSize(.small)
            case .preparing, .loading:
                StatusChip(title: "Getting ready", level: .waiting)
            case .ready:
                StatusChip(title: "Active", level: .ok)
            case .notLoaded, .failed:
                StatusChip(title: "Not loaded", level: .waiting)
            }
        } else if ModelManager.isDownloaded(model) {
            StatusChip(title: "Downloaded", level: .waiting)
        } else {
            StatusChip(title: "\(model.approximateSizeMB) MB download", level: .waiting)
        }
    }
}

/// Proves the whole chain rather than just the download.
///
/// "Ready" only ever meant the files were on disk and loaded. It said nothing about
/// whether inference runs, which microphone is selected, or whether that microphone is
/// muted — so the first time you found out was your first real dictation. This records a
/// few seconds and shows you the words back.
private struct VoiceTestCard: View {

    let dictation: DictationCoordinator

    var body: some View {
        Card(highlighted: dictation.voiceTest.isRunning) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(dictation.voiceTest.isRunning
                         ? "Listening — say anything."
                         : "Say a few words and see what it hears.")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button(dictation.voiceTest.isRunning ? "Stop" : "Test") {
                        dictation.toggleVoiceTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                switch dictation.voiceTest {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView().controlSize(.small)
                case .heard(let text, let seconds):
                    StatusChip(
                        title: "Heard \u{201C}\(text)\u{201D} · \(String(format: "%.1fs", seconds))",
                        level: .ok
                    )
                case .silent:
                    StatusChip(title: "Nothing was heard — check the microphone", level: .bad)
                case .failed(let message):
                    StatusChip(title: message, level: .bad)
                }
            }
        }
    }
}

/// Names and jargon, as a list rather than a comma-separated text field.
///
/// These now go to the **speech model**, not the cleanup prompt. Biasing the transcription
/// beats asking a language model to repair "cover a lee" into "Kovalee" afterwards — and
/// it works with clean-up switched off entirely.
private struct CustomWordsCard: View {

    @Bindable var settings: SettingsStore
    @State private var entry = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if settings.customWords.isEmpty {
                    Text("Add names the model keeps getting wrong.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    WrapChips(items: settings.customWords) { word in
                        settings.customWords.removeAll { $0 == word }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a word", text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .controlSize(.small)
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        let word = entry.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !settings.customWords.contains(word) else { return }
        settings.customWords.append(word)
        entry = ""
    }
}

/// Chips that wrap onto as many lines as they need.
struct WrapChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        // A flow layout via a wrapping HStack: `Grid` would force columns of equal width,
        // which looks wrong when the entries are "Léa" and "Anthropic".
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    onRemove(item)
                } label: {
                    HStack(spacing: 4) {
                        Text(item).font(.caption)
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: .capsule)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
    }
}

/// Lays children left to right, wrapping when the line runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var total = CGSize.zero

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > width, lineWidth > 0 {
                total.width = max(total.width, lineWidth - spacing)
                total.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        total.width = max(total.width, lineWidth - spacing)
        total.height += lineHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
