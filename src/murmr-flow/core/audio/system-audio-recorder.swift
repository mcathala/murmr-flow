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
    private let callbacks = OSAllocatedUnfairLock(initialState: 0)

    private(set) var outputURL: URL?

    /// Format the tap actually delivered, which is not necessarily what was asked for.
    private(set) var capturedFormat: AVAudioFormat?

    var isRecording: Bool { ioProcID != nil }

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
    }

    /// Stops capture and returns the file written, plus how much audio landed in it.
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval, callbacks: Int)? {
        guard isRecording else { return nil }
        AudioDeviceStop(aggregateID, ioProcID)

        let duration = writer?.finish() ?? 0
        let fired = callbacks.withLock { $0 }
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
    /// **The current output device has to be in the sub-device list.** A tap carries no
    /// clock of its own, so an aggregate built from a tap alone has nothing to drive its
    /// IO cycle: it is created successfully, `AudioDeviceStart` returns `noErr`, and the
    /// IOProc is then simply never called. Measured exactly that — a tap that reported
    /// started and produced a 4096-byte file containing nothing but the WAV header.
    ///
    /// Listing the output device does not take it over or change what the user hears. The
    /// aggregate stays private, is never made the system default, and we never write to
    /// its output streams — it is there to supply a clock.
    private func createAggregateDevice() throws {
        let tap = try tapUID()
        let output = try defaultOutputUID()

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmr Flow Capture",
            kAudioAggregateDeviceUIDKey: "app.murmr.MurmrFlow.capture",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: output]
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

    /// UID of whatever the Mac is currently playing through, which is the device the tap
    /// is capturing from and therefore the right clock to follow.
    private func defaultOutputUID() throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw RecorderError.aggregateDeviceFailed(status)
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else {
            throw RecorderError.aggregateDeviceFailed(status)
        }
        Self.log.notice("clocking capture from output device \(uid as String, privacy: .public)")
        return uid
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
            self.callbacks.withLock { $0 += 1 }
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
        callbacks.withLock { $0 = 0 }
    }
}
