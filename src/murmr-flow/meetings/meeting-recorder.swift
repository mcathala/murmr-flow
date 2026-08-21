import AVFoundation
import Foundation
import OSLog

/// Records a meeting as two separate streams: your microphone, and everything the Mac
/// plays.
///
/// Two files rather than one mixed track, because that separation *is* the speaker
/// labelling. Whatever arrives on the microphone is you; whatever the system plays is
/// them. No diarization model, no clustering, no threshold to tune — it is right by
/// construction rather than by guess, which is exactly what "You vs Them" needs.
///
/// The one real limitation is acoustic bleed. On speakers the microphone also hears the
/// other party, so their words can show up under both labels. Headphones remove it
/// completely, and the transcript builder drops the quieter duplicate where it can.
@MainActor
final class MeetingRecorder {

    struct Recording: Sendable {
        /// Microphone — attributed to "You".
        let you: URL
        /// System output — attributed to "Them".
        let them: URL
        let startedAt: Date
        /// Longer of the two streams, which is the meeting's real length.
        let duration: TimeInterval
        /// The folder holding both files, so the caller can delete it wholesale.
        let folder: URL
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case unsupportedSystem

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "No microphone is available. Check your input device in Sound settings."
            case .unsupportedSystem:
                "Recording system audio needs macOS 14.2 or later."
            }
        }
    }

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "meeting-recorder")

    /// Nil whenever we are not recording. Holding an `AVAudioEngine` past `stop()` keeps
    /// the input device configured, which on a Bluetooth headset pins the link to
    /// hands-free mode until the app quits — the same trap dictation hit.
    private var micEngine: AVAudioEngine?
    private var micWriter: AudioFileWriter?

    private let system = SystemAudioRecorder()

    private var folder: URL?
    private(set) var startedAt: Date?

    var isRecording: Bool { startedAt != nil }

    /// How long the current recording has been running.
    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Control

    func start() throws {
        guard !isRecording else { return }
        guard SystemAudioRecorder.isSupported else { throw RecorderError.unsupportedSystem }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-flow-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder

        do {
            // System audio first. It is the half that can be refused outright, and
            // failing before the microphone opens means no permission prompt and no
            // device churn for a session that was never going to start.
            try system.start(writingTo: folder.appendingPathComponent("them.wav"))
            try startMicrophone(writingTo: folder.appendingPathComponent("you.wav"))
        } catch {
            discard()
            throw error
        }

        startedAt = Date()
        Self.log.notice("meeting recording started")
    }

    /// Stops both streams and returns what was captured.
    func stop() -> Recording? {
        guard let startedAt, let folder else { return nil }

        let micDuration = micWriter?.finish() ?? 0
        releaseMicrophone()
        let systemResult = system.stop()

        self.startedAt = nil
        self.folder = nil
        micWriter = nil

        guard let systemResult else {
            // The system tap is what makes this a meeting rather than a dictation. Its
            // absence means there is nothing worth calling a transcript.
            try? FileManager.default.removeItem(at: folder)
            return nil
        }

        let duration = max(micDuration, systemResult.duration)
        Self.log.notice(
            "meeting stopped: you=\(micDuration, privacy: .public)s them=\(systemResult.duration, privacy: .public)s"
        )

        return Recording(
            you: folder.appendingPathComponent("you.wav"),
            them: systemResult.url,
            startedAt: startedAt,
            duration: duration,
            folder: folder
        )
    }

    /// Stops everything and deletes the audio without producing a recording.
    func discard() {
        micWriter?.finish()
        releaseMicrophone()
        system.stop()
        micWriter = nil
        startedAt = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Microphone

    private func startMicrophone(writingTo url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let writer = try AudioFileWriter(sourceFormat: format, url: url, label: "mic")
        micWriter = writer

        // Installed from a nonisolated helper on purpose. A closure written inline here
        // would inherit this method's @MainActor isolation, and AVFoundation invokes the
        // tap on the audio thread — which traps the first time a buffer arrives.
        Self.installTap(on: input, format: format, writer: writer)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            micWriter = nil
            throw error
        }
        micEngine = engine
    }

    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        writer: AudioFileWriter
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.append(buffer)
        }
    }

    /// Every step matters: the tap holds a reference, `stop()` ends the stream, `reset()`
    /// tears down the node graph, and dropping the reference is what actually lets Core
    /// Audio hand the device back.
    private func releaseMicrophone() {
        guard let micEngine else { return }
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        micEngine.reset()
        self.micEngine = nil
    }
}
