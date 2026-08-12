import Combine
import Foundation
import Security
import os

struct UsageWindow: Equatable, Sendable {
    /// Free text, not a fixed 5h/7d pair: Antigravity meters four buckets across two model
    /// families and labels each one itself ("Gem 5h", "C/GPT 7d") (#18).
    let label: String
    /// Percent USED, 0-100. Providers that report what is LEFT (Antigravity, Gemini both send a
    /// `remainingFraction`) are converted in their parser, so every window on the strip means the
    /// same thing.
    let utilization: Double
    let resetsAt: Date
    /// A separate pool held back beyond the main bucket, which the reference UI renders as
    /// "88% left · 75% in reserve". Optional because no provider wired here actually sends it:
    /// Antigravity IDE 1.107.0's `RetrieveUserQuotaSummary` has no such field (verified against
    /// the language server's own protobuf tags), so this is nil in practice today (#18).
    let reserve: Double?
    /// The provider itself says this number is an estimate rather than metered quota — Kiro
    /// prints a literal "Estimated Usage" header. The strip must mark it, never pass it off as
    /// real remaining quota (#18).
    let isEstimate: Bool

    /// Defaulted so every existing Claude/Codex call site — which has neither a reserve nor an
    /// estimate — is unchanged. A `let` with an inline default would be dropped from the
    /// memberwise initializer entirely, hence the explicit one.
    init(
        label: String,
        utilization: Double,
        resetsAt: Date,
        reserve: Double? = nil,
        isEstimate: Bool = false
    ) {
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.reserve = reserve
        self.isEstimate = isEstimate
    }

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
    /// The plan or tier exactly as the provider names it ("KIRO FREE"). nil when it doesn't say —
    /// Antigravity's quota summary carries no tier field at all (#18).
    let detail: String?

    init(provider: String, windows: [UsageWindow], detail: String? = nil) {
        self.provider = provider
        self.windows = windows
        self.detail = detail
    }
}

enum UsageSourceError: Error {
    case unavailable
    case httpStatus(Int)
}

/// The three things a provider can be, replacing a binary available/absent that could not tell
/// "your credentials could not be read" apart from "you don't use this provider" — both rendered
/// as nothing at all, so the Claude row simply vanished with no explanation and no way to retry
/// (#28).
enum UsageAvailability: Equatable, Sendable {
    /// Credentials in hand; fetch away.
    case ready
    /// Credentials exist but could not be read right now. The row stays on screen saying so, and
    /// the strip's refresh button is its retry.
    case unavailable(String)
    /// Nothing configured for this provider on this machine — omit it entirely.
    case notConfigured
}

/// One line of the usage strip: either real numbers or a visible admission that they could not be
/// had. A provider is only ever *dropped* from this list when it is genuinely not configured.
enum UsageRow: Equatable, Identifiable, Sendable {
    case usage(ProviderUsage)
    case unavailable(provider: String, detail: String)

    var id: String { provider }

    var provider: String {
        switch self {
        case .usage(let usage): return usage.provider
        case .unavailable(let provider, _): return provider
        }
    }
}

/// `Sendable` because the aggregator now refreshes every source concurrently (#18) — see
/// `UsageProvider.refresh()`.
protocol UsageSource: Sendable {
    var name: String { get }
    /// Cheap, synchronous, side-effect-free: "do I already hold what I need?". Called on every
    /// refresh, so it must never spawn work — see `ClaudeUsageSource.isAvailable()`.
    func isAvailable() -> Bool
    /// The real answer, allowed to do work (and, for the keychain, to block on a system prompt).
    func availability() async -> UsageAvailability
    /// The user asked again — forget any memoized refusal so the next read can genuinely re-try.
    func prepareForRetry()
    func fetch() async throws -> ProviderUsage
}

extension UsageSource {
    func availability() async -> UsageAvailability {
        isAvailable() ? .ready : .notConfigured
    }

    func prepareForRetry() {}
}

enum UsageTokenReadResult: Equatable, Sendable {
    case token(String)
    /// Credentials exist, but this read could not produce a usable token.
    case unreadable(String)
    case notConfigured
}

