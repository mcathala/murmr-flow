import SwiftUI

/// The only pane that should ever look empty.
///
/// Granted permissions collapse to a single line. Anything that needs attention is at the
/// top, outlined, with the button that fixes it. The build-signing warning that used to
/// live on this screen is gone — that was a message for a terminal.
struct PermissionsPane: View {

    let permissions: PermissionManager
    @Bindable var settings: SettingsStore
    let notes: MeetingStore

    var body: some View {
        PaneScroll(title: "Permissions") {
            if permissions.allGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("All permissions granted.").font(.callout)
                    Spacer(minLength: 0)
                    Button("Re-check") { permissions.refresh() }
                        .controlSize(.small)
                }
            } else {
                if permissions.accessibility != .granted {
                    WarningRow(
                        message: "Accessibility is off, so dictation copies to the "
                            + "clipboard instead of typing.",
                        action: ("Open Settings", { permissions.openAccessibilitySettings() })
                    )
                }
                if permissions.microphone != .granted {
                    WarningRow(
                        message: "The microphone isn't available.",
                        action: (
                            permissions.microphone == .notDetermined ? "Ask" : "Open Settings",
                            {
                                if permissions.microphone == .notDetermined {
                                    Task { await permissions.requestMicrophone() }
                                } else {
                                    permissions.openMicrophoneSettings()
                                }
                            }
                        )
                    )
                }
            }

            // System audio has no API to query, so there is nothing honest to show until
            // a meeting actually asks for it. Saying "granted" here would be a guess.
            Text("System audio is requested the first time you record a meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SectionLabel(title: "Behaviour")
            SettingRow(title: "Pause music while dictating") {
                Toggle("", isOn: $settings.pauseMediaWhileDictating).labelsHidden()
            }

            SectionLabel(title: "Notes")
            Card {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Where notes are saved").font(.callout.weight(.medium))
                        Text(MeetingStore.folder.path(percentEncoded: false))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button("Open") { notes.openFolder() }
                        .controlSize(.small)
                }
            }

            SectionLabel(title: "About")
            Text("Murmr Flow \(Self.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { permissions.refresh() }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
