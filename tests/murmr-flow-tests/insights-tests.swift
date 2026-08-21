import Foundation
import Testing

@testable import MurmrFlow

@Suite("Insights")
struct InsightsTests {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_775_000_000)

    private func record(daysAgo: Int, words: Int, seconds: Double = 10, app: String? = nil)
        -> DictationRecord
    {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return DictationRecord(
            date: date,
            audioDuration: seconds,
            rawText: "",
            finalText: Array(repeating: "word", count: words).joined(separator: " "),
            targetAppName: app
        )
    }

    @Test("no records means no numbers")
    func empty() {
        #expect(Insights.compute(from: [], calendar: calendar, now: now).isEmpty)
    }

    @Test("words and pace come from the records")
    func totals() {
        let insights = Insights.compute(
            from: [record(daysAgo: 0, words: 30, seconds: 30)],
            calendar: calendar, now: now
        )
        #expect(insights.wordsDictated == 30)
        // 30 words in 30 seconds is 60 wpm.
        #expect(insights.paceWordsPerMinute == 60)
    }

    @Test("pace is weighted by length, not an average of averages")
    func weightedPace() {
        // One long slow dictation and one short fast one. Averaging the two rates would
        // let the two-word burst count as much as the two-minute stretch.
        let insights = Insights.compute(
            from: [
                record(daysAgo: 0, words: 100, seconds: 120),
                record(daysAgo: 0, words: 4, seconds: 1),
            ],
            calendar: calendar, now: now
        )
        #expect(insights.paceWordsPerMinute == 52)  // 104 words / 121s
    }

    @Test("a streak counts consecutive days up to today")
    func streak() {
        let insights = Insights.compute(
            from: [record(daysAgo: 0, words: 1), record(daysAgo: 1, words: 1),
                   record(daysAgo: 2, words: 1)],
            calendar: calendar, now: now
        )
        #expect(insights.streakDays == 3)
    }

    @Test("yesterday still counts as live")
    func streakGrace() {
        // A streak that breaks the moment you wake up is a streak nobody can hold.
        let insights = Insights.compute(
            from: [record(daysAgo: 1, words: 1), record(daysAgo: 2, words: 1)],
            calendar: calendar, now: now
        )
        #expect(insights.streakDays == 2)
    }

    @Test("a gap ends the streak but not the best one")
    func brokenStreak() {
        let insights = Insights.compute(
            from: [record(daysAgo: 0, words: 1),
                   record(daysAgo: 5, words: 1), record(daysAgo: 6, words: 1),
                   record(daysAgo: 7, words: 1)],
            calendar: calendar, now: now
        )
        #expect(insights.streakDays == 1)
        #expect(insights.bestStreakDays == 3)
    }

    @Test("the chart includes quiet days")
    func quietDaysIncluded() {
        let insights = Insights.compute(
            from: [record(daysAgo: 0, words: 5)],
            windowDays: 7, calendar: calendar, now: now
        )
        // Omitting empty days would flatter the chart and read as continuous use.
        #expect(insights.days.count == 7)
        #expect(insights.days.filter { $0.words == 0 }.count == 6)
    }

    @Test("app shares sum to the window's words")
    func appShares() {
        let insights = Insights.compute(
            from: [record(daysAgo: 0, words: 30, app: "Brave"),
                   record(daysAgo: 0, words: 10, app: "Mail")],
            calendar: calendar, now: now
        )
        #expect(insights.topApps.first?.name == "Brave")
        #expect(abs((insights.topApps.first?.share ?? 0) - 0.75) < 0.001)
    }

    @Test("time saved subtracts the time you spent speaking")
    func timeSaved() {
        // 40 words at 40 wpm is 60s of typing; speaking took 10s.
        let insights = Insights.compute(
            from: [record(daysAgo: 0, words: 40, seconds: 10)],
            typingWordsPerMinute: 40, calendar: calendar, now: now
        )
        #expect(abs(insights.timeSaved - 50) < 0.001)
    }
}
