import Foundation
import Observation

/// The dictionary: spelling corrections and snippets, in one list.
///
/// Stored as JSON in `UserDefaults`, the same way prompts are — user-authored text that is
/// small, needs no schema, and should survive a rebuild.
///
/// **Seeded once from `cleanup.customWords`.** That key held a plain `[String]` and is the
/// only thing an existing install has, so the first launch after this ships turns each word
/// into a hint scoped to both jobs — which is exactly what those words did before, since
/// both pipelines passed the same array. The old key is then **left in place, never
/// deleted**: removing a persisted key silently resets it for everyone who already launched
/// the app, and leaving it costs a few bytes and makes this reversible.
@MainActor
@Observable
final class DictionaryStore {

    private enum Key {
        static let entries = "dictionary.entries"
        /// Read once, to seed. Never written, never removed.
        static let legacyWords = "cleanup.customWords"
    }

    private(set) var entries: [DictionaryEntry] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Key.entries),
           let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            entries = decoded
            return
        }

        let legacy = defaults.stringArray(forKey: Key.legacyWords) ?? []
        guard !legacy.isEmpty else { return }

        entries = legacy.map {
            DictionaryEntry(kind: .spelling, replacement: $0, scope: .both)
        }
        persist()
    }

    // MARK: - Reading

    /// Everything that applies to one job. A `both` entry answers to either.
    func entries(usedIn scope: DictionaryEntry.Scope) -> [DictionaryEntry] {
        entries.filter { $0.isUsable && $0.scope.covers(scope) }
    }

    // MARK: - Writing

    /// Returns what it added, so a view can open the editor on it straight away.
    @discardableResult
    func add(
        kind: DictionaryEntry.Kind = .swap,
        trigger: String = "",
        replacement: String = "",
        scope: DictionaryEntry.Scope = .both
    ) -> DictionaryEntry {
        let entry = DictionaryEntry(
            kind: kind, trigger: trigger, replacement: replacement, scope: scope
        )
        entries.append(entry)
        persist()
        return entry
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persist()
    }

    func remove(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Key.entries)
    }
}
