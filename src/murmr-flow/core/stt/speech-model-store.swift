import Foundation
import Observation

/// Which speech model is in use, and what has been proved about each one.
///
/// Mirrors `ProviderStore`, for the same reason: the voice test was a single transient
/// value, so proving one model worked and then looking at the other discarded the result —
/// and a relaunch discarded it regardless.
///
/// Unlike a provider there is nothing to configure per model, so this holds only the
/// active choice and the verifications. Download state stays in `ModelManager`, which is
/// where the work happens.
@MainActor
@Observable
final class SpeechModelStore {

    private enum Key {
        static let active = "stt.activeModel"
        static let verifications = "stt.verifications"
    }

    /// The model dictation actually uses. Changed only by an explicit action.
    private(set) var activeModel: SpeechModel

    private var verifications: [String: Verification]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.activeModel =
            SpeechModel(rawValue: defaults.string(forKey: Key.active) ?? "") ?? .parakeetV3

        if let data = defaults.data(forKey: Key.verifications),
           let stored = try? JSONDecoder().decode([String: Verification].self, from: data) {
            self.verifications = stored
        } else {
            self.verifications = [:]
        }
    }

    // MARK: - Reading

    func verification(for model: SpeechModel) -> Verification {
        verifications[model.rawValue] ?? .untested
    }

    var others: [SpeechModel] {
        SpeechModel.allCases.filter { $0 != activeModel }
    }

    // MARK: - Writing

    func setActive(_ model: SpeechModel) {
        guard model != activeModel else { return }
        activeModel = model
        defaults.set(model.rawValue, forKey: Key.active)
    }

    func setVerification(_ verification: Verification, for model: SpeechModel) {
        verifications[model.rawValue] = verification
        persist()
    }

    /// Called when a model is removed or re-downloaded: whatever we proved was about the
    /// files that were there at the time.
    func clearVerification(for model: SpeechModel) {
        verifications.removeValue(forKey: model.rawValue)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(verifications) else { return }
        defaults.set(data, forKey: Key.verifications)
    }
}
