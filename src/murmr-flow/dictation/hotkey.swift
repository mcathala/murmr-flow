import AppKit
import CoreGraphics

/// A key combination the user chose.
///
/// This replaced an enum of three fixed triggers. Three was an arbitrary number that
/// happened to be what we had implemented, and it meant the answer to "which key" was
/// whichever of ours you disliked least.
///
/// Two shapes, because macOS reports them through different events:
///
///   - **Modifiers only** — fn, right ⌥, or fn + left ⇧. Arrive as `flagsChanged`, and the
///     only way to tell left from right is the key code, so the code of the key that
///     completes the chord is what we store rather than its flag. Any other modifiers in
///     the chord are stored as flags: left and right are told apart for the one key, not
///     for its companions.
///   - **A key with modifiers** — ⌘⇧D. Arrives as `keyDown`.
///
/// A bare non-modifier key is deliberately not expressible: it would fire every time you
/// typed that letter.
struct Hotkey: Codable, Equatable, Sendable {

    let keyCode: UInt16
    /// Modifiers that must be held *as well*. For a modifier-only trigger these are the
    /// *other* modifiers in the chord — empty when the key is on its own.
    let modifierRawValue: UInt64
    let isModifierOnly: Bool

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierRawValue) }

    /// fn holds a dictation. The same key Wispr Flow and OpenWhispr chose: alone in the
    /// corner of every Apple keyboard, nothing types with it, and no layout treats it as
    /// AltGr the way French ones treat right ⌥.
    static let `default` = Hotkey(keyCode: 63, modifierRawValue: 0, isModifierOnly: true)

    /// What dictation was bound to before fn: right ⌥. Installs from then keep it — see
    /// `SettingsStore` — so a key nobody asked to change does not change under them.
    static let legacyDefault = Hotkey(keyCode: 61, modifierRawValue: 0, isModifierOnly: true)

    /// fn + left ⇧ starts and stops a meeting. The same corner key with one more finger, so
    /// the two jobs are learnt as one gesture and its variant rather than as two keys —
    /// and a second finger is what stops a meeting starting by accident.
    static let meetingDefault = Hotkey(
        keyCode: 56, modifierRawValue: CGEventFlags.maskSecondaryFn.rawValue,
        isModifierOnly: true
    )

    /// The one flag a modifier key sets while it is down, or nil for any other key.
    var ownFlag: CGEventFlags? { Self.modifierFlags[keyCode] }

    /// Whether fn is part of this key — on its own, in a chord, or held with a letter. The
    /// system's own fn action has to be parked while any such key is ours.
    var usesFn: Bool {
        (isModifierOnly && keyCode == 63) || modifiers.contains(.maskSecondaryFn)
    }

    // MARK: - Matching

    /// What a `flagsChanged` event means for a modifier-only trigger: now held (`true`),
    /// now released (`false`), or nothing to do with it (`nil`).
    ///
    /// The event has to be about one of the chord's own keys — fn or left ⇧ for
    /// fn + left ⇧ — so that pressing them in either order lands, and so that right ⇧ does
    /// nothing when left ⇧ was recorded. The modifier bits then have to match **exactly**:
    /// fn on its own is not held while ⇧ is also down, or the dictation key would fire on
    /// the first half of the meeting chord.
    func modifierState(keyCode code: UInt16, flags: CGEventFlags) -> Bool? {
        guard isModifierOnly, let ownFlag else { return nil }
        if code != keyCode {
            guard let flag = Self.modifierFlags[code], flag != ownFlag, modifiers.contains(flag)
            else { return nil }
        }
        let required = modifiers.union(ownFlag)
        return flags.intersection(Self.allModifierMasks) == required
    }

    /// Every bit a modifier key can set, for isolating them from the rest of an event's flags.
    static let allModifierMasks: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    // MARK: - Naming

    /// `right ⌥`, or `⌘⇧D`. Written the way a Mac keyboard shortcut is normally written,
    /// so it is recognisable rather than described.
    var displayName: String {
        if isModifierOnly {
            let key = Self.modifierNames[keyCode] ?? "key \(keyCode)"
            // "fn + left ⇧": the companions by symbol, the key by name, because only the key
            // knows which side it is on.
            return (Self.words(for: modifiers) + [key]).joined(separator: " + ")
        }
        return Self.symbols(for: modifiers) + (Self.keyNames[keyCode] ?? "key \(keyCode)")
    }

    /// True when this is something we can actually watch for.
    ///
    /// A plain letter with no modifiers would fire while typing, which is why it is
    /// rejected rather than merely discouraged.
    var isUsable: Bool {
        isModifierOnly || !modifiers.intersection(Self.watchedModifiers).isEmpty
    }

    static let watchedModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
    ]

    /// Physical modifier keys, by key code. Left and right are separate keys and worth
    /// distinguishing — right ⌥ is a good push-to-talk key precisely because the left one
    /// stays free for typing accented characters.
    static let modifierNames: [UInt16: String] = [
        54: "right ⌘", 55: "left ⌘",
        56: "left ⇧", 60: "right ⇧",
        58: "left ⌥", 61: "right ⌥",
        59: "left ⌃", 62: "right ⌃",
        63: "fn",
    ]

    /// Which flag is set while a given modifier key is held.
    static let modifierFlags: [UInt16: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand,
        56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
        63: .maskSecondaryFn,
    ]

    static func isModifierKeyCode(_ code: UInt16) -> Bool {
        modifierNames[code] != nil
    }

    private static func symbols(for flags: CGEventFlags) -> String {
        // Apple's order: control, option, shift, command.
        var out = ""
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        return out
    }

    /// The same, one word per modifier and with fn first, the way Apple writes fn chords.
    private static func words(for flags: CGEventFlags) -> [String] {
        var out: [String] = []
        if flags.contains(.maskSecondaryFn) { out.append("fn") }
        if flags.contains(.maskControl) { out.append("⌃") }
        if flags.contains(.maskAlternate) { out.append("⌥") }
        if flags.contains(.maskShift) { out.append("⇧") }
        if flags.contains(.maskCommand) { out.append("⌘") }
        return out
    }

    /// Enough of the US layout to name what someone is likely to pick. Anything missing
    /// falls back to its code rather than being refused — an unnamed key still works.
    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8",
        29: "0",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        (0x7A): "F1", (0x78): "F2", (0x63): "F3", (0x76): "F4", (0x60): "F5", (0x61): "F6",
        (0x62): "F7", (0x64): "F8", (0x65): "F9", (0x6D): "F10", (0x67): "F11",
        (0x6F): "F12",
        (0x7B): "←", (0x7C): "→", (0x7D): "↓", (0x7E): "↑",
    ]
}

