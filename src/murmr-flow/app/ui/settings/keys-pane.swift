import SwiftUI

/// Its own pane now: two keys, and honesty about conflicts.
struct KeysPane: View {

    @Bindable var settings: SettingsStore
    let dictation: DictationCoordinator

    var body: some View {
        PaneScroll(title: "Key binds") {
            SectionLabel(title: "Dictate")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: hotkeyBinding) {
                        ForEach(HotkeyMonitor.Trigger.allCases) { trigger in
                            Text(trigger.displayName).tag(trigger)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    if let conflict = HotkeyMonitor.conflict(for: settings.hotkey) {
                        Text(conflict)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        StatusChip(title: "Nothing else is using it", level: .ok)
                    }
                }
            }

            // The one caption that survives in the app. "Off" genuinely needs a sentence:
            // the label alone can't tell you what the other behaviour is.
            SettingRow(
                title: "Hold to talk",
                detail: settings.holdToTalk
                    ? nil
                    : "Press once to start, once to stop."
            ) {
                Toggle("", isOn: $settings.holdToTalk).labelsHidden()
            }

            SectionLabel(title: "Meetings")
            Card {
                HStack {
                    Text("No key set — meetings start from the window or the panel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if !dictation.hotkeyActive {
                WarningRow(
                    message: "The key watcher isn't running. Grant Accessibility, then "
                        + "restart Murmr Flow."
                )
            }
        }
    }

    /// Changing the key has to re-install the watcher, which is why this goes through the
    /// coordinator rather than writing the setting directly.
    private var hotkeyBinding: Binding<HotkeyMonitor.Trigger> {
        Binding(
            get: { settings.hotkey },
            set: { dictation.changeHotkey(to: $0) }
        )
    }
}
