import SwiftUI

/// Four figures, a chart and a breakdown.
///
/// Kept deliberately small. Milestones, badges and personal records are engagement
/// mechanics — they exist to make you open an app you're paying for, and this one was
/// built to escape a subscription. The streak stays because it's a fact about you; the
/// trophies don't.
struct InsightsGrid: View {

    let insights: Insights
    let typingSpeed: Double
    /// Only used for the footnotes, which must not claim "last 7 days" while showing 30.
    var windowDays: Int = 7

    var body: some View {
        if insights.isEmpty {
            Card {
                Text("Nothing to measure yet. Numbers appear after your first dictation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                figures
                activity
                if !insights.topApps.isEmpty { destinations }
            }
        }
    }

    // MARK: - Figures

    private var figures: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 120), spacing: 10), count: 4),
            spacing: 10
        ) {
            Figure(
                label: "Words dictated",
                value: "\(insights.wordsDictated)",
                footnote: "last \(windowDays) days"
            )
            // The only figure here that isn't a measurement. It is a word count divided
            // by a typing speed nobody timed, so the assumption is printed next to it
            // rather than hidden inside the arithmetic.
            Figure(
                label: "Time saved",
                value: Insights.shortDuration(insights.timeSaved),
                footnote: "vs typing at \(Int(typingSpeed)) wpm"
            )
            Figure(
                label: "Your pace",
                value: "\(insights.paceWordsPerMinute)",
                unit: "wpm",
                footnote: "speaking, not typing"
            )
            Figure(
                label: "Streak",
                value: "\(insights.streakDays)",
                unit: insights.streakDays == 1 ? "day" : "days",
                footnote: "best \(insights.bestStreakDays)"
            )
        }
    }

    // MARK: - Activity

    private var activity: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Activity")
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(insights.days) { day in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(day.words > 0 ? AnyShapeStyle(.tint)
                                                    : AnyShapeStyle(.quaternary))
                                // Capped, and centred in an even column. Left to fill the
                                // width, seven bars across a wide card became blocks —
                                // wider than they were tall, which reads as a stack of
                                // slabs rather than a chart.
                                .frame(maxWidth: 26)
                                .frame(height: barHeight(day.words))
                            Text(Self.weekday(day.date))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .help("\(day.words) words")
                    }
                }
                .frame(height: 72, alignment: .bottom)
            }
        }
    }

    /// Scaled against the busiest day in the window, with a floor so a quiet-but-nonzero
    /// day is still visible — a bar rounded down to nothing reads as "never used".
    private func barHeight(_ words: Int) -> CGFloat {
        let peak = insights.days.map(\.words).max() ?? 0
        guard peak > 0 else { return 3 }
        guard words > 0 else { return 3 }
        return 3 + 49 * CGFloat(words) / CGFloat(peak)
    }

    private static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date)
    }

    // MARK: - Destinations

    /// The tile no other app can show you, because it needs the target we capture at the
    /// moment of dictating.
    private var destinations: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Where your words go")
                ForEach(insights.topApps) { app in
                    HStack(spacing: 10) {
                        AppBadge(name: app.name, bundleID: app.bundleID)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.tint)
                                .frame(width: max(4, geometry.size.width * app.share))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 8)
                        Text("\(app.name) · \(Int((app.share * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// One number, with its label above and its caveat below.
private struct Figure: View {
    let label: String
    let value: String
    var unit: String?
    let footnote: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                    if let unit {
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
