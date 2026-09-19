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

            bindCard(slot: .dictate, title: "Dictation", hotkey: settings.hotkey)

            bindCard(slot: .meeting, title: "Notetaker", hotkey: settings.meetingHotkey)

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
                        message: "Nothing starts when you press a hotkey \u{2014} Accessibility "
                            + "is off.",
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

    private func bindCard(slot: Slot, title: String, hotkey: Hotkey?) -> some View {
        let isRecording = recording == slot
        return Card(highlighted: isRecording) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(title).font(.callout.weight(.medium))

                    Spacer(minLength: 0)

                    if isRecording {
                        Text("Press a key…")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.tint)
                        Button("Cancel") { stopRecording() }
                            .controlSize(.small)
                    } else {
                        // Always a cap, set or not — see `Keycap`.
                        Keycap(text: hotkey?.displayName)
                        Button(hotkey == nil ? "Set" : "Change") { start(slot) }
                            .controlSize(.small)
                            // "Set" and "Change" are different lengths, and a row is not
                            // the place to discover that: the buttons sit in the same
                            // column whichever word is on them.
                            .frame(minWidth: 62)
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

            // No two binds may be the same key, or one of them silently never wins —
            // and styles hold keys now too, so "the other hotkey" is no longer the whole
            // question. `AppServices` is the one place that can see all of them.
            let current = slot == .dictate ? settings.hotkey : settings.meetingHotkey
            if captured == current { return }
            if let taken = services.whatUses(captured) {
                rejected = "\(captured.displayName) is already \(taken)."
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
///
/// An unset key is drawn as an empty cap rather than as nothing at all. The two rows in
/// this pane are built by the same function, but one had a key and one did not, so one
/// had a cap and one did not — and the buttons beside them landed in different places
/// down a list that is meant to read as a column. An empty cap keeps the shape, and says
/// "there is a key here, it is unset" rather than leaving the eye to infer it.
struct Keycap: View {
    let text: String?

    init(text: String?) { self.text = text }

    var body: some View {
        Text(text ?? "—")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(text == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // Wide enough for the longest key this app binds, so the buttons beside every
            // cap line up whatever is in it.
            .frame(minWidth: 34)
            .background(.background.secondary, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.separator, lineWidth: 1)
            }
    }
}
