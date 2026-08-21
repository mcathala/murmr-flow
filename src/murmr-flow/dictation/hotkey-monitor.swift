import AppKit
import CoreGraphics

/// Watches for a push-to-talk key held anywhere in the system.
///
/// Whatever the user recorded — a modifier on its own, or a key with modifiers. Right ⌥
/// is the default because holding a modifier while speaking cannot collide with typing and
/// needs no "was that a tap or a hold" heuristic, but it is a default rather than a limit.
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

    /// Whether any enabled macOS shortcut is bound to the same combination.
    ///
    /// Reads the system's own symbolic-hotkey list. Scoped precisely, because over-claiming
    /// would be worse than not checking: it cannot see shortcuts owned by other apps, and
    /// it cannot know that a keyboard layout treats right ⌥ as AltGr. Silence means
    /// "nothing in the system list", not "guaranteed free".
    static func conflict(for hotkey: Hotkey) -> String? {
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

            if hotkey.isModifierOnly {
                // A modifier-only shortcut carries no key code of its own.
                guard keyCode == 0xFFFF || keyCode < 0 else { continue }
                guard let flag = Hotkey.modifierFlags[hotkey.keyCode],
                      carbonMask(for: flag) == modifiers
                else { continue }
            } else {
                guard keyCode == Int(hotkey.keyCode),
                      carbonMask(for: hotkey.modifiers) == modifiers
                else { continue }
            }
            return "A macOS shortcut already uses \(hotkey.displayName)."
        }
        return nil
    }

    /// The system list stores Carbon-style masks, which are not the CoreGraphics bits.
    private static func carbonMask(for flags: CGEventFlags) -> Int {
        var mask = 0
        if flags.contains(.maskShift) { mask |= 131_072 }
        if flags.contains(.maskControl) { mask |= 262_144 }
        if flags.contains(.maskAlternate) { mask |= 524_288 }
        if flags.contains(.maskCommand) { mask |= 1_048_576 }
        return mask
    }

    private(set) var hotkey: Hotkey = .default

    /// Called on the main actor when the key goes down / comes back up.
    var onPress: (@MainActor @Sendable () -> Void)?
    var onRelease: (@MainActor @Sendable () -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false

    var isRunning: Bool { tap != nil }

    // MARK: - Lifecycle

    func start(hotkey: Hotkey = .default) throws {
        stop()
        self.hotkey = hotkey

        // flagsChanged for a modifier-only trigger; keyDown and keyUp for a combination.
        // Watching all three unconditionally keeps `handle` the only place that decides
        // what counts, rather than splitting the rule across two masks.
        let mask =
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

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

        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        let held: Bool
        if hotkey.isModifierOnly {
            guard type == .flagsChanged, code == hotkey.keyCode,
                  let flag = Hotkey.modifierFlags[hotkey.keyCode]
            else { return }
            // flagsChanged fires for press *and* release; which one it is has to be
            // inferred from whether the flag is still set.
            held = event.flags.contains(flag)
        } else {
            guard type == .keyDown || type == .keyUp, code == hotkey.keyCode else { return }
            // The modifiers must be held on the way down. On the way up they often are
            // not — releasing ⌘ before D is normal — so a keyUp for the right key ends it
            // regardless, or the recording would never stop.
            if type == .keyDown {
                guard event.flags.isSuperset(of: hotkey.modifiers) else { return }
                held = true
            } else {
                held = false
            }
        }

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
