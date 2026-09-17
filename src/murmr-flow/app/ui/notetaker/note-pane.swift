import SwiftUI

/// The two ways of looking at one meeting.
///
/// Not three. The transcript is evidence rather than a view of the note, so it folds away
/// at the bottom instead of taking a third of a control the eye has to choose from.
enum NotePane: String, CaseIterable, Identifiable, Hashable {
    case enhanced
    case mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enhanced: "Enhanced"
        case .mine: "Your notes"
        }
    }
}
