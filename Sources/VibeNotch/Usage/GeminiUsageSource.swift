import Foundation

// MARK: - Credentials

/// Nothing in this file ever logs, prints or persists a token. The access token is read, put in
/// one `Authorization` header, and dropped; `oauth_creds.json`'s `refresh_token` and `id_token`
/// are not read at all (#18).
struct GeminiCredentials: Equatable, Sendable {
    let accessToken: String
    /// Milliseconds since the epoch, as the Gemini CLI writes it.
    let expiryDate: Double?

    func isExpired(at now: Date) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate / 1000.0 <= now.timeIntervalSince1970
    }
}

enum GeminiCredentialParser {
    static func credentials(from data: Data) throws -> GeminiCredentials {
        let raw = try JSONDecoder().decode(RawGeminiCredentials.self, from: data)
        guard !raw.accessToken.isEmpty else { throw CocoaError(.coderValueNotFound) }
        return GeminiCredentials(accessToken: raw.accessToken, expiryDate: raw.expiryDate)
    }

    private struct RawGeminiCredentials: Decodable {
        let accessToken: String
        let expiryDate: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiryDate = "expiry_date"
        }
    }
}

struct RuntimeGeminiTokenSource: GeminiTokenSource {
    let credentialsURL: URL

    init(credentialsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/oauth_creds.json")) {
        self.credentialsURL = credentialsURL
    }

    func credentials() -> GeminiCredentials? {
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return try? GeminiCredentialParser.credentials(from: data)
    }

    func credentialAvailability() -> UsageAvailability {
        CredentialFile.availability(of: credentialsURL) {
            try? GeminiCredentialParser.credentials(from: $0)
        }
    }
}

protocol GeminiTokenSource: Sendable {
    func credentials() -> GeminiCredentials?
    /// See `CodexTokenSource.credentialAvailability` — same distinction, same reason.
    func credentialAvailability() -> UsageAvailability
}

extension GeminiTokenSource {
    func credentialAvailability() -> UsageAvailability {
        credentials() != nil ? .ready : .notConfigured
    }
}

// MARK: - Eligibility

/// Google stopped serving this OAuth path for consumer accounts in June 2026: the very accounts
/// that still have quota get it through Antigravity instead, which this strip already reads. So a
/// refusal here is not an error worth a row — it is a provider that does not apply to this
/// machine, and the row is omitted (#18).
enum GeminiEligibility: Equatable, Sendable {
    case eligible
    case ineligible
    /// A 5xx, a 429, or no network: keep the row, keep whatever numbers it already had.
    case transient

    static func classify(status: Int, body: Data) -> GeminiEligibility {
        if 200..<300 ~= status { return .eligible }
        // Rate limiting is the one 4xx that says nothing about eligibility.
        if status == 429 { return .transient }
        let text = String(decoding: body, as: UTF8.self)
        let refusals = ["UNSUPPORTED_CLIENT", "IneligibleTier", "PERMISSION_DENIED", "FAILED_PRECONDITION"]
        if 400..<500 ~= status || refusals.contains(where: { text.contains($0) }) { return .ineligible }
        return .transient
    }
}

// MARK: - Parsing

enum GeminiQuotaParser {
    static func parse(_ data: Data) throws -> ProviderUsage {
        let decoder = JSONDecoder()
        let payload: RawGeminiQuota
        if let envelope = try? decoder.decode(RawGeminiQuotaEnvelope.self, from: data),
           let inner = envelope.response {
            payload = inner
        } else {
            payload = try decoder.decode(RawGeminiQuota.self, from: data)
        }

        let windows = payload.buckets.compactMap { $0.usageWindow() }
        guard !windows.isEmpty else { throw UsageSourceError.unavailable }
        return ProviderUsage(provider: "Gemini", windows: windows)
    }

    static func label(modelId: String?, tokenType: String?) -> String {
        let model = modelId.map { String($0.replacingOccurrences(of: "gemini-", with: "").prefix(8)) } ?? ""
        let kind = tokenType?.lowercased() ?? ""
        let parts = [model, kind].filter { !$0.isEmpty }
        return parts.isEmpty ? "quota" : parts.joined(separator: " ")
    }
}

private struct RawGeminiQuotaEnvelope: Decodable {
    let response: RawGeminiQuota?
}

private struct RawGeminiQuota: Decodable {
    let buckets: [RawGeminiBucket]
}

