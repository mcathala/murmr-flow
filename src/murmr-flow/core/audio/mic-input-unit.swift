import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog

/// Captures one microphone, chosen explicitly, and hands buffers to a callback.
///
/// **This exists because `AVAudioEngine` cannot record from a device you name.** Reading
/// `engine.inputNode` opens the *current default* input device, and only then can its
/// audio unit be pointed somewhere else — by which time the damage is done. On a
/// Bluetooth headset that first touch is what drags the link from A2DP into hands-free
/// mode, collapsing the user's music to 16 kHz mono, and it stays there. Measured: pinning
/// an `AVAudioEngine` to the built-in microphone still took the headset's output from
/// 48000 Hz to 16000 Hz, even though the engine did then read the built-in microphone.
///
/// AUHAL takes the device *before* `AudioUnitInitialize`, so a microphone we did not ask
/// for is never opened at all. Same measurement through this path: 48000 Hz throughout,
/// 379 buffers delivered from the built-in microphone while the headset kept playing music
/// at full quality.
///
/// The buffers arrive on the real-time audio thread. The callback must copy and return.
final class MicInputUnit: @unchecked Sendable {

    enum UnitError: LocalizedError {
        case unavailable
        case noInputDevice
        case configurationFailed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "The audio input component is unavailable."
            case .noInputDevice:
                "No microphone is available. Check your input device in Sound settings."
            case .configurationFailed(let stage, let status):
                "Could not open the microphone (\(stage) failed, error \(status))."
            }
        }
    }

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "mic-input")

    /// Bus 1 is the input side of an AUHAL unit; bus 0 is the output side we never use.
    private static let inputBus: AudioUnitElement = 1
    private static let outputBus: AudioUnitElement = 0

    private let unit: AudioUnit
    private let onBuffer: (UnsafePointer<AudioBufferList>) -> Void

    /// Scratch buffers for `AudioUnitRender`, allocated once. Allocating per callback on
    /// the audio thread is exactly the sort of thing that produces glitches.
    private let scratch: UnsafeMutableAudioBufferListPointer
    private let scratchBytes: [UnsafeMutableRawPointer]
    private let bytesPerFrame: UInt32
    private let maxFrames: UInt32

    /// Format the device actually delivers, which the caller needs to convert from.
    let format: AVAudioFormat

    private(set) var isRunning = false

    /// Opens `device`, or the system default input when it is nil.
    ///
    /// Nothing is captured until `start()`. The device is fixed for the unit's lifetime:
    /// changing microphone mid-recording would change the format underneath the writer,
    /// so the caller stops and builds a new one instead.
    init(
        device: AudioDeviceID?,
        onBuffer: @escaping (UnsafePointer<AudioBufferList>) -> Void
    ) throws {
        self.onBuffer = onBuffer

        guard let resolved = device ?? Self.defaultInputDevice() else {
            throw UnitError.noInputDevice
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw UnitError.unavailable
        }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created), "instance")
        guard let created else { throw UnitError.unavailable }
        self.unit = created

        // Order matters throughout. Enable the input side and disable the output side
        // first, then name the device, and only then initialise.
        var on: UInt32 = 1
        var off: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(
            AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, Self.inputBus, &on, flagSize
            ), "enable input")
        try Self.check(
            AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, Self.outputBus, &off, flagSize
            ), "disable output")

        // The line this whole class exists for.
        var deviceID = resolved
        try Self.check(
            AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ), "select device")

        // Whatever the hardware gives us sets the rate; we only insist on float samples,
        // because that is what every consumer downstream reads.
        var hardware = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(
            AudioUnitGetProperty(
                created, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, Self.inputBus, &hardware, &asbdSize
            ), "read hardware format")
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
            AudioComponentInstanceDispose(created)
            throw UnitError.noInputDevice
        }

        var client = Self.floatFormat(
            sampleRate: hardware.mSampleRate,
            channels: hardware.mChannelsPerFrame
        )
        try Self.check(
            AudioUnitSetProperty(
                created, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, Self.inputBus,
                &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ), "set client format")

        guard let format = AVAudioFormat(streamDescription: &client) else {
            AudioComponentInstanceDispose(created)
            throw UnitError.noInputDevice
        }
        self.format = format
        self.bytesPerFrame = UInt32(MemoryLayout<Float>.size)

        // We render into our own buffers, so tell the unit not to allocate any.
        try Self.check(
            AudioUnitSetProperty(
                created, kAudioUnitProperty_ShouldAllocateBuffer,
                kAudioUnitScope_Output, Self.inputBus, &off, flagSize
            ), "disable unit buffers")

        var slice: UInt32 = 4096
        var sliceSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(
            created, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &slice, &sliceSize
        )
        self.maxFrames = max(slice, 4096)

        let channels = Int(client.mChannelsPerFrame)
        let capacity = Int(self.maxFrames) * MemoryLayout<Float>.size
        self.scratch = AudioBufferList.allocate(maximumBuffers: channels)
        var allocated: [UnsafeMutableRawPointer] = []
        for index in 0..<channels {
            let memory = UnsafeMutableRawPointer.allocate(
                byteCount: capacity, alignment: MemoryLayout<Float>.alignment
            )
            allocated.append(memory)
            self.scratch[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(capacity),
                mData: memory
            )
        }
        self.scratchBytes = allocated

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                Unmanaged<MicInputUnit>.fromOpaque(refCon)
                    .takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try Self.check(
            AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "set callback")

        try Self.check(AudioUnitInitialize(created), "initialize")
        Self.log.notice(
            """
            microphone opened: \(Self.deviceName(resolved), privacy: .public) at \
            \(client.mSampleRate, privacy: .public) Hz / \
            \(client.mChannelsPerFrame, privacy: .public) ch
            """
        )
    }

    deinit {
        if isRunning { AudioOutputUnitStop(unit) }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        for memory in scratchBytes { memory.deallocate() }
        free(scratch.unsafeMutablePointer)
    }

    // MARK: - Control

    func start() throws {
        guard !isRunning else { return }
        try Self.check(AudioOutputUnitStart(unit), "start")
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    // MARK: - Audio thread

    /// Real-time thread. Pulls the captured frames and hands them straight on.
    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard frames > 0, frames <= maxFrames else { return noErr }

        // Resize to this callback's frame count. The memory is already there; only the
        // advertised length changes.
        let bytes = frames * bytesPerFrame
        for index in 0..<scratch.count {
            scratch[index].mDataByteSize = bytes
        }

        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, scratch.unsafeMutablePointer)
        guard status == noErr else { return status }

        onBuffer(UnsafePointer(scratch.unsafeMutablePointer))
        return noErr
    }

    // MARK: - Devices

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func deviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? (name as String? ?? "unknown") : "unknown"
    }

    // MARK: - Plumbing

    private static func floatFormat(
        sampleRate: Float64,
        channels: UInt32
    ) -> AudioStreamBasicDescription {
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: size,
            mFramesPerPacket: 1,
            mBytesPerFrame: size,
            mChannelsPerFrame: channels,
            mBitsPerChannel: size * 8,
            mReserved: 0
        )
    }

    private static func check(_ status: OSStatus, _ stage: String) throws {
        guard status != noErr else { return }
        throw UnitError.configurationFailed(stage, status)
    }
}
