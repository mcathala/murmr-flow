import Foundation
import Observation
import OSLog

/// Keeps a record of every dictation.
///
/// A **line-delimited JSON file**, not a database. One row per dictation, appended and
/// never rewritten. At a few thousand dictations that is a file measured in megabytes
/// that loads in milliseconds, and in exchange it stays readable in any text editor,
/// survives a crash mid-write (the last line is simply short), needs no schema migration,
/// and adds no dependency. If it ever outgrows that, the file is trivial to import.
///
/// Meetings are deliberately *not* in here. Their notes are Markdown files on disk and
/// those files are the source of truth, so listing them means reading the folder — see
/// `MeetingStore`. Two stores because there are genuinely two kinds of thing: one we own,
/// and one the user owns.
@MainActor
@Observable
final class HistoryStore {

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "history")

    /// Newest first, which is the order every screen wants.
    private(set) var dictations: [DictationRecord] = []

    private let url: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    /// `~/Library/Application Support/Murmr Flow/dictations.jsonl` — our own state, so
    /// Application Support rather than Documents.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Murmr Flow", isDirectory: true)
            .appendingPathComponent("dictations.jsonl")
    }

    // MARK: - Reading

    func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            dictations = []
            return
        }

        var loaded: [DictationRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            // A corrupt or half-written line is skipped rather than failing the load.
            // Losing one row is survivable; losing the whole history is not.
            guard let record = try? decoder.decode(DictationRecord.self, from: data) else {
                continue
            }
            loaded.append(record)
        }

        dictations = loaded.sorted { $0.date > $1.date }
        Self.log.notice("loaded \(loaded.count, privacy: .public) dictations")
    }

    // MARK: - Writing

    func add(_ record: DictationRecord) {
        dictations.insert(record, at: 0)
        append(record)
    }

    /// Replaces a record in place — used when cleanup is re-run against a new prompt.
    ///
    /// This is the one operation an append-only log can't express, so the file is
    /// rewritten whole. Rare enough that the cost never shows.
    func replace(_ record: DictationRecord) {
        guard let index = dictations.firstIndex(where: { $0.id == record.id }) else { return }
        dictations[index] = record
        rewrite()
    }

    func delete(_ record: DictationRecord) {
        delete(ids: [record.id])
    }

    /// One rewrite for the whole batch. Deleting fifty rows one at a time would rewrite
    /// the file fifty times.
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        dictations.removeAll { ids.contains($0.id) }
        rewrite()
    }

    /// Permanent. Unlike a note, a dictation has no file of its own to send to the Trash,
    /// so there is nowhere to recover it from — which is why the UI says so before asking.
    func deleteAll() {
        dictations = []
        try? FileManager.default.removeItem(at: url)
    }

    private func append(_ record: DictationRecord) {
        guard let line = encode(record) else { return }
        do {
            try ensureFolder()
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            Self.log.error("append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rewrite() {
        do {
            try ensureFolder()
            // Oldest first on disk, so the file reads chronologically and an append is
            // always the newest line.
            var data = Data()
            for record in dictations.reversed() {
                guard let line = encode(record) else { continue }
                data.append(line)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("rewrite failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func encode(_ record: DictationRecord) -> Data? {
        guard var data = try? encoder.encode(record) else { return nil }
        data.append(0x0A)  // newline — the "L" in JSONL
        return data
    }

    private func ensureFolder() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
