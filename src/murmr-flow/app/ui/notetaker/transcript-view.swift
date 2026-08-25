import SwiftUI

/// A conversation, laid out as turns.
///
/// Its own view rather than a private helper inside the notes pane, because the thing that
/// needed checking here was how it *looks* — and a view that can be rendered on its own can
/// be snapshotted in a test. Every layout mistake in this app so far was found by eye and
/// missed by arithmetic.
struct TranscriptView: View {

    let turns: [NoteFile.Turn]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(turns) { turn in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    // Fixed gutter, so every line of speech starts at the same x no matter
                    // which label sits beside it. Ragged left edges are what make a
                    // transcript tiring to read.
                    VStack(alignment: .leading, spacing: 3) {
                        Text(turn.speaker)
                            .font(Theme.Text.label)
                            .tracking(Theme.labelTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(turn.isYou ? Theme.Palette.tide : Theme.Palette.gold)
                        Text(turn.time)
                            .font(Theme.Text.mono)
                            .foregroundStyle(Theme.Palette.faint)
                    }
                    .frame(width: 46, alignment: .leading)

                    Text(turn.text)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Palette.text)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
