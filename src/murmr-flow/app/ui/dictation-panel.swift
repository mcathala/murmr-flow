import SwiftUI

/// Phase 1 harness: pick a model, record, transcribe, and read the timings.
///
/// This is how the Phase 1 gate is demonstrated — speak, see accurate text, and see
/// how long it took. The hotkey replaces the button in Phase 2.
struct DictationPanel: View {

    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelSection
            Divider()
            recordSection
            if !coordinator.transcript.isEmpty || coordinator.timing != nil {
                Divider()
                resultSection
            }
            if case .failed(let message) = coordinator.stage {
                Divider()
                errorRow(message)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Speech to text", systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { coordinator.models.selected },
                set: { coordinator.models.select($0) }
            )) {
                ForEach(SpeechModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(coordinator.models.state.isBusy || coordinator.stage.isBusy)

            Text(coordinator.models.selected.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)

            modelStateRow
        }
    }

    @ViewBuilder
    private var modelStateRow: some View {
        switch coordinator.models.state {
        case .notLoaded:
            HStack(spacing: 8) {
                Text("~\(coordinator.models.selected.approximateSizeMB) MB download")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download & load") {
                    Task { await coordinator.warmUp() }
                }
                .controlSize(.small)
            }

        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text("Downloading… \(Int(fraction * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model…").font(.caption2).foregroundStyle(.secondary)
            }

        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready on the Neural Engine")
                    .font(.caption2)
                if let duration = coordinator.models.loadDuration {
                    Text("· loaded in \(duration.seconds, format: .number.precision(.fractionLength(1)))s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let message):
            errorRow(message)
        }
    }

    // MARK: - Record

    private var recordSection: some View {
        HStack(spacing: 12) {
            Button {
                if coordinator.stage.isRecording {
                    Task { await coordinator.stopAndTranscribe() }
                } else {
                    coordinator.startRecording()
                }
            } label: {
                Label(
                    coordinator.stage.isRecording ? "Stop and transcribe" : "Record",
                    systemImage: coordinator.stage.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(coordinator.stage.isRecording ? .red : .accentColor)
            .disabled(coordinator.stage == .transcribing)

            if coordinator.stage.isRecording {
                Text("\(coordinator.elapsed, format: .number.precision(.fractionLength(1)))s")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
                Button("Cancel") { coordinator.cancelRecording() }
                    .controlSize(.small)
            }

            if coordinator.stage == .transcribing {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Result

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !coordinator.transcript.isEmpty {
                Text(coordinator.transcript)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
            }

            if let timing = coordinator.timing {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("Audio").foregroundStyle(.secondary)
                        Text("\(timing.audioDuration, format: .number.precision(.fractionLength(2)))s")
                            .monospaced()
                    }
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text("\(timing.modelTime, format: .number.precision(.fractionLength(3)))s")
                            .monospaced()
                    }
                    GridRow {
                        Text("End to end").foregroundStyle(.secondary)
                        Text("\(timing.endToEnd, format: .number.precision(.fractionLength(3)))s")
                            .monospaced()
                            .fontWeight(.semibold)
                    }
                    GridRow {
                        Text("Realtime").foregroundStyle(.secondary)
                        Text("\(timing.realtimeFactor, format: .number.precision(.fractionLength(0)))x")
                            .monospaced()
                    }
                    if let confidence = coordinator.confidence {
                        GridRow {
                            Text("Confidence").foregroundStyle(.secondary)
                            Text("\(confidence, format: .number.precision(.fractionLength(2)))")
                                .monospaced()
                        }
                    }
                }
                .font(.caption2)
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