protocol UsageTokenSource: Sendable {
    /// Cache-only. Never spawns a read, never raises a keychain prompt.
    func accessToken() -> String?
    func read() async -> UsageTokenReadResult
    func retryAfterFailure()
}

extension UsageTokenSource {
    func read() async -> UsageTokenReadResult {
        guard let token = accessToken() else { return .notConfigured }
        return .token(token)
    }

    func retryAfterFailure() {}
}

protocol UsageLoading: Sendable {
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

/// What an `OSStatus` from `SecItemCopyMatching` means for us. Split out as a pure function so the
/// branch mapping is testable without ever touching a real keychain.
enum KeychainReadOutcome: Equatable, Sendable {
    /// The item came back.
    case success
    /// The user said no, or there was no way to ask. A visible error row with a working retry —
    /// never a silent disappearance, and never an immediate re-prompt.
    case declined
    /// No such item. Fall through to the `security` CLI, then the credentials file.
    case notFound
    /// Something else went wrong; worth exactly one more try.
    case failed

    static func of(_ status: OSStatus) -> KeychainReadOutcome {
        switch status {
        case errSecSuccess: return .success
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .declined
        case errSecItemNotFound: return .notFound
        default: return .failed
        }
    }
}

/// The native, in-process keychain read.
///
/// This used to shell out to `/usr/bin/security`, which makes the *security binary* the process
/// asking for the item rather than VibeNotch. Spawned from a GUI app with no TTY that read can be
/// refused outright instead of prompting, and its failure was indistinguishable from "no
/// credentials" — which is how the Claude row came to vanish silently (#28). Asking in-process
/// means macOS shows the ordinary "VibeNotch wants to access key … in your keychain" dialog with
/// Allow / Always Allow, and the grant sticks, because the app is signed with a stable identity.
///
/// `kSecUseAuthenticationUI` is deliberately NOT set: the prompt appearing is the point.
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"

    static func read() -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    /// Second chance, only ever reached on `errSecItemNotFound`: some installs keep the item under
    /// attributes this query doesn't reproduce, and the CLI finds those.
    static func securityCLI() -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// Reads Claude Code's OAuth credentials, in this order: the native keychain API, then the
/// `security` CLI, then `~/.claude/.credentials.json` — the last two only when the keychain says
/// the item simply isn't there.
///
/// A class, not a struct, because it owns two pieces of process-lifetime state that exist purely
/// so one bad read cannot cost the user their usage row:
/// - `cachedToken`: once a token has been read, it is the answer for the rest of the process. No
///   later failure can turn a working provider into an absent one, and `accessToken()` (called on
///   every refresh) answers from it without work and without re-prompting.
/// - `declined`: a refusal is remembered so a refresh loop cannot re-raise the system dialog over
///   and over. The user's own retry — the strip's refresh button — clears it deliberately.
///
/// Reads run on a serial queue off the main thread: one may sit on a modal keychain dialog for as
/// long as the user takes, and only ONE is ever in flight; a read that queued behind another finds
/// the cache (or the refusal) already filled in and returns without asking a second time.
final class RuntimeUsageTokenSource: UsageTokenSource, @unchecked Sendable {
    let credentialsURL: URL
    private let keychainRead: () -> (status: OSStatus, data: Data?)
    private let securityCLIRead: () -> Data?
    private let logger = Logger(subsystem: "com.vibenotch", category: "usage-credentials")
    private let queue = DispatchQueue(label: "com.vibenotch.usage-credentials")
    private let lock = NSLock()
    private var cachedToken: String?
    private var declined: String?

    init(
        credentialsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json"),
        keychainRead: @escaping () -> (status: OSStatus, data: Data?) = ClaudeKeychain.read,
        securityCLIRead: @escaping () -> Data? = ClaudeKeychain.securityCLI
    ) {
        self.credentialsURL = credentialsURL
        self.keychainRead = keychainRead
        self.securityCLIRead = securityCLIRead
    }

    func accessToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedToken
    }

