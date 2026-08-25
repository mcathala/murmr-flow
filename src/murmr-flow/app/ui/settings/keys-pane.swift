import SwiftUI

/// The two hotkeys, recorded rather than chosen from a list.
///
/// It used to offer three fixed triggers. Three was an arbitrary number — it was what we
/// had implemented — so the answer to "which key" was whichever of ours you disliked least.
/// Now you press the key you want and the app takes it.
struct KeysPane: View {

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
                subtitle: dictation.hotkeyActive
                    ? nil
                    : "The hotkey watcher isn't running, so this won't fire."
            )

            bindCard(
                slot: .meeting,
                title: "Notetaker",
                hotkey: settings.meetingHotkey,
                subtitle: settings.meetingHotkey == nil
                    ? "Not set — meetings start from the panel or the window."
                    : nil
            )

            if let rejected {
                WarningRow(message: rejected)
            }

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

            if !dictation.hotkeyActive {
                WarningRow(
                    message: "Grant Accessibility, then restart Murmr Flow, or no hotkey "
                        + "will fire."
                )
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
                        if hotkey != nil, slot == .meeting {
                            // Only the meeting bind can be cleared. Removing the dictation
                            // key would leave the app's main action with no way to start.
                            Button("Clear") { services.changeMeetingHotkey(to: nil) }
                                .controlSize(.small)
                        }
                    }
                }

                if isRecording {
                    Text("Escape cancels. A letter on its own won't be accepted — it would "
                         + "fire every time you typed it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let hotkey, let conflict = HotkeyMonitor.conflict(for: hotkey) {
                    Text(conflict).font(.caption).foregroundStyle(.orange)
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
            case .dictate: dictation.changeHotkey(to: captured)
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
