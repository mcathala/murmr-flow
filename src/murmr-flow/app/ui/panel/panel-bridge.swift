import AppKit
import Foundation

/// Keeps the floating panel in step with the two coordinators.
///
/// Deliberately one-way and in one place. The coordinators publish state and know nothing
/// about windows; the panel takes state and knows nothing about audio. Everything that
/// would otherwise be a reference from one to the other lives here.
///
/// Stage changes push immediately. The values that move continuously — timer, levels —
/// are polled while something is running, because a callback per audio buffer would
/// rebuild the view far more often than a screen can show.
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
    /// The last empty dictation the pill spoke about, so each one is mentioned once.
    private var reportedNothingHeard = 0
    private var noticeTask: Task<Void, Never>?

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
        refreshHotkey()
        refreshTranslation()

        dictation.onStageChange = { [weak self] _ in self?.sync() }

        // The row's job is to say where the text will land *before* you speak, so the
        // target has to be captured when the row opens. Capturing it only at the start of
        // a recording meant the icon was always one beat late — and absent exactly when
        // it was supposed to be useful.
        panel.onPhaseChanged = { [weak self] phase in
            if phase == .armed { self?.captureTarget() }
        }
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

        // Finish properly. Which of the two is running decides what "properly" means.
        model.onStop = { [weak self] in
            guard let self else { return }
            if self.meetings.stage.isRecording {
                self.meetings.toggle()
            } else if self.dictation.stage.isRecording {
                Task { await self.dictation.endDictation() }
            }
        }

        // Throw it away. From `armed` there is nothing to throw, so it just dismisses.
        model.onDiscard = { [weak self] in
            guard let self else { return }
            switch self.panel.model.phase {
            case .dictating:
                self.dictation.cancelDictation()
            case .failed:
                self.panel.model.set(.resting)
            default:
                self.panel.model.hide()
            }
            self.panel.apply()
        }

        model.onToggleTranslate = { [weak self] in
            guard let self else { return }
            let settings = self.dictation.settings
            if self.panel.model.mode == .note {
                settings.notetakerTranslates.toggle()
            } else {
                settings.dictationTranslates.toggle()
            }
            self.refreshTranslation()
            self.panel.apply()
        }

        panel.onPromptChosen = { [weak self] id in
            guard let self else { return }
            let model = self.panel.model
            if model.mode == .note {
                self.prompts.notetakerPromptID = id
            } else if let bundleID = model.targetBundleID,
                      var rule = self.prompts.appRules.first(where: { $0.bundleID == bundleID }) {
                // A rule for this app is what is deciding, and the bubble says so — so a
                // rule is what changes. Setting the standing style here instead would look
                // like the pill ignoring the click: the rule would still win, and the
                // bubble would still read the same.
                rule.outcome = .style(id)
                self.prompts.setRule(rule)
            } else {
                self.prompts.dictationPromptID = id
            }
            self.refreshPrompts()
            self.panel.apply()
        }
    }

    /// Kept in step with Settings, and nil when the watcher isn't running — the row must
    /// not show a key that cannot fire.
    /// The keys stay visible whether or not the watcher runs — a blank where the bind
    /// should be reads as a bug — but the view dims an unarmed one and says why.
    private func refreshHotkey() {
        panel.model.hotkeyLabel = dictation.settings.hotkey.displayName
        panel.model.meetingHotkeyLabel = dictation.settings.meetingHotkey?.displayName
        panel.model.hotkeyArmed = dictation.hotkeyActive
    }

    private func refreshPrompts() {
        panel.model.promptOptions = prompts.presets.map { (id: $0.id, name: $0.name) }
        refreshStyle()
    }

    /// The style the bubble names, and why.
    ///
    /// A dictation that is already running keeps the style it was started with — that was
    /// settled at key-down and is what will actually run, so showing anything else would be
    /// a promise the finished text would break. Otherwise the answer is resolved fresh
    /// from the app in front, which is what makes the bubble change as you move between
    /// windows.
    private func refreshStyle() {
        let model = panel.model
        let noteName = prompts.notetakerPrompt?.name ?? "As spoken"
        if model.notePromptName != noteName { model.notePromptName = noteName }
        guard model.mode != .note else {
            if model.promptDetail != nil { model.promptDetail = nil }
            return
        }
        let choice = (dictation.stage.isBusy ? dictation.currentStyle : nil)
            ?? prompts.choice(forApp: model.targetBundleID)
        // Only on a change. This runs on the pump, ten times a second, and an assignment
        // to an observed property counts as one whether or not the value moved.
        if model.promptName != choice.displayName { model.promptName = choice.displayName }
        if model.promptDetail != choice.detail { model.promptDetail = choice.detail }
    }

    /// Mirrors Settings for whichever job the pill is showing, so a change made in the
    /// window shows in the pill — and the bubble always describes the active recording.
    private func refreshTranslation() {
        let settings = dictation.settings
        let (on, language) = panel.model.mode == .note
            ? (settings.notetakerTranslates, settings.notetakerOutputLanguage)
            : (settings.dictationTranslates, settings.dictationOutputLanguage)
        panel.model.translateOn = on
        panel.model.translateLanguage = language
        panel.model.translateCode = OutputLanguage.shortCode(for: language)
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
        case .failed(let kind, _):
            model.mode = .note
            model.set(.failed(kind))
            panel.apply()
            return
        case .idle, .saved:
            break
        }

        // Whichever branch runs, the chips and bubble must describe the job it is about.
        defer { refreshTranslation() }

        switch dictation.stage {
        case .recording:
            model.mode = .dictation
            captureTarget()
            model.set(.dictating)

        case .transcribing:
            model.set(.working("Transcribing…"))

        case .cleaning:
            model.set(.working("Cleaning up…"))

        case .injecting:
            model.set(.working("Inserting…"))

        case .failed(let kind, _):
            model.set(.failed(kind))

        case .idle:
            // No success state. The text appearing in your document *is* the confirmation;
            // announcing it would be the app taking credit for something already visible.
            // Nor is a clean-up that fell back to the raw transcript a failure: the words
            // landed, and the rougher read is the whole of the difference.
            //
            // Two things *are* said. Text that could not be typed into the app in front
            // is on the clipboard, and the person has to be told, or the dictation
            // simply vanished. And a dictation that heard nothing looks exactly like a
            // key that never fired — so the pill says which, for a moment.
            if let run = dictation.lastRun, run.id != reportedRunID {
                reportedRunID = run.id
                model.set(run.insertionFailed ? .failed(.insertion) : .resting)
            } else if dictation.nothingHeardCount != reportedNothingHeard {
                reportedNothingHeard = dictation.nothingHeardCount
                show(notice: "Didn\u{2019}t hear anything", for: .seconds(2))
            } else if model.phase.isBusy {
                model.set(.resting)
            }
        }

        panel.apply()
    }

    /// A notice is a moment, not a state: it clears itself unless something else has
    /// taken the pill over in the meantime.
    private func show(notice: String, for duration: Duration) {
        panel.model.set(.notice(notice))
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled,
                  case .notice = self.panel.model.phase else { return }
            self.panel.model.set(.resting)
            self.panel.apply()
        }
    }

    private func captureTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        panel.model.targetAppName = app.localizedName
        panel.model.targetAppIcon = app.icon
        panel.model.targetBundleID = app.bundleIdentifier
        // The app decides the style, so knowing the app is what makes the bubble able to
        // say which style is coming — before a word is spoken, which is the whole point.
        refreshStyle()
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
        // Before the state switch, and deliberately outside it: the panel has to follow
        // the pointer between displays whether anything is running or not. A pill parked
        // on the other monitor is a pill you cannot reach.
        panel.followPointerIfNeeded()
        let sizeBefore = panel.model.size
        refreshHotkey()
        refreshTranslation()
        refreshStyle()
        // The bubble appearing or going changes the window's height even when the phase
        // has not moved — a settings change in the window, or the satellite flipping the
        // mode between two jobs with different translation states.
        if panel.model.size != sizeBefore { panel.apply() }

        let model = panel.model

        switch model.phase {
        case .dictating:
            model.elapsed = dictation.elapsed
            model.micLevel = dictation.micLevel

        case .meeting:
            model.elapsed = meetings.elapsed
            model.youLevel = meetings.youLevel
            model.themLevel = meetings.themLevel

        default:
            return
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }
}
