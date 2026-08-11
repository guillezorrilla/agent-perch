import Foundation

/// The one process scan a refresh and a click share.
///
/// Scanning costs a `pgrep` plus a batched `lsof` and a batched `ps` — cheap for one pass, but
/// the store reconciles on every hook event and every jump used to rescan from scratch on the
/// main thread on top of that. Agent processes do not come and go inside two seconds, so a click
/// reuses the snapshot the store just took, and the next reconcile reuses the one the click took.
///
/// Thread-safe by design: the store reads it on the main actor while `Jumper` reads it on the
/// discovery queue. The lock is never held across the scan itself — two callers racing a cold
/// cache both scan, which is merely wasteful, whereas blocking the main thread behind someone
/// else's `lsof` is the exact stall this type exists to remove. The main actor never scans at all
/// any more: it reads `cachedProcesses()`, which hands back what it has and rescans in the
/// background (#32).
final class ProcessTableCache: @unchecked Sendable {
    static let shared = ProcessTableCache()

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let scan: @Sendable () -> [ClaudeProcess]
    private let lock = NSLock()
    private var cached: [ClaudeProcess] = []
    private var scannedAt: Date?
    private var isScanning = false
    private var refreshHandler: (@Sendable () -> Void)?
    /// Its own serial queue rather than `DiscoveryQueue`: a periodic rescan must never queue up
    /// behind a click's Warp database read, and two `lsof` runs at once is exactly what the lock
    /// below is arranged to avoid.
    private let queue = DispatchQueue(label: "dev.vibenotch.process.scan", qos: .utility)

    init(
        ttl: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = { Date() },
        scan: @escaping @Sendable () -> [ClaudeProcess] = { TTYResolver().processes() }
    ) {
        self.ttl = ttl
        self.now = now
        self.scan = scan
    }

    /// Called after a background rescan replaces the snapshot, so whoever built a UI from the
    /// older one can rebuild it. Set once, by the app; nil in tests, which drive their own tables.
    func onRefresh(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { refreshHandler = handler }
    }

    /// The blocking read: scans on the caller's thread when the snapshot has aged out. Only for
    /// callers already off the main actor — everything the main actor touches goes through
    /// `cachedProcesses()`.
    func processes() -> [ClaudeProcess] {
        if let fresh = freshSnapshot() { return fresh }
        return publish(scan())
    }

    /// The non-blocking read: the snapshot we already have — empty until the first scan lands —
    /// with a rescan kicked off in the background whenever it has aged out.
    ///
    /// This is what the main actor calls. `SessionStore` reconciles on every hook event and every
    /// file change, and a `pgrep` plus two batched `lsof`/`ps` runs behind each of those is the
    /// same main-thread stall the answer path used to pay for (#32) — just spread thinner.
    func cachedProcesses() -> [ClaudeProcess] {
        if let fresh = freshSnapshot() { return fresh }
        scheduleScan()
        return lock.withLock { cached }
    }

    private func scheduleScan() {
        let shouldScan: Bool = lock.withLock {
            guard !isScanning else { return false }
            isScanning = true
            return true
        }
        guard shouldScan else { return }

        queue.async { [self] in
            let scanned = scan()
            _ = publish(scanned)
            let handler: (@Sendable () -> Void)? = lock.withLock {
                isScanning = false
                return refreshHandler
            }
            handler?()
        }
    }

    @discardableResult
    private func publish(_ scanned: [ClaudeProcess]) -> [ClaudeProcess] {
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
