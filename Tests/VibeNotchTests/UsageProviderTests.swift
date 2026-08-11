import Foundation
import Security
import XCTest
@testable import VibeNotch

final class UsageProviderTests: XCTestCase {
    func testParsesFiveHourAndSevenDayUsageFixture() throws {
        let usage = try ClaudeUsageParser.parse(Data(#"""
        {
          "five_hour": {"utilization": 11, "resets_at": "2026-08-09T20:15:00Z"},
          "seven_day": {"utilization": 2.5, "resets_at": "2026-08-15T17:00:00Z"}
        }
        """#.utf8))

        XCTAssertEqual(usage.provider, "Claude")
        XCTAssertEqual(usage.windows[0].label, "5h")
        XCTAssertEqual(usage.windows[0].utilization, 11)
        XCTAssertEqual(usage.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-08-09T20:15:00Z"))
        XCTAssertEqual(usage.windows[1].label, "7d")
        XCTAssertEqual(usage.windows[1].utilization, 2.5)
        XCTAssertEqual(usage.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-08-15T17:00:00Z"))
    }

    func testParsesAccessTokenFromCredentialFixture() throws {
        let token = try CredentialParser.accessToken(from: Data(#"""
        {
          "claudeAiOauth": {
            "accessToken": "fixture-token",
            "refreshToken": "not-used"
          }
        }
        """#.utf8))

        XCTAssertEqual(token, "fixture-token")
    }

    func testFormatsResetIntervalsAndUtilizationLevels() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            UsageWindow(label: "5h", utilization: 49, resetsAt: now.addingTimeInterval(3 * 3_600 + 59 * 60))
                .resetText(from: now),
            "3h59m"
        )
        XCTAssertEqual(
            UsageWindow(label: "7d", utilization: 80, resetsAt: now.addingTimeInterval(6 * 86_400 + 3_600))
                .resetText(from: now),
            "6d1h"
        )
        XCTAssertEqual(UsageWindow(label: "5h", utilization: 49, resetsAt: now).level, .low)
        XCTAssertEqual(UsageWindow(label: "5h", utilization: 50, resetsAt: now).level, .medium)
        XCTAssertEqual(UsageWindow(label: "5h", utilization: 80, resetsAt: now).level, .high)
    }
}

final class DwellTimeTests: XCTestCase {
    func testDwellOptionsMapToRequestedSeconds() {
        XCTAssertEqual(NeedsActionDwellTime.allCases.map(\.label), ["Off", "3s", "5s", "10s"])
        XCTAssertNil(NeedsActionDwellTime.off.seconds)
        XCTAssertEqual(NeedsActionDwellTime.threeSeconds.seconds, 3)
        XCTAssertEqual(NeedsActionDwellTime.fiveSeconds.seconds, 5)
        XCTAssertEqual(NeedsActionDwellTime.tenSeconds.seconds, 10)
    }
}

extension UsageProviderTests {
    func testParsesFractionalSecondsResetTimestamp() throws {
        // Real API shape: fractional seconds + offset. Default ISO8601 formatter rejects this.
        let json = """
        {"five_hour":{"utilization":17.0,"resets_at":"2026-08-09T22:19:59.588521+00:00"},
         "seven_day":{"utilization":100.0,"resets_at":"2026-08-10T00:59:59.588545+00:00"}}
        """.data(using: .utf8)!
        let usage = try ClaudeUsageParser.parse(json)
        XCTAssertEqual(usage.windows[0].utilization, 17.0)
        XCTAssertEqual(usage.windows[1].utilization, 100.0)
    }

    func testParsesTimestampWithoutFractionalSeconds() throws {
        let json = """
        {"five_hour":{"utilization":5.0,"resets_at":"2026-08-09T22:19:59Z"},
         "seven_day":{"utilization":9.0,"resets_at":"2026-08-10T00:59:59Z"}}
        """.data(using: .utf8)!
        let usage = try ClaudeUsageParser.parse(json)
        XCTAssertEqual(usage.windows[0].utilization, 5.0)
    }
}

extension UsageProviderTests {
    func testParsesCodexPrimaryWindowOnlyWhenSecondaryIsNull() throws {
        let json = """
        {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
         "primary_window":{"used_percent":96,"limit_window_seconds":604800,"reset_after_seconds":506984,"reset_at":1786834931},
         "secondary_window":null},"additional_rate_limits":[],"credits":{}}
        """.data(using: .utf8)!

        let usage = try CodexUsageParser.parse(json)
        XCTAssertEqual(usage.provider, "Codex")
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].label, "7d")
        XCTAssertEqual(usage.windows[0].utilization, 96)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_786_834_931))
    }

    func testParsesCodexPrimaryAndSecondaryWindows() throws {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":17,"limit_window_seconds":18000,"reset_at":1786000000},
         "secondary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_at":1786800000}}}
        """.data(using: .utf8)!

        let usage = try CodexUsageParser.parse(json)
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].label, "5h")
        XCTAssertEqual(usage.windows[0].utilization, 17)
        XCTAssertEqual(usage.windows[1].label, "7d")
        XCTAssertEqual(usage.windows[1].utilization, 42)
    }

    func testCodexWindowLabelDerivesCompactLabelForOtherDurations() throws {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":3600,"reset_at":1786000000},
         "secondary_window":{"used_percent":20,"limit_window_seconds":86400,"reset_at":1786800000}}}
        """.data(using: .utf8)!

        let usage = try CodexUsageParser.parse(json)
        XCTAssertEqual(usage.windows[0].label, "1h")
        XCTAssertEqual(usage.windows[1].label, "1d")
    }

    func testParsesCodexAuthTokenFixture() throws {
        let credentials = try CodexCredentialParser.credentials(from: Data(#"""
        {
          "tokens": {
            "access_token": "codex-access-token",
            "account_id": "acct-123",
            "id_token": "ignored",
            "refresh_token": "ignored"
          }
        }
        """#.utf8))

        XCTAssertEqual(credentials.accessToken, "codex-access-token")
        XCTAssertEqual(credentials.accountId, "acct-123")
    }

    func testCodexAuthMissingTokensIsUnavailable() {
        XCTAssertThrowsError(try CodexCredentialParser.credentials(from: Data(#"{"foo": "bar"}"#.utf8)))

        let source = RuntimeCodexTokenSource(authURL: URL(fileURLWithPath: "/nonexistent/path/auth.json"))
        XCTAssertNil(source.credentials())
    }
}

extension UsageProviderTests {
    private final class StubToken: UsageTokenSource {
        func accessToken() -> String? { "tok" }
    }
    // `@unchecked` since `UsageSource` and friends became `Sendable` for the concurrent refresh
    // (#18): these doubles mutate freely, and each test drives exactly one at a time.
    private final class StubLoader: UsageLoading, @unchecked Sendable {
        var status: Int
        var body: Data
        private(set) var calls = 0
        init(status: Int, body: Data) { self.status = status; self.body = body }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            calls += 1
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
    }

    @MainActor
    func testKeepsLastGoodOnTransient429() async {
        let good = """
        {"five_hour":{"utilization":10,"resets_at":"2026-08-09T22:19:59.5Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-08-10T00:59:59.5Z"}}
        """.data(using: .utf8)!
        let loader = StubLoader(status: 200, body: good)
        let source = ClaudeUsageSource(tokenSource: StubToken(), loader: loader)
        let provider = UsageProvider(sources: [source], minFetchInterval: 0)
        await provider.refresh()
        XCTAssertFalse(provider.providers.isEmpty)
        loader.status = 429; loader.body = Data("{}".utf8)
        await provider.refresh()
        XCTAssertFalse(provider.providers.isEmpty, "429 must not blank the last good snapshot")
    }

    @MainActor
    func testThrottleServesCacheWithoutHittingNetwork() async {
        let good = """
        {"five_hour":{"utilization":10,"resets_at":"2026-08-09T22:19:59Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-08-10T00:59:59Z"}}
        """.data(using: .utf8)!
        let loader = StubLoader(status: 200, body: good)
        let source = ClaudeUsageSource(tokenSource: StubToken(), loader: loader)
        let provider = UsageProvider(sources: [source], minFetchInterval: 999)
        await provider.refresh()
        await provider.refresh()
        await provider.refresh()
        XCTAssertEqual(loader.calls, 1, "within the throttle window only the first call hits the network")
    }
}

extension UsageProviderTests {
    @MainActor
    func testForceRefreshBypassesThrottle() async {
        let good = """
        {"five_hour":{"utilization":10,"resets_at":"2026-08-09T22:19:59Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-08-10T00:59:59Z"}}
        """.data(using: .utf8)!
        let loader = StubLoader(status: 200, body: good)
        let source = ClaudeUsageSource(tokenSource: StubToken(), loader: loader)
        let provider = UsageProvider(sources: [source], minFetchInterval: 999)
        await provider.refresh()        // call 1 (network)
        await provider.refresh()        // throttled -> cache
        await provider.forceRefresh()   // bypass -> network again
        XCTAssertEqual(loader.calls, 2, "forceRefresh ignores the throttle window")
    }
}

extension UsageProviderTests {
    private final class StubUsageSource: UsageSource, @unchecked Sendable {
        let name: String
        var available: Bool
        var results: [Result<ProviderUsage, Error>]
        private var callIndex = 0
        private(set) var fetchCount = 0

        init(name: String, available: Bool = true, results: [Result<ProviderUsage, Error>]) {
            self.name = name
            self.available = available
            self.results = results
        }

        func isAvailable() -> Bool { available }

        func fetch() async throws -> ProviderUsage {
            fetchCount += 1
            let result = results[min(callIndex, results.count - 1)]
            callIndex += 1
            return try result.get()
        }
    }

    private func stubWindow(_ utilization: Double) -> UsageWindow {
        UsageWindow(label: "5h", utilization: utilization, resetsAt: Date())
    }

    @MainActor
    func testAggregatorKeepsFailingProviderLastGoodWhileHealthyOneUpdates() async {
        let claude = StubUsageSource(name: "Claude", results: [
            .success(ProviderUsage(provider: "Claude", windows: [stubWindow(10)])),
            .success(ProviderUsage(provider: "Claude", windows: [stubWindow(20)]))
        ])
        let codex = StubUsageSource(name: "Codex", results: [
            .success(ProviderUsage(provider: "Codex", windows: [stubWindow(30)])),
            .failure(UsageSourceError.httpStatus(429))
        ])
        let provider = UsageProvider(sources: [claude, codex], minFetchInterval: 0)

        await provider.refresh()
        XCTAssertEqual(provider.providers.map(\.provider), ["Claude", "Codex"])
        XCTAssertEqual(provider.providers[1].windows[0].utilization, 30)

        await provider.refresh()
        XCTAssertEqual(provider.providers[0].windows[0].utilization, 20, "healthy provider updates")
        XCTAssertEqual(provider.providers[1].windows[0].utilization, 30, "failing provider keeps its last good value")
    }

    @MainActor
    func testAggregatorOmitsProviderWithNoCredentials() async {
        let claude = StubUsageSource(name: "Claude", results: [
            .success(ProviderUsage(provider: "Claude", windows: [stubWindow(10)]))
        ])
        let codex = StubUsageSource(name: "Codex", available: false, results: [])
        let provider = UsageProvider(sources: [claude, codex], minFetchInterval: 0)

        await provider.refresh()
        XCTAssertEqual(provider.providers.map(\.provider), ["Claude"])
    }

    @MainActor
    func testForceRefreshBypassesThrottleForAllProviders() async {
        let claude = StubUsageSource(name: "Claude", results: [
            .success(ProviderUsage(provider: "Claude", windows: [stubWindow(10)])),
            .success(ProviderUsage(provider: "Claude", windows: [stubWindow(20)]))
        ])
        let codex = StubUsageSource(name: "Codex", results: [
            .success(ProviderUsage(provider: "Codex", windows: [stubWindow(30)])),
            .success(ProviderUsage(provider: "Codex", windows: [stubWindow(40)]))
        ])
        let provider = UsageProvider(sources: [claude, codex], minFetchInterval: 999)

        await provider.refresh()
        await provider.refresh()
        await provider.forceRefresh()

        XCTAssertEqual(claude.fetchCount, 2)
        XCTAssertEqual(codex.fetchCount, 2)
    }
}

// MARK: - Keychain credentials (#28)

/// The `OSStatus` branch mapping, exercised as the pure function it is — no keychain involved.
final class KeychainReadOutcomeTests: XCTestCase {
    func testSuccessIsUsable() {
        XCTAssertEqual(KeychainReadOutcome.of(errSecSuccess), .success)
    }

    /// The user said no, or there was no way to ask — an error row with a working retry, never a
    /// silent disappearance.
    func testTheThreeDeclinedStatusesMapToDeclined() {
        XCTAssertEqual(KeychainReadOutcome.of(errSecUserCanceled), .declined)
        XCTAssertEqual(KeychainReadOutcome.of(errSecAuthFailed), .declined)
        XCTAssertEqual(KeychainReadOutcome.of(errSecInteractionNotAllowed), .declined)
    }

    func testItemNotFoundFallsThroughToTheFallbacks() {
        XCTAssertEqual(KeychainReadOutcome.of(errSecItemNotFound), .notFound)
    }

    func testAnythingElseIsARetryableFailure() {
        XCTAssertEqual(KeychainReadOutcome.of(errSecIO), .failed)
        XCTAssertEqual(KeychainReadOutcome.of(errSecNotAvailable), .failed)
        XCTAssertEqual(KeychainReadOutcome.of(-1), .failed)
    }
}

/// Every read here goes through an injected closure — the real keychain is never touched.
final class RuntimeUsageTokenSourceTests: XCTestCase {
    private static let credentialsJSON = Data(#"{"claudeAiOauth":{"accessToken":"tok-abc"}}"#.utf8)
    private let missingFile = URL(fileURLWithPath: "/nonexistent/vibenotch/.credentials.json")

    private final class Script: @unchecked Sendable {
        var results: [(OSStatus, Data?)]
        private(set) var calls = 0
        init(_ results: [(OSStatus, Data?)]) { self.results = results }
        func next() -> (status: OSStatus, data: Data?) {
            let result = results[min(calls, results.count - 1)]
            calls += 1
            return (result.0, result.1)
        }
    }

    private func source(
        _ script: Script,
        securityCLIRead: @escaping () -> Data? = { nil },
        credentialsURL: URL? = nil
    ) -> RuntimeUsageTokenSource {
        RuntimeUsageTokenSource(
            credentialsURL: credentialsURL ?? missingFile,
            keychainRead: { script.next() },
            securityCLIRead: securityCLIRead
        )
    }

    func testASuccessfulReadYieldsTheToken() async {
        let script = Script([(errSecSuccess, Self.credentialsJSON)])
        let result = await source(script).read()
        XCTAssertEqual(result, .token("tok-abc"))
        XCTAssertEqual(script.calls, 1)
    }

    /// A declined prompt is credentials that exist and could not be read — an error the strip can
    /// show, never "this provider is not configured".
    func testADeclinedPromptIsUnreadableNotMissing() async {
        let script = Script([(errSecInteractionNotAllowed, nil)])
        let tokenSource = source(script) { XCTFail("must not shell out when the item exists"); return nil }
        let result = await tokenSource.read()
        XCTAssertEqual(result, .unreadable("keychain access denied"))
    }

    /// The prompt must not be raised again and again behind the user's back — only their own
    /// retry re-arms it.
    func testADeclinedReadIsRememberedUntilAnExplicitRetry() async {
        let script = Script([(errSecUserCanceled, nil)])
        let tokenSource = source(script)

        _ = await tokenSource.read()
        _ = await tokenSource.read()
        _ = await tokenSource.read()
        XCTAssertEqual(script.calls, 1, "a refusal must not be re-asked on every refresh")

        tokenSource.retryAfterFailure()
        _ = await tokenSource.read()
        XCTAssertEqual(script.calls, 2, "the user's own retry re-attempts the read")
    }

    func testARetryableFailureIsRetriedExactlyOnceAndThenSucceeds() async {
        let script = Script([(errSecIO, nil), (errSecSuccess, Self.credentialsJSON)])
        let result = await source(script).read()
        XCTAssertEqual(result, .token("tok-abc"))
        XCTAssertEqual(script.calls, 2)
    }

    func testTwoRetryableFailuresGiveUpAsUnreadableNotMissing() async {
        let script = Script([(errSecIO, nil)])
        let result = await source(script).read()
        XCTAssertEqual(result, .unreadable("keychain unavailable"))
        XCTAssertEqual(script.calls, 2, "retried once, never in a loop")
    }

    /// An item that IS there but whose contents can't be parsed is still not "unconfigured".
    func testUnparsableKeychainContentsAreUnreadable() async {
        let script = Script([(errSecSuccess, Data("not json".utf8))])
        let result = await source(script).read()
        XCTAssertEqual(result, .unreadable("credentials unreadable"))
    }

    func testItemNotFoundFallsBackToTheSecurityCLI() async {
        let script = Script([(errSecItemNotFound, nil)])
        let tokenSource = source(script, securityCLIRead: { Self.credentialsJSON })
        let result = await tokenSource.read()
        XCTAssertEqual(result, .token("tok-abc"))
    }

    func testItemNotFoundFallsBackToTheCredentialsFileLast() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        try Self.credentialsJSON.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }

        let script = Script([(errSecItemNotFound, nil)])
        let tokenSource = source(script, securityCLIRead: { nil }, credentialsURL: file)
        let result = await tokenSource.read()
        XCTAssertEqual(result, .token("tok-abc"))
    }

    func testNothingAnywhereIsNotConfigured() async {
        let script = Script([(errSecItemNotFound, nil)])
        let result = await source(script).read()
        XCTAssertEqual(result, .notConfigured)
    }

    /// Not memoized: signing into Claude Code later must bring the row back on its own.
    func testNotConfiguredIsRecheckedOnEveryRead() async {
        let script = Script([(errSecItemNotFound, nil), (errSecSuccess, Self.credentialsJSON)])
        let tokenSource = source(script)
        let first = await tokenSource.read()
        XCTAssertEqual(first, .notConfigured)
        let second = await tokenSource.read()
        XCTAssertEqual(second, .token("tok-abc"))
    }

    /// One read that worked is the answer for the rest of the process — no later failure can turn
    /// a working provider into an absent one.
    func testASucceededReadIsCachedSoALaterFailedReadStillYieldsTheToken() async {
        let script = Script([(errSecSuccess, Self.credentialsJSON), (errSecItemNotFound, nil)])
        let tokenSource = source(script)

        let first = await tokenSource.read()
        XCTAssertEqual(first, .token("tok-abc"))
        let second = await tokenSource.read()
        XCTAssertEqual(second, .token("tok-abc"))
        XCTAssertEqual(script.calls, 1, "the cached token answers without touching the keychain again")
    }

    /// `isAvailable()` runs on every refresh: cache-only, so it can neither spawn a read nor
    /// re-raise the prompt.
    func testAccessTokenIsCacheOnlyAndNeverReads() async {
        let script = Script([(errSecSuccess, Self.credentialsJSON)])
        let tokenSource = source(script)

        XCTAssertNil(tokenSource.accessToken())
        XCTAssertEqual(script.calls, 0, "the cheap synchronous check must not touch the keychain")

        _ = await tokenSource.read()
        XCTAssertEqual(tokenSource.accessToken(), "tok-abc")
        XCTAssertEqual(script.calls, 1)
    }

    /// Concurrent refreshes must not queue up a second prompt behind the first.
    func testConcurrentReadsCollapseToASingleKeychainRead() async {
        let script = Script([(errSecSuccess, Self.credentialsJSON)])
        let tokenSource = source(script)

        async let first = tokenSource.read()
        async let second = tokenSource.read()
        async let third = tokenSource.read()
        let results = await [first, second, third]

        XCTAssertEqual(results, [.token("tok-abc"), .token("tok-abc"), .token("tok-abc")])
        XCTAssertEqual(script.calls, 1)
    }
}

// MARK: - Three-state strip (#28)

extension UsageProviderTests {
    private static let credentialsJSON = Data(#"{"claudeAiOauth":{"accessToken":"tok-abc"}}"#.utf8)
    private static let usageJSON = Data("""
    {"five_hour":{"utilization":10,"resets_at":"2026-08-09T22:19:59Z"},
     "seven_day":{"utilization":20,"resets_at":"2026-08-10T00:59:59Z"}}
    """.utf8)

    private func claudeSource(
        keychain: @escaping () -> (status: OSStatus, data: Data?),
        loader: UsageLoading
    ) -> ClaudeUsageSource {
        ClaudeUsageSource(
            tokenSource: RuntimeUsageTokenSource(
                credentialsURL: URL(fileURLWithPath: "/nonexistent/vibenotch/.credentials.json"),
                keychainRead: keychain,
                securityCLIRead: { nil }
            ),
            loader: loader
        )
    }

    /// The regression itself: credentials that exist but cannot be read used to leave the strip
    /// with no Claude row at all, indistinguishable from never having used Claude.
    @MainActor
    func testUnreadableCredentialsRenderAnErrorRowInsteadOfDisappearing() async {
        let source = claudeSource(
            keychain: { (errSecInteractionNotAllowed, nil) },
            loader: StubLoader(status: 200, body: Self.usageJSON)
        )
        let provider = UsageProvider(sources: [source], minFetchInterval: 0)

        await provider.refresh()

        XCTAssertEqual(provider.rows, [.unavailable(provider: "Claude", detail: "keychain access denied")])
        XCTAssertTrue(provider.providers.isEmpty)
    }

    /// The other half of the three-state model: genuinely absent credentials stay omitted.
    @MainActor
    func testNoCredentialsAtAllOmitsTheProviderEntirely() async {
        let source = claudeSource(
            keychain: { (errSecItemNotFound, nil) },
            loader: StubLoader(status: 200, body: Self.usageJSON)
        )
        let provider = UsageProvider(sources: [source], minFetchInterval: 0)

        await provider.refresh()

        XCTAssertTrue(provider.rows.isEmpty)
    }

    /// A provider that HAS numbers keeps showing them through an unreadable-credentials spell,
    /// exactly like the 429 path.
    @MainActor
    func testAnUnreadableReadKeepsTheLastGoodNumbersOnScreen() async {
        final class Flip: @unchecked Sendable {
            var fail = false
            func read() -> (status: OSStatus, data: Data?) {
                fail ? (errSecUserCanceled, nil) : (errSecSuccess, UsageProviderTests.credentialsJSON)
            }
        }
        let flip = Flip()
        let source = claudeSource(keychain: { flip.read() }, loader: StubLoader(status: 200, body: Self.usageJSON))
        let provider = UsageProvider(sources: [source], minFetchInterval: 0)

        await provider.refresh()
        XCTAssertEqual(provider.providers.first?.windows.first?.utilization, 10)

        flip.fail = true
        await provider.refresh()
        XCTAssertEqual(
            provider.providers.first?.windows.first?.utilization, 10,
            "an unreadable read must not blank a provider that already has numbers"
        )
    }

    /// The cached token is what makes that true even across a keychain that has gone away
    /// entirely: one failed read can never drop the provider.
    @MainActor
    func testTheTokenCacheMeansASecondFailedReadStillYieldsData() async {
        final class Script: @unchecked Sendable {
            var calls = 0
            func read() -> (status: OSStatus, data: Data?) {
                calls += 1
                return calls == 1 ? (errSecSuccess, UsageProviderTests.credentialsJSON) : (errSecItemNotFound, nil)
            }
        }
        let script = Script()
        let source = claudeSource(keychain: { script.read() }, loader: StubLoader(status: 200, body: Self.usageJSON))
        let provider = UsageProvider(sources: [source], minFetchInterval: 0)

        await provider.refresh()
        await provider.refresh()

        XCTAssertEqual(provider.providers.map(\.provider), ["Claude"])
        XCTAssertEqual(script.calls, 1, "isAvailable/fetch must not re-read once a token is cached")
    }

    /// A fetch that fails with nothing cached is still a visible row — the point of the whole
    /// three-state model is that nothing ever leaves the strip without saying why.
    @MainActor
    func testAFailedFirstFetchShowsAnErrorRowRatherThanNothing() async {
        let source = claudeSource(
            keychain: { (errSecSuccess, Self.credentialsJSON) },
            loader: StubLoader(status: 500, body: Data("{}".utf8))
        )
        let provider = UsageProvider(sources: [source], minFetchInterval: 0)

        await provider.refresh()

        XCTAssertEqual(provider.rows, [.unavailable(provider: "Claude", detail: "usage unavailable")])
    }

    /// The strip's refresh button is the error row's retry: it re-attempts the read, so a prompt
    /// the user declined can be raised again.
    @MainActor
    func testForceRefreshReAttemptsADeclinedKeychainRead() async {
        final class Script: @unchecked Sendable {
            var calls = 0
            var declined = true
            func read() -> (status: OSStatus, data: Data?) {
                calls += 1
                return declined ? (errSecUserCanceled, nil) : (errSecSuccess, UsageProviderTests.credentialsJSON)
            }
        }
        let script = Script()
        let source = claudeSource(keychain: { script.read() }, loader: StubLoader(status: 200, body: Self.usageJSON))
        let provider = UsageProvider(sources: [source], minFetchInterval: 0)

        await provider.refresh()
        XCTAssertEqual(provider.rows, [.unavailable(provider: "Claude", detail: "keychain access denied")])

        await provider.refresh()
        XCTAssertEqual(script.calls, 1, "an ordinary refresh must not re-raise the prompt")

        script.declined = false
        await provider.forceRefresh()
        XCTAssertEqual(script.calls, 2)
        XCTAssertEqual(provider.providers.map(\.provider), ["Claude"])
    }
}
