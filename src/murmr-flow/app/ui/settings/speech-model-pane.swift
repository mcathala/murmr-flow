import SwiftUI

/// Which model turns speech into text.
///
/// Same rule as the clean-up pane: the one in use stays at the top, and nothing changes it
/// except a button that says so. What has been proved about a model is stored with that
/// model, so looking at the alternative does not discard it — and neither does relaunching.
struct SpeechModelPane: View {

    let loader: SpeechModelLoader
    let dictation: DictationCoordinator

    private var speech: SpeechModelStore { dictation.speech }

    var body: some View {
        PaneScroll(title: "Speech model") {
            SectionLabel(title: "In use")
            activeCard

            if case .failed(let message) = loader.state {
                WarningRow(message: message)
            }

            SectionLabel(title: "Other models")
            ForEach(speech.others) { model in
                alternativeRow(model)
            }
        }
    }

    // MARK: - Active

    private var activeCard: some View {
        let model = speech.activeModel
        return Card(highlighted: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.headline).font(.callout.weight(.semibold))
                        Text(model.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    badge(for: model)
                    Spacer(minLength: 0)
                }

                if case .downloading(let fraction) = loader.state {
                    ProgressView(value: fraction).controlSize(.small)
                }

                Divider()
                testRow
            }
        }
    }

    /// Proves the whole chain rather than just the download.
    ///
    /// "Ready" only ever meant the files were on disk and loaded. It said nothing about
    /// whether inference runs, which microphone is selected, or whether that microphone is
    /// muted — so the first time you found out was your first real dictation.
    private var testRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(dictation.isTestingSpeechModel
                     ? "Listening — say anything, then press Stop."
                     : "Say a few words and see what it hears.")
                    .font(.callout)
                Spacer(minLength: 0)
                Button(dictation.isTestingSpeechModel ? "Stop" : "Test") {
                    dictation.toggleSpeechModelTest()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if dictation.isTestingSpeechModel {
                ProgressView().controlSize(.small)
            } else if let heard = dictation.lastHeard {
                Text("Heard \u{201C}\(heard)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = speech.verification(for: speech.activeModel).failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Alternatives

    /// Listed, not selected. Clicking a card used to switch models immediately, which is
    /// the same mistake the provider pane made: looking was the same action as choosing.
    private func alternativeRow(_ model: SpeechModel) -> some View {
        Card {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.headline).font(.callout.weight(.medium))
                    Text(model.summary).font(.caption).foregroundStyle(.secondary)
                }
                availability(for: model)
                Spacer(minLength: 0)
                Button(SpeechModelLoader.isDownloaded(model) ? "Use" : "Download and use") {
                    dictation.changeSpeechModel(model)
                }
                .controlSize(.small)
                .disabled(loader.state.isBusy)
            }
        }
    }

    @ViewBuilder
    private func availability(for model: SpeechModel) -> some View {
        if SpeechModelLoader.isDownloaded(model) {
            if speech.verification(for: model).isWorking {
                StatusChip(title: "Downloaded · tested", level: .ok)
            } else {
                StatusChip(title: "Downloaded", level: .waiting)
            }
        } else {
            StatusChip(title: model.approximateSizeLabel, level: .waiting)
        }
    }

    /// Three states, as everywhere else: not ready, ready but unproved, proved.
    @ViewBuilder
    private func badge(for model: SpeechModel) -> some View {
        if dictation.isTestingSpeechModel {
            StatusChip(title: "Testing", level: .waiting)
        } else if loader.state.isBusy {
            StatusChip(title: "Getting ready", level: .waiting)
        } else {
            switch speech.verification(for: model) {
            case .working(let latency, _):
                StatusChip(title: "Working · \(String(format: "%.1fs", latency))", level: .ok)
            case .failed:
                StatusChip(title: "Not working", level: .bad)
            case .untested:
                StatusChip(
                    title: loader.models != nil ? "Not tested" : "Not loaded",
                    level: loader.models != nil ? .waiting : .bad
                )
            }
        }
    }
}

