import Foundation
import Testing

@testable import MurmrFlow

/// Puts the shipped prompts to the test against the real model.
///
/// Not a unit test: it costs money and a few minutes, so it runs only when asked —
///
///     MURMR_PROMPT_EVAL=1 swift test --filter PromptEval
///     MURMR_PROMPT_EVAL=default,structure MURMR_EVAL_RUNS=5 swift test --filter PromptEval
///     MURMR_PROMPT_EVAL=1 MURMR_EVAL_PROVIDER=cerebras swift test --filter PromptEval
///
/// The provider is any catalogue entry whose key is saved in Settings; the model defaults
/// to that provider's, `MURMR_EVAL_MODEL` overrides it. Groq's free tier runs out of
/// tokens for the day partway through, so the same gpt-oss-120b on Cerebras is the
/// usual choice for a full run.
///
/// Every fixture is a raw transcript the way the speech model hands it over — lowercase,
/// unpunctuated, with the fillers in — and a handful of things the clean text must and
/// must not contain. Each is sent through `PromptLibrary.render` exactly as the app does,
/// several times. A second `Variant` can be added to a target to measure a rewording
/// beside the shipped one — a compact third-length version was, and lost whole rules
/// rather than polish, which is why only the full wording ships.
/// The report per prompt lands in `build/prompt-eval/`, with the checks scored, the
/// prompt-token cost and the latency of each variant, and every output in full, so the
/// question the numbers cannot answer — does it *read* well — can be answered by reading.
@Suite("Prompt eval", .serialized)
struct PromptEval {

    // MARK: - Fixtures

    struct Case: Sendable {
        enum Extra: Sendable {
            /// Every non-empty line is a bullet ("- ", "1. ") or a lead-in ending with ":".
            case allLinesStructured
            case bulletLines(min: Int)
            case exactBulletLines(Int)
            case leadIns(min: Int)
            case noNumbering
            /// Lines opening with `###`, which is how the note's topics are marked.
            case headings(min: Int)
            case startsUppercase
            /// The output is the input, character for character.
            case unchanged
        }

        let name: String
        let raw: String
        var keep: [String] = []
        var drop: [String] = []
        /// Phrases that must appear exactly once — the restatement checks.
        var once: [String] = []
        var extra: [Extra] = []
        /// Markdown is a fault in a dictation, which is typed into someone's document,
        /// and the point of a note, which is a file you open in an editor.
        var allowsMarkdown = false
    }

    /// One person talking, as Default and Formal both receive it.
    static let dictation: [Case] = [
        Case(
            name: "fillers, and a 'like' that is a verb",
            raw: "um so i like this plan a lot but uh the client wants to see the the numbers first you know",
            keep: ["like this plan", "numbers first"],
            drop: ["um", "uh", "the the", "you know"],
            extra: [.startsUppercase]
        ),
        Case(
            name: "mid-sentence correction",
            raw: "can we book the call for tuesday no wait wednesday at three pm",
            keep: ["wednesday", "3"],
            drop: ["tuesday", "no wait"]
        ),
        Case(
            name: "scratch that",
            raw: "tell them we'll ship in june scratch that tell them we'll ship in july",
            keep: ["july"],
            drop: ["june", "scratch that"]
        ),
        Case(
            name: "trigger words that are content",
            raw: "no problem i can send it tonight actually good idea let's do that",
            keep: ["no problem", "actually good"]
        ),
        Case(
            name: "spelled name and acronym",
            raw: "the company is called S N O W F L A K E and their main K P I is churn",
            keep: ["snowflake", "kpi", "churn"],
            drop: ["s n o w", "k p i"]
        ),
        Case(
            name: "naming conventions",
            raw: "the field is called snake case user id and the other one camel case created at",
            keep: ["user_id", "createdat"],
            drop: ["snake case", "camel case"]
        ),
        Case(
            name: "numbers, percent, time",
            raw: "we grew fifty percent last quarter we have about two hundred customers and the meeting is at ten a.m.",
            keep: ["50%", "200", "10"],
            drop: ["fifty percent", "two hundred"]
        ),
        Case(
            name: "spoken punctuation",
            raw: "hi anna comma thanks for the call new paragraph i'll send the deck tomorrow period",
            keep: ["anna,", "deck tomorrow."],
            drop: [" comma", "new paragraph", " period"]
        ),
        Case(
            name: "email and url said aloud",
            raw: "send it to anna at example dot com and have a look at example dot com slash pricing",
            keep: ["anna@example.com", "example.com/pricing"],
            drop: ["dot com"]
        ),
        Case(
            name: "french with a correction",
            raw: "euh donc on va décaler la réunion à jeudi euh non vendredi matin",
            keep: ["réunion", "vendredi"],
            drop: ["jeudi", "euh"]
        ),
        Case(
            name: "trailing restatement",
            raw: "i'm at the office now and i'll start on the report so yeah i'm at the office right now",
            keep: ["report"],
            drop: ["so yeah"],
            once: ["at the office"]
        ),
        Case(
            name: "a question is content",
            raw: "what's the capital of australia i should ask marc",
            keep: ["capital of australia", "marc"],
            drop: ["canberra"]
        ),
        Case(
            name: "already clean",
            raw: "Please review the attached draft and send me your comments by Friday.",
            extra: [.unchanged]
        ),
        Case(
            name: "fragments stay fragments",
            raw: "quick note to self um buy milk call mom",
            keep: ["buy milk", "call mom"],
            drop: ["um"]
        ),
        Case(
            name: "vague stays vague",
            raw: "so marie is involved in the migration and we might ship in november",
            keep: ["involved", "might"],
            drop: ["leads", "will ship"]
        ),
    ]

