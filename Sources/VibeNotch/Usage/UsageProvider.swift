import Combine
import Foundation

struct UsageWindow: Equatable, Sendable {
    let label: String
    let utilization: Double
    let resetsAt: Date

    var level: UsageLevel {
        if utilization < 50 { return .low }
        if utilization < 80 { return .medium }
        return .high
    }

    func resetText(from now: Date = Date()) -> String {
        let totalMinutes = max(0, Int(resetsAt.timeIntervalSince(now)) / 60)
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

enum UsageLevel: Equatable, Sendable {
    case low
    case medium
    case high
}

struct ProviderUsage: Equatable, Sendable {
    let provider: String
    let windows: [UsageWindow]
}

enum UsageSourceError: Error {
    case unavailable
    case httpStatus(Int)
}

protocol UsageSource {
    var name: String { get }
    func isAvailable() -> Bool
    func fetch() async throws -> ProviderUsage
}

protocol UsageTokenSource {
    func accessToken() -> String?
}

protocol UsageLoading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UsageLoading {}

// MARK: - Claude

enum CredentialParser {
    static func accessToken(from data: Data) throws -> String {
        let credentials = try JSONDecoder().decode(Credentials.self, from: data)
        guard !credentials.claudeAiOauth.accessToken.isEmpty else {
            throw CocoaError(.coderValueNotFound)
        }
        return credentials.claudeAiOauth.accessToken
    }

    private struct Credentials: Decodable {
        let claudeAiOauth: OAuth
    }

    private struct OAuth: Decodable {
        let accessToken: String
    }
}

struct RuntimeUsageTokenSource: UsageTokenSource {
    let credentialsURL: URL

    init(credentialsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")) {
        self.credentialsURL = credentialsURL
    }

    func accessToken() -> String? {
        if let data = securityOutput(), let token = try? CredentialParser.accessToken(from: data) {
            return token
        }
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return try? CredentialParser.accessToken(from: data)
    }

    private func securityOutput() -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

enum ClaudeUsageParser {
    static func parse(_ data: Data) throws -> ProviderUsage {
        let raw = try JSONDecoder().decode(RawClaudeUsage.self, from: data)
        return ProviderUsage(provider: "Claude", windows: [
            try raw.fiveHour.window(label: "5h"),
            try raw.sevenDay.window(label: "7d")
        ])
    }

    // The API sends fractional seconds ("...59.588521+00:00"), which a default
    // ISO8601DateFormatter can't parse — try with fractional seconds first, then without.
    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

struct ClaudeUsageSource: UsageSource {
    let name = "Claude"
    private let tokenSource: UsageTokenSource
    private let loader: UsageLoading

    init(tokenSource: UsageTokenSource = RuntimeUsageTokenSource(), loader: UsageLoading = URLSession.shared) {
        self.tokenSource = tokenSource
        self.loader = loader
    }

    func isAvailable() -> Bool {
        tokenSource.accessToken() != nil
    }

    func fetch() async throws -> ProviderUsage {
        guard let token = tokenSource.accessToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw UsageSourceError.unavailable
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw UsageSourceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try ClaudeUsageParser.parse(data)
    }
}

private struct RawClaudeUsage: Decodable {
    let fiveHour: RawClaudeWindow
    let sevenDay: RawClaudeWindow

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct RawClaudeWindow: Decodable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    func window(label: String) throws -> UsageWindow {
        guard let date = ClaudeUsageParser.parseDate(resetsAt) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return UsageWindow(label: label, utilization: utilization, resetsAt: date)
    }
}

// MARK: - Codex

struct CodexCredentials: Equatable {
    let accessToken: String
    let accountId: String
}

protocol CodexTokenSource {
    func credentials() -> CodexCredentials?
}

enum CodexCredentialParser {
    static func credentials(from data: Data) throws -> CodexCredentials {
        let raw = try JSONDecoder().decode(RawCodexAuth.self, from: data)
        guard !raw.tokens.accessToken.isEmpty, !raw.tokens.accountId.isEmpty else {
            throw CocoaError(.coderValueNotFound)
        }
        return CodexCredentials(accessToken: raw.tokens.accessToken, accountId: raw.tokens.accountId)
    }

    private struct RawCodexAuth: Decodable {
        let tokens: RawTokens
    }

    private struct RawTokens: Decodable {
        let accessToken: String
        let accountId: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }
}

struct RuntimeCodexTokenSource: CodexTokenSource {
    let authURL: URL

    init(authURL: URL = RuntimeCodexTokenSource.defaultAuthURL()) {
        self.authURL = authURL
    }

    static func defaultAuthURL() -> URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    func credentials() -> CodexCredentials? {
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        return try? CodexCredentialParser.credentials(from: data)
    }
}

enum CodexUsageParser {
    static func parse(_ data: Data) throws -> ProviderUsage {
        let raw = try JSONDecoder().decode(RawCodexUsage.self, from: data)
        var windows = [raw.rateLimit.primaryWindow.window]
        if let secondary = raw.rateLimit.secondaryWindow {
            windows.append(secondary.window)
        }
        return ProviderUsage(provider: "Codex", windows: windows)
    }
}

private struct RawCodexUsage: Decodable {
    let rateLimit: RawRateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private struct RawRateLimit: Decodable {
    let primaryWindow: RawCodexWindow
    let secondaryWindow: RawCodexWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct RawCodexWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    var window: UsageWindow {
        UsageWindow(
            label: Self.label(forSeconds: limitWindowSeconds),
            utilization: usedPercent,
            resetsAt: Date(timeIntervalSince1970: resetAt)
        )
    }

    static func label(forSeconds seconds: Int) -> String {
        switch seconds {
        case 18_000: return "5h"
        case 604_800: return "7d"
        default:
            if seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
            if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
            return "\(seconds)s"
        }
    }
}

struct CodexUsageSource: UsageSource {
    let name = "Codex"
    private let tokenSource: CodexTokenSource
    private let loader: UsageLoading

    init(tokenSource: CodexTokenSource = RuntimeCodexTokenSource(), loader: UsageLoading = URLSession.shared) {
        self.tokenSource = tokenSource
        self.loader = loader
    }

    func isAvailable() -> Bool {
        tokenSource.credentials() != nil
    }

    func fetch() async throws -> ProviderUsage {
        guard let credentials = tokenSource.credentials(),
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw UsageSourceError.unavailable
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "chatgpt-account-id")

        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw UsageSourceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try CodexUsageParser.parse(data)
    }
}

// MARK: - Aggregator

@MainActor
final class UsageProvider: ObservableObject {
    @Published private(set) var providers: [ProviderUsage] = []
    private var states: [SourceState]
    private let minFetchInterval: TimeInterval

    private struct SourceState {
        let source: UsageSource
        var lastGood: ProviderUsage?
        var lastFetchAt: Date?
    }

    init(
        sources: [UsageSource] = [ClaudeUsageSource(), CodexUsageSource()],
        minFetchInterval: TimeInterval = 90
    ) {
        self.states = sources.map { SourceState(source: $0, lastGood: nil, lastFetchAt: nil) }
        self.minFetchInterval = minFetchInterval
    }

    func showCached() {
        providers = states.compactMap(\.lastGood)
    }

    // User tapped "refresh": bypass the throttle and hit the network now, for every provider.
    func forceRefresh() async {
        for index in states.indices { states[index].lastFetchAt = nil }
        await refresh()
    }

    func refresh() async {
        for index in states.indices {
            await refreshSource(at: index)
        }
        providers = states.compactMap(\.lastGood)
    }

    private func refreshSource(at index: Int) async {
        // Hovering re-creates the panel and re-fires this on every expand; without a
        // floor, rapid hovers hammer the usage endpoints into 429. Serve cache within the window.
        if let last = states[index].lastFetchAt, Date().timeIntervalSince(last) < minFetchInterval {
            return
        }
        states[index].lastFetchAt = Date()

        guard states[index].source.isAvailable() else {
            // No credentials at all — this provider is simply absent, not an error.
            states[index].lastGood = nil
            return
        }

        do {
            states[index].lastGood = try await states[index].source.fetch()
        } catch {
            // Transient failure (429 rate-limit, 5xx, network error, etc.) — keep the
            // last good numbers for this provider instead of dropping it from the strip.
        }
    }
}
