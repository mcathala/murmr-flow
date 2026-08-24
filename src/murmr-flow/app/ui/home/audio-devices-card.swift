import SwiftUI

/// Which microphone records you, and what the Mac is playing through.
///
/// The pair belongs together and belongs on Home, because between them they are the whole
/// physical setup: one decides what the app hears from you, the other decides what you
/// hear — and on a Bluetooth headset the two are entangled in a way that costs audio
/// quality, so seeing them side by side is the point.
///
/// The asymmetry is intentional and labelled. The microphone is *ours*: a preference this
/// app keeps, that changes nothing outside it. The output is the *Mac's*: there is nothing
/// app-local to set, because Murmr Flow never plays audio, so choosing here moves the
/// system's own output the way the Sound menu would.
struct AudioDevicesCard: View {

    let services: AppServices
    @State private var probe = MicLevelProbe()

    private var devices: AudioDeviceStore { services.audioDevices }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                microphoneRow
                Divider().overlay(Theme.Palette.hairline)
                outputRow
                if let warning { hint(warning) }
                if let failure = probe.failure { hint(failure) }
            }
        }
    }

    // MARK: - Microphone

    private var microphoneRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone").font(Theme.Text.bodyStrong)
                Text("Records your side. Only this app.")
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
            }

            Spacer(minLength: 8)

            if probe.isRunning {
                LevelMeter(label: "", level: probe.level)
                    .transition(.opacity)
            }

            Button(probe.isRunning ? "Stop" : "Test") {
                probe.toggle(device: devices.selectedInputDeviceID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(services.meetings.isRecording || services.dictation.stage.isRecording)
            .help("Open the microphone for a few seconds and watch the meter")

            Menu {
                Button {
                    devices.selectedInputUID = nil
                } label: {
                    Label(
                        "System default",
                        systemImage: devices.selectedInputUID == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(devices.inputs) { device in
                    Button {
                        devices.selectedInputUID = device.id
                    } label: {
                        Label(
                            menuTitle(for: device),
                            systemImage: devices.selectedInputUID == device.id ? "checkmark" : "")
                    }
                }
            } label: {
                Text(inputTitle).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 190, alignment: .trailing)
            .fixedSize()
        }
    }

    private var inputTitle: String {
        guard let effective = devices.effectiveInput else { return "No microphone" }
        return devices.selectedInputUID == nil ? "\(effective.name) (default)" : effective.name
    }

    private func menuTitle(for device: AudioDeviceStore.Device) -> String {
        var title = device.name
        if device.isBluetooth { title += " (Bluetooth)" }
        if device.isDefault { title += " — system default" }
        return title
    }

    // MARK: - Output

    private var outputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Output").font(Theme.Text.bodyStrong)
                Text("What gets recorded as them. Changes the Mac's output.")
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
            }

            Spacer(minLength: 8)

            Menu {
                ForEach(devices.outputs) { device in
                    Button {
                        devices.selectOutput(device)
                    } label: {
                        Label(
                            menuTitle(for: device),
                            systemImage: device.isDefault ? "checkmark" : "")
                    }
                }
            } label: {
                Text(devices.currentOutput?.name ?? "No output").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 190, alignment: .trailing)
            .fixedSize()
        }
    }

    // MARK: - The Bluetooth trap

    /// Says the quiet part out loud, and only when it applies.
    ///
    /// Recording from a Bluetooth headset's microphone forces the link into hands-free
    /// mode, which drops what the user is *listening to* to 16 kHz mono. It is a Bluetooth
    /// constraint rather than something the app can code around, so the only honest move
    /// is to name it at the moment the user is choosing, next to the control that fixes it.
    private var warning: String? {
        guard let input = devices.effectiveInput, input.isBluetooth,
            let output = devices.currentOutput,
            AudioDeviceStore.isSameHardware(input, output)
        else { return nil }
        return "Recording from \(input.name) drops its audio to phone quality while you "
            + "record — Bluetooth can't do a microphone and full-quality sound at once. "
            + "Pick a different microphone to keep the music clean."
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Text.small)
            .foregroundStyle(Theme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
