import SwiftUI

/// Which microphone records you, and what the Mac is playing through.
///
/// The pair belongs together and belongs on Home, because between them they are the whole
/// physical setup: one decides what the app hears from you, the other decides what you
/// hear — and on a Bluetooth headset the two are entangled in a way that costs audio
/// quality, so seeing them side by side is the point.
///
/// The two rows are not quite the same kind of thing — the microphone is a preference
/// this app keeps, while the output has nothing app-local to set (Murmr Flow never plays
/// audio) and so moves the Mac's own default. That is left for the user to discover by
/// using it. Two rows of caption explaining it were more words than the whole rest of the
/// card, which is the usual sign the captions were wrong rather than the labels.
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

            Text("Microphone").font(Theme.Text.bodyStrong)

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

            // Picking one here moves the Mac's own default output, not a setting of this
            // app's — so the row says whose setting it is rather than leaving that to be
            // discovered when the music moves.
            // "Speaker", because that is the thing, and the caption underneath said what
            // the row plainly does. A label that needs a sentence explaining it is the
            // wrong label.
            Text("Speaker").font(Theme.Text.bodyStrong)

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
                Text(devices.currentOutput?.name ?? "No speaker").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 190, alignment: .trailing)
            .fixedSize()
        }
    }

    /// Only ever shown when opening the microphone actually failed, which is the one
    /// thing here worth spending a line of prose on.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Text.small)
            .foregroundStyle(Theme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
