import SwiftUI

/// The menu bar: the only surface that is always there.
///
/// The app has no Dock icon, so when the window is closed this is the whole interface —
/// and it is the only sign that a meeting is still recording after the panel has been
/// hidden. So it carries live state and the one control you can't reach otherwise, then
/// hands off.
struct MenuBarContent: View {

    let services: AppServices

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if services.meetings.stage.isRecording {
                Button {
                    services.meetings.toggle()
                } label: {
                    Label(
                        "Stop meeting · \(MeetingTranscript.clock(services.meetings.elapsed))",
                        systemImage: "stop.fill"
                    )
                }
                .controlSize(.small)
            } else {
                Button {
                    services.meetings.toggle()
                } label: {
                    Label("Start meeting", systemImage: "record.circle")
                }
                .controlSize(.small)
                .disabled(services.dictation.stage.isRecording)
            }

            let notes = services.notes.notes.prefix(3)
            if !notes.isEmpty {
                Divider()
                SectionLabel(title: "Recent notes")
                ForEach(notes) { note in
                    Button {
                        services.notes.open(note)
                    } label: {
                        Text(note.title).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }

            Divider()

            Button("Open Murmr Flow") { openWindow(id: MurmrFlowApp.mainWindowID) }
                .controlSize(.small)
            Button("Settings…") {
                services.openSettings()
                openWindow(id: MurmrFlowApp.mainWindowID)
            }
            .controlSize(.small)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(12)
        .frame(width: 250)
        .onAppear { services.notes.reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Murmr Flow").font(.subheadline.weight(.medium))
                Text(statusText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusColor: Color {
        if services.meetings.stage.isRecording { return .red }
        if services.dictation.stage.isBusy { return .orange }
        if !services.permissions.allGranted { return .orange }
        return services.dictation.hotkeyActive ? .green : .orange
    }

    private var statusText: String {
        if services.meetings.stage.isRecording { return "Recording a meeting" }
        if services.dictation.stage.isBusy { return services.dictation.stage.label }
        if !services.permissions.allGranted { return "Permissions needed" }
        return services.dictation.hotkeyActive
            ? "Hold \(services.dictation.settings.hotkey.displayName)"
            : "Hotkey not active"
    }
}
