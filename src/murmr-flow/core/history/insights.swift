import Foundation

/// What your own use looks like, computed from the dictation log.
///
/// Four of the five figures are **measurements**. One — time saved — is a *story*: it is
/// your word count divided by a typing speed nobody measured. That distinction is kept
/// visible rather than smoothed over, which is why `typingWordsPerMinute` is an explicit
/// input and gets shown next to the number.
struct Insights: Sendable, Equatable {

    struct Day: Sendable, Equatable, Identifiable {
        let date: Date
        let words: Int
        var id: Date { date }
    }

    struct AppShare: Sendable, Equatable, Identifiable {
        let name: String
        let bundleID: String?
        let words: Int
        /// 0…1 of the words in the window.
        let share: Double
        var id: String { bundleID ?? name }
    }

    let wordsDictated: Int
    let dictationCount: Int
    /// Assumed, not measured. See the note above.
    let timeSaved: TimeInterval
    /// Your speaking pace, weighted by length rather than averaging the averages —
    /// otherwise a two-word dictation counts as much as a two-minute one.
    let paceWordsPerMinute: Int
    let streakDays: Int
    let bestStreakDays: Int
    let days: [Day]
    let topApps: [AppShare]

    var isEmpty: Bool { dictationCount == 0 }

    static let empty = Insights(
        wordsDictated: 0, dictationCount: 0, timeSaved: 0, paceWordsPerMinute: 0,
        streakDays: 0, bestStreakDays: 0, days: [], topApps: []
    )

    /// A common typing speed for prose. Adjustable, because the whole figure hangs on it.
    static let defaultTypingWordsPerMinute: Double = 40

    /// - Parameters:
    ///   - windowDays: how far back the totals and the chart reach.
    ///   - typingWordsPerMinute: the assumption behind "time saved".
    ///   - now: injected so the result is testable and doesn't drift mid-render.
    static func compute(
        from records: [DictationRecord],
        windowDays: Int = 7,
        typingWordsPerMinute: Double = defaultTypingWordsPerMinute,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Insights {
        guard !records.isEmpty else { return .empty }

        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today)
        else { return .empty }

        let inWindow = records.filter { $0.date >= windowStart }

        let words = inWindow.reduce(0) { $0 + $1.wordCount }
        let spokenSeconds = inWindow.reduce(0.0) { $0 + $1.audioDuration }

        // Length-weighted, not a mean of means.
        let pace = spokenSeconds > 0 ? Double(words) / (spokenSeconds / 60) : 0

        // Typing the same words, minus the time you actually spent saying them.
        let typingSeconds = typingWordsPerMinute > 0
            ? Double(words) / typingWordsPerMinute * 60
            : 0
        let saved = max(0, typingSeconds - spokenSeconds)

        return Insights(
            wordsDictated: words,
            dictationCount: inWindow.count,
            timeSaved: saved,
            paceWordsPerMinute: Int(pace.rounded()),
            streakDays: streak(in: records, calendar: calendar, from: today),
            bestStreakDays: bestStreak(in: records, calendar: calendar),
            days: dailyWords(in: inWindow, days: windowDays, calendar: calendar, today: today),
            topApps: appShares(in: inWindow, totalWords: words)
        )
    }

    // MARK: - Streaks

    /// Days in a row up to today. Yesterday still counts as live, because a streak that
    /// breaks the moment you wake up would be a streak nobody could hold.
    private static func streak(
        in records: [DictationRecord], calendar: Calendar, from today: Date
    ) -> Int {
        let active = Set(records.map { calendar.startOfDay(for: $0.date) })
        guard !active.isEmpty else { return 0 }

        var cursor = today
        if !active.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  active.contains(yesterday)
            else { return 0 }
            cursor = yesterday
        }

        var count = 0
        while active.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private static func bestStreak(in records: [DictationRecord], calendar: Calendar) -> Int {
        let active = Set(records.map { calendar.startOfDay(for: $0.date) }).sorted()
        guard !active.isEmpty else { return 0 }

        var best = 1
        var run = 1
        for index in 1..<active.count {
            let gap = calendar.dateComponents([.day], from: active[index - 1], to: active[index]).day
            if gap == 1 {
                run += 1
                best = max(best, run)
            } else {
                run = 1
            }
        }
        return best
    }

    // MARK: - Breakdowns

    /// Every day in the window, including the empty ones — a chart that silently omits
    /// quiet days flatters you and misreads as continuous use.
    private static func dailyWords(
        in records: [DictationRecord], days: Int, calendar: Calendar, today: Date
    ) -> [Day] {
        var totals: [Date: Int] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            totals[day, default: 0] += record.wordCount
        }

        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return Day(date: date, words: totals[date] ?? 0)
        }
    }

    private static func appShares(
        in records: [DictationRecord], totalWords: Int
    ) -> [AppShare] {
        guard totalWords > 0 else { return [] }

        var words: [String: Int] = [:]
        var bundles: [String: String] = [:]
        for record in records {
            let name = record.targetAppName ?? "Elsewhere"
            words[name, default: 0] += record.wordCount
            if let bundle = record.targetBundleID { bundles[name] = bundle }
        }

        return words
            .map {
                AppShare(
                    name: $0.key,
                    bundleID: bundles[$0.key],
                    words: $0.value,
                    share: Double($0.value) / Double(totalWords)
                )
            }
            .sorted { $0.words > $1.words }
            .prefix(4)
            .map { $0 }
    }

    // MARK: - Formatting

    /// `14m`, `2h 05m`, `< 1m` — never a bare "0" for work that did happen.
    static func shortDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return "0" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes < 1 { return "< 1m" }
        return "\(minutes)m"
    }
}
