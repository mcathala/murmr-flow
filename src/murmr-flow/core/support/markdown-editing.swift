import Foundation

/// Turning a line into a heading, a bullet or a task, and back.
///
/// Pure string work, apart from the view entirely, because this is the part that is easy
/// to get subtly wrong — a prefix stripped one character short, a selection left pointing
/// into the middle of markup — and the only way to know it is right is to test it.
///
/// Everything is `NSString`-based on purpose. The text view speaks `NSRange`, and
/// converting to `String.Index` and back at every step is where off-by-one bugs live.
enum MarkdownEdit {

    /// What a line already is, which is what the toolbar shows as chosen.
    enum Block: Equatable, Hashable, CaseIterable, Identifiable {
        case body
        case heading(Int)
        case bullet
        case task

        static var allCases: [Block] { [.body, .heading(1), .heading(2), .heading(3), .bullet, .task] }

        var id: String {
            switch self {
            case .body: "body"
            case .heading(let level): "h\(level)"
            case .bullet: "bullet"
            case .task: "task"
            }
        }

        /// The Markdown a line of this kind opens with.
        var prefix: String {
            switch self {
            case .body: ""
            case .heading(let level): String(repeating: "#", count: level) + " "
            case .bullet: "- "
            case .task: "- [ ] "
            }
        }

        var title: String {
            switch self {
            case .body: "Normal text"
            case .heading(let level): "Heading \(level)"
            case .bullet: "Bullet"
            case .task: "Task"
            }
        }
    }

    /// The whole of every line the selection touches, so a change applies to lines rather
    /// than to the few characters that happen to be highlighted.
    static func lineRange(in text: NSString, covering range: NSRange) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = NSRange(
            location: min(range.location, text.length - 1),
            length: min(range.length, max(text.length - range.location, 0))
        )
        return text.lineRange(for: clamped)
    }

    /// What the first line the selection touches already is.
    static func block(of text: NSString, at range: NSRange) -> Block {
        let lines = text.substring(with: lineRange(in: text, covering: range))
        guard let first = lines.components(separatedBy: "\n").first else { return .body }
        return block(ofLine: first)
    }

    static func block(ofLine line: String) -> Block {
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") { return .task }
        if line.hasPrefix("- ") { return .bullet }
        let hashes = line.prefix { $0 == "#" }.count
        if hashes > 0, line.dropFirst(hashes).hasPrefix(" ") {
            return .heading(min(hashes, 3))
        }
        return .body
    }

    /// Strips whatever a line opens with, so a new prefix replaces rather than stacks.
    static func stripPrefix(_ line: String) -> String {
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") { return String(line.dropFirst(6)) }
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        let hashes = line.prefix { $0 == "#" }.count
        if hashes > 0, line.dropFirst(hashes).hasPrefix(" ") {
            return String(line.dropFirst(hashes + 1))
        }
        return line
    }

    /// Makes every line the selection touches the given kind, or plain text when it
    /// already is that kind — so the same control both applies and removes.
    static func setBlock(
        _ block: Block, in text: String, selection: NSRange
    ) -> (text: String, selection: NSRange) {
        let string = text as NSString
        let lines = lineRange(in: string, covering: selection)
        guard lines.length > 0 || string.length == 0 else { return (text, selection) }

        let slice = string.substring(with: lines)
        let endsWithNewline = slice.hasSuffix("\n")
        let pieces = (endsWithNewline ? String(slice.dropLast()) : slice)
            .components(separatedBy: "\n")

        let alreadyIs = pieces.allSatisfy { self.block(ofLine: $0) == block }
        let target: Block = alreadyIs ? .body : block

        let rewritten = pieces
            .map { target.prefix + stripPrefix($0) }
            .joined(separator: "\n") + (endsWithNewline ? "\n" : "")

        let updated = string.replacingCharacters(in: lines, with: rewritten)
        // The caret lands at the end of the changed block, which is where somebody who
        // just made a heading wants to carry on typing.
        let end = lines.location + (rewritten as NSString).length - (endsWithNewline ? 1 : 0)
        return (updated, NSRange(location: end, length: 0))
    }

    /// Whether the selection is already wrapped in a marker, so the button showing it can
    /// be lit the way the bullet and task buttons are.
    ///
    /// Bold wins over italic when both could match: `**word**` is bold, and reading the
    /// outer asterisk of a bold pair as an italic one would light both buttons for text
    /// that is only ever one of them.
    static func isWrapped(_ marker: String, in text: String, selection: NSRange) -> Bool {
        let string = text as NSString
        guard selection.location + selection.length <= string.length else { return false }
        if marker == "*", isWrapped("**", in: text, selection: selection) { return false }

        let selected = string.substring(with: selection)
        if selected.hasPrefix(marker), selected.hasSuffix(marker),
           selected.count >= marker.count * 2 {
            return true
        }
        let markerLength = (marker as NSString).length
        let outer = NSRange(
            location: selection.location - markerLength,
            length: selection.length + markerLength * 2
        )
        guard outer.location >= 0, outer.location + outer.length <= string.length else {
            return false
        }
        return string.substring(with: outer) == marker + selected + marker
    }

    /// Wraps the selection in a marker, or unwraps it when it is already wrapped. With
    /// nothing selected it leaves the pair behind with the caret between them, which is
    /// how every editor behaves and is what makes the button usable before typing.
    static func wrap(
        _ marker: String, in text: String, selection: NSRange
    ) -> (text: String, selection: NSRange) {
        let string = text as NSString
        let markerLength = (marker as NSString).length
        guard selection.location + selection.length <= string.length else { return (text, selection) }

        let selected = string.substring(with: selection)
        if selected.hasPrefix(marker), selected.hasSuffix(marker),
           selected.count >= markerLength * 2 {
            let bare = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return (
                string.replacingCharacters(in: selection, with: bare),
                NSRange(location: selection.location, length: (bare as NSString).length)
            )
        }

        // Already wrapped from just outside the selection: "**word**" with "word" picked.
        let outer = NSRange(
            location: selection.location - markerLength,
            length: selection.length + markerLength * 2
        )
        if outer.location >= 0, outer.location + outer.length <= string.length,
           string.substring(with: outer) == marker + selected + marker {
            return (
                string.replacingCharacters(in: outer, with: selected),
                NSRange(location: outer.location, length: selection.length)
            )
        }

        let wrapped = marker + selected + marker
        return (
            string.replacingCharacters(in: selection, with: wrapped),
            selection.length == 0
                ? NSRange(location: selection.location + markerLength, length: 0)
                : NSRange(location: selection.location + markerLength, length: selection.length)
        )
    }
}
