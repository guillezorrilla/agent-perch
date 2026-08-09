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
