import Foundation

/// The app in front, as everything downstream needs it.
///
/// A struct rather than `NSRunningApplication`, because the two things ever read from it
/// are a name to show and a bundle id to match a rule against — and because a running
/// application cannot be constructed in a test, which left the whole "which style does
/// this app get" question unexercisable.
struct TargetApp: Equatable, Sendable {
    var name: String?
    var bundleID: String?

    var isEmpty: Bool { name == nil && bundleID == nil }
}

/// What one app should get instead of the standing style.
///
/// Keyed by bundle id, which is the only name for an app that survives a rename, a move
/// and a localisation. The display name is stored beside it so the row can be drawn for an
/// app that is not installed any more, rather than showing a reverse-DNS string.
struct AppStyleRule: Codable, Identifiable, Hashable, Sendable {
    let bundleID: String
    var appName: String
    var outcome: Outcome

    var id: String { bundleID }

    /// What the rule does. **Off is not a style**, which is why it is a case here rather
    /// than a magic preset: it means the words are typed exactly as heard, with no request
    /// made at all. That is the setting people want for a terminal, where clean-up
    /// "fixes" the punctuation of a command, and for a password field, where nothing
    /// should leave the machine.
    enum Outcome: Codable, Hashable, Sendable {
        case style(UUID)
        case off
    }

    var styleID: UUID? {
        if case .style(let id) = outcome { return id }
        return nil
    }
}

/// The style one dictation will use, and what chose it.
///
/// The reason travels with the choice on purpose. The pill shows it before you speak, and
/// "Formal, because you are in Mail" is the difference between a setting that feels
/// helpful and one that feels like the app changing its mind on its own.
struct StyleChoice: Equatable, Sendable {
    /// The style to run, or nil when this dictation is typed exactly as heard.
    var preset: PromptPreset?
    var source: Source

    enum Source: Equatable, Sendable {
        /// The style assigned to Dictation, with nothing overriding it.
        case standing
        /// A rule for the app the text is going to, named as the person would name it.
        case app(String)
        /// A key of the style's own, written the way a shortcut is written.
        case key(String)
    }

    /// The half-sentence that says why, or nil when nothing chose it. Shown beside the
    /// style's name in the pill.
    var detail: String? {
        switch source {
        case .standing: nil
        case .app(let name): name
        case .key(let key): key
        }
    }

    /// The name to show, "Off" included — a dictation that ran no clean-up is a state
    /// worth naming rather than a blank.
    var displayName: String { preset?.name ?? "Off" }
}
