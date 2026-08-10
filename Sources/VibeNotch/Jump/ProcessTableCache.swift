import Foundation

/// The one process scan a refresh and a click share.
///
/// Scanning costs a `pgrep` plus a batched `lsof` and a batched `ps` — cheap for one pass, but
/// the store reconciles on every hook event and every jump used to rescan from scratch on the
/// main thread on top of that. Agent processes do not come and go inside two seconds, so a click
/// reuses the snapshot the store just took, and the next reconcile reuses the one the click took.
///
/// Thread-safe by design: the store reads it on the main actor while `Jumper` reads it on its
/// discovery queue. The lock is never held across the scan itself — two callers racing a cold
/// cache both scan, which is merely wasteful, whereas blocking the main thread behind someone
/// else's `lsof` is the exact stall this type exists to remove.
final class ProcessTableCache: @unchecked Sendable {
    static let shared = ProcessTableCache()

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let scan: @Sendable () -> [ClaudeProcess]
    private let lock = NSLock()
    private var cached: [ClaudeProcess] = []
    private var scannedAt: Date?

    init(
        ttl: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = { Date() },
        scan: @escaping @Sendable () -> [ClaudeProcess] = { TTYResolver().processes() }
    ) {
        self.ttl = ttl
        self.now = now
        self.scan = scan
    }

    func processes() -> [ClaudeProcess] {
        if let fresh = freshSnapshot() { return fresh }
        let scanned = scan()
        let scannedAt = now()
        lock.withLock {
            cached = scanned
            self.scannedAt = scannedAt
        }
        return scanned
    }

    private func freshSnapshot() -> [ClaudeProcess]? {
        lock.withLock {
            guard let scannedAt, now().timeIntervalSince(scannedAt) < ttl else { return nil }
            return cached
        }
    }
}
