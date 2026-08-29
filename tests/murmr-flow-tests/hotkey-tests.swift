import CoreGraphics
import Foundation
import Testing

@testable import MurmrFlow

/// Recorded key binds, replacing an enum of three fixed triggers.
@Suite("Hotkeys")
struct HotkeyTests {

    @Test("a modifier on its own names the physical key")
    func modifierName() {
        // Left and right are different keys, and the difference matters: right option is a
        // good push-to-talk key precisely because the left one stays free for typing.
        #expect(Hotkey(keyCode: 61, modifierRawValue: 0, isModifierOnly: true)
            .displayName == "right ⌥")
        #expect(Hotkey(keyCode: 58, modifierRawValue: 0, isModifierOnly: true)
            .displayName == "left ⌥")
    }

    @Test("a combination reads in Apple's order")
    func combinationName() {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskControl]
        let hotkey = Hotkey(keyCode: 2, modifierRawValue: flags.rawValue, isModifierOnly: false)
        // Control, option, shift, command — the order they appear on a menu.
        #expect(hotkey.displayName == "⌃⇧⌘D")
    }

    @Test("a bare letter is not usable")
    func bareLetterRejected() {
        // It would fire every time you typed it, so it is rejected rather than merely
        // discouraged.
        let bare = Hotkey(keyCode: 2, modifierRawValue: 0, isModifierOnly: false)
        #expect(!bare.isUsable)

        let withCommand = Hotkey(
            keyCode: 2, modifierRawValue: CGEventFlags.maskCommand.rawValue,
            isModifierOnly: false
        )
        #expect(withCommand.isUsable)
    }

    @Test("a modifier on its own is always usable")
    func modifierUsable() {
        #expect(Hotkey(keyCode: 61, modifierRawValue: 0, isModifierOnly: true).isUsable)
    }

    @Test("it survives being stored and read back")
    func codableRoundTrip() throws {
        let original = Hotkey(
            keyCode: 2,
            modifierRawValue: CGEventFlags([.maskCommand, .maskShift]).rawValue,
            isModifierOnly: false
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Hotkey.self, from: data)

        #expect(restored == original)
        #expect(restored.displayName == original.displayName)
    }

    @Test("the meeting default is fn with left shift, and not the dictation key")
    func meetingDefault() {
        #expect(Hotkey.meetingDefault.displayName == "fn + left ⇧")
        #expect(Hotkey.meetingDefault.isModifierOnly)
        #expect(Hotkey.meetingDefault != Hotkey.default)
    }

    @Test("the default is fn")
    func defaultBind() {
        #expect(Hotkey.default.displayName == "fn")
        #expect(Hotkey.default.isModifierOnly)
    }

    @Test("a modifier chord survives being stored and read back")
    func chordRoundTrip() throws {
        let data = try JSONEncoder().encode(Hotkey.meetingDefault)
        let restored = try JSONDecoder().decode(Hotkey.self, from: data)
        #expect(restored == Hotkey.meetingDefault)
        #expect(restored.displayName == "fn + left ⇧")
    }

    // MARK: - What a flagsChanged event means

    private let fn: UInt16 = 63
    private let leftShift: UInt16 = 56
    private let rightShift: UInt16 = 60

    /// The chord is down once both keys are, whichever went first.
    @Test("a chord is held in either order and released when either key comes up")
    func chordOrder() {
        let chord = Hotkey.meetingDefault
        let both: CGEventFlags = [.maskSecondaryFn, .maskShift]

        // fn, then ⇧.
        #expect(chord.modifierState(keyCode: fn, flags: .maskSecondaryFn) == false)
        #expect(chord.modifierState(keyCode: leftShift, flags: both) == true)
        // ⇧, then fn.
        #expect(chord.modifierState(keyCode: leftShift, flags: .maskShift) == false)
        #expect(chord.modifierState(keyCode: fn, flags: both) == true)
        // Letting go of either ends it.
        #expect(chord.modifierState(keyCode: fn, flags: .maskShift) == false)
        #expect(chord.modifierState(keyCode: leftShift, flags: .maskSecondaryFn) == false)
    }

    /// Left and right are told apart for the key that completes the chord.
    @Test("the other shift is not the chord")
    func chordSide() {
        let chord = Hotkey.meetingDefault
        let both: CGEventFlags = [.maskSecondaryFn, .maskShift]
        #expect(chord.modifierState(keyCode: rightShift, flags: both) == nil)
    }

    /// fn alone must not fire on the first half of fn + ⇧, and must not care about keys
    /// that are not part of it.
    @Test("a single modifier needs exactly its own flag")
    func singleModifierExact() {
        let key = Hotkey.default
        #expect(key.modifierState(keyCode: fn, flags: .maskSecondaryFn) == true)
        #expect(key.modifierState(keyCode: fn, flags: [.maskSecondaryFn, .maskShift]) == false)
        #expect(key.modifierState(keyCode: fn, flags: []) == false)
        // Other bits an event carries — non-coalesced, caps lock — are not modifiers.
        #expect(key.modifierState(keyCode: fn, flags: [.maskSecondaryFn, .maskNonCoalesced]) == true)
        // Some other key's flagsChanged is nothing to do with it.
        #expect(key.modifierState(keyCode: leftShift, flags: .maskShift) == nil)
        #expect(key.modifierState(keyCode: leftShift, flags: [.maskSecondaryFn, .maskShift]) == nil)
    }

    // MARK: - fn and the system

    @Test("fn is recognised wherever it appears in a key")
    func usesFn() {
        #expect(Hotkey.default.usesFn)
        #expect(Hotkey.meetingDefault.usesFn)
        #expect(!Hotkey(keyCode: 61, modifierRawValue: 0, isModifierOnly: true).usesFn)
        #expect(Hotkey(
            keyCode: 2, modifierRawValue: CGEventFlags.maskSecondaryFn.rawValue,
            isModifierOnly: false
        ).usesFn)
    }

    /// A stand-in for the system's setting.
    private final class FakeSystem: @unchecked Sendable {
        var usage: Int32
        init(_ usage: Int32) { self.usage = usage }
        var backend: FnKeyOwner.Backend {
            FnKeyOwner.Backend(get: { self.usage }, set: { self.usage = $0 })
        }
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "murmr-fn-\(UUID())")!
    }

    @Test("owning fn parks the system action and letting go restores it")
    func claimAndRelease() {
        let system = FakeSystem(1)  // change input source
        let defaults = freshDefaults()

        FnKeyOwner.update(for: [Hotkey.default, nil], defaults: defaults, backend: system.backend)
        #expect(system.usage == FnKeyOwner.doNothing)

        let rightOption = Hotkey(keyCode: 61, modifierRawValue: 0, isModifierOnly: true)
        FnKeyOwner.update(for: [rightOption, nil], defaults: defaults, backend: system.backend)
        #expect(system.usage == 1)
    }

    @Test("a setting already off is left alone, and not 'restored' to anything")
    func alreadyOff() {
        let system = FakeSystem(0)
        let defaults = freshDefaults()
        FnKeyOwner.update(for: [Hotkey.default], defaults: defaults, backend: system.backend)
        FnKeyOwner.release(defaults: defaults, backend: system.backend)
        #expect(system.usage == 0)
    }

    /// The user picking a new action while we own the key is their decision, not a
    /// glitch to correct.
    @Test("the user's own change wins over the remembered value")
    func userWins() {
        let system = FakeSystem(2)  // emoji
        let defaults = freshDefaults()
        FnKeyOwner.claim(defaults: defaults, backend: system.backend)
        #expect(system.usage == 0)

        system.usage = 3  // they chose dictation in System Settings
        FnKeyOwner.claim(defaults: defaults, backend: system.backend)   // next launch
        FnKeyOwner.release(defaults: defaults, backend: system.backend)
        #expect(system.usage == 3)
    }

    /// A crash leaves the marker behind; the next launch must not mistake our own
    /// "Do Nothing" for the user's preference.
    @Test("a marker from a crashed run is picked up, not overwritten")
    func crashRecovery() {
        let system = FakeSystem(1)
        let defaults = freshDefaults()
        FnKeyOwner.claim(defaults: defaults, backend: system.backend)
        // Process dies here. New launch, same defaults, system still at 0:
        FnKeyOwner.claim(defaults: defaults, backend: system.backend)
        FnKeyOwner.release(defaults: defaults, backend: system.backend)
        #expect(system.usage == 1)
    }

    @Test("without the system call nothing is touched")
    func noBackend() {
        let defaults = freshDefaults()
        FnKeyOwner.update(for: [Hotkey.default], defaults: defaults, backend: nil)
        #expect(defaults.object(forKey: "fnKey.originalUsage") == nil)
    }

    @Test("a key with modifiers has no modifier state")
    func combinationHasNoModifierState() {
        let combo = Hotkey(
            keyCode: 2, modifierRawValue: CGEventFlags.maskCommand.rawValue, isModifierOnly: false
        )
        #expect(combo.modifierState(keyCode: 55, flags: .maskCommand) == nil)
    }

    @Test("modifier key codes are recognised as modifiers")
    func modifierDetection() {
        #expect(Hotkey.isModifierKeyCode(61))   // right ⌥
        #expect(Hotkey.isModifierKeyCode(63))   // fn
        #expect(!Hotkey.isModifierKeyCode(2))   // D
    }

    @Test("an unnamed key still works, named by its code")
    func unknownKey() {
        // Refusing a key we have no label for would be worse than showing its number.
        let odd = Hotkey(
            keyCode: 200, modifierRawValue: CGEventFlags.maskCommand.rawValue,
            isModifierOnly: false
        )
        #expect(odd.isUsable)
        #expect(odd.displayName.contains("200"))
    }
}
