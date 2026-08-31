import AppKit
import Observation
import OSLog

/// Owns the objects that live for as long as the process does.
///
/// These used to be `@State` on the `App` struct, started from a view's `.task`. That
/// tied process-lifetime concerns to a view's lifecycle, which meant the hotkey was only
/// installed if a particular window happened to appear — and never re-installed when the
/// user granted Accessibility while the app was already running.
@MainActor
@Observable
final class AppServices {

    static let shared = AppServices()

    let permissions = PermissionManager()

    /// Which section the window is showing. Held here rather than as view state so the
    /// menu bar and the ⌘, shortcut can move it from outside the view.
    var route: MainWindow.Route = .home

    /// Where leaving Settings returns you.
    ///
    /// The sidebar swaps its list rather than growing one, so Settings is a level you
    /// enter and leave. Three places used to set `route` to a settings pane directly — the
    /// sidebar row, ⌘, and the menu bar — and none of them could have known where "back"
    /// should go. They all call `openSettings` now, which is the only thing that records it.
    private(set) var routeBeforeSettings: MainWindow.Route = .home

    /// One settings store, one model, one transcriber — shared by both modes. Two
    /// `SpeechModelLoader`s would each load their own copy of the model, and two
    /// `SettingsStore`s would not see each other's changes.
    let settings = SettingsStore()
    let history = HistoryStore()
    let notes = NoteStore()
    let prompts = PromptStore()
    let providers = ProviderStore()
    let dictionary = DictionaryStore()
    let speech = SpeechModelStore()
    let audioDevices: AudioDeviceStore

    /// First launch. Reads the same permission and model state as everything else, so a
    /// step is shown only while its condition is unmet — see the coordinator for the rules.
    let onboarding: OnboardingCoordinator
    private let loader = SpeechModelLoader()
    private let transcriber = TranscriptionService()

    let dictation: DictationCoordinator
    let meetings: MeetingCoordinator

