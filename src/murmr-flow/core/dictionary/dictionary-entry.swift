import Foundation

/// One entry in the dictionary: something you say, and what should be written instead.
///
/// **A spelling correction and a snippet are the same thing at different lengths**, so
/// they are one type and one list rather than two features that would drift apart. "my
/// email address" → `mc@kovalee.app` and "Cavalley" → "Kovalee" differ only in how much
/// text comes out.
///
/// The one real split is *how* an entry can be honoured, and it follows from whether a
/// trigger was given:
///
///   - **With a trigger** — an exact replacement. Done locally, before the text ever
///     reaches a provider, so it is deterministic and works with clean-up switched off
///     entirely. An email address or a referral link must come out character for character;
///     an LLM getting one wrong is a failure nobody notices until it has been sent.
///   - **Without one** — a spelling hint. There is nothing to match on, because the point
///     is that you cannot predict every way a name will be misheard, so the word is handed
///     to the clean-up prompt and the model does the fuzzy work. **This does nothing at all
///     with clean-up off**, which is why a hint says so on its card.
struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {

    let id: UUID

    /// What you say. Empty makes this a spelling hint rather than a replacement.
    var trigger: String

    /// What gets written. For a hint, this is the word itself, spelled the way you want it.
    var replacement: String

    var scope: Scope

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

    init(id: UUID = UUID(), trigger: String = "", replacement: String, scope: Scope = .both) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.scope = scope
    }

    /// True when this entry can be applied exactly, without a provider.
    var isReplacement: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An entry with nothing in it is not worth keeping or sending anywhere.
    var isUsable: Bool {
        !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the sidebar of a card shows: the trigger for a replacement, the word itself for
    /// a hint.
    var displayTrigger: String {
        isReplacement ? trigger : replacement
    }
}
