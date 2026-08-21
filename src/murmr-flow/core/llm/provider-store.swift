import Foundation
import Observation

/// Everything the app knows about each clean-up provider, kept **per provider**.
///
/// This replaces a single set of `providerID` / `baseURL` / `model` values, which made
/// several things impossible rather than merely awkward:
///
///   - There was nowhere to keep a second provider's endpoint or model, so switching
///     overwrote whatever you had configured. (The old code carried a comment promising it
///     would "keep whatever the user typed" — it did the opposite, unconditionally.)
///   - Verification was one flag for the whole app, cleared on every switch, so a provider
///     you had just proved worked went back to "not tested" the moment you looked at
///     another one — and a relaunch forgot it entirely.
///   - Choosing a provider to *look at* was the same action as making it active.
///
/// So: state is per provider and persisted, and `activeID` is the only thing that decides
/// which one is used.
@MainActor
@Observable
final class ProviderStore {

    /// Whether this provider has actually been exercised. A pasted key is not a working
    /// key, and the difference used to surface only as a failed dictation.
    enum Verification: Codable, Equatable, Sendable {
        case untested
        case working(latency: TimeInterval, at: Date)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    struct State: Codable, Equatable, Sendable {
        var baseURL: String
        var model: String
        var verification: Verification = .untested
    }

    private enum Key {
        static let states = "providers.states"
        static let active = "providers.activeID"
    }

    private(set) var states: [String: State]

    /// The provider dictation actually uses. Changed only by an explicit action.
    var activeID: String {
        didSet {
            guard oldValue != activeID else { return }
            defaults.set(activeID, forKey: Key.active)
        }
    }

    /// Bumped whenever a key is written or removed, so views reading `hasKey` refresh.
    /// The Keychain is not observable, so without this a saved key would not appear until
    /// something else happened to redraw the pane.
    private(set) var keyRevision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var loaded: [String: State] = [:]
        if let data = defaults.data(forKey: Key.states),
           let stored = try? JSONDecoder().decode([String: State].self, from: data) {
            loaded = stored
        }
        // Anything in the catalogue we have never seen starts from its own defaults, so a
        // provider added in a later version appears configured rather than blank.
        for entry in ProviderCatalog.all where loaded[entry.id] == nil {
            loaded[entry.id] = State(baseURL: entry.defaultBaseURL, model: entry.defaultModel)
        }
        self.states = loaded

        let stored = defaults.string(forKey: Key.active)
        self.activeID = ProviderCatalog.all.contains { $0.id == stored }
            ? stored! : ProviderCatalog.groq.id
    }

    // MARK: - Reading

    func state(for id: String) -> State {
        states[id] ?? {
            let entry = ProviderCatalog.entry(id: id)
            return State(baseURL: entry.defaultBaseURL, model: entry.defaultModel)
        }()
    }

    var activeState: State { state(for: activeID) }
    var activeEntry: ProviderCatalog.Entry { ProviderCatalog.entry(id: activeID) }

    var others: [ProviderCatalog.Entry] {
        ProviderCatalog.all.filter { $0.id != activeID }
    }

    func hasKey(_ id: String) -> Bool {
        // Reading `keyRevision` is what subscribes an observing view to key changes.
        _ = keyRevision
        return KeychainStore.hasKey(account: KeychainStore.account(forProvider: id))
    }

    /// Whether this provider could be used at all — endpoint, model, and a key if the
    /// endpoint needs one. Separate from whether it has been *proved* to work.
    func isUsable(_ id: String) -> Bool {
        let state = state(for: id)
        guard !state.baseURL.isEmpty, !state.model.isEmpty else { return false }
        return !ProviderCatalog.entry(id: id).requiresKey || hasKey(id)
    }

    func config(for id: String) -> ProviderConfig? {
        let state = state(for: id)
        guard !state.baseURL.isEmpty, !state.model.isEmpty else { return nil }
        return ProviderConfig(providerID: id, baseURL: state.baseURL, model: state.model)
    }

    var activeConfig: ProviderConfig? { config(for: activeID) }

    // MARK: - Writing

    /// Any change to the endpoint or the model invalidates a previous result, so
    /// verification resets. A "working" badge earned against a different endpoint would
    /// be a claim about something that is no longer configured.
    func update(baseURL: String? = nil, model: String? = nil, for id: String) {
        var state = self.state(for: id)
        let before = state
        if let baseURL { state.baseURL = baseURL }
        if let model { state.model = model }
        guard state.baseURL != before.baseURL || state.model != before.model else { return }

        state.verification = .untested
        states[id] = state
        persist()
    }

    func setVerification(_ verification: Verification, for id: String) {
        var state = self.state(for: id)
        state.verification = verification
        states[id] = state
        persist()
    }

    /// Puts a provider's endpoint and model back to what we ship.
    func resetToDefaults(_ id: String) {
        let entry = ProviderCatalog.entry(id: id)
        states[id] = State(baseURL: entry.defaultBaseURL, model: entry.defaultModel)
        persist()
    }

    // MARK: - Keys

    func saveKey(_ key: String, for id: String) throws {
        try KeychainStore.write(key, account: KeychainStore.account(forProvider: id))
        // A new key says nothing about whether it works.
        setVerification(.untested, for: id)
        keyRevision += 1
    }

    func deleteKey(for id: String) throws {
        try KeychainStore.delete(account: KeychainStore.account(forProvider: id))
        setVerification(.untested, for: id)
        keyRevision += 1
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: Key.states)
    }
}
