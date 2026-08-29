import AppKit
import CoreGraphics
import os

/// Watches for a push-to-talk key held anywhere in the system.
///
/// Whatever the user recorded — modifiers on their own, or a key with modifiers. fn is the
/// default because holding a modifier while speaking cannot collide with typing and needs
/// no "was that a tap or a hold" heuristic, but it is a default rather than a limit.
///
/// The tap is **listen-only**, so the keypress still reaches the frontmost app.
/// Swallowing it would be surprising for a key the user may want for its normal purpose.
///
/// **A modifier press is reported after a short arming delay**, not on the way down. The
/// two default chords share a key — fn dictates, fn + left ⇧ starts a meeting — so on
/// the way down there is no telling which one is coming, and macOS's own fn shortcuts
/// (fn + arrows, fn + a function key) look identical to the start of a dictation. If
/// another key joins within the delay the press is dropped; if the key comes back up
/// first it was a clean tap and press and release are delivered together. Speech that
/// starts within 150 ms of the key going down is rarer than a chord is.
final class HotkeyMonitor: @unchecked Sendable {

    /// How long a modifier has to be down on its own before it counts as pressed.
    static let armingDelay: Duration = .milliseconds(150)

    /// `log show --predicate 'subsystem == "app.murmr.MurmrFlow" AND category == "hotkey"'`
    /// — the one way to see what the key did on a machine that isn't this one.
    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "hotkey")

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
                guard let flag = hotkey.ownFlag,
                      carbonMask(for: hotkey.modifiers.union(flag)) == modifiers
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
        if flags.contains(.maskSecondaryFn) { mask |= 8_388_608 }
        return mask
    }

    /// What macOS itself still does with a lone fn, if the hotkey is fn and the system's
    /// action is on.
    ///
    /// Normally nothing: `FnKeyOwner` parks the system's action the moment fn becomes one
    /// of our keys. This is the fallback for when it could not — the private call is gone,
    /// or the user put their own action back — because a held fn is then taken away from
    /// us a tenth of a second in, and every dictation dies with "No audio was captured".
    static func systemFnWarning(for hotkey: Hotkey) -> String? {
        guard hotkey.usesFn else { return nil }
        // Ask the system live; the HIToolbox defaults lag behind a change made this session.
        let usage = FnKeyOwner.systemUsage()
            ?? (UserDefaults(suiteName: "com.apple.HIToolbox")?
                .object(forKey: "AppleFnUsageType") as? Int).map(Int32.init)
        guard usage != FnKeyOwner.doNothing else { return nil }
        return "macOS is still using fn for itself, so holding it won\u{2019}t work. Set "
            + "“Press 🌐 key to” to “Do Nothing” in Keyboard settings."
    }

    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private(set) var hotkey: Hotkey = .default

    /// Called on the main actor when the key goes down / comes back up.
    var onPress: (@MainActor @Sendable () -> Void)?
    var onRelease: (@MainActor @Sendable () -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false

    /// A modifier press waiting out the arming delay. Only ever touched on the main run
    /// loop, which is where the tap delivers.
    private var pendingPress: Task<Void, Never>?
    /// Set when a pending press was dropped because another key joined. The chord's own
    /// key is still down; nothing counts again until it has come back up.
    private var interrupted = false

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
        pendingPress?.cancel()
        pendingPress = nil
        interrupted = false
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
            // A key typed while our modifier is arming means it was a shortcut, not us.
            if type == .keyDown {
                if pendingPress != nil {
                    Self.log.notice("key \(code, privacy: .public) during arming — dropped")
                    interrupt()
                }
                return
            }
            guard type == .flagsChanged else { return }
            // flagsChanged fires for press *and* release; which one it is has to be
            // inferred from the flags.
            guard let state = hotkey.modifierState(keyCode: code, flags: event.flags) else {
                // Some other modifier. Going down while ours is arming makes a chord that
                // isn't ours — ⇧ after fn, when fn alone is the key.
                if pendingPress != nil, Self.isPress(code: code, flags: event.flags) {
                    Self.log.notice("modifier \(code, privacy: .public) during arming — dropped")
                    interrupt()
                }
                return
            }
            if interrupted {
                // Waiting for the key to come back up before it can count again.
                if !state { interrupted = false }
                return
            }
            held = state
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

        let flags = event.flags.intersection(Hotkey.allModifierMasks).rawValue
        if held, hotkey.isModifierOnly {
            Self.log.notice("\(self.hotkey.displayName, privacy: .public) down (flags \(flags, privacy: .public)) — arming")
            armPress()
        } else if held {
            Self.log.notice("\(self.hotkey.displayName, privacy: .public) down — pressed")
            deliver(press: true)
        } else if let pending = pendingPress {
            // Up before the delay ran out: a clean tap. Both halves, in order, so a
            // press-to-toggle key still toggles.
            Self.log.notice("\(self.hotkey.displayName, privacy: .public) up before arming (flags \(flags, privacy: .public)) — tap")
            pending.cancel()
            pendingPress = nil
            deliver(press: true)
            deliver(press: false)
        } else {
            Self.log.notice("\(self.hotkey.displayName, privacy: .public) up (flags \(flags, privacy: .public)) — released")
            deliver(press: false)
        }
    }

    private static func isPress(code: UInt16, flags: CGEventFlags) -> Bool {
        Hotkey.modifierFlags[code].map { flags.contains($0) } ?? false
    }

    private func armPress() {
        pendingPress?.cancel()
        pendingPress = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.armingDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingPress = nil
            Self.log.notice("\(self.hotkey.displayName, privacy: .public) held — pressed")
            self.onPress?()
        }
    }

    private func interrupt() {
        pendingPress?.cancel()
        pendingPress = nil
        isHeld = false
        interrupted = true
    }

    private func deliver(press: Bool) {
        let press = press ? onPress : onRelease
        // The tap callback runs on the run loop, not necessarily where the UI lives.
        Task { @MainActor in press?() }
    }
}
