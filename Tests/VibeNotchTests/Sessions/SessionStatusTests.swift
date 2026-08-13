import XCTest
@testable import VibeNotch

final class SessionStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testSessionIsActiveUntilFiveMinutesOld() {
        XCTAssertEqual(SessionStatus.at(modifiedAt: now, now: now), .active)
        XCTAssertEqual(
            SessionStatus.at(modifiedAt: now.addingTimeInterval(-299), now: now),
            .active
        )
    }

    func testSessionIsIdleFromFiveUntilSixtyMinutesOld() {
        XCTAssertEqual(
            SessionStatus.at(modifiedAt: now.addingTimeInterval(-300), now: now),
            .idle
        )
        XCTAssertEqual(
            SessionStatus.at(modifiedAt: now.addingTimeInterval(-3_599), now: now),
            .idle
        )
    }

    func testSessionIsHiddenAtSixtyMinutesOld() {
        XCTAssertNil(
            SessionStatus.at(modifiedAt: now.addingTimeInterval(-3_600), now: now)
        )
    }
}
