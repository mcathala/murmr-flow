import SwiftUI

/// What your own use looks like.
///
/// Its own section rather than the bottom half of Home. Home is for *what you made* and
/// wants to be glanceable; these are figures you come to look at, and the two were
/// competing for the same scroll. Splitting them also leaves room for the window
/// selector, which had nowhere to go before.
struct InsightsView: View {

    let history: HistoryStore
    /// Holds the window and the typing speed, so both survive leaving the pane. Seven
    /// days is the default because a week is the unit people actually think in.
    @Bindable var settings: SettingsStore

    @State private var editingTypingSpeed = false

    private var windowDays: Int { settings.insightsWindowDays }
    private var typingSpeed: Double { settings.typingWordsPerMinute }

    var body: some View {
        PaneScroll {
            HStack(spacing: 10) {
                Text("Insights").font(.title2.weight(.semibold))
                Spacer(minLength: 0)
                Picker("", selection: $settings.insightsWindowDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            InsightsGrid(insights: insights, typingSpeed: typingSpeed, windowDays: windowDays)

            if !insights.isEmpty { assumption }
        }
    }

    private var insights: Insights {
        Insights.compute(
            from: history.dictations,
            windowDays: windowDays,
            typingWordsPerMinute: typingSpeed
        )
    }

    /// "Time saved" is the one figure that isn't a measurement — it is a word count
    /// divided by a typing speed nobody timed. So the assumption is adjustable and stated
    /// out loud rather than buried in the arithmetic.
    private var assumption: some View {
        Card {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time saved assumes you type at \(Int(typingSpeed)) words a minute")
                        .font(.callout.weight(.medium))
                    Text("Every other figure here is measured. This one is a comparison, so "
                         + "it is only as good as that number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if editingTypingSpeed {
                    Stepper(
                        value: $settings.typingWordsPerMinute, in: 20...120, step: 5
                    ) {
                        Text("\(Int(typingSpeed))").font(.callout.monospacedDigit())
                    }
                    .fixedSize()
                    Button("Done") { editingTypingSpeed = false }
                        .controlSize(.small)
                } else {
                    Button("Change") { editingTypingSpeed = true }
                        .controlSize(.small)
                }
            }
        }
    }
}
