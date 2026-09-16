import CoreAudio
import FluidAudio
import Foundation

@testable import MurmrFlow

/// Stand-ins for the hardware and the network, so the coordinators can be driven end to
/// end from a test. Each one answers from a script and remembers what it was asked.

struct TestError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Speech to text from a queue of answers. Each `transcribe` pops one; an empty queue
/// hears nothing, which is also a case worth testing.
final class FakeTranscriber: Transcribing, @unchecked Sendable {
    var ready = true
    var outputs: [Result<String, Error>] = []
    var segmentBatches: [[TranscriptionService.Segment]] = []
    var segmentError: Error?
    private(set) var transcribeCalls = 0

    var isReady: Bool {
        get async { ready }
    }

    func load(_ models: AsrModels) async throws {}
    func unload() async {}

    func transcribe(_ samples: [Float]) async throws -> TranscriptionService.Output {
        transcribeCalls += 1
        let next: Result<String, Error> = outputs.isEmpty ? .success("") : outputs.removeFirst()
        return TranscriptionService.Output(
            text: try next.get(), confidence: 1, audioDuration: 1.5, processingTime: 0.1
        )
    }

    func transcribeSegments(_ samples: [Float]) async throws -> [TranscriptionService.Segment] {
        if let segmentError { throw segmentError }
        return segmentBatches.isEmpty ? [] : segmentBatches.removeFirst()
    }
}

/// A clean-up pass that upper-cases by default, so the cleaned text is recognisable, and
/// can be told to fall back, fail, or take its time.
final class FakeCleaner: Cleaning, @unchecked Sendable {
    var outcome: @Sendable (String) -> CleanupService.Outcome = {
        CleanupService.Outcome(text: $0.uppercased(), usedRawFallback: false, note: nil, latency: 0.2)
    }
    var turnsOutcome: @Sendable ([CleanupService.Turn]) -> CleanupService.TurnsOutcome = {
        CleanupService.TurnsOutcome(
            texts: $0.map { $0.text.uppercased() }, cleanedCount: $0.count, note: nil, latency: 0.3
        )
    }
    var delay: Duration = .zero
    private(set) var providerIDs: [String] = []
    private(set) var transcripts: [String] = []
    private(set) var contexts: [PromptLibrary.Context] = []
    /// The template each call was given, so a test can tell which *style* ran — which is
    /// the whole question once an app rule or a key can pick one.
    private(set) var templates: [String] = []

    func clean(
        transcript: String, config: ProviderConfig?, prompt: PromptLibrary,
        context: PromptLibrary.Context, dictionary: [DictionaryEntry], timeout: TimeInterval
    ) async -> CleanupService.Outcome {
        providerIDs.append(config?.providerID ?? "none")
        transcripts.append(transcript)
        contexts.append(context)
        templates.append(prompt.template)
        if delay > .zero { try? await Task.sleep(for: delay) }
        // No provider, no clean-up — the same contract the real service keeps, so a test
        // can assert on the words rather than only on who was asked.
        guard config != nil else { return .raw(transcript, note: nil) }
        return outcome(transcript)
    }

    func cleanTurns(
        _ turns: [CleanupService.Turn], config: ProviderConfig?, prompt: PromptLibrary,
        context: PromptLibrary.Context, dictionary: [DictionaryEntry], timeout: TimeInterval
    ) async -> CleanupService.TurnsOutcome {
        providerIDs.append(config?.providerID ?? "none")
        return turnsOutcome(turns)
    }
}

/// Remembers whether it was asked to pause, and what it was told when asked to resume.
final class FakeMedia: MediaPausing, @unchecked Sendable {
    var isPlaying = true
    private(set) var pauses = 0
    private(set) var resumes: [Bool] = []

    func pauseIfPlaying() async -> Bool {
        pauses += 1
        return isPlaying
    }

    func resumeIfWePaused(_ wePaused: Bool) async {
        resumes.append(wePaused)
    }
}

/// A microphone that records whatever samples it is given, at the target rate so no
/// resampling happens.
@MainActor
final class FakeMic: MicRecording {
    var inputDeviceID: AudioDeviceID?
    private(set) var startedAt: Date?
    var level: Float = 0
    var startError: Error?
    var captureError: Error?
    var samples: [Float] = [0.1, 0.2, 0.3]
    private(set) var cancels = 0

    func start() throws {
        if let startError { throw startError }
        startedAt = Date()
    }

    func snapshot() -> MicRecorder.Capture? { nil }

    func finishCapture() throws -> MicRecorder.Capture {
        startedAt = nil
        if let captureError { throw captureError }
        return MicRecorder.Capture(samples: samples, sampleRate: MicRecorder.targetSampleRate)
    }

    func cancel() {
        startedAt = nil
        cancels += 1
    }
}

/// Both meeting streams, "recorded" to two URLs the test's sample reader recognises.
@MainActor
final class FakeMeetingRecorder: MeetingRecording {
    var inputDeviceID: AudioDeviceID?
    private(set) var isRecording = false
    var elapsed: TimeInterval = 0
    var youLevel: Float = 0
    var themLevel: Float = 0
    var startError: Error?
    var recording: MeetingRecorder.Recording?
    private(set) var discards = 0

    func start() throws {
        if let startError { throw startError }
        isRecording = true
    }

    func stop() -> MeetingRecorder.Recording? {
        isRecording = false
        return recording
    }

    func discard() {
        isRecording = false
        discards += 1
    }
}

/// One chat-completions reply, or one failure, for the clean-up service's own tests.
final class ScriptedLLM: LLMCompleting, @unchecked Sendable {
    var reply: Result<String, Error>
    private(set) var prompts: [String] = []

    init(_ reply: Result<String, Error>) {
        self.reply = reply
    }

    func complete(
        prompt: String, config: ProviderConfig, timeout: TimeInterval
    ) async throws -> LLMClient.Completion {
        prompts.append(prompt)
        return LLMClient.Completion(text: try reply.get(), latency: 0.1)
    }
}

/// Collects what the coordinator would have typed into the app in front.
@MainActor
final class InjectionSink {
    var texts: [String] = []
    var error: Error?

    func inject(_ text: String) throws {
        if let error { throw error }
        texts.append(text)
    }
}

/// Every stage a coordinator went through, in order.
@MainActor
final class StageLog<Stage> {
    var stages: [Stage] = []
}

/// The app in front, as a test decides it. The real seam asks the workspace, which in a
/// test process answers with whatever happens to be running.
@MainActor
final class FakeFrontmost {
    var app: TargetApp?

    init(_ app: TargetApp? = nil) { self.app = app }

    func set(_ name: String, _ bundleID: String) {
        app = TargetApp(name: name, bundleID: bundleID)
    }
}

enum Scratch {
    static func defaults(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: "murmr-tests-\(name)-\(UUID().uuidString)")!
    }

    /// A fresh directory under the temporary folder, created.
    static func folder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmr-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls until `condition` holds or the wait runs out, so a test can follow a task the
    /// coordinator started without sleeping a fixed, flaky amount.
    @MainActor
    static func waitUntil(
        _ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
