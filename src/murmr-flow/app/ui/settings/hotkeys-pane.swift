import SwiftUI

/// The two hotkeys, recorded rather than chosen from a list — and what happens while one
/// is held.
///
/// It used to offer three fixed triggers. Three was an arbitrary number — it was what we
/// had implemented — so the answer to "which key" was whichever of ours you disliked least.
/// Now you press the key you want and the app takes it.
///
/// Pausing music moved here from Permissions, which had collected it along with a folder
/// path and a version string. It is not a permission; it is what holding the key does.
struct HotkeysPane: View {

    let services: AppServices

    private var settings: SettingsStore { services.settings }
    private var dictation: DictationCoordinator { services.dictation }

    /// Which bind is listening, if either. Only one at a time: two recorders would both
    /// swallow the same keypress.
    @State private var recording: Slot?
    @State private var recorder = HotkeyRecorder()
    @State private var rejected: String?

    private enum Slot: String, Identifiable {
        case dictate, meeting
        var id: String { rawValue }
    }

    var body: some View {
        PaneScroll(title: "Hotkeys") {
            SectionLabel(title: "Active")

            bindCard(
                slot: .dictate,
                title: "Dictation",
                hotkey: settings.hotkey,
                subtitle: nil
            )

            bindCard(
                slot: .meeting,
                title: "Notetaker",
                hotkey: settings.meetingHotkey,
                subtitle: settings.meetingHotkey == nil
                    ? "No key. Notes start from the pill or the window."
                    : nil
            )

            if let rejected {
                WarningRow(message: rejected)
            }

            SectionLabel(title: "Behaviour")

            // The one caption that survives in the app. "Off" genuinely needs a sentence:
            // the label alone cannot tell you what the other behaviour is.
            SettingRow(
                title: "Hold to talk",
                detail: settings.holdToTalk ? nil : "Press once to start, once to stop."
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.holdToTalk },
                    set: { settings.holdToTalk = $0 }
                ))
                .labelsHidden()
            }

            SettingRow(title: "Pause music while dictating") {
                Toggle("", isOn: Binding(
                    get: { settings.pauseMediaWhileDictating },
                    set: { settings.pauseMediaWhileDictating = $0 }
                ))
                .labelsHidden()
            }

            // Said once, here at the bottom, with a verb on the button. The Dictation
            // card's subtitle used to say it too, and the button was named after the pane
            // it went to rather than what it did.
            if !dictation.hotkeyActive {
                if services.permissions.accessibility != .granted {
                    WarningRow(
                        message: "Accessibility is off, so no hotkey will fire.",
                        action: ("Allow", { services.permissions.requestAccessibility() })
                    )
                } else {
                    WarningRow(
                        message: "The hotkey watcher isn\u{2019}t running. Quit and reopen "
                            + "Murmr Flow.",
                        action: ("Quit and reopen", { services.relaunch() })
                    )
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    // MARK: - One bind

    private func bindCard(
        slot: Slot, title: String, hotkey: Hotkey?, subtitle: String?
    ) -> some View {
        let isRecording = recording == slot
        return Card(highlighted: isRecording) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout.weight(.medium))
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)

                    if isRecording {
                        Text("Press a key…")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                        Button("Cancel") { stopRecording() }
                            .controlSize(.small)
                    } else {
                        if let hotkey {
                            Keycap(text: hotkey.displayName)
                        }
                        Button(hotkey == nil ? "Set" : "Change") { start(slot) }
                            .controlSize(.small)
                        // The Notetaker key is optional — the store keeps "cleared" as a
                        // state of its own — but there was no control that cleared it.
                        if slot == .meeting, hotkey != nil {
                            Button("Clear") { services.changeMeetingHotkey(to: nil) }
                                .controlSize(.small)
                                .help("Start Notetaker only from the pill or the window")
                        }
                    }
                }

                if isRecording {
                    Text("Escape cancels. Modifiers can be combined — fn with ⇧, say. A "
                         + "letter on its own won't be accepted; it would fire every time "
                         + "you typed it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let hotkey {
                    if let conflict = HotkeyMonitor.conflict(for: hotkey) {
                        WarningRow(message: conflict)
                    }
                    if let warning = HotkeyMonitor.systemFnWarning(for: hotkey) {
                        WarningRow(
                            message: warning,
                            action: ("Open Keyboard Settings", { HotkeyMonitor.openKeyboardSettings() })
                        )
                    } else if hotkey.usesFn {
                        // The app takes the 🌐 key's system job for itself while fn is a
                        // hotkey. Done silently until now; the person deserves to know
                        // where their emoji picker went.
                        Text("While fn is your hotkey, its usual job — emoji, switching "
                             + "input sources — is paused.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Recording

    private func start(_ slot: Slot) {
        rejected = nil
        recording = slot
        recorder.onFinish = { captured in
            defer { recording = nil }
            guard let captured else { return }  // Escape

            // The two binds must not be the same key, or one of them silently never wins.
            let other = slot == .dictate ? settings.meetingHotkey : settings.hotkey
            if captured == other {
                rejected = "\(captured.displayName) is already used by the other hotkey."
                return
            }

            switch slot {
            case .dictate: services.changeDictationHotkey(to: captured)
            case .meeting: services.changeMeetingHotkey(to: captured)
            }
        }
        recorder.start()
    }

    private func stopRecording() {
        recorder.stop()
        recording = nil
    }
}

/// A key drawn as a key, so it is recognised rather than read.
struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.background.secondary, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.separator, lineWidth: 1)
            }
    }
}
