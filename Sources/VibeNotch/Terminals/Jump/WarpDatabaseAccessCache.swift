import Foundation

/// Per-launch memory of Warp's state database: whether macOS let us read it, and the working
/// copy we most recently made.
///
/// Warp's sqlite lives in ANOTHER app's group container, which macOS gates behind TCC. Every
/// fresh attempt to read it re-triggers the consent prompt, so a refusal has to be remembered
/// and never retried for the rest of the launch — otherwise every single session click prompts
/// again (#20). Successful reads are cached for a few seconds too, so a jump and the answer
/// injection that follows it share one copy instead of hitting the container twice.
///
/// Keyed by database URL so tests get their own state without touching the real Warp container.
final class WarpDatabaseAccessCache: @unchecked Sendable {
    static let shared = WarpDatabaseAccessCache()

    private struct Entry {
        var isDenied = false
        var copy: URL?
        var copiedAt: Date?
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    /// Whether macOS already refused this database. Callers must not touch the container again.
    func isDenied(_ databaseURL: URL) -> Bool {
        lock.withLock { entries[databaseURL]?.isDenied ?? false }
    }

    func markDenied(_ databaseURL: URL) {
        lock.withLock {
            var entry = entries[databaseURL] ?? Entry()
            entry.isDenied = true
            entry.copy = nil
            entry.copiedAt = nil
            entries[databaseURL] = entry
        }
    }

    /// A copy young enough to reuse, or `nil` if a fresh one is needed.
    func reusableCopy(for databaseURL: URL, now: Date, within window: TimeInterval) -> URL? {
        lock.withLock {
            guard let entry = entries[databaseURL], !entry.isDenied,
                  let copy = entry.copy, let copiedAt = entry.copiedAt,
                  now.timeIntervalSince(copiedAt) < window else { return nil }
            return copy
        }
    }

    /// Records a fresh copy and hands back the one it replaces, so the caller can delete it.
    func store(copy: URL, for databaseURL: URL, at date: Date) -> URL? {
        lock.withLock {
            var entry = entries[databaseURL] ?? Entry()
            let previous = entry.copy
            entry.isDenied = false
            entry.copy = copy
            entry.copiedAt = date
            entries[databaseURL] = entry
            return previous
        }
    }
}