    /// Formal adds one: register.
    static let formalOnly: [Case] = [
        Case(
            name: "register lifted, contractions out",
            raw: "hey so i can't make it tomorrow gonna be late basically the thing is that we need to push the demo",
            keep: ["cannot", "push the demo"],
            drop: ["can't", "gonna", "basically", "the thing is that"]
        ),
    ]

    static let structure: [Case] = [
        Case(
            name: "chronology becomes a numbered list",
            raw: "so this morning i did the standup then i reviewed anna's pull request after that i had the call with the client and now i'm writing the summary",
            keep: ["1.", "2.", "3.", "4.", "standup", "pull request", "client", "summary"],
            extra: [.allLinesStructured]
        ),
        Case(
            name: "a set becomes dashes",
            raw: "for the database we could use postgres mysql or sqlite",
            keep: ["postgres", "mysql", "sqlite"],
            extra: [.allLinesStructured, .bulletLines(min: 3), .noNumbering]
        ),
        Case(
            name: "two topics, two sections",
            raw: "two things um first the hiring we have three candidates for the design role and i like the second one she's based in lyon second the budget we're at eighty percent already and it's only september",
            keep: ["hiring", "budget", "80%", "lyon", "september"],
            drop: ["um"],
            extra: [.allLinesStructured, .leadIns(min: 2)]
        ),
        Case(
            name: "vague stays vague",
            raw: "marie is involved in the migration project and we might ship in november",
            keep: ["involved", "might"],
            drop: ["leads", "will ship"],
            extra: [.allLinesStructured]
        ),
        Case(
            name: "correction inside a fact",
            raw: "the deadline is the fifteenth no the twentieth and the owner is tom",
            keep: ["20", "tom"],
            drop: ["15", "fifteenth"],
            extra: [.allLinesStructured]
        ),
        Case(
            name: "one breath, three lines",
            raw: "she joined last year she handles pricing she's based in lyon",
            keep: ["joined last year", "pricing", "lyon"],
            extra: [.allLinesStructured, .bulletLines(min: 3)]
        ),
        Case(
            name: "a clause that cannot stand alone stays attached",
            raw: "the meeting ran long which was annoying",
            keep: ["ran long", "annoying"],
            extra: [.allLinesStructured, .exactBulletLines(1)]
        ),
        Case(
            name: "end-markers and a restatement",
            raw: "okay notes from the call the client wants the export feature by q1 they also asked about pricing for the team plan that's it so yeah export by q1",
            keep: ["export", "q1", "team plan"],
            drop: ["so yeah", "that's it"],
            once: ["q1"],
            extra: [.allLinesStructured]
        ),
        Case(
            name: "questions stay questions",
            raw: "open questions do we need SOC two before the enterprise deal and who owns the security questionnaire",
            keep: ["soc", "?", "security questionnaire"],
            extra: [.allLinesStructured]
        ),
        Case(
            name: "french priorities",
            raw: "alors les priorités de la semaine euh finir le dashboard relancer paul pour le contrat et préparer la démo de jeudi",
            keep: ["priorités", "dashboard", "paul", "démo"],
            drop: ["euh"],
            extra: [.allLinesStructured, .bulletLines(min: 3)]
        ),
    ]

