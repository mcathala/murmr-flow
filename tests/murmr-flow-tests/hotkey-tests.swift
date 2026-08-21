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

    @Test("the default is right option")
    func defaultBind() {
        #expect(Hotkey.default.displayName == "right ⌥")
        #expect(Hotkey.default.isModifierOnly)
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
