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
        case deliveredNothing

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                "Could not capture system audio (error \(status)). Turn on Murmr Flow "
                    + "under Privacy & Security › Screen & System Audio Recording — only "
                    + "the audio is taken, never your screen."
            case .aggregateDeviceFailed(let status):
                "Could not set up the capture device (error \(status))."
            case .formatUnavailable:
                "The system audio format could not be read."
            case .ioProcFailed(let status), .startFailed(let status):
                "Could not start the audio stream (error \(status))."
            case .deliveredNothing:
                "The system audio stream started but delivered no audio. Try switching "
                    + "your output device in Sound settings and recording again."
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

    // MARK: - Permission

    /// Where a successful tap creation is remembered. macOS offers no way to *read* the
    /// System Audio Recording grant — the only probe is creating a tap, and the first
    /// attempt is also the request — so the app keeps the one trace it can: whether a tap
    /// has ever been created on this install.
    static let accessDefaultsKey = "permissions.systemAudio"

    /// Whether meetings are known to be allowed to hear the system's audio. False means
    /// "never proven", not "denied" — the difference only a probe can settle.
    static var hasKnownAccess: Bool {
        !isSupported || UserDefaults.standard.bool(forKey: accessDefaultsKey)
    }

    /// Whether Apple's dialog has ever been raised on this install.
    ///
    /// The missing half of the question. `hasKnownAccess` says whether a tap has ever
    /// worked; it cannot tell "you said no" from "nobody has asked you yet", and those two
    /// want opposite things from the app — a warning in the first case, silence in the
    /// second. Recorded the moment the app does something that makes macOS ask.
    static let askedDefaultsKey = "permissions.systemAudio.asked"

    static var hasBeenAsked: Bool {
        UserDefaults.standard.bool(forKey: askedDefaultsKey)
    }

    static func markAsked() {
        UserDefaults.standard.set(true, forKey: askedDefaultsKey)
    }

    /// Asks for — or re-checks — the grant, by recording for a moment and throwing the
    /// result away.
    ///
    /// It used to create a tap, destroy it, and call that an answer. It is not one:
    /// `AudioHardwareCreateProcessTap` is not the gated call, so it succeeds on a machine
    /// that has granted nothing — which is how the app came to believe it had permission
    /// it had never been given, and then said nothing while the Notetaker recorded silence
    /// from everyone but you.
    ///
    /// The only thing that settles it is audio arriving, so this builds the whole pipeline
    /// — tap, aggregate device, IOProc, start — waits for the first callback and tears it
    /// all down. Starting IO is also what raises Apple's dialog, so the first call ever is
    /// the request and must come from a button the user pressed; it will return false
    /// whatever they click, because the dialog is still up when the call returns.
    static func probeAccess() -> Bool {
        guard isSupported else { return false }

        let recorder = SystemAudioRecorder()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-permission-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            // Marks the question as asked and writes the remembered yes on success — both
            // in `start`, where they belong.
            try recorder.start(writingTo: url)
            recorder.stop()
            return true
        } catch {
            log.notice("system audio probe failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Lifecycle

    /// Begins capture, writing to `url`.
    ///
    /// The first call is what triggers the system permission prompt — there is no API to
    /// ask ahead of time — so this is deliberately the moment the user pressed a button.
    ///
    /// And it is the *starting* of IO that raises Apple's dialog, not the tap or the
    /// aggregate device, so this is where the asking is recorded. The call cannot wait for
    /// the answer: the dialog is put up alongside it and this returns having heard nothing,
    /// which is why the first attempt on a fresh machine always fails however the person
    /// answers. What the app must not do is call that a refusal.
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        Self.markAsked()

        // Try each clock in turn and keep the first that actually delivers audio. A
        // failure here is not hypothetical: a Bluetooth headset as the clock has been
        // observed to start cleanly and then never run its IOProc, twice in a row on the
        // same machine, while the built-in device on the same machine worked every time.
        // Rather than argue about which device is trustworthy, prove it in 20 ms.
        var lastError: Error = RecorderError.deliveredNothing
        for clock in clockCandidates() {
            do {
                try start(writingTo: url, clockedFrom: clock)
                return
            } catch {
                lastError = error
                Self.log.error(
                    """
                    capture clocked from \(clock as String, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                // Leaving a tap or a half-built aggregate device behind would make the
                // next attempt fail for a different reason than the real one.
                teardown()
            }
        }
        throw lastError
    }

    private func start(writingTo url: URL, clockedFrom clock: CFString) throws {
        callbacks.withLock { $0.run += 1; $0.count = 0 }

        try createTap()
        try createAggregateDevice(clockedFrom: clock)

        let format = try tapStreamFormat()
        capturedFormat = format
        writer = try AudioFileWriter(sourceFormat: format, url: url, label: "system")
        outputURL = url

        try installIOProc()

        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw RecorderError.startFailed(status) }

        try waitForFirstCallback()

        // **This** is where the grant is proven, and the only place it can be.
        //
        // It used to be recorded when the tap was created, which proves nothing:
        // `AudioHardwareCreateProcessTap` is not the gated call and succeeds whether or
        // not anyone has allowed anything. So the app wrote down "granted" during an
        // attempt that then failed at `AudioDeviceStart` — recording a yes and reporting a
        // no in the same breath, and thereafter staying silent about a permission it had
        // never actually been given.
        //
        // A callback carrying audio cannot happen without the grant. Nothing short of it
        // is evidence.
        UserDefaults.standard.set(true, forKey: Self.accessDefaultsKey)

        Self.log.notice(
            "system audio capture started, clocked from \(clock as String, privacy: .public)"
        )
    }

    /// Blocks until the IOProc fires once, or gives up.
    ///
    /// `AudioDeviceStart` returning `noErr` is not evidence that anything is running: a
    /// dead aggregate is indistinguishable from a healthy one until the callbacks fail to
    /// arrive, and the only previous way to find out was an empty transcript half an hour
    /// later. At any real clock rate the first callback is due in single-digit
    /// milliseconds, so half a second of nothing is a verdict rather than impatience.
    ///
    /// Blocking is deliberate. This runs once, when the user presses record, and the
    /// common case returns almost immediately — far better than handing back a recorder
    /// that is quietly recording nothing.
    private func waitForFirstCallback() throws {
        let deadline = Date().addingTimeInterval(Self.firstCallbackTimeout)
        while Date() < deadline {
            if callbackCount > 0 { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw RecorderError.deliveredNothing
    }

    private static let firstCallbackTimeout: TimeInterval = 0.5

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
            // Something is wrong enough that the remembered yes should not be trusted —
            // forget it, so onboarding's step comes back rather than being skipped on a
            // machine that would fail.
            UserDefaults.standard.removeObject(forKey: Self.accessDefaultsKey)
            throw RecorderError.tapCreationFailed(status)
        }
        // Nothing is written here on success. Creating a tap is not the gated call and
        // says nothing about the grant — see where audio actually arrives.
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
    private func createAggregateDevice(clockedFrom clock: CFString) throws {
        let tap = try tapUID()

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

    /// Devices that could drive the aggregate's IO cycle, best first.
    ///
    /// **The built-in output leads, deliberately — not whatever the user is listening
    /// on.** The tap is a *process* tap: it captures what applications play, upstream of
    /// routing, so the clock has no bearing on what lands in the file. Measured on a
    /// Bluetooth headset while clocking from the built-in device: identical peak sample,
    /// 0.3617 against 0.3616.
    ///
    /// Clocking from the listening device, meanwhile, welds the capture to that device's
    /// health, and on a Bluetooth headset that is a bad bet. The IO rate follows the link:
    /// measured 235 callbacks per window on A2DP, dropping to 131 the moment opening the
    /// microphone dragged the headset into hands-free mode. Worse, in the wild the same
    /// headset produced a tap that started cleanly and then delivered nothing whatsoever,
    /// twice. Clocked from the built-in device across the same transitions: 321, 308, 609.
    /// Untouched.
    ///
    /// The current output device stays on the list as a fallback rather than being
    /// dropped, because a Mac with no built-in output — or a built-in output that is
    /// itself unhappy — should still record. `start()` proves each one before committing.
    private func clockCandidates() -> [CFString] {
        var seen = Set<String>()
        return [builtInOutputDevice(), defaultOutputDevice()]
            .compactMap { $0.flatMap(deviceUID) }
            .filter { seen.insert($0 as String).inserted }
    }

    private func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
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
