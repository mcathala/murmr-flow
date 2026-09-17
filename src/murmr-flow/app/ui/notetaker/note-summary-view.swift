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
    /// Called with the task's position in the note when its box is clicked. Nil leaves the
    /// boxes drawn but inert, which is what a snapshot wants.
    var onToggleTask: ((Int) -> Void)?

    var body: some View {
        // Tasks are numbered as they appear, because that is how the file counts them
        // when one is ticked — matching on the words would tick the wrong one of two
        // tasks that happen to read the same.
        var taskNumber = -1
        return VStack(alignment: .leading, spacing: 0) {
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
                    let number = { taskNumber += 1; return taskNumber }()
                    row(marker: checkbox(done, at: number), text: text)

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

    /// A task from the note, ticked by clicking it.
    ///
    /// The click writes the `x` into the file, which is why this can be interactive at all
    /// — a box that ticked on screen and not on disk would be two answers to one question.
    /// And it works without entering the editor: ticking something off is the most ordinary
    /// thing anyone does to a note, and making it cost a mode was the wrong trade.
    private func checkbox(_ done: Bool, at index: Int) -> some View {
        Button {
            onToggleTask?(index)
        } label: {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(done ? Theme.Palette.gold : Theme.Palette.faint)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(onToggleTask == nil)
        .help(done ? "Mark as not done" : "Mark as done")
    }
}
