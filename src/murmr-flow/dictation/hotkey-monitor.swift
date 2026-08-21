import AppKit
import CoreGraphics

/// Watches for a push-to-talk key held anywhere in the system.
///
/// A modifier key is used rather than a letter chord: holding it while speaking cannot
/// collide with typing, and it needs no "was that a tap or a hold" heuristic. Right
/// Option is the default because the Globe/fn key only behaves consistently on Apple
/// keyboards.
///
/// The tap is **listen-only**, so the keypress still reaches the frontmost app.
/// Swallowing it would be surprising for a key the user may want for its normal purpose.
final class HotkeyMonitor: @unchecked Sendable {

    enum MonitorError: LocalizedError {
        case tapCreationFailed

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed:
                "Could not watch for the hotkey. Grant Accessibility permission and "
                    + "restart Murmr Flow."
            }
        }
    }

    /// Push-to-talk keys we support. Raw values are virtual keycodes.
    enum Trigger: Int, CaseIterable, Identifiable, Sendable {
        case rightOption = 61
        case rightCommand = 54
        case rightControl = 62

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .rightOption: "Right ⌥ Option"
            case .rightCommand: "Right ⌘ Command"
            case .rightControl: "Right ⌃ Control"
            }
        }

        /// The modifier bit that is set while this key is held.
        /// Carbon-style mask, which is what the system hotkey list stores.
        var carbonModifier: Int {
            switch self {
            case .rightOption: 524_288
            case .rightCommand: 1_048_576
            case .rightControl: 262_144
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .rightOption: .maskAlternate
            case .rightCommand: .maskCommand
            case .rightControl: .maskControl
            }
        }
    }

    /// Whether any enabled macOS shortcut uses this modifier on its own.
    ///
    /// Scoped precisely, because over-claiming would be worse than not checking: this
    /// reads the system's own symbolic-hotkey list and looks for an entry bound to this
    /// modifier alone. It cannot see shortcuts owned by other apps, and it cannot know
    /// that a keyboard layout treats right Option as AltGr. Silence here means "nothing
    /// in the system list", not "guaranteed free".
    static func conflict(for trigger: Trigger) -> String? {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return nil }

        for (_, raw) in hotkeys {
            guard let entry = raw as? [String: Any],
                  entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let modifiers = parameters[2] as? Int,
                  let keyCode = parameters[1] as? Int
            else { continue }

            // A modifier-only shortcut carries no key code of its own.
            guard keyCode == 0xFFFF || keyCode < 0 else { continue }
            guard modifiers == trigger.carbonModifier else { continue }
            return "A macOS shortcut already uses \(trigger.displayName) on its own."
        }
        return nil
    }

    private(set) var trigger: Trigger = .rightOption

    /// Called on the main actor when the key goes down / comes back up.
    var onPress: (@MainActor @Sendable () -> Void)?
    var onRelease: (@MainActor @Sendable () -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false

    var isRunning: Bool { tap != nil }

    // MARK: - Lifecycle

    func start(trigger: Trigger = .rightOption) throws {
        stop()
        self.trigger = trigger

        // flagsChanged fires for modifier press *and* release; which one it is has to be
        // inferred from whether the flag is still set.
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw MonitorError.tapCreationFailed
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        isHeld = false
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that takes too long to respond. Re-enable rather than
        // silently losing the hotkey for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .flagsChanged else { return }

        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(trigger.rawValue)
        else { return }

        let held = event.flags.contains(trigger.flag)
        guard held != isHeld else { return }
        isHeld = held

        let press = onPress
        let release = onRelease
        // The tap callback runs on the run loop, not necessarily where the UI lives.
        Task { @MainActor in
            if held { press?() } else { release?() }
        }
    }
}
