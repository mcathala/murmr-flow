import SwiftUI

/// One button, and whatever the last meeting produced.
struct MeetingsTab: View {

    @Bindable var meetings: MeetingCoordinator

    var body: some View {
        TabScroll {
            statusBanner
            controls
            Divider()
            if let result = meetings.lastResult {
                lastMeeting(result)
            } else {
                emptyHint
            }
            if case .failed(let message) = meetings.stage {
                WarningRow(message: message)
                if message.contains("System Audio Recording") {
                    Button("Open Privacy & Security") {
                        meetings.openSystemAudioSettings()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Status

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .overlay {
                    if meetings.stage.isRecording {
                        Circle()
                            .stroke(statusColor.opacity(0.4), lineWidth: 5)
                            .scaleEffect(1.8)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle).font(.subheadline.weight(.medium))
                Text(statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.10), in: .rect(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch meetings.stage {
        case .recording: .red
        case .transcribing: .orange
        case .saved: .green
        case .failed: .red
        case .idle: .secondary
        }
    }

    private var statusTitle: String {
        switch meetings.stage {
        case .idle: "No meeting running"
        case .recording: "Recording the meeting"
        case .transcribing(let step): step.label
        case .saved: "Note saved"
        case .failed: "Something went wrong"
        }
    }

    private var statusDetail: String {
        switch meetings.stage {
        case .idle:
            "Captures your microphone and everything this Mac plays. Nothing leaves the "
                + "machine, and the audio is deleted once the note is written."
        case .recording:
            "Elapsed \(MeetingTranscript.clock(meetings.elapsed)) — press Stop when the "
                + "meeting ends."
        case .transcribing:
            "Runs faster than real time, so a long meeting still finishes quickly."
        case .saved:
            "Saved as a Markdown file you own."
        case .failed(let message):
            message
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                meetings.toggle()
            } label: {
                Label(
                    meetings.stage.isRecording ? "Stop meeting" : "Start meeting",
                    systemImage: meetings.stage.isRecording ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(meetings.stage.isRecording ? .red : .accentColor)
            .disabled(isTranscribing)

            if meetings.stage.isRecording {
                Button("Discard") { meetings.discard() }
            }

            Button {
                meetings.openNotesFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open the meeting notes folder")
        }
    }

    private var isTranscribing: Bool {
        if case .transcribing = meetings.stage { return true }
        return false
    }

    // MARK: - Result

    private func lastMeeting(_ result: MeetingCoordinator.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Last meeting", icon: "text.book.closed")

            DetailGrid {
                GridRow {
                    Text("Length").foregroundStyle(.secondary)
                    Text(MeetingTranscript.clock(result.transcript.duration))
                        .monospacedDigit()
                }
                GridRow {
                    Text("Turns").foregroundStyle(.secondary)
                    Text("\(result.transcript.utterances.count)").monospacedDigit()
                }
                GridRow {
                    Text("Transcribed in").foregroundStyle(.secondary)
                    Text(String(format: "%.1fs", result.processingTime)).monospacedDigit()
                }
                GridRow {
                    Text("Saved to").foregroundStyle(.secondary)
                    Text(result.file.lastPathComponent)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 8) {
                Button("Open note") { meetings.openLastNote() }
                Button("Show in Finder") { meetings.revealLastNote() }
            }
            .controlSize(.small)

            if result.transcript.isEmpty {
                WarningRow(
                    message: "Nothing was transcribed. Check that the meeting audio was "
                        + "playing through this Mac and that the microphone was not muted."
                )
            } else {
                preview(result.transcript)
            }
        }
    }

    /// The first few turns, so it is obvious at a glance whether the labelling came out
    /// right — that is the part most likely to be wrong.
    private func preview(_ transcript: MeetingTranscript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(transcript.utterances.prefix(4)) { utterance in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(utterance.speaker.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(utterance.speaker == .you ? .blue : .purple)
                        Text(utterance.timestamp)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(utterance.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if transcript.utterances.count > 4 {
                Text("…and \(transcript.utterances.count - 4) more in the note.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "How it works", icon: "info.circle")
            Text("Your microphone becomes \"You\". Everything this Mac plays becomes "
                 + "\"Them\". Both are transcribed on this machine after you stop, then "
                 + "the audio is deleted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Wear headphones if you can. On speakers your microphone also hears the "
                 + "other person, which blurs the labels.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
