import AVFoundation
import CoreAudio
import Foundation
import Observation

/// Opens a microphone briefly so the user can watch a meter move and know it is live.
///
/// **Deliberately on demand rather than always on.** A permanently running level meter
/// would mean permanently holding a microphone open, and on a Bluetooth headset holding
/// the microphone open is precisely what collapses the user's music to 16 kHz. A meter
/// that quietly ruined your audio the whole time the window was in front of you would be
/// a worse bug than the one it is drawn to diagnose.
///
/// So it runs for `duration` and stops itself.
@MainActor
@Observable
final class MicLevelProbe {

    /// Loudness of the microphone, 0…1. Zero whenever the probe is not running.
    private(set) var level: Float = 0
    private(set) var isRunning = false
    private(set) var failure: String?

    /// Long enough to say a few words into, short enough that nobody leaves it running.
    static let duration: TimeInterval = 6

    private var unit: MicInputUnit?
    private var meter: Meter?
    private var poll: Task<Void, Never>?
    private var stopper: Task<Void, Never>?

    func toggle(device: AudioDeviceID?) {
        if isRunning { stop() } else { start(device: device) }
    }

    func start(device: AudioDeviceID?) {
        guard !isRunning else { return }
        failure = nil

        let meter = Meter()
        do {
            let opened = try MicInputUnit(device: device) { [meter] list in
                meter.absorb(list)
            }
            try opened.start()
            unit = opened
            self.meter = meter
            isRunning = true
        } catch {
            failure = error.localizedDescription
            return
        }

        // Ten reads a second is smooth enough to look live and cheap enough to ignore.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let meter = self.meter else { return }
                self.level = meter.level
            }
        }
        stopper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        stopper?.cancel()
        stopper = nil
        unit?.stop()
        unit = nil
        meter = nil
        level = 0
        isRunning = false
    }

    /// Reads loudness off the audio thread and holds it behind a lock, so the UI never
    /// waits on the capture and the capture never waits on the UI.
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Float = 0

        var level: Float {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func absorb(_ bufferList: UnsafePointer<AudioBufferList>) {
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: bufferList)
            )
            guard let first = list.first, let data = first.mData else { return }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }

            // RMS rather than peak, matching every other meter in the app — see
            // `AudioLevel` for why peak lights up on noise alone.
            let samples = data.assumingMemoryBound(to: Float.self)
            var sum: Float = 0
            for index in 0..<frames {
                let sample = samples[index]
                sum += sample * sample
            }
            let rms = (sum / Float(frames)).squareRoot()

            lock.lock()
            current = AudioLevel.smooth(current, towards: rms)
            lock.unlock()
        }
    }
}
