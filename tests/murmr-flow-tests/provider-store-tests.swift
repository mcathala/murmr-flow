import Foundation
import Testing

@testable import MurmrFlow

/// The behaviours the old single-valued model made impossible.
@MainActor
@Suite("Provider store")
struct ProviderStoreTests {

    private func store() -> (ProviderStore, UserDefaults) {
        let suite = "murmr-providers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ProviderStore(defaults: defaults), defaults)
    }

    private var groq: String { ProviderCatalog.groq.id }
    private var custom: String { ProviderCatalog.custom.id }

    @Test("every provider starts from its own defaults")
    func seeded() {
        let (providers, _) = store()
        #expect(providers.state(for: groq).model == ProviderCatalog.groq.defaultModel)
        #expect(providers.state(for: groq).baseURL == ProviderCatalog.groq.defaultBaseURL)
    }

    @Test("editing one provider leaves the other alone")
    func isolated() {
        // The old model had one baseURL and one model for the whole app, so touching a
        // second provider overwrote the first.
        let (providers, _) = store()
        providers.update(model: "my-tuned-model", for: groq)
        providers.update(baseURL: "http://localhost:11434/v1", model: "llama", for: custom)

        #expect(providers.state(for: groq).model == "my-tuned-model")
        #expect(providers.state(for: custom).model == "llama")
    }

    @Test("switching the active provider changes nothing else")
    func switchingIsHarmless() {
        let (providers, _) = store()
        providers.update(model: "my-tuned-model", for: groq)
        providers.setVerification(.working(latency: 0.4, at: Date()), for: groq)

        providers.activeID = custom
        providers.activeID = groq

        // Both of these were lost on every switch before.
        #expect(providers.state(for: groq).model == "my-tuned-model")
        #expect(providers.state(for: groq).verification.isWorking)
    }

    @Test("verification survives a relaunch")
    func verificationPersists() {
        let suite = "murmr-providers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = ProviderStore(defaults: defaults)
        first.setVerification(.working(latency: 0.4, at: Date()), for: groq)
        first.activeID = groq

        let reopened = ProviderStore(defaults: defaults)
        #expect(reopened.state(for: groq).verification.isWorking)
        #expect(reopened.activeID == groq)
    }

    @Test("changing the endpoint invalidates a previous result")
    func editResetsVerification() {
        let (providers, _) = store()
        providers.setVerification(.working(latency: 0.4, at: Date()), for: custom)
        providers.update(baseURL: "http://elsewhere/v1", for: custom)

        // A "working" badge earned against a different endpoint is a claim about
        // something that is no longer configured.
        #expect(!providers.state(for: custom).verification.isWorking)
    }

    @Test("writing the same value is not an edit")
    func noSpuriousReset() {
        let (providers, _) = store()
        providers.setVerification(.working(latency: 0.4, at: Date()), for: groq)
        // A text field re-emitting its current value must not wipe the badge.
        providers.update(model: ProviderCatalog.groq.defaultModel, for: groq)

        #expect(providers.state(for: groq).verification.isWorking)
    }

    @Test("usable means configured, which is not the same as proved")
    func usableVersusProved() {
        let (providers, _) = store()

        // Custom needs no key, so an endpoint and a model are enough to try it.
        providers.update(baseURL: "http://localhost:11434/v1", model: "llama", for: custom)
        #expect(providers.isUsable(custom))
        #expect(!providers.state(for: custom).verification.isWorking)

        // Groq requires a key, and there is none in this test's Keychain account.
        #expect(ProviderCatalog.groq.requiresKey)
    }

    @Test("an empty endpoint is not usable and yields no config")
    func incomplete() {
        let (providers, _) = store()
        #expect(!providers.isUsable(custom))       // ships with no endpoint
        #expect(providers.config(for: custom) == nil)
    }
}

/// The speech-model equivalent, for the same reasons.
@MainActor
@Suite("Speech model store")
struct SpeechModelStoreTests {

    private func store() -> (SpeechModelStore, UserDefaults) {
        let suite = "murmr-speech-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SpeechModelStore(defaults: defaults), defaults)
    }

    @Test("looking at the other model does not discard what you proved")
    func switchingKeepsVerification() {
        let (speech, _) = store()
        speech.setVerification(.working(latency: 0.2, at: Date()), for: .parakeetV3)

        speech.setActive(.parakeetV2)
        speech.setActive(.parakeetV3)

        // The voice test was a single transient value, so this used to be lost twice over.
        #expect(speech.verification(for: .parakeetV3).isWorking)
    }

    @Test("each model is verified separately")
    func perModel() {
        let (speech, _) = store()
        speech.setVerification(.working(latency: 0.2, at: Date()), for: .parakeetV3)
        #expect(speech.verification(for: .parakeetV3).isWorking)
        #expect(!speech.verification(for: .parakeetV2).isWorking)
    }

    @Test("verification and the active model survive a relaunch")
    func persists() {
        let suite = "murmr-speech-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = SpeechModelStore(defaults: defaults)
        first.setActive(.parakeetV2)
        first.setVerification(.working(latency: 0.2, at: Date()), for: .parakeetV2)

        let reopened = SpeechModelStore(defaults: defaults)
        #expect(reopened.activeModel == .parakeetV2)
        #expect(reopened.verification(for: .parakeetV2).isWorking)
    }

    @Test("others excludes the active one")
    func others() {
        let (speech, _) = store()
        #expect(!speech.others.contains(speech.activeModel))
        #expect(speech.others.count == SpeechModel.allCases.count - 1)
    }
}