private struct RawGeminiBucket: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
    let modelId: String?
    let tokenType: String?

    func usageWindow() -> UsageWindow? {
        guard let remainingFraction,
              let resetTime,
              let resetsAt = ClaudeUsageParser.parseDate(resetTime) else { return nil }
        return UsageWindow(
            label: GeminiQuotaParser.label(modelId: modelId, tokenType: tokenType),
            utilization: min(100, max(0, (1 - remainingFraction) * 100.0)),
            resetsAt: resetsAt
        )
    }
}

// MARK: - Source

/// Gemini CLI quota. Best-effort by design and the last provider on the strip: on this machine the
/// endpoint answers 403 for a perfectly valid token, so the row is omitted and Antigravity carries
/// the same account's numbers instead.
///
/// The eligibility verdict is probed once in `availability()` and memoized, so an account Google
/// refuses never flashes an error row before disappearing — it simply never appears. Whatever this
/// provider does, it does alone: the aggregator refreshes sources concurrently and independently,
/// so a Gemini refusal cannot touch the Claude, Codex, Antigravity or Kiro rows (#18).
final class GeminiUsageSource: UsageSource, @unchecked Sendable {
    let name = "Gemini"
    static let quotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"

    private let tokenSource: GeminiTokenSource
    private let loader: UsageLoading
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var verdict: GeminiEligibility?
    /// The payload the eligibility probe already paid for, handed to the very next `fetch()` so
    /// the first refresh costs one call rather than two.
    private var probedUsage: ProviderUsage?

    init(
        tokenSource: GeminiTokenSource = RuntimeGeminiTokenSource(),
        loader: UsageLoading = URLSession.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenSource = tokenSource
        self.loader = loader
        self.now = now
    }

    func isAvailable() -> Bool { tokenSource.credentials() != nil }

    func availability() async -> UsageAvailability {
        // A credential file that exists but could not be read is a retryable row, not an absent
        // provider. Everything below this line is about eligibility, which needs credentials in
        // hand to judge.
        if case .unavailable = tokenSource.credentialAvailability() {
            return tokenSource.credentialAvailability()
        }
        guard let credentials = tokenSource.credentials() else { return .notConfigured }
        // Token refresh is deliberately not implemented — see the note on `fetch()`. An expired
        // token is a provider we cannot serve, which is an omitted row, not an error row.
        guard !credentials.isExpired(at: now()) else { return .notConfigured }

        if let memoized = lock.withLock({ verdict }) {
            return memoized == .eligible ? .ready : .notConfigured
        }

        let (eligibility, usage) = await probe(credentials)
        lock.withLock {
            // A transient failure is not a verdict: re-probe next time rather than writing this
            // account off over one 500.
            if eligibility != .transient { verdict = eligibility }
            probedUsage = usage
        }
        switch eligibility {
        case .eligible: return .ready
        case .ineligible: return .notConfigured
        case .transient: return .unavailable("usage unavailable")
        }
    }

    func prepareForRetry() {
        lock.withLock {
            verdict = nil
            probedUsage = nil
        }
    }

    /// No token refresh: `oauth_creds.json` carries a `refresh_token`, but exchanging it needs the
    /// Gemini CLI's own OAuth client secret, and on this machine a *valid, unexpired* token is
    /// already refused — so refreshing would buy nothing and would mean handling one more secret.
    /// Wiring it later is a self-contained change behind `GeminiTokenSource`.
    func fetch() async throws -> ProviderUsage {
        if let pending = lock.withLock({ () -> ProviderUsage? in
            defer { probedUsage = nil }
            return probedUsage
        }) { return pending }

        guard let credentials = tokenSource.credentials(), !credentials.isExpired(at: now()) else {
            throw UsageSourceError.unavailable
        }
        let (eligibility, usage) = await probe(credentials)
        lock.withLock {
            if eligibility != .transient { verdict = eligibility }
        }
        guard let usage else { throw UsageSourceError.unavailable }
        return usage
    }

    private func probe(_ credentials: GeminiCredentials) async -> (GeminiEligibility, ProviderUsage?) {
        guard let url = URL(string: Self.quotaURL) else { return (.transient, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await loader.data(for: request),
              let http = response as? HTTPURLResponse else {
            return (.transient, nil)
        }
        let eligibility = GeminiEligibility.classify(status: http.statusCode, body: data)
        guard eligibility == .eligible else { return (eligibility, nil) }
        // A 200 whose body will not parse is not an eligible account with no quota — it is an
        // answer we do not understand, and guessing a number from it is what #18 forbids.
        guard let usage = try? GeminiQuotaParser.parse(data) else { return (.ineligible, nil) }
        return (.eligible, usage)
    }
}
