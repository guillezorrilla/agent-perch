import XCTest
@testable import AgentPerch

/// The two things that decide whether an update notice is honest: which of two versions is newer,
/// and whether "we couldn't check" is ever allowed to read as "you're up to date" (#75).
final class UpdateCheckTests: XCTestCase {
    private func release(_ tag: String) -> Data {
        Data(#"{"tag_name": "\#(tag)", "name": "whatever", "draft": false}"#.utf8)
    }

    func testATagsLeadingVIsNotPartOfTheVersion() {
        XCTAssertEqual(UpdateCheck.version(fromTag: "v0.2.0"), "0.2.0")
        XCTAssertEqual(UpdateCheck.version(fromTag: "0.2.0"), "0.2.0")
    }

    /// The failure a lexicographic compare would produce: "0.10.0" < "0.9.0" as text, so the app
    /// would stop offering updates forever after the first double-digit release.
    func testADoubleDigitComponentComparesAsANumber() {
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.0", than: "0.10.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.2.10", than: "1.2.9"))
    }

    func testTheSameVersionIsNotNewerThanItself() {
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
    }

    /// Downgrades happen when someone installs an old DMG on purpose. Offering them the version
    /// they just walked away from is noise.
    func testAnOlderReleaseIsNotAnUpdate() {
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
    }

    func testANewerTagIsOfferedAsAnUpdate() {
        XCTAssertEqual(
            UpdateCheck.state(fromLatestRelease: release("v0.2.0"), current: "0.1.0"),
            .available("0.2.0")
        )
    }

    func testTheCurrentTagReadsAsUpToDate() {
        XCTAssertEqual(
            UpdateCheck.state(fromLatestRelease: release("v0.1.0"), current: "0.1.0"),
            .upToDate("0.1.0")
        )
    }

    /// The one answer this must never give. A rate-limit page, an error body or a truncated
    /// response says nothing about whether an update exists, and reporting "up to date" there is
    /// the app claiming something it did not verify.
    func testAnUnreadableResponseIsAFailureAndNotUpToDate() {
        XCTAssertEqual(
            UpdateCheck.state(fromLatestRelease: Data(#"{"message": "API rate limit exceeded"}"#.utf8), current: "0.1.0"),
            .checkFailed
        )
        XCTAssertEqual(
            UpdateCheck.state(fromLatestRelease: Data("<html>502</html>".utf8), current: "0.1.0"),
            .checkFailed
        )
    }

    @MainActor
    private final class Announcements {
        var versions: [String] = []
    }

    /// A scratch defaults suite, since the dedup rule is *about* what survives across checkers.
    private func isolatedDefaults() -> UserDefaults {
        let name = "update-check-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    private func checker(
        enabled: Bool = true,
        version: String,
        into announced: Announcements,
        defaults: UserDefaults
    ) -> UpdateChecker {
        UpdateChecker(
            isEnabled: { enabled },
            fetch: { _ in .available(version) },
            announce: { announced.versions.append($0) },
            defaults: defaults
        )
    }

    /// The daily loop runs 365 times a year. Without this, so does the notification.
    @MainActor
    func testTheSameVersionIsAnnouncedOnlyOnce() async {
        let defaults = isolatedDefaults()
        let announced = Announcements()

        await checker(version: "9.9.9", into: announced, defaults: defaults).checkIfEnabled()
        await checker(version: "9.9.9", into: announced, defaults: defaults).checkIfEnabled()

        XCTAssertEqual(announced.versions, ["9.9.9"])
    }

    /// …but silence must not become permanent: the release after the one already announced is
    /// still news.
    @MainActor
    func testTheNextVersionIsAnnouncedAgain() async {
        let defaults = isolatedDefaults()
        let announced = Announcements()

        await checker(version: "9.9.9", into: announced, defaults: defaults).checkIfEnabled()
        await checker(version: "9.9.10", into: announced, defaults: defaults).checkIfEnabled()

        XCTAssertEqual(announced.versions, ["9.9.9", "9.9.10"])
    }

    @MainActor
    func testNothingIsCheckedWhileAutomaticChecksAreOff() async {
        let defaults = isolatedDefaults()
        let announced = Announcements()
        let checker = checker(enabled: false, version: "9.9.9", into: announced, defaults: defaults)

        await checker.checkIfEnabled()

        XCTAssertEqual(announced.versions, [])
        XCTAssertEqual(checker.state, .unknown)
    }

    /// "Check now" is the user asking, so it runs even with automatic checks off — and it never
    /// posts a notification, because the answer lands in the window they are already looking at.
    @MainActor
    func testCheckNowRunsWithAutomaticChecksOffAndStaysSilent() async {
        let defaults = isolatedDefaults()
        let announced = Announcements()
        let checker = checker(enabled: false, version: "9.9.9", into: announced, defaults: defaults)

        await checker.check(notifying: false)

        XCTAssertEqual(checker.state, .available("9.9.9"))
        XCTAssertEqual(announced.versions, [])
    }
}
