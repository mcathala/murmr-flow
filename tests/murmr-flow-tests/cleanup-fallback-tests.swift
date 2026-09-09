import Foundation
import Testing

@testable import MurmrFlow

/// The rule the whole clean-up rests on: **the user's words are never lost.** Every way a
/// provider can let us down has to resolve to the raw transcript and a reason, never to
/// an error or to a reply the model made up.
@Suite("Clean-up fallback")
struct CleanupFallbackTests {

    private let transcript =
        "so can we move the meeting to thursday and um also send me the report after"
    private let prompt = PromptLibrary(template: "Clean this up:\n{{transcript}}")

    private var config: ProviderConfig {
        ProviderConfig(
            providerID: "test", baseURL: "https://example.invalid/v1", model: "m",
            apiKeyOverride: "key"
        )
    }

    private func service(replying reply: Result<String, Error>) -> CleanupService {
        CleanupService(client: ScriptedLLM(reply))
    }

    @Test("a sensible reply is used")
    func plausibleReply() async {
        let cleaned = "Can we move the meeting to Thursday? And also send me the report after."
        let outcome = await service(replying: .success(cleaned)).clean(
            transcript: transcript, config: config, prompt: prompt,
            context: .init(transcript: transcript)
        )
        #expect(outcome.text == cleaned)
        #expect(!outcome.usedRawFallback)
        #expect(outcome.note == nil)
    }

    /// A model that answers the transcript instead of tidying it comes back several times
    /// longer. Typing that into a document would be worse than the raw words.
    @Test("a reply far longer than the input is thrown away")
    func implausibleReply() async {
        let essay = String(repeating: "Certainly! Here is a detailed plan for Thursday. ", count: 8)
        let outcome = await service(replying: .success(essay)).clean(
            transcript: transcript, config: config, prompt: prompt,
            context: .init(transcript: transcript)
        )
        #expect(outcome.text == transcript)
        #expect(outcome.usedRawFallback)
        #expect(outcome.note?.contains("unexpected") == true)
    }

    @Test("a provider error keeps the raw transcript and says why")
    func providerError() async {
        let outcome = await service(replying: .failure(TestError(message: "401 bad key"))).clean(
            transcript: transcript, config: config, prompt: prompt,
            context: .init(transcript: transcript)
        )
        #expect(outcome.text == transcript)
        #expect(outcome.usedRawFallback)
        #expect(outcome.note == "401 bad key")
    }

    @Test("no provider means the raw transcript, with a note")
    func noProvider() async {
        let llm = ScriptedLLM(.success("should never be asked"))
        let outcome = await CleanupService(client: llm).clean(
            transcript: transcript, config: nil, prompt: prompt,
            context: .init(transcript: transcript)
        )
        #expect(outcome.text == transcript)
        #expect(outcome.usedRawFallback)
        #expect(outcome.note == "No cleanup provider configured.")
        #expect(llm.prompts.isEmpty)
    }

    @Test("an empty transcript is returned as it is, without a request")
    func emptyTranscript() async {
        let llm = ScriptedLLM(.success("should never be asked"))
        let outcome = await CleanupService(client: llm).clean(
            transcript: "   ", config: config, prompt: prompt, context: .init(transcript: "   ")
        )
        #expect(outcome.usedRawFallback)
        #expect(outcome.note == nil)
        #expect(llm.prompts.isEmpty)
    }

    /// An exact replacement the person asked for must come back. A model that swallowed
    /// the marker loses the whole clean-up rather than the email address.
    @Test("a dropped dictionary marker falls back to the raw text with the replacement in it")
    func droppedMarker() async {
        let entry = DictionaryEntry(
            kind: .swap, trigger: "my email", replacement: "me@example.com", scope: .both
        )
        let spoken = "please send it to my email before thursday thanks a lot for this"
        let outcome = await service(replying: .success("Please send it before Thursday. Thanks a lot."))
            .clean(
                transcript: spoken, config: config, prompt: prompt,
                context: .init(transcript: spoken), dictionary: [entry]
            )
        #expect(outcome.usedRawFallback)
        #expect(outcome.text.contains("me@example.com"))
        #expect(outcome.note?.contains("marker") == true)
    }

    /// A conversation: a turn the model never returned keeps its raw wording, and the
    /// count of cleaned turns says how many did not.
    @Test("a short reply to a conversation keeps the missing turns as spoken")
    func partialTurns() async {
        let turns = [
            CleanupService.Turn(speaker: "You", text: "so are we good to move it to thursday"),
            CleanupService.Turn(speaker: "Them", text: "yeah thursday works for me perfect"),
        ]
        let outcome = await service(replying: .success("[0] You: Are we good to move it to Thursday?"))
            .cleanTurns(
                turns, config: config, prompt: prompt, context: .init(transcript: "")
            )
        #expect(outcome.texts.count == 2)
        #expect(outcome.texts[0] == "Are we good to move it to Thursday?")
        #expect(outcome.texts[1] == turns[1].text)
        #expect(outcome.cleanedCount == 1)
        #expect(!outcome.usedRawFallback)
    }
}
