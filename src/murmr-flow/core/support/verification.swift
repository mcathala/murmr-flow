import Foundation

/// Whether a thing has actually been exercised, as opposed to merely configured.
///
/// Shared between the clean-up providers and the speech models because it is one concept:
/// a pasted key is not a working key, and a downloaded model is not a model that has been
/// shown to transcribe. In both cases the difference used to surface only at the moment
/// you needed it to work.
///
/// The result is stored *per thing* and persisted, so looking at an alternative does not
/// discard what you proved about the one you are using.
enum Verification: Codable, Equatable, Sendable {
    case untested
    case working(latency: TimeInterval, at: Date)
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var latency: TimeInterval? {
        if case .working(let latency, _) = self { return latency }
        return nil
    }

    var failure: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}
