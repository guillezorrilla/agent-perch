import Foundation
import XCTest
@testable import VibeNotch

final class UsageProviderTests: XCTestCase {
    func testParsesFiveHourAndSevenDayUsageFixture() throws {
        let snapshot = try UsageSnapshot.parse(Data(#"""
        {
          "five_hour": {"utilization": 11, "resets_at": "2026-08-09T20:15:00Z"},
          "seven_day": {"utilization": 2.5, "resets_at": "2026-08-15T17:00:00Z"}
        }
        """#.utf8))

        XCTAssertEqual(snapshot.fiveHour.utilization, 11)
        XCTAssertEqual(snapshot.fiveHour.resetsAt, ISO8601DateFormatter().date(from: "2026-08-09T20:15:00Z"))
        XCTAssertEqual(snapshot.sevenDay.utilization, 2.5)
        XCTAssertEqual(snapshot.sevenDay.resetsAt, ISO8601DateFormatter().date(from: "2026-08-15T17:00:00Z"))
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
            UsageWindow(utilization: 49, resetsAt: now.addingTimeInterval(3 * 3_600 + 59 * 60))
                .resetText(from: now),
            "3h59m"
        )
        XCTAssertEqual(
            UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(6 * 86_400 + 3_600))
                .resetText(from: now),
            "6d1h"
        )
        XCTAssertEqual(UsageWindow(utilization: 49, resetsAt: now).level, .low)
        XCTAssertEqual(UsageWindow(utilization: 50, resetsAt: now).level, .medium)
        XCTAssertEqual(UsageWindow(utilization: 80, resetsAt: now).level, .high)
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
        let snap = try UsageSnapshot.parse(json)
        XCTAssertEqual(snap.fiveHour.utilization, 17.0)
        XCTAssertEqual(snap.sevenDay.utilization, 100.0)
    }

    func testParsesTimestampWithoutFractionalSeconds() throws {
        let json = """
        {"five_hour":{"utilization":5.0,"resets_at":"2026-08-09T22:19:59Z"},
         "seven_day":{"utilization":9.0,"resets_at":"2026-08-10T00:59:59Z"}}
        """.data(using: .utf8)!
        let snap = try UsageSnapshot.parse(json)
        XCTAssertEqual(snap.fiveHour.utilization, 5.0)
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
        let provider = UsageProvider(tokenSource: StubToken(), loader: loader, minFetchInterval: 0)
        await provider.refresh()
        XCTAssertNotNil(provider.usage)
        loader.status = 429; loader.body = Data("{}".utf8)
        await provider.refresh()
        XCTAssertNotNil(provider.usage, "429 must not blank the last good snapshot")
    }

    @MainActor
    func testThrottleServesCacheWithoutHittingNetwork() async {
        let good = """
        {"five_hour":{"utilization":10,"resets_at":"2026-08-09T22:19:59Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-08-10T00:59:59Z"}}
        """.data(using: .utf8)!
        let loader = StubLoader(status: 200, body: good)
        let provider = UsageProvider(tokenSource: StubToken(), loader: loader, minFetchInterval: 999)
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
        let provider = UsageProvider(tokenSource: StubToken(), loader: loader, minFetchInterval: 999)
        await provider.refresh()        // call 1 (network)
        await provider.refresh()        // throttled -> cache
        await provider.forceRefresh()   // bypass -> network again
        XCTAssertEqual(loader.calls, 2, "forceRefresh ignores the throttle window")
    }
}
