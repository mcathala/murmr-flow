import AVFoundation
import FluidAudio

/// Captures microphone audio and hands back 16 kHz mono Float samples, which is the
/// only format Parakeet accepts.
///
/// Conversion happens **once, at stop** rather than per buffer. Resampling each
/// captured buffer independently introduces discontinuities at buffer boundaries,
/// because the resampler has no history across calls.
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

    /// Target rate for Parakeet.
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()

    /// Guards `samples` and `inputSampleRate`, both touched from the audio thread.
    private let lock = NSLock()
    private var samples: [Float] = []
    private var inputSampleRate: Double = 0

    /// Roughly 60 s at 48 kHz, reserved up front so the audio thread does not have to
    /// reallocate mid-recording.
    private static let reservedFrames = 48_000 * 60

    private(set) var startedAt: Date?

    var isRecording: Bool { engine.isRunning }

    // MARK: - Control

    func start() throws {
        guard !engine.isRunning else { return }

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

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        startedAt = Date()
    }

    /// Stops capture and returns the recording as 16 kHz mono Float samples.
    func stop() throws -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startedAt = nil

        lock.lock()
        let captured = samples
        let rate = inputSampleRate
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !captured.isEmpty else { throw RecorderError.nothingRecorded }
        guard rate > 0 else { throw RecorderError.noInputDevice }

        // Already at the target rate — no conversion needed.
        if abs(rate - Self.targetSampleRate) < 1 { return captured }

        // AudioConverter rather than hand-rolled resampling: bit depth, channel layout
        // and rate conversion all have edge cases that show up as empty transcripts
        // rather than as errors.
        return try AudioConverter(sampleRate: Self.targetSampleRate)
            .resample(captured, from: rate)
    }

    /// Discards the recording without transcribing.
    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startedAt = nil
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - Audio thread

    /// Called on the real-time audio thread. Keep it short and allocation-free in the
    /// common case — the capacity reserved in `start()` is what makes the append cheap.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Microphone input is mono in practice; if it isn't, take the first channel
        // rather than downmixing by hand.
        let channel = channels[0]

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        lock.unlock()
    }
}
