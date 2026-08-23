import Foundation

// MARK: - Command running

/// Kiro publishes no usage API at all — the only way to its numbers is `kiro-cli`, so this
/// provider is a subprocess behind an injectable seam rather than a URL (#18).
protocol KiroCommandRunning: Sendable {
    /// Combined stdout+stderr, or nil when the command could not be spawned, failed, or outran
    /// `timeout`. Blocking: callers must already be off the main thread.
    func run(_ arguments: [String], timeout: TimeInterval) -> String?
}

struct RuntimeKiroCommandRunner: KiroCommandRunning {
    let executableURL: URL

    func run(_ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }

        // Drained on another thread: waiting for exit before reading deadlocks the moment the
        // child fills the pipe buffer, and reading to EOF on this thread would ignore the timeout
        // entirely — `/usage` is allowed twenty seconds and must not be able to take more.
        let output = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        if drained.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // Terminating closes the write end, so the reader unblocks; bounded so a wedged child
            // cannot pin this thread either.
            _ = drained.wait(timeout: .now() + 2)
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.get(), encoding: .utf8)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.withLock { data = value } }
        func get() -> Data { lock.withLock { data } }
    }
}

// MARK: - Parsing

struct KiroUsage: Equatable, Sendable {
    let plan: String?
    let usedCredits: Double?
    let totalCredits: Double?
    /// 0-100, used.
    let percentUsed: Double
    let resetsAt: Date
    /// Kiro heads its own output "Estimated Usage". When it says so, the strip must say so (#18).
    let isEstimate: Bool
}

