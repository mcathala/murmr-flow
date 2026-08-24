import AVFoundation
import CoreAudio
import OSLog
import os

/// Captures everything the Mac plays and streams it to a file.
///
/// Uses **Core Audio process taps** (macOS 14.2+) rather than ScreenCaptureKit. A tap is
/// the audio-only path, and it asks the user for "System Audio Recording" — not the far
/// broader, and for a note-taking app far more alarming, "Screen Recording".
///
/// The tap is global: it records notification sounds and music alongside the meeting.
/// `CATapDescription` can be narrowed to specific processes, which is the obvious later
/// refinement once there is a reason to pick.
final class SystemAudioRecorder: @unchecked Sendable {

    enum RecorderError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case formatUnavailable
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                "Could not capture system audio (error \(status)). Allow Murmr Flow "
                    + "under Privacy & Security › System Audio Recording."
            case .aggregateDeviceFailed(let status):
                "Could not set up the capture device (error \(status))."
            case .formatUnavailable:
                "The system audio format could not be read."
            case .ioProcFailed(let status), .startFailed(let status):
                "Could not start the audio stream (error \(status))."
            }
        }
    }

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "system-audio")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// Written to by the audio thread through the writer's own queue.
    private var writer: AudioFileWriter?

    /// Counts IOProc invocations. Worth keeping rather than deleting after the bug it
    /// found: a tap that starts cleanly and then delivers nothing looks identical to a
    /// silent meeting, and this is the only thing that tells them apart.
    ///
    /// `run` rises once per `start()`, so the silent-start watchdog can tell "this
    /// recording has delivered nothing" from "a different recording has since begun" —
    /// and from "we already stopped", which resets the count and would otherwise read as
    /// a failure every time a meeting ended inside a second.
    private let callbacks = OSAllocatedUnfairLock(initialState: (run: 0, count: 0))

    private(set) var outputURL: URL?

    /// Format the tap actually delivered, which is not necessarily what was asked for.
    private(set) var capturedFormat: AVAudioFormat?

    var isRecording: Bool { ioProcID != nil }

    /// IOProc invocations so far. Zero while recording means the capture is dead.
    var callbackCount: Int { callbacks.withLock { $0.count } }

    /// Loudness of what the Mac is currently playing, 0…1.
    var level: Float { writer?.level ?? 0 }

    // MARK: - Availability

    /// Whether the OS is new enough for process taps at all.
    ///
    /// The deployment target is already 14.2, so this is only false on a Mac that somehow
    /// launched an app it should not have. Kept as a named check so the failure reads as
    /// "not supported" rather than as a Core Audio error code.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    // MARK: - Lifecycle

    /// Begins capture, writing to `url`.
    ///
    /// The first call is what triggers the system permission prompt — there is no API to
    /// ask ahead of time — so this is deliberately the moment the user pressed a button.
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        callbacks.withLock { $0.run += 1; $0.count = 0 }

        do {
            try createTap()
            try createAggregateDevice()

            let format = try tapStreamFormat()
            capturedFormat = format
            writer = try AudioFileWriter(sourceFormat: format, url: url, label: "system")
            outputURL = url

            try installIOProc()

            let status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw RecorderError.startFailed(status) }
        } catch {
            // Leaving a tap or a half-built aggregate device behind would make the next
            // attempt fail for a different reason than the real one.
            teardown()
            throw error
        }

        Self.log.notice("system audio capture started")
        watchForSilentStart(run: callbacks.withLock { $0.run })
    }

    /// `AudioDeviceStart` returning `noErr` is not evidence that anything is running. A
    /// dead aggregate looks exactly like a healthy one until the callbacks fail to arrive,
    /// and the only previous way to find out was an empty transcript half an hour later.
    /// At a 48 kHz clock the first callback is due within milliseconds, so a full second
    /// of nothing is conclusive rather than merely slow.
    ///
    /// Everything it touches lives behind the counter's lock, because this runs on a
    /// background queue while `start()` and `stop()` run on the main actor.
    private func watchForSilentStart(run: Int) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let stalled = self.callbacks.withLock { $0.run == run && $0.count == 0 }
            guard stalled else { return }
            Self.log.error(
                "system audio tap started but delivered no callbacks after 1s — capture is dead"
            )
        }
    }

    /// Stops capture and returns the file written, plus how much audio landed in it.
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval, callbacks: Int)? {
        guard isRecording else { return nil }
        AudioDeviceStop(aggregateID, ioProcID)

        let duration = writer?.finish() ?? 0
        let fired = callbacks.withLock { $0.count }
        let url = outputURL
        teardown()

        Self.log.notice(
            "system audio stopped: \(duration, privacy: .public)s over \(fired, privacy: .public) callbacks"
        )
        guard let url else { return nil }
        return (url, duration, fired)
    }

    // MARK: - Tap

    private func createTap() throws {
        guard #available(macOS 14.2, *) else {
            throw RecorderError.tapCreationFailed(OSStatus(kAudioHardwareUnsupportedOperationError))
        }

        // A *global* tap with an empty exclusion list. The mixdown initialisers take a
        // list of processes to **include**, so passing them an empty array asks for a tap
        // over nothing at all — which is created quite happily and then delivers no
        // callbacks whatsoever. Measured that exact failure: "started", zero frames.
        //
        // Mono, because the transcript is mono in the end and the tap does a better
        // downmix than a converter fed two channels would.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Murmr Flow meeting capture"
        // Private: it belongs to this process and never appears in the user's sound
        // settings as a selectable device.
        description.isPrivate = true
        // Must not mute. The user still has to hear the meeting they are in.
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw RecorderError.tapCreationFailed(status)
        }
        tapID = id
    }

    private func tapUID() throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { throw RecorderError.formatUnavailable }
        return uid
    }

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &description) else {
            throw RecorderError.formatUnavailable
        }
        Self.log.notice(
            "tap format: \(format.sampleRate, privacy: .public) Hz / \(format.channelCount, privacy: .public) ch"
        )
        return format
    }

    // MARK: - Aggregate device

    /// A tap is only readable through an aggregate device that lists it.
    ///
    /// **Some real device has to be in the sub-device list.** A tap carries no clock of
    /// its own, so an aggregate built from a tap alone has nothing to drive its IO cycle:
    /// it is created successfully, `AudioDeviceStart` returns `noErr`, and the IOProc is
    /// then simply never called. Measured exactly that — a tap that reported started and
    /// produced a 4096-byte file containing nothing but the WAV header.
    ///
    /// It does **not** have to be the device the user is listening on. See
    /// `clockDeviceUID()` for why it had better not be.
    ///
    /// Listing a device does not take it over or change what the user hears. The
    /// aggregate stays private, is never made the system default, and we never write to
    /// its output streams — it is there to supply a clock.
    private func createAggregateDevice() throws {
        let tap = try tapUID()
        let clock = try clockDeviceUID()

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmr Flow Capture",
            kAudioAggregateDeviceUIDKey: "app.murmr.MurmrFlow.capture",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: clock,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: clock]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw RecorderError.aggregateDeviceFailed(status)
        }
        aggregateID = id
    }

    /// UID of the device that drives the aggregate's IO cycle.
    ///
    /// **The built-in output, deliberately — not whatever the user is listening on.** The
    /// tap is a *process* tap: it captures what applications play, upstream of routing, so
    /// the clock has no bearing on what lands in the file. Measured on a Bluetooth headset
    /// while clocking from the built-in device: identical peak sample, 0.3617 against
    /// 0.3616.
    ///
    /// Clocking from the listening device, meanwhile, welds the capture to that device's
    /// health. On a Bluetooth headset that is a bad bet. The IO rate follows the link:
    /// measured 235 callbacks per window on A2DP, dropping to 131 the moment opening the
    /// microphone dragged the headset into hands-free mode — and once, in the wild, a tap
    /// that took 2.15 s to start and then delivered nothing at all for 24 minutes. Clocked
    /// from the built-in device across the same transitions: 321, 308, 609. Untouched.
    ///
    /// Falls back to the current default output on a Mac with no built-in output at all,
    /// which is better than refusing to record.
    private func clockDeviceUID() throws -> CFString {
        if let builtIn = builtInOutputDevice(), let uid = deviceUID(builtIn) {
            Self.log.notice("clocking capture from built-in output \(uid as String, privacy: .public)")
            return uid
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown, let uid = deviceUID(deviceID) else {
            throw RecorderError.aggregateDeviceFailed(status)
        }
        Self.log.notice(
            "no built-in output; clocking capture from default output \(uid as String, privacy: .public)"
        )
        return uid
    }

    /// First output device the machine reports as built in.
    private func builtInOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return nil }

        return devices.first { transportType($0) == kAudioDeviceTransportTypeBuiltIn
            && outputChannelCount($0) > 0 }
    }

    private func transportType(_ device: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    /// Output channels, which is what separates a speaker from a microphone. The built-in
    /// microphone also reports itself as built-in transport.
    private func outputChannelCount(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
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
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func deviceUID(_ device: AudioObjectID) -> CFString? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? uid : nil
    }

    // MARK: - IO

    private func installIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, nil
        ) { [weak self] _, inputData, _, _, _ in
            // Real-time audio thread. The writer copies and hands off; nothing here
            // touches the file.
            guard let self else { return }
            self.callbacks.withLock { $0.count += 1 }
            self.writer?.append(bufferList: inputData)
        }
        guard status == noErr, procID != nil else {
            throw RecorderError.ioProcFailed(status)
        }
        ioProcID = procID
    }

    // MARK: - Teardown

    /// Order matters: stop delivering callbacks, then drop the device, then the tap.
    /// Destroying the tap while an IOProc is still attached leaves the aggregate device
    /// referencing a dead sub-tap.
    private func teardown() {
        if let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        writer = nil
        // Bumping the run invalidates any watchdog still pending for the recording that
        // just ended, which would otherwise see a freshly zeroed count and cry failure.
        callbacks.withLock { $0.run += 1; $0.count = 0 }
    }
}
