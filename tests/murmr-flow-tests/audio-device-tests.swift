import Testing

@testable import MurmrFlow

/// A Bluetooth headset is one object to the person wearing it and two to Core Audio.
@Suite("Audio devices")
struct AudioDeviceTests {

    private func device(_ uid: String, bluetooth: Bool = true) -> AudioDeviceStore.Device {
        AudioDeviceStore.Device(
            id: uid, name: "Max’s Beats³", deviceID: 0,
            isDefault: true, isBluetooth: bluetooth
        )
    }

    @Test("the two halves of one headset are recognised as the same hardware")
    func headsetHalvesMatch() {
        // The exact UIDs a W1 headset reports. Comparing these directly says "different
        // device" about the thing on your head, which is what stopped the warning firing.
        let input = device("DC-D3-A2-B0-E1-60:input")
        let output = device("DC-D3-A2-B0-E1-60:output")
        #expect(AudioDeviceStore.isSameHardware(input, output))
    }

    @Test("two genuinely different devices stay different")
    func differentDevicesDoNotMatch() {
        let headset = device("DC-D3-A2-B0-E1-60:input")
        let speakers = device("BuiltInSpeakerDevice", bluetooth: false)
        #expect(!AudioDeviceStore.isSameHardware(headset, speakers))
    }

    @Test("a UID carrying no role suffix compares whole")
    func plainUIDsCompareWhole() {
        #expect(
            AudioDeviceStore.isSameHardware(
                device("BuiltInMicrophoneDevice", bluetooth: false),
                device("BuiltInMicrophoneDevice", bluetooth: false)
            ))
        #expect(
            !AudioDeviceStore.isSameHardware(
                device("BuiltInMicrophoneDevice", bluetooth: false),
                device("BuiltInSpeakerDevice", bluetooth: false)
            ))
    }

    /// The suffix is stripped from the end only. A device whose name happens to contain
    /// the word must not be truncated in the middle.
    @Test("only a trailing role suffix is dropped")
    func suffixStrippedOnlyAtTheEnd() {
        #expect(
            !AudioDeviceStore.isSameHardware(
                device("rig:input:main", bluetooth: false),
                device("rig:output:main", bluetooth: false)
            ))
    }
}