enum KiroUsageParser {
    /// `kiro-cli` writes for a terminal: colour, bold, cursor moves. Everything the parser wants
    /// is plain text underneath.
    static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]") else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    /// Real captured shape (KIRO FREE, this machine):
    ///
    ///     Estimated Usage | resets on 2026-09-01 | KIRO FREE
    ///     Credits (0.00 of 50 covered in plan)
    ///     ███…███ 0%
    static func parse(_ raw: String, timeZone: TimeZone = .current) -> KiroUsage? {
        let text = stripANSI(raw)
        guard let resetsAt = resetDate(in: text, timeZone: timeZone) else { return nil }

        let used = capture(#"\(\s*([0-9][0-9,.]*)\s+of\s+([0-9][0-9,.]*)\s+covered in plan"#, in: text)
        let usedCredits = used.count == 2 ? number(used[0]) : nil
        let totalCredits = used.count == 2 ? number(used[1]) : nil

        // Prefer the exact ratio over the bar's rounded percentage; fall back to the bar when the
        // credits line is missing. With neither there is no honest number, so no row.
        let percentUsed: Double
        if let usedCredits, let totalCredits, totalCredits > 0 {
            percentUsed = min(100, max(0, usedCredits / totalCredits * 100.0))
        } else if let printed = capture(#"([0-9]+(?:\.[0-9]+)?)\s*%"#, in: text).first.flatMap(number) {
            percentUsed = min(100, max(0, printed))
        } else {
            return nil
        }

        return KiroUsage(
            plan: planName(in: text),
            usedCredits: usedCredits,
            totalCredits: totalCredits,
            percentUsed: percentUsed,
            resetsAt: resetsAt,
            // Data-driven, not assumed: a plan Kiro meters exactly would drop the word and the
            // strip would stop hedging on its own.
            isEstimate: text.localizedCaseInsensitiveContains("Estimated")
        )
    }

    static func providerUsage(from usage: KiroUsage) -> ProviderUsage {
        ProviderUsage(
            provider: "Kiro",
            windows: [UsageWindow(
                label: "mo",
                utilization: usage.percentUsed,
                resetsAt: usage.resetsAt,
                isEstimate: usage.isEstimate
            )],
            detail: detail(from: usage)
        )
    }

    /// The tail of the header line: "Estimated Usage | resets on … | KIRO FREE".
    static func planName(in text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("resets on") }) else { return nil }
        let segments = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = segments.last, segments.count > 1, !last.isEmpty, !last.contains("resets on") else {
            return nil
        }
        return last
    }

    private static func detail(from usage: KiroUsage) -> String? {
        var parts: [String] = []
        if let plan = usage.plan { parts.append(plan) }
        if let used = usage.usedCredits, let total = usage.totalCredits {
            parts.append("\(compact(used))/\(compact(total))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func compact(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static func resetDate(in text: String, timeZone: TimeZone) -> Date? {
        guard let stamp = capture(#"resets on\s+(\d{4}-\d{2}-\d{2})"#, in: text).first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Kiro prints a bare calendar date, so it can only mean local midnight. The countdown is
        // days long; the hours of slack that timezone guess costs never show.
        formatter.timeZone = timeZone
        return formatter.date(from: stamp)
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    /// Every capture group of the first match, in order.
    private static func capture(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return []
        }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Source

/// Kiro quota, read by driving `kiro-cli`.
///
/// Everything else on the strip is one HTTP call; this is a subprocess that CodexBar allows twenty
/// seconds. So it keeps its own cache with its own, much longer, interval — asking Kiro every time
/// the user hovers the notch would spawn a process per hover — and every blocking call is pushed
/// off the caller's thread. The aggregator refreshes sources concurrently (#18), so however long
/// this takes, the Claude and Codex rows render without it.
final class KiroUsageSource: UsageSource, @unchecked Sendable {
    let name = "Kiro"

    /// CodexBar's timeouts, kept as-is: `/usage` really can take the best part of twenty seconds.
    static let whoamiTimeout: TimeInterval = 3
    static let usageTimeout: TimeInterval = 20

    private let runner: KiroCommandRunning?
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var confirmedLogin = false
    private var cached: ProviderUsage?
    private var cachedAt: Date?

    private static let queue = DispatchQueue(label: "com.agentperch.usage-kiro", qos: .utility)

    init(
        runner: KiroCommandRunning? = KiroUsageSource.installedRunner(),
        ttl: TimeInterval = 10 * 60.0,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.ttl = ttl
        self.now = now
    }

    func isAvailable() -> Bool { runner != nil }

    func availability() async -> UsageAvailability {
        guard let runner else { return .notConfigured }
        if lock.withLock({ confirmedLogin }) { return .ready }

        guard let whoami = await Self.offCallerThread({ runner.run(["whoami"], timeout: Self.whoamiTimeout) }) else {
            return .unavailable("kiro-cli not responding")
        }
        // Signed out is credentials that do not exist — the same state as never having used Kiro,
        // so the row is omitted rather than shown as an error. Not memoized: signing in later
        // brings it back on its own, exactly like the Claude path.
        let lowered = whoami.lowercased()
        if lowered.contains("not logged in") || lowered.contains("logged out") { return .notConfigured }
        // Anything else is treated as signed in and left for `/usage` to judge: an unrecognised
        // whoami must not silently delete a provider the user does have (#28).
        lock.withLock { confirmedLogin = true }
        return .ready
    }

    func prepareForRetry() {
        lock.withLock {
            confirmedLogin = false
            cached = nil
            cachedAt = nil
        }
    }

    func fetch() async throws -> ProviderUsage {
        if let fresh = lock.withLock({ () -> ProviderUsage? in
            guard let cached, let cachedAt, now().timeIntervalSince(cachedAt) < ttl else { return nil }
            return cached
        }) { return fresh }

        guard let runner else { throw UsageSourceError.unavailable }
        guard let output = await Self.offCallerThread({
            runner.run(["chat", "--no-interactive", "/usage"], timeout: Self.usageTimeout)
        }) else { throw UsageSourceError.unavailable }
        guard let parsed = KiroUsageParser.parse(output) else { throw UsageSourceError.unavailable }

        let usage = KiroUsageParser.providerUsage(from: parsed)
        lock.withLock {
            cached = usage
            cachedAt = now()
        }
        return usage
    }

    static func installedRunner(fileManager: FileManager = .default) -> KiroCommandRunning? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/kiro-cli"),
            URL(fileURLWithPath: "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"),
            URL(fileURLWithPath: "/opt/homebrew/bin/kiro-cli"),
            URL(fileURLWithPath: "/usr/local/bin/kiro-cli")
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
            .map { RuntimeKiroCommandRunner(executableURL: $0) }
    }

    private static func offCallerThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