    /// A whole conversation, the way `writeNote` hands one over: one line per turn,
    /// speaker first. Invented rather than taken from a real meeting — a fixture lives in
    /// the repository for good, and somebody's actual call does not belong there.
    static let summary: [Case] = [
        Case(
            name: "a walkthrough, with figures and one thing taken on",
            raw: "You: ok so can you hear me right um i wanted to walk through how the deploy works so i can write it up after\nThem: yeah sure so uh there's two environments there's staging and there's production and everything goes through staging first\nThem: a build goes out to staging automatically on every merge and then someone has to press the button for production\nYou: and how long does that usually take\nThem: staging is about four minutes production is closer to twelve because it does the database migration as well\nThem: the rule we have is you never deploy on a friday after 4pm unless it's a hotfix and a hotfix needs two approvals not one\nYou: two approvals ok\nThem: yeah and if the error rate goes above zero point five percent in the first ten minutes it rolls back on its own\nYou: right that's the bit i didn't know\nThem: i'll send you the runbook link this afternoon so you've got the exact steps\nYou: perfect thanks",
            keep: [
                "staging", "production", "four minutes", "twelve",
                "two approvals", "0.5%", "ten minutes", "runbook",
            ],
            drop: ["can you hear me", "perfect thanks"],
            extra: [.headings(min: 2), .bulletLines(min: 4)],
            allowsMarkdown: true
        ),
        Case(
            name: "nothing was taken on, so there are no next steps",
            raw: "You: um so i was reading about the new pricing page and i think the three tier layout reads better than the four we had\nThem: yeah i saw that too although the middle one is doing most of the work at the moment about sixty percent of signups\nYou: right so maybe the middle one just needs to be the one that's highlighted\nThem: maybe i don't know we'd want to look at it properly",
            keep: ["60%", "middle"],
            // The section is only written when somebody agreed to do something, and
            // nobody did — the hardest instruction in the prompt to keep.
            drop: ["Next steps"],
            extra: [.headings(min: 1)],
            allowsMarkdown: true
        ),
    ]

    struct Variant: Sendable {
        let name: String
        let template: String
    }

    struct Target: Sendable {
        let key: String
        let name: String
        let variants: [Variant]
        let cases: [Case]
    }

    static var targets: [Target] {
        return [
            Target(
                key: "default", name: "Default",
                variants: [
                    Variant(name: "Full", template: ShippedPrompts.standard),
                ],
                cases: dictation
            ),
            Target(
                key: "formal", name: "Formal",
                variants: [
                    Variant(name: "Full", template: ShippedPrompts.formal),
                ],
                cases: dictation + formalOnly
            ),
            Target(
                key: "structure", name: "Structure",
                variants: [
                    Variant(name: "Full", template: ShippedPrompts.structure),
                ],
                cases: structure
            ),
            Target(
                key: "summary", name: "Summary",
                variants: [
                    Variant(name: "Full", template: ShippedPrompts.summary),
                ],
                cases: summary
            ),
        ]
    }

    // MARK: - Checks

    struct Outcome: Sendable {
        let variant: String
        let caseName: String
        let run: Int
        let output: String
        let failures: [String]
        let latency: TimeInterval
        let promptTokens: Int?
        let completionTokens: Int?
        let error: String?
    }

