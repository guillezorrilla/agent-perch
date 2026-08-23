import Foundation

// MARK: - Discovery

/// A live Antigravity language server: the loopback port it answers on and the CSRF token it was
/// launched with. Both are per-launch values — the port is whatever the OS handed out and the
/// token is a fresh UUID in the process's own argv — so both are discovered every time and
/// neither is ever configured or hard-coded (#18).
struct AntigravityEndpoint: Equatable, Sendable {
    let port: Int
    let csrfToken: String
}

/// Turns `ps` and `lsof` text into candidate endpoints. Pure, so the whole discovery path is
/// testable against captured output without Antigravity running.
enum AntigravityProcessScan {
    /// Full argv, unwrapped and untruncated — the CSRF token sits several flags in.
    static let psArguments = ["-Aww", "-o", "pid=,args="]
    static let lsofArguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]

    /// More than one language server runs at once (one per open workspace, plus a bare one). They
    /// all answer for the same account, so any that responds is as good as another — but a given
    /// process listens on several ports and only one speaks Connect, hence a candidate *list* that
    /// `AntigravityUsageSource` walks until one answers.
    static func endpointCandidates(psOutput: String, lsofOutput: String, limit: Int = 12) -> [AntigravityEndpoint] {
        let ports = listeningPorts(lsofOutput: lsofOutput)
        let candidates = csrfTokens(psOutput: psOutput).flatMap { process in
            (ports[process.pid] ?? []).map { AntigravityEndpoint(port: $0, csrfToken: process.token) }
        }
        return Array(candidates.prefix(limit))
    }

    /// Matches on the executable PATH, never the process name: Antigravity's own main process is
    /// named plain `Electron`, which is why this repo's first attempt at finding it found nothing
    /// (#27). `isAntigravityExecutable` requires the bundle as a whole path component, so an
    /// unrelated Electron app cannot match.
    static func csrfTokens(psOutput: String) -> [(pid: Int32, token: String)] {
        psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[trimmed.startIndex..<space]) else { return nil }
            let args = String(trimmed[trimmed.index(after: space)...])
            guard AntigravityProcessCheck.isAntigravityExecutable(args) else { return nil }
            // The extension server's token is a genuine fallback: some launches carry only it.
            guard let token = flagValue("--csrf_token", in: args)
                ?? flagValue("--extension_server_csrf_token", in: args) else { return nil }
            return (pid, token)
        }
    }

    /// Whole-field match, so asking for `--csrf_token` can never come back with
    /// `--extension_server_csrf_token`'s value.
    static func flagValue(_ flag: String, in args: String) -> String? {
        let fields = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let index = fields.firstIndex(of: flag), index + 1 < fields.count else { return nil }
        let value = fields[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    /// One batched `lsof` for every process, indexed by pid.
    static func listeningPorts(lsofOutput: String) -> [Int32: [Int]] {
        var ports: [Int32: [Int]] = [:]
        for line in lsofOutput.split(separator: "\n") where line.contains("(LISTEN)") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 1, let pid = Int32(fields[1]) else { continue }
            // Loopback only. A `*:PORT` row is the same server bound on every interface, and a
            // CSRF token must never leave this machine.
            guard let address = fields.first(where: { $0.hasPrefix("127.0.0.1:") }),
                  let port = Int(address.dropFirst("127.0.0.1:".count)) else { continue }
            ports[pid, default: []].append(port)
        }
        return ports
    }
}

/// Antigravity's language server serves HTTPS on 127.0.0.1 with a self-signed certificate, so the
/// system's trust evaluation rejects it outright and no amount of retrying helps.
///
/// This accepts that certificate — and only ever for host `127.0.0.1`. Anything with a routable
/// host, including a DNS name that happens to resolve to loopback, falls through to default
/// handling, so nothing off this machine can reach the exception (#18).
final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// The `UsageLoading` that speaks to that server. Short timeouts because a wrong candidate port
/// must cost the strip a moment, not a refresh cycle.
final class LoopbackTrustingLoader: UsageLoading, @unchecked Sendable {
    private let session: URLSession

