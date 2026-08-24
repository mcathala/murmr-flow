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
        /// IOProc invocations on the system tap. Zero means the tap never ran, which is a
        /// capture failure and not a quiet meeting — the two are indistinguishable from
        /// the audio alone, and telling the user the wrong one sends them hunting in the
        /// wrong place.
        let systemCallbacks: Int
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

    /// Nil whenever we are not recording, so no audio hardware stays claimed.
    private var micUnit: MicInputUnit?
    private var micWriter: AudioFileWriter?

    /// Microphone to record from, or nil to follow the system default. Set by the caller
    /// from whatever the user picked, and read once per recording.
    var inputDeviceID: AudioDeviceID?

    private let system = SystemAudioRecorder()

    private var folder: URL?
    private(set) var startedAt: Date?

    var isRecording: Bool { startedAt != nil }

    /// Loudness of your microphone, 0…1.
    var youLevel: Float { micWriter?.level ?? 0 }

    /// Loudness of everything the Mac is playing, 0…1.
    ///
    /// The pair of these is the whole reason the panel has meters: a system-audio tap can
    /// start cleanly and capture nothing, and without a meter you find out half an hour
    /// later from an empty transcript.
    var themLevel: Float { system.level }

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
            folder: folder,
            systemCallbacks: systemResult.callbacks
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
        // `AudioFileWriter` needs the format up front, and the unit only knows it once
        // the device is open — hence the two-step: build the unit, read what it gives,
        // then hand the writer in through the box the callback already captured.
        let sink = BufferSink()
        let unit = try MicInputUnit(device: inputDeviceID) { [sink] list in
            sink.writer?.append(bufferList: list)
        }

        let writer = try AudioFileWriter(sourceFormat: unit.format, url: url, label: "mic")
        sink.writer = writer
        micWriter = writer

        do {
            try unit.start()
        } catch {
            sink.writer = nil
            micWriter = nil
            throw error
        }
        micUnit = unit
    }

    /// Dropping the unit is what lets Core Audio hand the device back. Holding one past
    /// `stop()` keeps the input device configured, and on a Bluetooth headset that pins
    /// the link to hands-free mode until the app quits.
    private func releaseMicrophone() {
        micUnit?.stop()
        micUnit = nil
    }

    /// Lets the real-time callback reach a writer that does not exist yet when the
    /// callback is created. A class so the callback captures the box, not a snapshot.
    private final class BufferSink: @unchecked Sendable {
        var writer: AudioFileWriter?
    }
}
