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
    let dictation = DictationCoordinator()

    /// Not observable state: it owns an NSPanel and must never be recreated.
    let hud = DictationHUD()

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "startup")

    private var accessibilityWatch: Task<Void, Never>?
    private var hasStarted = false

    private init() {}

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

        dictation.onStageChange = { [hud] stage in hud.update(stage: stage) }

        armHotkeyIfPossible()
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
