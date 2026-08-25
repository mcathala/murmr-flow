import FluidAudio
import Foundation

/// Turns 16 kHz mono samples into text using Parakeet on the Apple Neural Engine.
///
/// An actor because inference is expensive and must not run on the main thread, and
/// because concurrent calls into one `AsrManager` would interleave decoder state. Shared
/// between dictation and meetings so only one copy of the model is ever resident.
actor TranscriptionService {

    enum ServiceError: LocalizedError {
        case modelsNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelsNotLoaded:
                "The speech model has not finished loading yet."
            }
        }
    }

    struct Output: Sendable {
        let text: String
        let confidence: Float
        /// Length of the audio that was transcribed.
        let audioDuration: TimeInterval
        /// Time the model spent transcribing it.
        let processingTime: TimeInterval

        /// How many times faster than real time. 190x means a 1-hour recording
        /// transcribes in about 19 seconds.
        var realtimeFactor: Double {
            processingTime > 0 ? audioDuration / processingTime : 0
        }
    }

    /// A stretch of speech bounded by pauses, positioned in the recording.
    ///
    /// Dictation only ever needs one blob of text. A meeting needs to know *when* each
    /// phrase was said, because that is what lets two independently transcribed streams
    /// be woven back into one conversation.
    struct Segment: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// A gap longer than this ends a segment.
    ///
    /// Short enough to break at sentence boundaries in normal speech, long enough not to
    /// split mid-phrase on someone who pauses to think.
    static let pauseThreshold: TimeInterval = 0.7

    /// A segment is cut here regardless of pauses, so an uninterrupted monologue does not
    /// become one unreadable paragraph — and so interleaving still has something to
    /// interleave.
    static let maxSegmentDuration: TimeInterval = 25

    private var manager: AsrManager?

    var isReady: Bool { manager != nil }

    func load(_ models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func unload() {
        manager = nil
    }

    func transcribe(_ samples: [Float]) async throws -> Output {
        let result = try await run(samples)
        return Output(
            text: result.text,
            confidence: result.confidence,
            audioDuration: result.duration,
            processingTime: result.processingTime
        )
    }

    /// Transcribes and returns time-stamped segments rather than one string.
    ///
    /// The model gives per-token timings for free on this path, so segmenting costs
    /// nothing beyond grouping them. Transcribing the stream *whole* and splitting
    /// afterwards is deliberately not the same as transcribing it in chunks: the decoder
    /// keeps its context across the entire recording, so nothing is lost at a boundary
    /// we invented.
    func transcribeSegments(_ samples: [Float]) async throws -> [Segment] {
        let result = try await run(samples)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No timings means no tokens — a silent stream, not a failure.
            return []
        }
        return Self.segments(from: Self.dropInvented(timings, over: samples))
    }

    // MARK: - Silence

    /// Removes tokens the model invented over silence.
    ///
    /// A meeting hands the model a great deal of silence — the other party's stream has
    /// nothing in it for every second you are the one talking — and it will confidently
    /// produce sentences from it. Observed directly: a clip whose first second was silent
    /// gained a whole fabricated sentence ahead of the real one, in the *same* segment,
    /// so filtering per segment could not catch it.
    ///
    /// Filtering per *token* was worse than useless: it also trimmed the leading "The"
    /// and the trailing word off correct speech, because token alignment is approximate
    /// and a real word's window can sit just outside the signal.
    ///
    /// So the unit is a silent **region**. Audible stretches are dilated generously, and
    /// only tokens that fall entirely outside every one of them are dropped. A token
    /// anywhere near real speech survives; a sentence hallucinated in the middle of ten
    /// seconds of nothing does not.
    static func dropInvented(_ timings: [TokenTiming], over samples: [Float]) -> [TokenTiming] {
        guard !samples.isEmpty, !timings.isEmpty else { return timings }

        let rate = 16_000.0
        let hop = Int(rate * hopSeconds)
        guard hop > 0 else { return timings }

        let hopCount = (samples.count + hop - 1) / hop
        var audible = [Bool](repeating: false, count: hopCount)
        for index in 0..<hopCount {
            let start = index * hop
            audible[index] = AudioFileReader.level(
                of: samples, from: start, to: min(start + hop, samples.count)
            ) >= silenceFloor
        }

        // Nothing audible anywhere means the whole stream was silent, so every token was
        // invented.
        guard audible.contains(true) else { return [] }

        let dilated = dilate(audible, by: Int((guardSeconds / hopSeconds).rounded()))

        return timings.filter { timing in
            let first = max(0, Int(timing.startTime / hopSeconds))
            let last = min(dilated.count - 1, Int(timing.endTime / hopSeconds))
            guard first <= last else { return false }
            return dilated[first...last].contains(true)
        }
    }

    /// Widens every true run by `radius` hops on both sides.
    private static func dilate(_ mask: [Bool], by radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        var result = [Bool](repeating: false, count: mask.count)
        for (index, isSet) in mask.enumerated() where isSet {
            let lower = max(0, index - radius)
            let upper = min(mask.count - 1, index + radius)
            for target in lower...upper { result[target] = true }
        }
        return result
    }

    /// Resolution of the silence scan. Fine enough to find gaps between phrases, coarse
    /// enough that a single quiet consonant does not read as silence.
    private static let hopSeconds = 0.05

    /// How far a token may sit from real audio and still be believed. Comfortably more
    /// than the model's alignment error, comfortably less than a pause worth splitting on.
    private static let guardSeconds = 0.4

    /// Below this RMS nothing was playing at all. Two orders of magnitude under quiet
    /// speech, so this separates digital silence from audio rather than loud from soft.
    private static let silenceFloor: Float = 0.001

    private func run(_ samples: [Float]) async throws -> ASRResult {
        guard let manager else { throw ServiceError.modelsNotLoaded }

        // A fresh decoder state per recording. Each one is independent, so carrying state
        // over would leak context from the previous one into this one.
        var decoderState = try TdtDecoderState(
            decoderLayers: await manager.decoderLayerCount
        )

        return try await manager.transcribe(
            samples,
            decoderState: &decoderState,
            language: nil  // nil lets v3 auto-detect
        )
    }

    // MARK: - Segmenting

    /// Groups tokens into segments, breaking on pauses.
    ///
    /// Token text arrives with the SentencePiece word-boundary marker already turned into
    /// a leading space, so joining the pieces and trimming reproduces exactly what the
    /// model's own decoder would have produced for that span.
    static func segments(from timings: [TokenTiming]) -> [Segment] {
        var result: [Segment] = []
        var current: [TokenTiming] = []

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard let first = current.first, let last = current.last else { return }
            let text = current
                .map(\.token)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            result.append(Segment(text: text, start: first.startTime, end: last.endTime))
        }

        for timing in timings {
            // Never break in front of punctuation, and never let it open a segment.
            // The model emits the full stop or question mark a beat after the word it
            // belongs to, which is often enough of a gap to look like a pause — and the
            // result was a segment ending mid-sentence and the next one starting with a
            // stray "?".
            if isPunctuationOnly(timing.token) {
                if !current.isEmpty { current.append(timing) }
                continue
            }

            if let previous = current.last, let opened = current.first {
                let paused = timing.startTime - previous.endTime > pauseThreshold
                let tooLong = timing.endTime - opened.startTime > maxSegmentDuration
                if paused || tooLong { flush() }
            }
            current.append(timing)
        }
        flush()

        return result
    }

    private static func isPunctuationOnly(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }
}