    /// Not observable state: it owns an NSPanel and must never be recreated.
    let panel = FloatingPanel()
    private var bridge: PanelBridge?

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "startup")

    /// A second watcher, because a meeting is a *toggle* rather than a hold — one press
    /// starts, one stops. Sharing the dictation monitor would mean one key with two
    /// meanings depending on which handler happened to be installed.
    private let meetingHotkey = HotkeyMonitor()

    private var accessibilityWatch: Task<Void, Never>?
    private var hasStarted = false

    private init() {
        let devices = AudioDeviceStore(settings: settings)
        audioDevices = devices
        dictation = DictationCoordinator(
            settings: settings, loader: loader, transcriber: transcriber,
            history: history, prompts: prompts, providers: providers,
            speech: speech, dictionary: dictionary, devices: devices
        )
        meetings = MeetingCoordinator(
            loader: loader, transcriber: transcriber, notes: notes,
            settings: settings, prompts: prompts, providers: providers,
            dictionary: dictionary, devices: devices
        )

        // Locals, not `self`: an escaping closure may not capture `self` before every
        // stored property has been set, and this one is being set.
        let permissions = self.permissions
        let speech = self.speech
        onboarding = OnboardingCoordinator { step in
            switch step {
            case .language: SpeechModelLoader.isDownloaded(speech.activeModel)
            case .microphone: permissions.microphone == .granted
            case .accessibility: permissions.accessibility == .granted
            case .systemAudio: permissions.systemAudio == .granted
            // Nothing to check: these are there to be read or done, not verified.
            case .howItWorks, .underTheHood, .style, .tryIt: false
            }
        }
    }

    // MARK: - Onboarding

    /// The last screen's Done. Lands on Home, whatever the menu bar or ⌘, did to the route
    /// while the flow was covering it.
    func finishOnboarding() {
        onboarding.finish()
        dictation.deliversText = true
        route = .home
    }

    // MARK: - Settings level

    /// Enters Settings, remembering what to come back to. Re-entering from inside Settings
    /// leaves that memory alone, or moving between two panes would make Home the only way
    /// out of every one of them.
    func openSettings(_ pane: SettingsPane = .speechModel) {
        if !route.isSettings { routeBeforeSettings = route }
        route = .settings(pane)
    }

    func closeSettings() {
        route = routeBeforeSettings
    }

    // MARK: - Launch

    /// Idempotent, because it is triggered from two places on purpose.
    ///
    /// `applicationDidFinishLaunching` is the intended trigger, but SwiftUI can install
    /// an `@NSApplicationDelegateAdaptor` delegate *after* that notification has already
    /// been delivered, in which case it never arrives. Relying on it alone left the model
    /// unloaded and the window never ordered on screen. The window's `.task` is the
    /// backstop.
    func start(trigger: String) {
        guard !hasStarted else {
            Self.log.notice("start(\(trigger, privacy: .public)) ignored — already started")
            return
        }
        hasStarted = true
        Self.log.notice("start(\(trigger, privacy: .public)) running")

        onboarding.begin()
        Self.log.notice(
            "onboarding: \(self.onboarding.isComplete ? "complete" : String(describing: self.onboarding.step), privacy: .public)"
        )

        // One bridge owns every link between the coordinators and the panel, so neither
        // coordinator ever holds a reference to a window.
        let bridge = PanelBridge(
            panel: panel, dictation: dictation, meetings: meetings, prompts: prompts
        )
        bridge.start()
        self.bridge = bridge

        // The microphone cannot serve both at once, so whichever starts first wins.
        meetings.onRecordingChange = { [dictation] isRecording in
            dictation.isSuspended = isRecording
        }

        // A bundled font that failed to register is the quietest possible failure: every
        // screen silently falls back to the system face and looks subtly wrong for the whole
        // session with nothing to point at. Cheap to check, so check it.
        if !Theme.Face.isAvailable {
            let face = Theme.Face.ui
            Self.log.error(
                "bundled font \(face, privacy: .public) did not register; rendering in the system fallback"
            )
        }

        armHotkeyIfPossible()
        armMeetingHotkey()
        FnKeyOwner.update(for: [settings.hotkey, settings.meetingHotkey])
        Self.log.notice("hotkey armed: \(self.dictation.hotkeyActive, privacy: .public)")

        // Load the model now rather than during the first dictation. Otherwise the user
        // holds the key, speaks, releases — and only then waits for a ~600 MB download.
        //
        // Except when the first thing on screen is the question of *which* model: 600 MB of
        // one would already be on its way before the user had answered. Choosing is what
        // starts the download then — see `OnboardingView.choose`.
        guard onboarding.isComplete || onboarding.step != .language else { return }
        Task {
            Self.log.notice("warmUp starting")
            await dictation.warmUp()
            Self.log.notice("warmUp finished, state=\(String(describing: self.dictation.loader.state), privacy: .public)")
        }
    }

    // MARK: - Hotkey arming

    /// The hotkey needs Accessibility, which is the same permission text injection needs.
    /// If it isn't granted yet, watch for it instead of requiring a restart.
    func armHotkeyIfPossible() {
        permissions.refresh()

        guard permissions.accessibility == .granted else {
            watchForAccessibility()
            return
        }
        guard !dictation.hotkeyActive else { return }

        dictation.installHotkey()
        if dictation.hotkeyActive { accessibilityWatch?.cancel() }
    }

    /// Installs the meeting key, or removes it when there isn't one.
    ///
    /// Called on launch and whenever the binding changes, so an unset key genuinely stops
    /// being watched rather than lingering until the next restart.
    func armMeetingHotkey() {
        meetingHotkey.stop()
        guard let key = settings.meetingHotkey, permissions.accessibility == .granted else {
            return
        }

        meetingHotkey.onPress = { [meetings] in meetings.toggle() }
        meetingHotkey.onRelease = nil
        try? meetingHotkey.start(hotkey: key)
    }

    func changeMeetingHotkey(to hotkey: Hotkey?) {
        settings.meetingHotkey = hotkey
        armMeetingHotkey()
        FnKeyOwner.update(for: [settings.hotkey, settings.meetingHotkey])
    }

    /// Un-hides the pill. Wired to the app coming forward: hiding it is one click on the
    /// ✕ satellite, so touching the app is the gesture that says "I want my controls
    /// back" — without it, the only way to see the pill again was to start a recording.
    func revealPanel() {
        panel.model.reveal()
        panel.apply()
    }

    func changeDictationHotkey(to hotkey: Hotkey) {
        dictation.changeHotkey(to: hotkey)
        FnKeyOwner.update(for: [settings.hotkey, settings.meetingHotkey])
    }

    /// The system gets its fn key back. Called from `applicationWillTerminate`; a crash
    /// skips it, and the next launch picks the marker up instead.
    func willTerminate() {
        FnKeyOwner.release()
    }

    private func watchForAccessibility() {
        guard accessibilityWatch == nil else { return }
        accessibilityWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.permissions.refresh()
                guard self.permissions.accessibility == .granted else { continue }
                self.dictation.installHotkey()
                if self.dictation.hotkeyActive {
                    self.accessibilityWatch = nil
                    return
                }
            }
        }
    }
}
