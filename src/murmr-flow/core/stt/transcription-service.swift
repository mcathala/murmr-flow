import FluidAudio
import Foundation

/// Turns 16 kHz mono samples into text using Parakeet on the Apple Neural Engine.
///
/// An actor because inference is expensive and must not run on the main thread, and
/// because concurrent calls into one `AsrManager` would interleave decoder state.
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
        guard let manager else { throw ServiceError.modelsNotLoaded }

        // A fresh decoder state per utterance. Each dictation is independent, so
        // carrying state over would leak context from the previous one into this one.
        var decoderState = try TdtDecoderState(
            decoderLayers: await manager.decoderLayerCount
        )

        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState,
            language: nil  // nil lets v3 auto-detect
        )

        return Output(
            text: result.text,
            confidence: result.confidence,
            audioDuration: result.duration,
            processingTime: result.processingTime
        )
    }
}
