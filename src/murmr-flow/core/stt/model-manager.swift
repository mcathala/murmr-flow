import FluidAudio
import Foundation
import Observation

/// Downloads and loads the local speech model.
///
/// Models are fetched on demand and cached — never bundled. A ~600 MB payload inside
/// the app would balloon the download and defeat the curl installer.
@MainActor
@Observable
final class ModelManager {

    enum State: Equatable {
        case notLoaded
        case downloading(fraction: Double)
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .loading: true
            case .notLoaded, .ready, .failed: false
            }
        }
    }

    private(set) var state: State = .notLoaded
    private(set) var selected: SpeechModel = .parakeetV3

    /// Loaded CoreML bundle, handed to `TranscriptionService`.
    private(set) var models: AsrModels?

    /// How long the last load took, download included.
    private(set) var loadDuration: Duration?

    func select(_ model: SpeechModel) {
        guard model != selected else { return }
        selected = model
        // The previously loaded bundle belongs to the old selection.
        models = nil
        state = .notLoaded
    }

    /// Downloads the selected model if needed, then loads it. Safe to call repeatedly.
    func prepare() async {
        guard !state.isBusy, models == nil else { return }

        state = .downloading(fraction: 0)
        let clock = ContinuousClock()
        let started = clock.now

        do {
            let loaded = try await AsrModels.downloadAndLoad(
                version: selected.asrVersion,
                progressHandler: { [weak self] progress in
                    // Fired off the main actor by the downloader.
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction: progress.fractionCompleted)
                    }
                }
            )
            models = loaded
            loadDuration = clock.now - started
            state = .ready
        } catch {
            models = nil
            state = .failed(error.localizedDescription)
        }
    }

    /// Frees the loaded model. The download stays cached on disk.
    func unload() {
        models = nil
        state = .notLoaded
    }
}