    static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    /// How many times `phrase` appears in `text` as whole words.
    static func occurrences(of phrase: String, in text: String) -> Int {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: normalise(phrase))
            + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func check(_ output: String, against c: Case) -> [String] {
        var failures: [String] = []
        let norm = normalise(output)
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // A phrase counts as kept when it survives with punctuation added inside it:
        // "actually, good idea" keeps "actually good". Phrases that *are* about
        // punctuation ("anna,") still match the raw form.
        let unpunctuated = norm.replacingOccurrences(of: "[,;:.!—–-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
        for phrase in c.keep {
            let wanted = normalise(phrase)
            if !norm.contains(wanted) && !unpunctuated.contains(wanted) {
                failures.append("missing \"\(phrase)\"")
            }
        }
        // Whole words only: "um" is inside "numbers", and that is not a filler left in.
        for phrase in c.drop where occurrences(of: phrase, in: norm) > 0 {
            failures.append("still has \"\(phrase)\"")
        }
        for phrase in c.once {
            let count = occurrences(of: phrase, in: norm)
            if count != 1 { failures.append("\"\(phrase)\" appears \(count)×") }
        }

        // Shared with every prompt: how the reply is framed.
        if let first = lines.first?.lowercased(),
           first.hasPrefix("here") || first.hasPrefix("sure") || first.hasPrefix("voici")
            || first.hasPrefix("certainly") || first.hasPrefix("okay, here")
        {
            failures.append("preamble")
        }
        if !c.allowsMarkdown,
           output.contains("**") || lines.contains(where: { $0.hasPrefix("#") }) {
            failures.append("markdown")
        }
        if let first = output.first, first == "\"" || first == "“" {
            failures.append("quoted")
        }

        func isBullet(_ line: String) -> Bool {
            line.hasPrefix("- ") || line.hasPrefix("• ")
                || line.range(of: "^\\d+\\.\\s", options: .regularExpression) != nil
        }
        let bullets = lines.filter(isBullet).count
        let leadIns = lines.filter { $0.hasSuffix(":") && !isBullet($0) }.count

        for extra in c.extra {
            switch extra {
            case .allLinesStructured:
                let stray = lines.filter { !isBullet($0) && !$0.hasSuffix(":") }
                if !stray.isEmpty { failures.append("prose line: \"\(stray[0].prefix(40))\"") }
            case .bulletLines(let min):
                if bullets < min { failures.append("\(bullets) bullet lines, wanted ≥\(min)") }
            case .exactBulletLines(let n):
                if bullets != n { failures.append("\(bullets) bullet lines, wanted \(n)") }
            case .leadIns(let min):
                if leadIns < min { failures.append("\(leadIns) lead-ins, wanted ≥\(min)") }
            case .headings(let min):
                let headings = lines.filter { $0.hasPrefix("###") }.count
                if headings < min { failures.append("\(headings) headings, wanted >=\(min)") }
            case .noNumbering:
                if lines.contains(where: { $0.range(of: "^\\d+\\.", options: .regularExpression) != nil }) {
                    failures.append("numbered a set")
                }
            case .startsUppercase:
                if let first = output.first, first.isLowercase { failures.append("starts lowercase") }
            case .unchanged:
                if output.trimmingCharacters(in: .whitespacesAndNewlines) != c.raw {
                    failures.append("changed a clean input")
                }
            }
        }
        return failures
    }

    // MARK: - Run

    @Test("shipped prompts against the model")
    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let selection = env["MURMR_PROMPT_EVAL"], !selection.isEmpty else { return }
        let wanted = selection == "1"
            ? Set(Self.targets.map(\.key))
            : Set(selection.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let runs = Int(env["MURMR_EVAL_RUNS"] ?? "") ?? 3
        let provider = ProviderCatalog.entry(id: env["MURMR_EVAL_PROVIDER"] ?? ProviderCatalog.groq.id)
        let model = env["MURMR_EVAL_MODEL"] ?? provider.defaultModel

        var config = ProviderCatalog.defaultConfig(for: provider)
        config.model = model
        config.apiKeyOverride = env["MURMR_EVAL_KEY"]
        let sendable = config
        guard sendable.apiKey != nil else {
            Issue.record("No \(provider.displayName) key: save one in Settings, or set MURMR_EVAL_KEY.")
            return
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let outDir = root.appendingPathComponent("build/prompt-eval/\(provider.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let client = LLMClient()
        var summary: [String] = []
        var stopped = false

        for target in Self.targets where wanted.contains(target.key) && !stopped {
            var outcomes: [Outcome] = []
            // Two in flight. The limit that matters is tokens per minute, so more would only
            // queue up behind 429s; two keeps the wire busy while one waits.
            let jobs = target.variants.flatMap { variant in
                target.cases.flatMap { c in (1...runs).map { (variant, c, $0) } }
            }
            // One call at a time. The limits that bite are per minute and per day, so
            // parallel calls only queue behind each other's 429s — and a run that hits the
            // day's cap stops here rather than sleeping until tomorrow.
            for (variant, c, run) in jobs where !stopped {
                let outcome = await Self.evaluate(
                    variant: variant, c: c, run: run, client: client, config: sendable
                )
                outcomes.append(outcome)
                if outcome.error?.contains(Self.dailyCapMarker) == true {
                    let note = "\(provider.displayName) is out of tokens for the day; stopping. Partial report written."
                    Issue.record("\(note)")
                    stopped = true
                }
            }
            let report = Self.report(target: target, outcomes: outcomes, runs: runs, model: model)
            try report.write(
                to: outDir.appendingPathComponent("\(target.key).md"),
                atomically: true, encoding: .utf8
            )
            summary.append(Self.scoreboard(target: target, outcomes: outcomes, runs: runs))
        }
        print("\n" + summary.joined(separator: "\n\n") + "\n")
    }

    static func evaluate(
        variant: Variant, c: Case, run: Int, client: LLMClient, config: ProviderConfig
    ) async -> Outcome {
        let rendered = PromptLibrary(template: variant.template)
            .render(.init(transcript: c.raw))
        do {
            let completion = try await withRateLimitRetry {
                try await client.complete(prompt: rendered, config: config, timeout: 45)
            }
            return Outcome(
                variant: variant.name, caseName: c.name, run: run, output: completion.text,
                failures: check(completion.text, against: c), latency: completion.latency,
                promptTokens: completion.promptTokens,
                completionTokens: completion.completionTokens, error: nil
            )
        } catch {
            return Outcome(
                variant: variant.name, caseName: c.name, run: run, output: "",
                failures: ["error"], latency: 0, promptTokens: nil, completionTokens: nil,
                error: String(describing: error)
            )
        }
    }

    static let dailyCapMarker = "out of tokens for the day"

    /// Groq's free tier allows 8 000 tokens a minute on this model — about eight full-length
    /// clean-ups. The eval is well over that, so a 429 is expected, not a failure: wait the
    /// time the reply asks for and go again. A wait of minutes or hours means the *daily*
    /// cap, and that is not something to wait out.
    static func withRateLimitRetry<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        for _ in 0..<40 {
            do {
                return try await body()
            } catch LLMClient.ClientError.http(let status, let message) where status == 429 {
                let seconds = suggestedWait(in: message) ?? 3
                if seconds > 120 {
                    throw LLMClient.ClientError.http(status: 429, body: dailyCapMarker + ": " + message)
                }
                try await Task.sleep(for: .milliseconds(Int((seconds + 0.5) * 1000)))
            }
        }
        return try await body()
    }

    /// "try again in 1.305s", "in 2m3.5s", "in 1h12m" → seconds.
    static func suggestedWait(in message: String) -> Double? {
        guard let range = message.range(of: "try again in ([0-9hms.]+)", options: .regularExpression)
        else { return nil }
        let spec = message[range].split(separator: " ").last.map(String.init) ?? ""
        var total = 0.0, number = ""
        for ch in spec {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            let value = Double(number) ?? 0
            number = ""
            switch ch {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: break
            }
        }
        if !number.isEmpty { total += Double(number) ?? 0 }
        return total
    }

    // MARK: - Report

    static func scoreboard(target: Target, outcomes: [Outcome], runs: Int) -> String {
        var lines = ["\(target.name) — \(target.cases.count) cases × \(runs) runs"]
        lines.append("| variant | prompt tok | latency | runs clean | cases clean every run |")
        lines.append("|---|---|---|---|---|")
        for variant in target.variants {
            let mine = outcomes.filter { $0.variant == variant.name }
            let clean = mine.filter { $0.failures.isEmpty }.count
            let tokens = mine.compactMap(\.promptTokens)
            let meanTokens = tokens.isEmpty ? 0 : tokens.reduce(0, +) / tokens.count
            let latencies = mine.filter { $0.error == nil }.map(\.latency)
            let meanLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)
            let casesClean = target.cases.filter { c in
                mine.filter { $0.caseName == c.name }.allSatisfy { $0.failures.isEmpty }
            }.count
            lines.append(
                "| \(variant.name) | \(meanTokens) | \(String(format: "%.2f", meanLatency)) s "
                + "| \(clean)/\(mine.count) | \(casesClean)/\(target.cases.count) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func report(target: Target, outcomes: [Outcome], runs: Int, model: String) -> String {
        var out = "# \(target.name)\n\n"
        out += "Model `\(model)`, \(runs) runs per case, temperature and reasoning effort as the app sends them.\n\n"
        out += scoreboard(target: target, outcomes: outcomes, runs: runs) + "\n\n"

        // Failures by kind, per variant: the fastest way to see what a prompt gets wrong.
        for variant in target.variants {
            let mine = outcomes.filter { $0.variant == variant.name }
            var counts: [String: Int] = [:]
            for outcome in mine { for failure in outcome.failures { counts[failure, default: 0] += 1 } }
            if !counts.isEmpty {
                out += "**\(variant.name) failures**\n\n"
                for (failure, count) in counts.sorted(by: { $0.value > $1.value }) {
                    out += "- \(failure) ×\(count)\n"
                }
                out += "\n"
            }
        }

        for c in target.cases {
            out += "---\n\n## \(c.name)\n\n"
            out += "> \(c.raw)\n\n"
            for variant in target.variants {
                let mine = outcomes
                    .filter { $0.variant == variant.name && $0.caseName == c.name }
                    .sorted { $0.run < $1.run }
                for outcome in mine {
                    let mark = outcome.failures.isEmpty ? "✓" : "✗ " + outcome.failures.joined(separator: ", ")
                    out += "**\(variant.name) \(outcome.run)** \(mark)"
                    if let tokens = outcome.promptTokens {
                        out += " · \(tokens) tok · \(String(format: "%.1f", outcome.latency)) s"
                    }
                    out += "\n\n```\n\(outcome.error ?? outcome.output)\n```\n\n"
                }
            }
        }
        return out
    }
}
