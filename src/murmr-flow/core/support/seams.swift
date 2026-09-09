import CoreAudio
import FluidAudio
import Foundation

/// The five places the coordinators touch hardware, the network or another process,
/// named as protocols so a test can stand a fake in each one.
///
/// Nothing here changes how the app runs: every default is the real object, and the
/// protocols repeat the real objects' signatures. What they buy is that the two
/// coordinators — the state machines that *are* the product — can be driven end to end
/// without a microphone, a speech model on disk, a provider key or a pasteboard. Until
/// they existed, both had zero tests, because both constructed their own recorder and
/// clean-up service and called a static text injector.

/// Speech to text. `TranscriptionService` is an actor; the fake in tests is not.
protocol Transcribing: Sendable {
    var isReady: Bool { get async }
    func load(_ models: AsrModels) async throws
    func unload() async
    func transcribe(_ samples: [Float]) async throws -> TranscriptionService.Output
    func transcribeSegments(_ samples: [Float]) async throws -> [TranscriptionService.Segment]
}

extension TranscriptionService: Transcribing {}

/// The clean-up pass, for one dictation or a conversation of turns.
protocol Cleaning: Sendable {
    func clean(
        transcript: String,
        config: ProviderConfig?,
        prompt: PromptLibrary,
        context: PromptLibrary.Context,
        dictionary: [DictionaryEntry],
        timeout: TimeInterval
    ) async -> CleanupService.Outcome

    func cleanTurns(
        _ turns: [CleanupService.Turn],
        config: ProviderConfig?,
        prompt: PromptLibrary,
        context: PromptLibrary.Context,
        dictionary: [DictionaryEntry],
        timeout: TimeInterval
    ) async -> CleanupService.TurnsOutcome
}

extension CleanupService: Cleaning {}

/// One request to a chat-completions endpoint. The seam under `CleanupService`, so its
/// fallback rules can be tested against canned replies rather than a live provider.
protocol LLMCompleting: Sendable {
    func complete(
        prompt: String, config: ProviderConfig, timeout: TimeInterval
    ) async throws -> LLMClient.Completion
}

extension LLMClient: LLMCompleting {}

/// Pausing whatever is playing while a dictation records, and putting it back.
protocol MediaPausing: Sendable {
    func pauseIfPlaying() async -> Bool
    func resumeIfWePaused(_ wePaused: Bool) async
}

extension MediaPlaybackController: MediaPausing {}

/// The microphone, for dictation. Main-actor because the coordinator reads the level and
/// the start time from its ticker on the main actor.
@MainActor
protocol MicRecording: AnyObject {
    var inputDeviceID: AudioDeviceID? { get set }
    var startedAt: Date? { get }
    var level: Float { get }
    func start() throws
    func snapshot() -> MicRecorder.Capture?
    func finishCapture() throws -> MicRecorder.Capture
    func cancel()
}

extension MicRecorder: MicRecording {}

/// Both sides of a meeting — microphone and system audio — written to files.
@MainActor
protocol MeetingRecording: AnyObject {
    var inputDeviceID: AudioDeviceID? { get set }
    var isRecording: Bool { get }
    var elapsed: TimeInterval { get }
    var youLevel: Float { get }
    var themLevel: Float { get }
    func start() throws
    func stop() -> MeetingRecorder.Recording?
    func discard()
}

extension MeetingRecorder: MeetingRecording {}
