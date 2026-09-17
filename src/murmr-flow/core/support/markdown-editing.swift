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

    // MARK: - Finding emphasis in the file

    /// A run of emphasis as the *file* writes it: where the markers are, and what they
    /// wrap. Only ever used on the way in, to take them out again.
    struct Emphasis: Equatable {
        /// `**` or `*`.
        let marker: String
        let opening: NSRange
        let closing: NSRange
        /// The words between them.
        let inner: NSRange

        var isBold: Bool { marker == "**" }
    }

    /// Every `**bold**` and `*italic*` in the text.
    ///
    /// Bold is matched first and its ranges are then off limits, so the outer asterisk of
    /// a bold pair is never read as the start of an italic one.
    ///
    /// A marker has to sit against a word: `4 * 3 * 2` is arithmetic, and an editor that
    /// silently italicised it would be worse than one that did nothing.
    static func emphasis(in text: NSString) -> [Emphasis] {
        var found: [Emphasis] = []
        var taken: [NSRange] = []

        func scan(_ pattern: String, marker: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let whole = NSRange(location: 0, length: text.length)
            for match in regex.matches(in: text as String, range: whole) {
                let inner = match.range(at: 1)
                guard inner.location != NSNotFound else { continue }
                let overlaps = taken.contains { NSIntersectionRange($0, match.range).length > 0 }
                guard !overlaps else { continue }
                let markerLength = (marker as NSString).length
                found.append(
                    Emphasis(
                        marker: marker,
                        opening: NSRange(location: match.range.location, length: markerLength),
                        closing: NSRange(
                            location: match.range.location + match.range.length - markerLength,
                            length: markerLength
                        ),
                        inner: inner
                    )
                )
                taken.append(match.range)
            }
        }

        // No newline inside a run: emphasis belongs to one line, and a stray marker two
        // paragraphs down must not reach back and swallow everything between.
        scan(#"\*\*(?![\s*])((?:[^*\n]|\*(?!\*))+?)(?<![\s*])\*\*"#, marker: "**")
        scan(#"(?<!\*)\*(?![\s*])([^*\n]+?)(?<![\s*])\*(?!\*)"#, marker: "*")
        return found.sorted { $0.opening.location < $1.opening.location }
    }

    // MARK: - Between the file and the page

    /// Emphasis as the page holds it: a stretch of words that is bold or italic, with no
    /// markers anywhere in the text.
    struct EmphasisRun: Equatable, Sendable {
        let range: NSRange
        let isBold: Bool
    }

    /// Takes the markers out, and says where the emphasis now is.
    ///
    /// **This is the whole design in one function.** The page never contains `**`, so
    /// there is nothing to hide, nothing to step the caret over, and nothing to half
    /// delete — the three faults that come with drawing markers and pretending they are
    /// not there. The file keeps them; the page keeps weight.
    static func stripEmphasis(_ markdown: String) -> (text: String, runs: [EmphasisRun]) {
        let source = markdown as NSString
        let spans = emphasis(in: source)
        guard !spans.isEmpty else { return (markdown, []) }

        var out = ""
        var runs: [EmphasisRun] = []
        var cursor = 0
        for span in spans {
            out += source.substring(with: NSRange(location: cursor, length: span.opening.location - cursor))
            let start = (out as NSString).length
            out += source.substring(with: span.inner)
            runs.append(
                EmphasisRun(
                    range: NSRange(location: start, length: (out as NSString).length - start),
                    isBold: span.isBold
                )
            )
            cursor = span.closing.location + span.closing.length
        }
        out += source.substring(from: cursor)
        return (out, runs)
    }

    /// Puts the markers back, for the file.
    ///
    /// Applied from the end backwards, so an insertion never moves the range of the run
    /// after it.
    static func markdown(text: String, runs: [EmphasisRun]) -> String {
        var out = text as NSString
        for run in runs.sorted(by: { $0.range.location > $1.range.location }) {
            guard run.range.location >= 0,
                  run.range.location + run.range.length <= out.length,
                  run.range.length > 0
            else { continue }
            let marker = run.isBold ? "**" : "*"
            let words = out.substring(with: run.range)
            out = out.replacingCharacters(in: run.range, with: marker + words + marker) as NSString
        }
        return out as String
    }

    /// The prefix changes that make every line the selection touches the given kind.
    ///
    /// Edits rather than a whole new string, so applying them leaves every other character
    /// — and every attribute riding on it — exactly where it was. Rebuilding the text
    /// wholesale would drop the emphasis the page is holding.
    ///
    /// Returned last line first, so applying them in order never invalidates the next.
    static func blockEdits(
        _ block: Block, in text: String, selection: NSRange
    ) -> (edits: [(range: NSRange, replacement: String)], selection: NSRange) {
        let string = text as NSString
        guard string.length > 0 else {
            return ([(NSRange(location: 0, length: 0), block.prefix)],
                    NSRange(location: (block.prefix as NSString).length, length: 0))
        }
        let lines = lineRange(in: string, covering: selection)

        var starts: [Int] = []
        string.enumerateSubstrings(in: lines, options: [.byLines]) { _, range, _, _ in
            starts.append(range.location)
        }
        if starts.isEmpty { starts = [lines.location] }

        let kinds = starts.map { start -> Block in
            let line = string.substring(with: string.lineRange(for: NSRange(location: start, length: 0)))
            return self.block(ofLine: line.hasSuffix("\n") ? String(line.dropLast()) : line)
        }
        let target: Block = kinds.allSatisfy { $0 == block } ? .body : block

        var edits: [(range: NSRange, replacement: String)] = []
        var delta = 0
        for (start, kind) in zip(starts, kinds) {
            let existing = (kind.prefix as NSString).length
            let replacement = target.prefix
            guard existing > 0 || !replacement.isEmpty else { continue }
            edits.append((NSRange(location: start, length: existing), replacement))
            delta += (replacement as NSString).length - existing
        }

        let caret = min(selection.location + delta, string.length + delta)
        return (edits.reversed(), NSRange(location: max(caret, 0), length: 0))
    }
}