    func read() async -> UsageTokenReadResult {
        if let memoized = memoizedResult() { return memoized }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readNow()) }
        }
    }

    func retryAfterFailure() {
        lock.lock()
        declined = nil
        lock.unlock()
    }

    private func memoizedResult() -> UsageTokenReadResult? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedToken { return .token(cachedToken) }
        if let declined { return .unreadable(declined) }
        return nil
    }

    private func readNow() -> UsageTokenReadResult {
        // A read that queued behind another already has its answer.
        if let memoized = memoizedResult() { return memoized }

        let (result, memoize) = resolve()
        lock.lock()
        switch result {
        case .token(let token):
            cachedToken = token
            declined = nil
        case .unreadable(let detail):
            if memoize { declined = detail }
        case .notConfigured:
            // Cheap and non-interactive to re-check, so it is not memoized: signing into Claude
            // Code later brings the row back on its own.
            break
        }
        lock.unlock()
        return result
    }

    /// The read, plus whether its answer is worth REMEMBERING for the rest of the process.
    ///
    /// Only a refusal earns the memo. A refusal is about the user's decision, which will not change
    /// on its own, and re-asking would raise the system dialog on every refresh — that is what
    /// `declined` exists to stop. A `.failed` read is the opposite: it is about the machine's
    /// circumstances at one instant, and it clears by itself.
    ///
    /// That distinction is not academic. The real failure was OSStatus -60008 (`errAuthorizationInternal`)
    /// followed by -25320 (`errSecInDarkWake`, "in dark wake, no UI possible") five milliseconds
    /// later: the keychain needed to ask the user and the machine had no way to draw the dialog.
    /// Both land in `.failed`, both attempts fall inside the same unwakeable instant, and the strip
    /// then showed "Claude · keychain unavailable" until the user pressed refresh by hand — for a
    /// condition that had cured itself the moment the display came back.
    private func resolve() -> (result: UsageTokenReadResult, memoize: Bool) {
        // Retried once: a single transient failure must never be enough to drop the provider.
        for attempt in 1...2 {
            let (status, data) = keychainRead()
            switch KeychainReadOutcome.of(status) {
            case .success:
                if let data, let token = try? CredentialParser.accessToken(from: data) {
                    return (.token(token), true)
                }
                logger.error("keychain item read but unusable (OSStatus \(status, privacy: .public))")
                // The grant is in hand and the item is simply not what we expect; re-reading it is
                // non-interactive but will keep saying the same thing until the file changes.
                return (.unreadable("credentials unreadable"), true)
            case .declined:
                logger.error("keychain read declined (OSStatus \(status, privacy: .public))")
                return (.unreadable("keychain access denied"), true)
            case .notFound:
                return (fallback(), true)
            case .failed:
                logger.error(
                    "keychain read failed (OSStatus \(status, privacy: .public), attempt \(attempt, privacy: .public))"
                )
            }
        }
        // Deliberately NOT memoized. The row still shows the error, so the failure stays visible,
        // but the next refresh genuinely re-reads instead of replaying this one bad moment forever.
        return (.unreadable("keychain unavailable"), false)
    }

    private func fallback() -> UsageTokenReadResult {
        if let data = securityCLIRead(), let token = try? CredentialParser.accessToken(from: data) {
            return .token(token)
        }
        if let data = try? Data(contentsOf: credentialsURL),
           let token = try? CredentialParser.accessToken(from: data) {
            return .token(token)
        }
        return .notConfigured
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

    /// Cache-only and instant. Every refresh calls this, so it must not spawn a keychain read or
    /// re-raise the prompt; `availability()` is where the reading actually happens.
    func isAvailable() -> Bool {
        tokenSource.accessToken() != nil
    }

    func availability() async -> UsageAvailability {
        switch await tokenSource.read() {
        case .token: return .ready
        case .unreadable(let detail): return .unavailable(detail)
        case .notConfigured: return .notConfigured
        }
    }

    func prepareForRetry() {
        tokenSource.retryAfterFailure()
    }

    func fetch() async throws -> ProviderUsage {
        guard case .token(let token) = await tokenSource.read(),
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

protocol CodexTokenSource: Sendable {
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

// MARK: - Row visibility (#39)

/// Which usage rows the user has switched off, kept as ONE defaults key holding the whole set
/// rather than a `Bool` per provider. The settings layer then hard-codes no provider list at all:
/// it renders a toggle per *registered* `UsageSource`, so a sixth provider gets its toggle for
/// free instead of needing a code change in three places.
///
/// The set stored is the HIDDEN one, never the shown one, for two reasons: the default — an empty
/// string — means "show everything", so existing installs see exactly what they saw before; and a
/// provider added later appears on its own rather than being born invisible because nobody had
/// ticked a box that did not exist yet.
enum UsageVisibility {
    /// `UsageProvider` reads this straight from `UserDefaults.standard` and `AppSettings` writes
    /// it through `@AppStorage`, which is backed by that same store — the same trick
    /// `showSubAgentSessions` uses, and the reason nothing has to be plumbed from Settings down
    /// to the fetch.
    static let hiddenKey = "hiddenUsageProviders"

    /// Commas separate, which keeps the value legible in `defaults read`; the one character a
    /// `UsageSource.name` may therefore not contain is a comma, and none does. Empty and
    /// whitespace-only fragments are dropped so a hand-edited "" or ",," reads as "nothing
    /// hidden" instead of hiding a nameless row.
    static func decode(_ raw: String) -> Set<String> {
        Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    /// Sorted, so hiding A then B stores the same string as hiding B then A — which is what lets
    /// the setter recognize a no-op write and skip the change notification.
    static func encode(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: ",")
    }

    static func hidden(in defaults: UserDefaults = .standard) -> Set<String> {
        decode(defaults.string(forKey: hiddenKey) ?? "")
    }
}

// MARK: - Aggregator

@MainActor
final class UsageProvider: ObservableObject {
    /// What the strip renders. A provider leaves this list only when it is genuinely not
    /// configured; everything else — unreadable credentials, a 429, a dead network — becomes a
    /// visible row rather than a silent absence (#28).
    @Published private(set) var rows: [UsageRow] = []

    /// Just the rows that carry real numbers.
    var providers: [ProviderUsage] {
        rows.compactMap { row -> ProviderUsage? in
            guard case .usage(let usage) = row else { return nil }
            return usage
        }
    }

    private var states: [SourceState]
    private let minFetchInterval: TimeInterval
    /// Read on every refresh and every publish rather than captured once, so a toggle flipped in
    /// Settings is honoured by the very next pass (#39).
    private let hiddenProviders: () -> Set<String>

    /// Every source wired in, in strip order. Settings renders one toggle per entry — this is the
    /// whole reason the provider list stays here and not in the settings layer (#39).
    var registeredProviders: [String] { states.map(\.source.name) }

    /// Nothing to show and nothing to say: every registered provider switched off. The strip then
    /// renders nothing at all, rather than its "usage unavailable" box — that box is an admission
    /// of failure, and a deliberate choice is not one (#39).
    var allProvidersHidden: Bool {
        let hidden = hiddenProviders()
        return !states.isEmpty && states.allSatisfy { hidden.contains($0.source.name) }
    }

    private struct SourceState {
        let source: UsageSource
        var lastGood: ProviderUsage?
        var lastFetchAt: Date?
        /// What to say when there are no numbers to show. Cleared by any successful fetch.
        var problem: String?
        /// False only when the provider is genuinely not set up on this machine.
        var configured = true
    }

    init(
        sources: [UsageSource] = [
            ClaudeUsageSource(),
            CodexUsageSource(),
            AntigravityUsageSource(),
            KiroUsageSource(),
            GeminiUsageSource()
        ],
        minFetchInterval: TimeInterval = 90,
        hiddenProviders: @escaping () -> Set<String> = { UsageVisibility.hidden() }
    ) {
        self.states = sources.map { SourceState(source: $0, lastGood: nil, lastFetchAt: nil) }
        self.minFetchInterval = minFetchInterval
        self.hiddenProviders = hiddenProviders
    }

    func showCached() {
        publish()
    }

    /// Settings changed which rows the user wants. Re-publish at once so the strip follows the
    /// toggle instead of waiting out the panel's two-minute loop; `objectWillChange` is sent by
    /// hand because hiding the last row of an already-empty strip changes no published value and
    /// would otherwise leave the old view on screen (#39).
    func visibilityDidChange() {
        objectWillChange.send()
        publish()
    }

    // User tapped "refresh": bypass the throttle and hit the network now, for every provider —
    // and let each source forget whatever made it give up, so a keychain prompt the user declined
    // (or dismissed) can be raised again by this very button.
    func forceRefresh() async {
        for index in states.indices {
            states[index].lastFetchAt = nil
            states[index].source.prepareForRetry()
        }
        await refresh()
    }

    /// Every source that is off the throttle refreshes CONCURRENTLY, and each answer is published
    /// the moment it lands rather than at the end.
    ///
    /// Serialized, one slow provider owned the whole strip: Kiro has no HTTP API at all and is
    /// read by spawning `kiro-cli chat`, which takes seconds and is allowed up to twenty — so
    /// Claude's and Codex's numbers, already in hand, would have sat unrendered behind it (#18).
    func refresh() async {
        let hidden = hiddenProviders()
        var due: [(index: Int, source: UsageSource)] = []
        for index in states.indices {
            // A hidden provider is not fetched at all — Kiro's read spawns a subprocess, and
            // nobody should pay for a row they switched off. Deliberately WITHOUT stamping
            // `lastFetchAt`: skipping leaves the throttle untouched, which is what makes
            // un-hiding fetch on the very next refresh instead of waiting out a window the
            // provider never spent (#39).
            guard !hidden.contains(states[index].source.name), isDue(at: index) else { continue }
            states[index].lastFetchAt = Date()
            due.append((index, states[index].source))
        }
        guard !due.isEmpty else {
            publish()
            return
        }

        await withTaskGroup(of: (Int, RefreshOutcome).self) { group in
            for (index, source) in due {
                group.addTask { (index, await Self.outcome(of: source)) }
            }
            for await (index, outcome) in group {
                apply(outcome, at: index)
                publish()
            }
        }
    }

    /// Hovering re-creates the panel and re-fires the refresh on every expand; without a floor,
    /// rapid hovers hammer the usage endpoints into 429. Serve cache within the window.
    private func isDue(at index: Int) -> Bool {
        guard let last = states[index].lastFetchAt else { return true }
        return Date().timeIntervalSince(last) >= minFetchInterval
    }

    /// What one source concluded. Computed off the main actor and applied back on it, which is
    /// what lets the group run them all at once.
    private enum RefreshOutcome: Sendable {
        case notConfigured
        case unavailable(String)
        case usage(ProviderUsage)
        case fetchFailed
    }

    private nonisolated static func outcome(of source: UsageSource) async -> RefreshOutcome {
        switch await source.availability() {
        case .notConfigured: return .notConfigured
        case .unavailable(let detail): return .unavailable(detail)
        case .ready:
            do { return .usage(try await source.fetch()) } catch { return .fetchFailed }
        }
    }

    private func apply(_ outcome: RefreshOutcome, at index: Int) {
        switch outcome {
        case .notConfigured:
            // No credentials at all — this provider is simply absent, not an error.
            states[index].configured = false
            states[index].lastGood = nil
            states[index].problem = nil
        case .unavailable(let detail):
            // Credentials exist but could not be read. Handled exactly like the 429 path below:
            // whatever numbers are already on screen stay there, and only with nothing at all to
            // show does the row admit the problem.
            states[index].configured = true
            states[index].problem = detail
        case .usage(let usage):
            states[index].configured = true
            states[index].lastGood = usage
            states[index].problem = nil
        case .fetchFailed:
            // Transient failure (429 rate-limit, 5xx, network error, etc.) — keep the
            // last good numbers for this provider instead of dropping it from the strip.
            states[index].configured = true
            states[index].problem = "usage unavailable"
        }
    }

    private func publish() {
        let hidden = hiddenProviders()
        rows = states.compactMap { state -> UsageRow? in
            // "Hidden by the user" is a fourth concept sitting ON TOP of the three-state model,
            // never folded into it: the state itself is left exactly as it was, so unhiding
            // brings back the numbers (or the error) unchanged, and `.unavailable` never comes
            // to mean "switched off". The #28 invariant is about silent vanishing; this one the
            // user asked for (#39).
            guard !hidden.contains(state.source.name) else { return nil }
            if let lastGood = state.lastGood { return .usage(lastGood) }
            guard state.configured, let problem = state.problem else { return nil }
            return .unavailable(provider: state.source.name, detail: problem)
        }
    }
}
