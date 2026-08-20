import SwiftUI

/// The menu-bar popover: status at a glance, and a way back to the window.
///
/// Deliberately thin. The menu bar is unreliable as a primary surface — on a crowded
/// bar the icon can be pushed out of sight entirely — so it summarises and hands off
/// rather than duplicating the window.
struct MenuBarContent: View {

    let permissions: PermissionManager
    let dictation: DictationCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Murmr Flow").font(.subheadline.weight(.medium))
                    Text(statusText).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let run = dictation.lastRun {
                Divider()
                Text(run.finalText)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy last dictation") {
                    TextInjector.copyToClipboard(run.finalText)
                }
                .controlSize(.small)
            }

            Divider()

            Button("Open Murmr Flow") { openWindow(id: MurmrFlowApp.panelWindowID) }
                .controlSize(.small)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(12)
        .frame(width: 240)
    }

    private var statusColor: Color {
        if dictation.stage.isBusy { return .orange }
        if !permissions.allGranted { return .red }
        return dictation.hotkeyActive ? .green : .red
    }

    private var statusText: String {
        if dictation.stage.isBusy { return dictation.stage.label }
        if !permissions.allGranted { return "Permissions needed" }
        return dictation.hotkeyActive
            ? "Hold \(dictation.settings.hotkey.displayName)"
            : "Hotkey not active"
    }
}
