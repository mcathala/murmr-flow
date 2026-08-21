import AVFoundation
import FluidAudio

/// Captures microphone audio and hands back 16 kHz mono Float samples, which is the
/// only format Parakeet accepts.
///
/// **The engine is created per recording and fully released afterwards.** Holding one
/// `AVAudioEngine` for the process lifetime leaves the input device configured even after
/// `stop()`, and on a Bluetooth headset that pins the link to hands-free mode — mono
/// 16 kHz output instead of 48 kHz stereo — until the app quits. Measured across repeated
/// runs: with the engine held the headset never recovered; released per recording it
/// recovered within three seconds and stayed recovered.
///
/// Conversion happens **once, at the end** rather than per buffer, because resampling
/// each captured buffer independently introduces discontinuities at the boundaries — the
/// resampler carries no history between calls.
final class MicRecorder: @unchecked Sendable {

    enum RecorderError: LocalizedError {
        case noInputDevice
        case engineFailed(String)
        case nothingRecorded

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "No microphone available. Check your input device in System Settings."
            case .engineFailed(let detail):
                "Could not start the microphone: \(detail)"
            case .nothingRecorded:
                "No audio was captured."
            }
        }
    }

    /// Raw capture, before rate conversion.
    struct Capture: Sendable {
        let samples: [Float]
        let sampleRate: Double
    }

    /// Target rate for Parakeet.
    static let targetSampleRate: Double = 16_000

    /// Nil whenever we are not recording, so no audio hardware stays claimed.
    private var engine: AVAudioEngine?

    /// Guards `samples`, `inputSampleRate` and `recentLevel`, all touched from the audio
    /// thread.
    private let lock = NSLock()
    private var samples: [Float] = []
    private var inputSampleRate: Double = 0
    private var recentLevel: Float = 0

    /// Roughly 60 s at 48 kHz, reserved up front so the audio thread does not have to
    /// reallocate mid-recording.
    private static let reservedFrames = 48_000 * 60

    private(set) var startedAt: Date?

    var isRecording: Bool { engine?.isRunning ?? false }

    /// Loudness of the last buffer, 0…1, for the waveform. Reading it is cheap and lossy
    /// on purpose — a meter that misses a buffer is invisible; a meter that locks the
    /// audio thread is a glitch.
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return recentLevel
    }

    /// Everything captured so far, without stopping. This is what makes a live preview
    /// possible: the audio keeps accumulating while a copy goes off to be transcribed.
    func snapshot() -> Capture? {
        lock.lock()
        let captured = samples
        let rate = inputSampleRate
        lock.unlock()

        guard !captured.isEmpty, rate > 0 else { return nil }
        return Capture(samples: captured, sampleRate: rate)
    }

    // MARK: - Control

    /// Main actor because `AVAudioEngine` lifecycle must not be driven from a background
    /// thread — see the note on `releaseEngine()`.
    @MainActor
    func start() throws {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Self.reservedFrames)
        inputSampleRate = format.sampleRate
        lock.unlock()

        // Installed from a nonisolated helper on purpose. A closure written inline here
        // would inherit this method's @MainActor isolation, and AVFoundation invokes the
        // tap on the audio thread — Swift 6 then traps on the actor assumption the first
        // time a buffer arrives (EXC_BREAKPOINT in _swift_task_checkIsolatedSwift).
        installTap(on: input, format: format)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }


        self.engine = engine
        startedAt = Date()
    }

    /// Stops the engine, releases it, and returns the raw capture.
    ///
    /// Resampling is deliberately *not* done here — that is CPU work and belongs off the
    /// main actor, whereas the teardown must happen on it.
    @MainActor
    func finishCapture() throws -> Capture {
        releaseEngine()
        startedAt = nil

        lock.lock()
        let captured = samples
        let rate = inputSampleRate
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !captured.isEmpty else { throw RecorderError.nothingRecorded }
        guard rate > 0 else { throw RecorderError.noInputDevice }

        return Capture(samples: captured, sampleRate: rate)
    }

    /// Discards the recording without transcribing.
    @MainActor
    func cancel() {
        releaseEngine()
        startedAt = nil
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        recentLevel = 0
        lock.unlock()
    }

    /// Converts a capture to the 16 kHz mono Float samples Parakeet expects. Pure CPU
    /// work, safe to call from any thread.
    static func resample(_ capture: Capture) throws -> [Float] {
        if abs(capture.sampleRate - targetSampleRate) < 1 { return capture.samples }

        // AudioConverter rather than hand-rolled resampling: bit depth, channel layout
        // and rate conversion all have edge cases that show up as empty transcripts
        // rather than as errors.
        return try AudioConverter(sampleRate: targetSampleRate)
            .resample(capture.samples, from: capture.sampleRate)
    }

    // MARK: - Teardown

    /// Every step matters: the tap holds a reference, `stop()` ends the stream, `reset()`
    /// tears down the node graph, and dropping the reference is what actually lets
    /// CoreAudio hand the device back.
    @MainActor
    private func releaseEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
    }

    // MARK: - Audio thread

    /// Installs the capture tap.
    ///
    /// `nonisolated` so the closure is not inferred as `@MainActor` from the caller.
    /// AVFoundation runs it on the real-time audio thread, and an actor-isolated closure
    /// there is an immediate crash under Swift 6 concurrency checking.
    nonisolated private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
    }

    /// Called on the real-time audio thread. Keep it short and allocation-free in the
    /// common case — the capacity reserved in `start()` is what makes the append cheap.
    nonisolated private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Microphone input is mono in practice; if it isn't, take the first channel
        // rather than downmixing by hand.
        let channel = channels[0]

        // RMS, not peak. Noise is spiky and speech is sustained, so peak is the worst
        // statistic available for "is someone talking": one stray sample from the mic's
        // own noise floor was enough to light the meter and keep it lit.
        var sum: Float = 0
        for index in 0..<frames {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        recentLevel = AudioLevel.smooth(recentLevel, towards: rms)
        lock.unlock()
    }
}
