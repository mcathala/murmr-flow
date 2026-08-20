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
        /// Checking what is present before we know whether a download is needed.
        case preparing
        case downloading(fraction: Double)
        /// CoreML compiling and loading the model.
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .downloading, .loading: true
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

    /// True while `prepare()` is running, whether or not a busy state is visible yet.
    /// Reentrancy is tracked here rather than via `state`, because `state` deliberately
    /// stays put during a fast load.
    private(set) var isPreparing = false

    /// Latest phase reported by the library, shown only once we decide to reveal it.
    private var latestPhase: State = .preparing

    /// Nothing is shown unless the work is still going after this long.
    ///
    /// A cached load measured 180 ms on an M2 Pro, so 400 ms leaves a comfortable margin
    /// while still surfacing progress promptly for a real download (which takes minutes).
    /// It also sits in the usual 300–500 ms range for delaying a progress indicator, below
    /// which one flickers rather than informs.
    ///
    /// Suppressing by *phase* was not enough on its own: the library reports
    /// `.downloading` even for a fully cached model, because it walks the files to verify
    /// them. So the trigger has to be elapsed time, not what the library says it is doing.
    private static let revealBusyAfter: Duration = .milliseconds(400)

    /// Whether this model's files are already on disk, so reselecting it can just reload
    /// rather than asking the user to download something they already have.
    static func isDownloaded(_ model: SpeechModel) -> Bool {
        AsrModels.modelsExist(
            at: MLModelConfigurationUtils.defaultModelsDirectory(for: model.repo),
            version: model.asrVersion
        )
    }

    var isSelectedDownloaded: Bool { Self.isDownloaded(selected) }

    func select(_ model: SpeechModel) {
        guard model != selected else { return }
        selected = model
        // The previously loaded bundle belongs to the old selection.
        models = nil
        state = .notLoaded
    }

    /// Downloads the selected model if needed, then loads it. Safe to call repeatedly.
    func prepare() async {
        guard !isPreparing, models == nil else { return }
        isPreparing = true
        latestPhase = .preparing

        let clock = ContinuousClock()
        let started = clock.now

        // Reveal a busy state only if we are still working after the threshold. A cached
        // load finishes first, so the UI never changes at all.
        let reveal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.revealBusyAfter)
            guard let self, !Task.isCancelled, self.isPreparing else { return }
            self.state = self.latestPhase
        }

        defer {
            reveal.cancel()
            isPreparing = false
        }

        do {
            let loaded = try await AsrModels.downloadAndLoad(
                version: selected.asrVersion,
                progressHandler: { [weak self] progress in
                    // Fired off the main actor by the downloader.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let phase: State =
                            switch progress.phase {
                            case .listing: .preparing
                            case .downloading: .downloading(fraction: progress.fractionCompleted)
                            case .compiling: .loading
                            }
                        self.latestPhase = phase
                        // Only touch what the user sees if we already revealed progress.
                        if self.state.isBusy { self.state = phase }
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
