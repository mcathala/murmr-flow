import Foundation

/// One entry in the dictionary: something you say, and what should be written instead.
///
/// **A spelling correction and a snippet are the same thing at different lengths**, so
/// they are one type and one list rather than two features that would drift apart. "my
/// email address" → `mc@kovalee.app` and "Cavalley" → "Kovalee" differ only in how much
/// text comes out.
///
/// The one real split is *how* an entry can be honoured, and it is a **stored choice**, not
/// something inferred:
///
///   - **`swap`** — an exact replacement. Done locally, before the text ever reaches a
///     provider, so it is deterministic and works with clean-up switched off entirely. An
///     email address or a referral link must come out character for character; an LLM
///     getting one wrong is a failure nobody notices until it has been sent.
///   - **`spelling`** — a hint for the clean-up prompt. There is nothing to match on,
///     because the point is that you cannot predict every way a name will be misheard, so
///     the word is handed to the model and it does the fuzzy work. **This does nothing at
///     all with clean-up off**, which the tab says when that is the case.
///
/// The kind was derived from "is the trigger empty" for exactly one build, and that was a
/// mistake twice over: it made the editor ask the user to express a choice by leaving a box
/// blank, and it could not tell a half-filled swap from a spelling fix, so an entry changed
/// kind under you between closing and reopening it.
struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {

    let id: UUID

    var kind: Kind

    /// What you say, for a `swap`. Unused by a `spelling` entry.
    var trigger: String

    /// What gets written. For a `spelling` entry, the word itself, spelled the way you want.
    var replacement: String

    var scope: Scope

    /// The two things an entry can be. Labels are verbs, because this is a choice about what
    /// you are doing rather than a category to classify it into — and because "hint" and
    /// "replacement" are our words, not anybody else's.
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case swap, spelling

        var id: String { rawValue }

        var label: String {
            switch self {
            case .swap: "Swap a phrase"
            case .spelling: "Fix a spelling"
            }
        }
    }

    /// Which job an entry applies to. Both is the default: a name you want spelled your way
    /// is usually wanted in a note as much as in a dictation.
    enum Scope: String, Codable, CaseIterable, Identifiable, Sendable {
        case dictation, notetaker, both

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dictation: "Dictation"
            case .notetaker: "Notetaker"
            case .both: "Both"
            }
        }

        func covers(_ other: Scope) -> Bool {
            self == .both || self == other
        }
    }

    init(
        id: UUID = UUID(),
        kind: Kind = .swap,
        trigger: String = "",
        replacement: String = "",
        scope: Scope = .both
    ) {
        self.id = id
        self.kind = kind
        self.trigger = trigger
        self.replacement = replacement
        self.scope = scope
    }

    /// Nothing typed in either field — an entry that was created and then abandoned.
    ///
    /// Deliberately *not* the inverse of `isUsable`. A swap with a trigger and no
    /// replacement is unusable but not blank, and it is kept: discarding it would throw away
    /// something the user typed. Blank means there is provably nothing to lose.
    var isBlank: Bool {
        trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Everything an entry of this kind needs before it is worth handing to a pipeline. A
    /// swap with no trigger has nothing to match on; either kind with no replacement has
    /// nothing to say.
    var isUsable: Bool {
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch kind {
        case .spelling: return true
        case .swap: return !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, kind, trigger, replacement, scope
    }

    /// Tolerant of entries written before `kind` was stored, where the trigger was the only
    /// thing that decided — so an install that already seeded from `cleanup.customWords`
    /// keeps those words as spelling fixes rather than losing them to a decode failure.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? .both
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? (trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .spelling
                : .swap)
    }
}