    init(timeout: TimeInterval = 4) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        // URLSession retains its delegate, and the delegate holds nothing back — no cycle.
        session = URLSession(configuration: configuration, delegate: LoopbackTrustDelegate(), delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - Parsing

enum AntigravityQuotaParser {
    static func parse(_ data: Data) throws -> ProviderUsage {
        let decoder = JSONDecoder()
        // The live server wraps everything in `response`; the recipe this was built from described
        // the bare `groups[]` shape. Accept both rather than betting on either (#18).
        let summary: RawAntigravitySummary
        if let envelope = try? decoder.decode(RawAntigravityEnvelope.self, from: data),
           let inner = envelope.response {
            summary = inner
        } else {
            summary = try decoder.decode(RawAntigravitySummary.self, from: data)
        }

        let windows = summary.groups.flatMap { group in
            group.buckets.compactMap { $0.usageWindow(groupDisplayName: group.displayName) }
        }
        // Zero usable buckets is not "0% used" — it is no answer, and inventing a number here is
        // exactly what #18 forbids.
        guard !windows.isEmpty else { throw UsageSourceError.unavailable }
        return ProviderUsage(provider: "Antigravity", windows: windows)
    }

    static func label(group: String?, bucketId: String?, window: String?) -> String {
        [groupLabel(group: group, bucketId: bucketId), windowLabel(window)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Four buckets have to share one strip row with their percentages and reset times, so the
    /// family name is abbreviated hard. The two bucket-id prefixes Antigravity ships today are
    /// spelled out; anything new falls back to a truncated display name so a new family shows up
    /// with a rough label rather than being dropped.
    static func groupLabel(group: String?, bucketId: String?) -> String {
        switch bucketId?.split(separator: "-").first.map(String.init) {
        case "gemini": return "Gem"
        case "3p": return "C/GPT"
        default: break
        }
        guard let group else { return "" }
        let noise: Set<String> = ["models", "model", "and", "limit", "remaining"]
        let joined = group.split(separator: " ")
            .map(String.init)
            .filter { !noise.contains($0.lowercased()) }
            .joined(separator: "/")
        return joined.count <= 6 ? joined : String(joined.prefix(6))
    }

    /// The bucket's own `window` field, in the strip's existing vocabulary.
    static func windowLabel(_ window: String?) -> String {
        switch window?.lowercased() {
        case "weekly": return "7d"
        case "daily": return "1d"
        case "monthly": return "30d"
        case .some(let raw) where !raw.isEmpty: return raw
        default: return ""
        }
    }
}

private struct RawAntigravityEnvelope: Decodable {
    let response: RawAntigravitySummary?
}

private struct RawAntigravitySummary: Decodable {
    let groups: [RawAntigravityGroup]
}

private struct RawAntigravityGroup: Decodable {
    let displayName: String?
    let buckets: [RawAntigravityBucket]
}

private struct RawAntigravityBucket: Decodable {
    let bucketId: String?
    let window: String?
    /// 0-1, and it is what is LEFT, not what is spent.
    let remainingFraction: Double?
    let resetTime: String?
    /// The bucket's own `displayName` ("Weekly Limit Remaining") is far too long for the strip, so
    /// the label is built from the group plus `window` instead — see `AntigravityQuotaParser.label`.
    let disabled: Bool?
    /// The reference UI shows "88% left · 75% in reserve", but Antigravity IDE 1.107.0 sends no
    /// such field — its language server's protobuf carries `remaining_fraction` and nothing
    /// reserve-shaped at all. Decoded anyway so a server that starts sending it lights the figure
    /// up without a model change; nil, and therefore unrendered, today (#18).
    let reserveFraction: Double?

    func usageWindow(groupDisplayName: String?) -> UsageWindow? {
        guard disabled != true,
              let remainingFraction,
              let resetTime,
              let resetsAt = ClaudeUsageParser.parseDate(resetTime) else { return nil }
        return UsageWindow(
            label: AntigravityQuotaParser.label(group: groupDisplayName, bucketId: bucketId, window: window),
            utilization: Self.percent(used: 1 - remainingFraction),
            resetsAt: resetsAt,
            reserve: reserveFraction.map { Self.percent(used: $0) }
        )
    }

    private static func percent(used fraction: Double) -> Double {
        min(100, max(0, fraction * 100.0))
    }
}

// MARK: - Source

/// Antigravity quota, read from the IDE's own language server over loopback.
///
/// A class rather than a struct because it caches the one endpoint that answered: discovery costs
/// a `ps` plus an `lsof`, and the strip refreshes on every hover. A cached endpoint that stops
/// answering is dropped so the next pass rediscovers — that is what a relaunched IDE on a new port
/// looks like from here (#18).
final class AntigravityUsageSource: UsageSource, @unchecked Sendable {
    let name = "Antigravity"

    private let loader: UsageLoading
    private let isInstalled: @Sendable () -> Bool
    private let discover: @Sendable () -> [AntigravityEndpoint]
    private let lock = NSLock()
    private var cachedEndpoint: AntigravityEndpoint?
    private var candidates: [AntigravityEndpoint] = []

    /// `ps` and `lsof` are subprocess spawns; nothing here may run on the caller's thread.
    private static let queue = DispatchQueue(label: "com.agentperch.usage-antigravity", qos: .utility)

    init(
        loader: UsageLoading = LoopbackTrustingLoader(),
        isInstalled: @escaping @Sendable () -> Bool = { AntigravityUsageSource.installedOnDisk() },
        discover: @escaping @Sendable () -> [AntigravityEndpoint] = { AntigravityUsageSource.liveEndpoints() }
    ) {
        self.loader = loader
        self.isInstalled = isInstalled
        self.discover = discover
    }

    func isAvailable() -> Bool {
        lock.withLock { cachedEndpoint != nil } || isInstalled()
    }

    func availability() async -> UsageAvailability {
        if lock.withLock({ cachedEndpoint != nil }) { return .ready }
        // Not installed is the only state that removes the row: it means this machine simply does
        // not do Antigravity. Installed-but-not-running is a visible, retryable row (#28).
        guard isInstalled() else { return .notConfigured }

        let discovered = await Self.offCallerThread(discover)
        lock.withLock { candidates = discovered }
        return discovered.isEmpty ? .unavailable("Antigravity not running") : .ready
    }

    func prepareForRetry() {
        lock.withLock {
            cachedEndpoint = nil
            candidates = []
        }
    }

    func fetch() async throws -> ProviderUsage {
        let known: [AntigravityEndpoint] = lock.withLock {
            guard let cachedEndpoint else { return candidates }
            return [cachedEndpoint] + candidates.filter { $0 != cachedEndpoint }
        }
        let endpoints = known.isEmpty ? await Self.offCallerThread(discover) : known

        for endpoint in endpoints {
            guard let usage = try? await requestQuota(from: endpoint) else { continue }
            lock.withLock { cachedEndpoint = endpoint }
            return usage
        }

        // Nothing answered: forget the cache so the next pass rediscovers instead of hammering a
        // port the IDE gave up when it relaunched.
        prepareForRetry()
        throw UsageSourceError.unavailable
    }

    private func requestQuota(from endpoint: AntigravityEndpoint) async throws -> ProviderUsage {
        guard let url = URL(
            string: "https://127.0.0.1:\(endpoint.port)"
                + "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        ) else { throw UsageSourceError.unavailable }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw UsageSourceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try AntigravityQuotaParser.parse(data)
    }

    static func installedOnDisk(fileManager: FileManager = .default) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser
        let paths = [
            URL(fileURLWithPath: "/Applications/Antigravity IDE.app"),
            URL(fileURLWithPath: "/Applications/Antigravity.app"),
            home.appendingPathComponent("Applications/Antigravity IDE.app"),
            home.appendingPathComponent(".antigravity-ide"),
            home.appendingPathComponent(".antigravity")
        ]
        return paths.contains { fileManager.fileExists(atPath: $0.path) }
    }

    static func liveEndpoints() -> [AntigravityEndpoint] {
        guard let ps = TTYResolver.output("/bin/ps", AntigravityProcessScan.psArguments) else { return [] }
        // `lsof` routinely exits non-zero when it cannot stat some other user's fds, with the rows
        // we want already printed — so keep the partial output.
        guard let lsof = TTYResolver.output(
            "/usr/sbin/lsof",
            AntigravityProcessScan.lsofArguments,
            keepingPartialOutput: true
        ) else { return [] }
        return AntigravityProcessScan.endpointCandidates(psOutput: ps, lsofOutput: lsof)
    }

    private static func offCallerThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
