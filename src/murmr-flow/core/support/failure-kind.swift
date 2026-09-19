import Foundation

/// Which part of the pipeline a failure belongs to.
///
/// Decided where the failure happens, by the coordinator that knows, and carried with the
/// message from then on. The floating pill used to work this out afterwards by searching
/// the message for words like "key" and "http" — so a system-audio tap that never ran
/// was announced as "Speech model failed", because its sentence contained none of them.
///
/// Two of these name a permission rather than a component, because that is what the
/// person can act on: a meeting that heard nothing is a system-audio grant, and text that
/// could not be typed is on the clipboard already — the row says how to get it.
enum FailureKind: Equatable, Sendable {
    case speechModel
    case aiProvider
    case systemAudio
    /// The first meeting on a machine that has never been asked.
    ///
    /// Not a refusal, and it must not be worded as one. Starting IO is what raises Apple's
    /// dialog, and that call returns having heard nothing while the dialog is still on
    /// screen — so the first attempt always fails, including for someone who is in the act
    /// of clicking Allow. Telling them it "isn't allowed" at that moment is the app
    /// contradicting what they just did.
    case systemAudioPending
    case microphone
    case insertion
    case notes

    /// The pill's whole vocabulary: two or three words, one per kind.
    var headline: String {
        switch self {
        case .speechModel: "Speech model failed"
        case .aiProvider: "AI provider failed"
        case .systemAudio: "System audio isn\u{2019}t allowed"
        case .systemAudioPending: "Allow system audio, then start again"
        case .microphone: "Microphone heard nothing"
        case .insertion: "Couldn\u{2019}t type here. Copied — press ⌘V"
        case .notes: "Couldn\u{2019}t save the note"
        }
    }

    /// The insertion line is a sentence, not a verdict, and needs the room.
    var pillWidth: CGFloat {
        self == .insertion ? 300 : 210
    }
}
