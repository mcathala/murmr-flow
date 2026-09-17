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

    // MARK: - Between the file and the page

    /// Weight, slant and a line under it — any of them, in any combination.
    ///
    /// A set rather than a choice, because a word can be all three and the first version
    /// made them exclusive: turning on italic quietly took the bold off.
    struct EmphasisStyle: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let bold = EmphasisStyle(rawValue: 1 << 0)
        static let italic = EmphasisStyle(rawValue: 1 << 1)
        static let underline = EmphasisStyle(rawValue: 1 << 2)
    }

    /// A stretch of words carrying one combination of styles, with no markers in it.
    struct EmphasisRun: Equatable, Sendable {
        let range: NSRange
        let style: EmphasisStyle
    }

    /// How a style is written into the file.
    ///
    /// Asterisks for weight and slant, as Markdown has always had them. Underline has no
    /// Markdown at all, so it is `<u>`, which is what Obsidian and every other editor that
    /// offers one settles on — HTML is the escape hatch Markdown was designed with, and a
    /// tag another reader will render is better than an invention it would show as text.
    private static func wrapping(_ style: EmphasisStyle, around words: String) -> String {
        var out = words
        let stars = switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): "***"
        case (true, false): "**"
        case (false, true): "*"
        case (false, false): ""
        }
        if !stars.isEmpty { out = stars + out + stars }
        if style.contains(.underline) { out = "<u>" + out + "</u>" }
        return out
    }

    /// Takes the markers out, and says which words carry what.
    ///
    /// **This is the whole design in one function.** The page never contains a marker, so
    /// there is nothing to hide, nothing to step the caret over and nothing to half delete
    /// — the three faults that come with drawing markers and pretending they are not
    /// there. The file keeps them; the page keeps the look.
    ///
    /// Done as a style *per character* and then gathered back into runs, which is what
    /// makes overlap a non-question: a word that is bold and underlined is not two runs
    /// fighting, it is one character set with two bits in it.
    /// Nesting is the one shape this does not read: `**a *b* c**` gives back an italic
    /// `b` with the outer asterisks left standing as text. They survive a round trip
    /// untouched, so nothing is lost — it reads worse than it should, and everything the
    /// app itself writes is flat.
    static func stripEmphasis(_ markdown: String) -> (text: String, runs: [EmphasisRun]) {
        var text = markdown as NSString
        var styles = [EmphasisStyle](repeating: [], count: text.length)

        /// Removes the marker ranges, carrying the per-character styles across with them.
        func remove(_ cuts: [NSRange], applying style: EmphasisStyle, to inner: [NSRange]) {
            for range in inner {
                for index in range.location..<(range.location + range.length)
                where index < styles.count {
                    styles[index].insert(style)
                }
            }
            // Copied a stretch at a time, never a unit at a time. A character outside the
            // basic plane — an emoji — is two UTF-16 units, and asking for one of them on
            // its own hands back a replacement glyph: the note's own words would come
            // back broken, which is far worse than losing a bold.
            var out = ""
            var kept: [EmphasisStyle] = []
            var index = 0
            for cut in cuts.sorted(by: { $0.location < $1.location }) {
                if cut.location > index {
                    let segment = NSRange(location: index, length: cut.location - index)
                    out += text.substring(with: segment)
                    kept.append(contentsOf: styles[segment.location..<(segment.location + segment.length)])
                }
                index = max(index, cut.location + cut.length)
            }
            if index < text.length {
                let tail = NSRange(location: index, length: text.length - index)
                out += text.substring(with: tail)
                kept.append(contentsOf: styles[tail.location..<(tail.location + tail.length)])
            }
            text = out as NSString
            styles = kept
        }

        // Underline first, so the asterisks inside a `<u>` are found on the second pass
        // the same way as any others.
        if let regex = try? NSRegularExpression(pattern: #"<u>((?:[^<\n]|<(?!/u>))+?)</u>"#) {
            let matches = regex.matches(
                in: text as String, range: NSRange(location: 0, length: text.length)
            )
            remove(
                matches.flatMap { [
                    NSRange(location: $0.range.location, length: 3),
                    NSRange(location: $0.range.location + $0.range.length - 4, length: 4),
                ] },
                applying: .underline,
                to: matches.map { $0.range(at: 1) }
            )
        }

        for (pattern, style, markerLength) in [
            (#"\*\*\*(?![\s*])([^*\n]+?)(?<![\s*])\*\*\*"#, EmphasisStyle([.bold, .italic]), 3),
            (#"\*\*(?![\s*])([^*\n]+?)(?<![\s*])\*\*"#, EmphasisStyle.bold, 2),
            (#"(?<!\*)\*(?![\s*])([^*\n]+?)(?<![\s*])\*(?!\*)"#, EmphasisStyle.italic, 1),
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(
                in: text as String, range: NSRange(location: 0, length: text.length)
            )
            guard !matches.isEmpty else { continue }
            remove(
                matches.flatMap { [
                    NSRange(location: $0.range.location, length: markerLength),
                    NSRange(
                        location: $0.range.location + $0.range.length - markerLength,
                        length: markerLength
                    ),
                ] },
                applying: style,
                to: matches.map { $0.range(at: 1) }
            )
        }

        return (text as String, runs(from: styles))
    }

    /// Gathers a style per character back into the longest runs that share one.
    static func runs(from styles: [EmphasisStyle]) -> [EmphasisRun] {
        var out: [EmphasisRun] = []
        var index = 0
        while index < styles.count {
            let style = styles[index]
            var end = index
            while end < styles.count, styles[end] == style { end += 1 }
            if !style.isEmpty {
                out.append(
                    EmphasisRun(range: NSRange(location: index, length: end - index), style: style)
                )
            }
            index = end
        }
        return out
    }

    /// Puts the markers back, for the file.
    ///
    /// Applied from the end backwards, so an insertion never moves the range of the run
    /// after it — and only after every run has been made into something the reader will
    /// recognise on the way back in. See `writable`.
    static func markdown(text: String, runs: [EmphasisRun]) -> String {
        var out = text as NSString
        for run in writable(runs, in: out).sorted(by: { $0.range.location > $1.range.location }) {
            let words = out.substring(with: run.range)
            out = out.replacingCharacters(
                in: run.range, with: wrapping(run.style, around: words)
            ) as NSString
        }
        return out as String
    }

    /// Cuts a run down to something the file can actually say.
    ///
    /// A page lets you select anything and press Bold; Markdown does not let you write
    /// most of it. Two rules, and both were losing formatting silently until a run written
    /// one launch came back plain the next:
    ///
    /// **A run stops at a line break.** `**a\nb**` is not emphasis to any reader, so a
    /// style dragged across two lines becomes one run per line.
    ///
    /// **A marker has to touch a word.** `**word **` does not parse, so the spaces at
    /// either end are left outside — and a run that is nothing but spaces is not written
    /// at all.
    static func writable(_ runs: [EmphasisRun], in text: NSString) -> [EmphasisRun] {
        var out: [EmphasisRun] = []
        for run in runs {
            guard !run.style.isEmpty, run.range.length > 0,
                  run.range.location >= 0,
                  run.range.location + run.range.length <= text.length
            else { continue }

            text.enumerateSubstrings(in: run.range, options: [.byLines]) { _, line, _, _ in
                var start = line.location
                var end = line.location + line.length
                while start < end, text.substring(with: NSRange(location: start, length: 1))
                    .trimmingCharacters(in: .whitespaces).isEmpty {
                    start += 1
                }
                while end > start, text.substring(with: NSRange(location: end - 1, length: 1))
                    .trimmingCharacters(in: .whitespaces).isEmpty {
                    end -= 1
                }
                guard end > start else { return }
                out.append(
                    EmphasisRun(
                        range: NSRange(location: start, length: end - start), style: run.style
                    )
                )
            }
        }
        return out
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
