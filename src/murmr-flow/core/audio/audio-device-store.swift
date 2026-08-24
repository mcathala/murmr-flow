import CoreAudio
import Foundation
import Observation
import OSLog

/// The microphones and outputs the Mac currently has, and which ones we are using.
///
/// Devices are remembered by **UID rather than by `AudioDeviceID`**, because the numeric
/// ID is assigned at connect time and is reused: unplug a headset and plug in a different
/// one and yesterday's ID can silently name today's other device. The UID is stable for
/// the life of the hardware, which is what a saved preference needs.
///
/// A device that is chosen and then unplugged is *not* forgotten. The selection stays and
/// falls back to the system default until the device comes back, which is what someone
/// who always records on the same interface expects.
@MainActor
@Observable
final class AudioDeviceStore {

    struct Device: Identifiable, Sendable, Equatable {
        let id: String  // the UID
        let name: String
        let deviceID: AudioDeviceID
        let isDefault: Bool
        /// Bluetooth devices are called out in the picker because choosing one as the
        /// microphone is what costs the user their listening quality.
        let isBluetooth: Bool
    }

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "audio-devices")

    private(set) var inputs: [Device] = []
    private(set) var outputs: [Device] = []

    private let settings: SettingsStore
    private var listener: AudioObjectPropertyListenerBlock?

    /// UID the user picked for recording, or nil for "follow the system".
    var selectedInputUID: String? {
        get { settings.inputDeviceUID }
        set {
            settings.inputDeviceUID = newValue
            refresh()
        }
    }

    /// The microphone recording should actually open, resolved against what is plugged in
    /// right now. Nil means "no preference" — let Core Audio pick the default.
    var selectedInputDeviceID: AudioDeviceID? {
        guard let uid = selectedInputUID else { return nil }
        return inputs.first { $0.id == uid }?.deviceID
    }

    /// What the picker should show as ticked. Falls back to the system default when the
    /// chosen device is unplugged, matching what recording would actually do.
    var effectiveInput: Device? {
        if let uid = selectedInputUID, let match = inputs.first(where: { $0.id == uid }) {
            return match
        }
        return inputs.first { $0.isDefault }
    }

    var currentOutput: Device? { outputs.first { $0.isDefault } }

    /// Whether an input and an output are two faces of one physical device.
    ///
    /// They are not one Core Audio object. A Bluetooth headset shows up as a *pair* —
    /// `DC-D3-A2-B0-E1-60:input` alongside `DC-D3-A2-B0-E1-60:output` — so comparing UIDs
    /// directly says "different device" about the thing on your head. Dropping the role
    /// suffix compares the hardware, which is the question actually being asked.
    nonisolated static func isSameHardware(_ one: Device, _ other: Device) -> Bool {
        baseUID(one.id) == baseUID(other.id)
    }

    nonisolated private static func baseUID(_ uid: String) -> String {
        for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }

    init(settings: SettingsStore) {
        self.settings = settings
        refresh()
        observeChanges()
    }

    // MARK: - Reading the hardware

    func refresh() {
        let defaultIn = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defaultOut = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)

        var seenInputs: [Device] = []
        var seenOutputs: [Device] = []

        for device in Self.allDevices() {
            guard let uid = Self.uid(device) else { continue }
            let name = Self.name(device)
            let bluetooth = Self.isBluetooth(device)

            if Self.channelCount(device, scope: kAudioObjectPropertyScopeInput) > 0 {
                seenInputs.append(
                    Device(
                        id: uid, name: name, deviceID: device,
                        isDefault: device == defaultIn, isBluetooth: bluetooth
                    ))
            }
            if Self.channelCount(device, scope: kAudioObjectPropertyScopeOutput) > 0 {
                seenOutputs.append(
                    Device(
                        id: uid, name: name, deviceID: device,
                        isDefault: device == defaultOut, isBluetooth: bluetooth
                    ))
            }
        }

        // Only publish on a real change: this runs on every device notification, and
        // @Observable would otherwise redraw the picker for nothing.
        if seenInputs != inputs { inputs = seenInputs }
        if seenOutputs != outputs { outputs = seenOutputs }
    }

    /// Makes `device` the Mac's output, exactly as the Sound menu would.
    ///
    /// This changes a *system* setting rather than something local to the app, which is
    /// unusual enough to be worth saying out loud in the UI. It earns its place because
    /// the app is entirely about what you are listening to, and noticing you are on the
    /// wrong output belongs in the moment before you record, not three menus away.
    func selectOutput(_ device: Device) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device.deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        if status != noErr {
            Self.log.error("could not switch output: \(status, privacy: .public)")
        }
        refresh()
    }

    // MARK: - Staying current

    /// Watches for hardware appearing, disappearing, or the system default moving.
    private func observeChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block

        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, block
            )
        }
    }

    // MARK: - Core Audio

    private static func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var devices = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func channelCount(
        _ device: AudioObjectID, scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
            size > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func uid(_ device: AudioObjectID) -> String? {
        stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private static func name(_ device: AudioObjectID) -> String {
        stringProperty(device, kAudioObjectPropertyName) ?? "Unknown device"
    }

    private static func stringProperty(
        _ device: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value == kAudioDeviceTransportTypeBluetooth
            || value == kAudioDeviceTransportTypeBluetoothLE
    }
}
