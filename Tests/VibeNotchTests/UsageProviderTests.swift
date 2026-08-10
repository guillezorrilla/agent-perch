import Foundation
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
    private final class StubLoader: UsageLoading {
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
    private final class StubUsageSource: UsageSource {
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
