import SwiftUI

/// The written note, above the transcript it was written from.
///
/// Laid out rather than printed. The file holds Markdown because it has to open in
/// anything, but `### Where the app stands` and `- [ ] send the runbook` on screen would be
/// markup in the one place the app is supposed to be reading to you — the same reason the
/// transcript became turns instead of a block of text with `**Them**` in it.
///
/// Its own view, so it can be rendered on its own in a snapshot. Every layout mistake in
/// this app so far was found by eye and missed by arithmetic.
struct NoteSummaryView: View {

    let lines: [NoteFile.SummaryLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                switch line {
                case .heading(let text):
                    Text(text)
                        .font(Theme.Text.heading)
                        .foregroundStyle(Theme.Palette.text)
                        // Space above a heading, none above the first: a gap at the top of
                        // the note would read as the pane being misaligned.
                        .padding(.top, index == 0 ? 0 : 16)
                        .padding(.bottom, 6)

                case .bullet(let text):
                    row(marker: bullet, text: text)

                case .task(let done, let text):
                    row(marker: checkbox(done), text: text)

                case .paragraph(let text):
                    Text(text)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Palette.text)
                        .lineSpacing(3)
                        .padding(.bottom, 5)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Marker and text on one baseline, with the text in a column of its own so a bullet
    /// that wraps stays clear of the marker instead of running under it.
    private func row(marker: some View, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.frame(width: 12, alignment: .leading)
            Text(text)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.text)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 5)
    }

    private var bullet: some View {
        Circle()
            .fill(Theme.Palette.faint)
            .frame(width: 4, height: 4)
            // On the text's baseline rather than centred on the line box, which puts a
            // dot beside a wrapped bullet's *second* line.
            .alignmentGuide(.firstTextBaseline) { _ in 4 }
    }

    /// A task from the note. Drawn, not interactive: the file is the source of truth, and
    /// a box that ticked here and not there would be two answers to one question.
    private func checkbox(_ done: Bool) -> some View {
        Image(systemName: done ? "checkmark.square.fill" : "square")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(done ? Theme.Palette.gold : Theme.Palette.faint)
    }
}