/// Captures the next key the user presses.
///
/// A **local** monitor, not a global tap: the user has just clicked a button in our window,
/// so our app is active and a local monitor sees the event. It also needs no Accessibility
/// permission, which a global tap would — asking for one to configure the other would be a
/// poor trade.
///
/// Returning nil from the handler swallows the event, so recording ⌘Q does not quit.
///
/// Modifiers are taken when the first of them comes back **up**, not when it goes down:
/// fn followed by ⇧ has to be recordable as one chord, and on the way down there is no
/// telling whether another key is about to join.
@MainActor
final class HotkeyRecorder {

    private var monitor: Any?

    /// Modifier keys currently down, in the order they were pressed. The last one is the
    /// key; the rest are its companions.
    private var heldModifiers: [UInt16] = []

    var isRecording: Bool { monitor != nil }

    /// Called with the captured combination, or nil if the user pressed Escape.
    var onFinish: ((Hotkey?) -> Void)?

    func start() {
        stop()
        heldModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            // Escape cancels rather than being recorded — otherwise the only way out of
            // recording mode would be to bind Escape to something.
            if event.keyCode == 53 {
                finish(nil)
                return nil
            }
            let flags = Self.eventFlags(event.modifierFlags)
            let hotkey = Hotkey(
                keyCode: event.keyCode,
                modifierRawValue: flags.rawValue,
                isModifierOnly: false
            )
            // A bare letter would fire while typing. Keep listening rather than accepting
            // it, so the user can add a modifier and try again.
            guard hotkey.isUsable else { return nil }
            finish(hotkey)
            return nil

        case .flagsChanged:
            guard let flag = Hotkey.modifierFlags[event.keyCode] else { return nil }
            // flagsChanged fires for press *and* release; which one has to be inferred
            // from whether the flag is now set.
            if Self.eventFlags(event.modifierFlags).contains(flag) {
                heldModifiers.removeAll { $0 == event.keyCode }
                heldModifiers.append(event.keyCode)
                return nil
            }
            // Released. Whatever was down at that moment is the answer.
            guard let key = heldModifiers.last else { return nil }
            let companions = heldModifiers.dropLast()
                .compactMap { Hotkey.modifierFlags[$0] }
                .reduce(CGEventFlags()) { $0.union($1) }
            finish(
                Hotkey(keyCode: key, modifierRawValue: companions.rawValue, isModifierOnly: true)
            )
            return nil

        default:
            return event
        }
    }

    private func finish(_ hotkey: Hotkey?) {
        stop()
        onFinish?(hotkey)
    }

    /// `NSEvent.ModifierFlags` and `CGEventFlags` do not share bit positions, so this
    /// cannot be a cast.
    private static func eventFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        if flags.contains(.function) { out.insert(.maskSecondaryFn) }
        return out
    }
}
