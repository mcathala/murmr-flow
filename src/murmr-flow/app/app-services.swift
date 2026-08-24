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

    /// One settings store, one model, one transcriber — shared by both modes. Two
    /// `ModelManager`s would each load their own copy of the model, and two
    /// `SettingsStore`s would not see each other's changes.
    let settings = SettingsStore()
    let history = HistoryStore()
    let notes = MeetingStore()
    let prompts = PromptStore()
    let providers = ProviderStore()
    let speech = SpeechModelStore()
    private let models = ModelManager()
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
        dictation = DictationCoordinator(
            settings: settings, models: models, transcriber: transcriber,
            history: history, prompts: prompts, providers: providers,
            speech: speech
        )
        meetings = MeetingCoordinator(
            models: models, transcriber: transcriber, notes: notes,
            settings: settings, prompts: prompts, providers: providers
        )
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
        Self.log.notice("hotkey armed: \(self.dictation.hotkeyActive, privacy: .public)")

        // Load the model now rather than during the first dictation. Otherwise the user
        // holds the key, speaks, releases — and only then waits for a ~600 MB download.
        Task {
            Self.log.notice("warmUp starting")
            await dictation.warmUp()
            Self.log.notice("warmUp finished, state=\(String(describing: self.dictation.models.state), privacy: .public)")
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
