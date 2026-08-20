import AppKit
import ApplicationServices
import CoreGraphics

/// Types text into whatever app is frontmost.
///
/// Uses clipboard-plus-⌘V rather than synthesizing a keystroke per character. Character
/// synthesis is far slower for a paragraph of dictation and breaks on non-ASCII input;
/// paste is instant and universal.
///
/// The clipboard is snapshotted and restored, because silently destroying whatever the
/// user had copied is not acceptable collateral for a dictation tool.
@MainActor
enum TextInjector {

    enum InjectionError: LocalizedError {
        case accessibilityDenied
        case pasteboardRejected

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                "Text was copied to the clipboard instead — grant Accessibility "
                    + "permission to have it typed for you."
            case .pasteboardRejected:
                "The clipboard refused the text."
            }
        }
    }

    /// How long to wait before restoring the previous clipboard. The paste is handled
    /// asynchronously by the target app, so restoring immediately would race it.
    private static let restoreDelay: Duration = .milliseconds(320)

    private static let virtualKeyV: CGKeyCode = 0x09

    /// Bumped per injection so only the most recent one restores the clipboard.
    private static var generation = 0
    /// The user's real clipboard, held while one or more injections are in flight.
    private static var pendingSnapshot: PasteboardSnapshot?

    /// Puts `text` at the cursor. Throws `.accessibilityDenied` when it could only be
    /// copied — the text is on the clipboard either way, so nothing is ever lost.
    static func inject(_ text: String) throws {
        guard !text.isEmpty else { return }

        generation += 1
        let thisGeneration = generation

        // Reuse the in-flight snapshot rather than taking a new one. Two dictations
        // within the restore window would otherwise have the second snapshot capture the
        // first one's pasted text, and then faithfully restore that as "the user's
        // clipboard".
        let snapshot = pendingSnapshot ?? PasteboardSnapshot.capture()
        pendingSnapshot = snapshot

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore()
            pendingSnapshot = nil
            throw InjectionError.pasteboardRejected
        }

        // Without Accessibility, posted events are silently discarded — the user would
        // see nothing happen and no error. Check first and degrade explicitly.
        guard AXIsProcessTrusted() else {
            // Deliberately leave the text on the clipboard so the dictation survives —
            // losing the user's previous clipboard is the accepted cost of not losing
            // their words. Clear the pending snapshot so the next injection captures
            // fresh rather than restoring this stale one.
            pendingSnapshot = nil
            throw InjectionError.accessibilityDenied
        }

        postPaste()

        Task { @MainActor in
            try? await Task.sleep(for: restoreDelay)
            // A later injection has superseded this one; let that one restore.
            guard thisGeneration == generation else { return }
            snapshot.restore()
            pendingSnapshot = nil
        }
    }

    /// Copies without pasting — the fallback path, and useful on its own.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Key synthesis

    private static func postPaste() {
        // .privateState keeps our synthetic ⌘V out of the global modifier state, so a
        // physically-held modifier (the push-to-talk key) cannot contaminate it.
        let source = CGEventSource(stateID: .privateState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard preservation

    private struct PasteboardSnapshot {
        /// One dictionary per pasteboard item, type → data.
        let items: [[NSPasteboard.PasteboardType: Data]]

        static func capture() -> PasteboardSnapshot {
            let pasteboard = NSPasteboard.general
            let captured = (pasteboard.pasteboardItems ?? []).map { item in
                var contents: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    // Data has to be copied out now: the items are invalidated by
                    // clearContents(), so holding references would give us nothing.
                    if let data = item.data(forType: type) {
                        contents[type] = data
                    }
                }
                return contents
            }
            return PasteboardSnapshot(items: captured)
        }

        func restore() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard !items.isEmpty else { return }

            let restored = items.compactMap { contents -> NSPasteboardItem? in
                guard !contents.isEmpty else { return nil }
                let item = NSPasteboardItem()
                for (type, data) in contents {
                    item.setData(data, forType: type)
                }
                return item
            }
            guard !restored.isEmpty else { return }
            pasteboard.writeObjects(restored)
        }
    }
}
