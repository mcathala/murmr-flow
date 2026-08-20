import SwiftUI

/// The only tab worth opening day to day: is the hotkey armed, and what did the last
/// dictation produce.
struct DictateTab: View {

    @Bindable var dictation: DictationCoordinator
    let permissions: PermissionManager

    var body: some View {
        TabScroll {
            armedBanner
            recordRow
            if let run = dictation.lastRun {
                Divider()
                lastRun(run)
            } else {
                Divider()
                emptyHint
            }
            if case .failed(let message) = dictation.stage {
                WarningRow(message: message)
            }
        }
    }

    // MARK: - Armed state

    /// Until you press it, the only evidence the hotkey works is a line of text. This
    /// makes "is it listening" answerable at a glance.
    private var armedBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(armedColor)
                .frame(width: 9, height: 9)
                .overlay {
                    if dictation.hotkeyActive && !dictation.stage.isBusy {
                        Circle()
                            .stroke(armedColor.opacity(0.4), lineWidth: 5)
                            .scaleEffect(1.8)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(armedTitle).font(.subheadline.weight(.medium))
                Text(armedDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(armedColor.opacity(0.10), in: .rect(cornerRadius: 8))
    }

    private var armedColor: Color {
        if dictation.stage.isBusy { return .orange }
        return dictation.hotkeyActive ? .green : .red
    }

    private var armedTitle: String {
        if dictation.stage.isBusy { return dictation.stage.label }
        return dictation.hotkeyActive ? "Listening for your hotkey" : "Hotkey not active"
    }

    private var armedDetail: String {
        if dictation.stage.isRecording {
            return String(format: "Recording — %.1fs", dictation.elapsed)
        }
        if dictation.stage.isBusy { return "Working…" }
        if dictation.hotkeyActive {
            return "Hold \(dictation.settings.hotkey.displayName) anywhere, speak, release."
        }
        return permissions.accessibility == .granted
            ? "Could not install the key watcher. Try restarting Murmr Flow."
            : "Grant Accessibility in Setup, then restart Murmr Flow."
    }

    // MARK: - Controls

    private var recordRow: some View {
        HStack(spacing: 8) {
            Button {
                if dictation.stage.isRecording {
                    Task { await dictation.endDictation() }
                } else {
                    dictation.beginDictation()
                }
            } label: {
                Label(
                    dictation.stage.isRecording ? "Stop" : "Record manually",
                    systemImage: dictation.stage.isRecording
                        ? "stop.circle.fill" : "mic.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(dictation.stage.isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(dictation.stage.isBusy && !dictation.stage.isRecording)

            if dictation.stage.isRecording {
                Button("Cancel") { dictation.cancelDictation() }
                    .controlSize(.large)
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title: "No dictation yet", icon: "text.quote")
            Text("Hold your hotkey and say something. The text is typed wherever your "
                 + "cursor is, and appears here too.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Last run

    private func lastRun(_ run: DictationCoordinator.Run) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "Last dictation", icon: "text.quote")
                Spacer()
                if let app = run.targetApp {
                    Text("→ \(app)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Text(run.finalText)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))

            if run.usedRawFallback {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Raw transcript — cleanup didn't run.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if run.rawTranscript != run.finalText {
                DisclosureGroup("Before cleanup") {
                    Text(run.rawTranscript)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .font(.caption2)
            }

            if let note = run.note { WarningRow(message: note) }

            timings(run.timing)
        }
    }

    /// One line rather than a four-row grid — the breakdown only matters when something
    /// is slow, and the total is what you actually glance at.
    private func timings(_ timing: DictationCoordinator.Timing) -> some View {
        HStack(spacing: 4) {
            Text("Audio \(timing.audioDuration, format: .number.precision(.fractionLength(1)))s")
            Text("·")
            Text("Transcribe \(timing.transcribeTime, format: .number.precision(.fractionLength(2)))s")
            if timing.cleanupTime > 0 {
                Text("·")
                Text("Cleanup \(timing.cleanupTime, format: .number.precision(.fractionLength(2)))s")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .overlay(alignment: .bottomLeading) {
            Text("Total \(timing.endToEnd, format: .number.precision(.fractionLength(2)))s")
                .font(.caption2.weight(.medium))
                .offset(y: 14)
        }
        .padding(.bottom, 14)
    }
}
