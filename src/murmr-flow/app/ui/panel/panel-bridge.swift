import AppKit
import Foundation

/// Keeps the floating panel in step with the two coordinators.
///
/// Deliberately one-way and in one place. The coordinators publish state and know nothing
/// about windows; the panel takes state and knows nothing about audio. Everything that
/// would otherwise be a reference from one to the other lives here.
///
/// Stage changes push immediately. The values that move continuously — timer, levels,
/// preview — are polled while something is running, because a callback per audio buffer
/// would rebuild the view far more often than a screen can show.
@MainActor
final class PanelBridge {

    private let panel: FloatingPanel
    private let dictation: DictationCoordinator
    private let meetings: MeetingCoordinator
    private let prompts: PromptStore

    private var pump: Task<Void, Never>?

    /// The last run we already reacted to, so a fallback notice is shown once and not
    /// again on every idle tick.
    private var reportedRunID: UUID?

    init(
        panel: FloatingPanel,
        dictation: DictationCoordinator,
        meetings: MeetingCoordinator,
        prompts: PromptStore
    ) {
        self.panel = panel
        self.dictation = dictation
        self.meetings = meetings
        self.prompts = prompts
    }

    func start() {
        wireActions()
        refreshPrompts()

        dictation.onStageChange = { [weak self] _ in self?.sync() }
        meetings.onStageChange = { [weak self] _ in self?.sync() }

        panel.present()
        sync()
        startPump()

    }

    // MARK: - Actions

    private func wireActions() {
        let model = panel.model

        model.onToggleDictation = { [weak self] in
            guard let self else { return }
            // Click is a toggle. The key is a hold — holding a mouse button to talk is
            // miserable, so the two routes genuinely differ here.
            if self.dictation.stage.isRecording {
                Task { await self.dictation.endDictation() }
            } else {
                self.dictation.beginDictation()
            }
        }

        model.onToggleMeeting = { [weak self] in
            self?.meetings.toggle()
        }

        model.onCancel = { [weak self] in
            guard let self else { return }
            switch self.panel.model.phase {
            case .failed:
                self.panel.model.set(.resting)
            default:
                // Only reachable from `armed`, where nothing has started yet.
                self.panel.model.hide()
            }
            self.panel.apply()
        }

        panel.onPromptChosen = { [weak self] id in
            guard let self else { return }
            self.prompts.dictationPromptID = id
            self.refreshPrompts()
            self.panel.apply()
        }
    }

    private func refreshPrompts() {
        panel.model.promptOptions = prompts.presets.map { (id: $0.id, name: $0.name) }
        panel.model.promptName = prompts.dictationPrompt.name
    }

    // MARK: - Sync

    /// Maps coordinator state onto the panel. Meetings win when both are somehow live —
    /// a long recording matters more than a stray dictation state.
    private func sync() {
        let model = panel.model

        switch meetings.stage {
        case .recording:
            model.mode = .note
            model.set(.meeting)
            panel.apply()
            return
        case .transcribing(let step):
            model.mode = .note
            model.set(.working(step.label))
            panel.apply()
            return
        case .failed(let message):
            model.mode = .note
            model.set(.failed(Self.failure(for: message)))
            panel.apply()
            return
        case .idle, .saved:
            break
        }

        switch dictation.stage {
        case .recording:
            model.mode = .dictation
            captureTarget()
            model.set(.dictating)

        case .transcribing:
            model.preview = ""
            model.set(.working("Transcribing…"))

        case .cleaning:
            // The live text goes when tidying starts. Keeping it visible while the model
            // rewrites it invites a comparison the panel is too small to host.
            model.preview = ""
            model.set(.working("Tidying up…"))

        case .injecting:
            model.set(.working("Inserting…"))

        case .failed(let message):
            model.set(.failed(Self.failure(for: message)))

        case .idle:
            // No success state. The text appearing in your document *is* the confirmation;
            // announcing it would be the app taking credit for something already visible.
            //
            // The exception is cleanup having fallen back to the raw transcript. That is
            // not a failed dictation — the words still landed — but it is worth saying,
            // because otherwise the only clue is that they read a little rougher.
            if let run = dictation.lastRun, run.id != reportedRunID {
                reportedRunID = run.id
                model.preview = ""
                model.set(run.usedRawFallback ? .failed(.cleanup) : .resting)
            } else if model.phase.isBusy {
                model.preview = ""
                model.set(.resting)
            }
        }

        panel.apply()
    }

    private static func failure(for message: String) -> PanelModel.Failure {
        // The panel's whole vocabulary is two lines: which half broke. Anything mentioning
        // the provider or a key is the AI side; everything else is the voice side.
        let lowered = message.lowercased()
        let cleanupWords = ["key", "provider", "api", "clean", "model responded", "http"]
        return cleanupWords.contains(where: lowered.contains) ? .cleanup : .transcription
    }

    private func captureTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        panel.model.targetAppName = app.localizedName
        panel.model.targetAppIcon = app.icon
    }

    // MARK: - Continuous values

    /// Ten times a second while something runs, and idle otherwise. Fast enough that a
    /// level meter reads as movement rather than flicker, cheap enough to ignore.
    private func startPump() {
        pump?.cancel()
        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let model = panel.model
        var changedSize = false

        switch model.phase {
        case .dictating:
            let hadPreview = !model.preview.isEmpty
            model.elapsed = dictation.elapsed
            model.micLevel = dictation.micLevel
            model.preview = dictation.preview
            // Gaining or losing the preview line changes how tall the panel has to be.
            changedSize = hadPreview != !model.preview.isEmpty

        case .meeting:
            model.elapsed = meetings.elapsed
            model.youLevel = meetings.youLevel
            model.themLevel = meetings.themLevel

        default:
            return
        }

        if changedSize { panel.apply() }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }
}
