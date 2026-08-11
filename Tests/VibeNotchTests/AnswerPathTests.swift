import XCTest
@testable import VibeNotch

/// The answer half of a card click, which used to run whole on the main thread: locating the
/// session's Warp tab copies a ~30MB database out of another app's container, and the UI was
/// frozen for every millisecond of it (#32). The store now acknowledges the click first, runs the
/// injection behind it, and gives that injection a deadline.
///
/// Everything here drives an injected fake — no real terminal, database or keychain is touched.
final class AnswerPathTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The whole point of the fix: the card says what happened to it while the typing is still
    /// going on, not after.
    @MainActor
    func testTheCardTakesItsResolutionBeforeTheInjectionFinishes() async {
        let store = makeStore()
        var resolutionDuringInjection: ActionResolution?

        let answered = await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            resolutionDuringInjection = store.resolutions["session-1"]
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }

        XCTAssertTrue(answered)
        XCTAssertEqual(
            resolutionDuringInjection,
            .answered("Approved ✓"),
            "the click must be acknowledged before the injection starts, not after it lands"
        )
        XCTAssertEqual(store.resolutions["session-1"], .answered("Approved ✓"))
        XCTAssertFalse(store.isAnswering("session-1"))
    }

    /// Nothing was typed anywhere — the card has to stop claiming otherwise.
    @MainActor
    func testAnInjectionThatFailsTurnsTheCardIntoTheFailureState() async {
        let store = makeStore()

        let answered = await store.performAnswer("session-1", label: "Approved ✓") { false }

        XCTAssertFalse(answered)
        XCTAssertEqual(store.resolutions["session-1"], .failed)
        XCTAssertFalse(store.isAnswering("session-1"))
    }

    /// A Warp database read that never returns must cost the answer, never the UI.
    @MainActor
    func testAnInjectionThatOutlastsItsDeadlineFallsBackToTheFailureState() async {
        let store = makeStore()
        let start = Date()

        let answered = await store.performAnswer(
            "session-1",
            label: "Approved ✓",
            timeout: 0.05
        ) {
            try? await Task.sleep(for: .milliseconds(500))
            return true
        }

        XCTAssertFalse(answered)
        XCTAssertEqual(store.resolutions["session-1"], .failed)
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.4,
            "the deadline must abandon the injection rather than wait for it"
        )
        XCTAssertFalse(store.isAnswering("session-1"))
    }

    /// Two digits into one prompt answer two questions — the second click is dropped, exactly as
    /// a second jump is.
    @MainActor
    func testASecondAnswerWhileOneIsInFlightIsIgnored() async {
        let store = makeStore()
        var attempts = 0

        let answered = await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            attempts += 1
            let reentrant = await store.performAnswer("session-1", label: "Denied ✕", hold: 0.05) {
                attempts += 1
                return true
            }
            XCTAssertFalse(reentrant)
            return true
        }

        XCTAssertTrue(answered)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(store.resolutions["session-1"], .answered("Approved ✓"))
        XCTAssertFalse(store.isAnswering("session-1"))
    }

    /// A different session answered at the same moment is a different card, and must go through.
    @MainActor
    func testAnAnswerForAnotherSessionIsNotBlockedByOneInFlight() async {
        let store = makeStore()

        let answered = await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            await store.performAnswer("session-2", label: "Denied ✕", hold: 0.05) { true }
        }

        XCTAssertTrue(answered)
        XCTAssertEqual(store.resolutions["session-2"], .answered("Denied ✕"))
    }

    /// The agent moved on (or the user jumped) while we were typing: whatever the card says now is
    /// newer than what this answer has to report, so the answer must not overwrite it.
    @MainActor
    func testAnAnswerClearedWhileInFlightIsNotResurrected() async {
        let store = makeStore()

        let answered = await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            store.clearResolution("session-1")
            return true
        }

        XCTAssertTrue(answered)
        XCTAssertNil(store.resolutions["session-1"])
    }

    /// The answered card's hold starts when the keystroke lands, not when the click does — a slow
    /// injection must not have its own confirmation dismissed out from under it.
    @MainActor
    func testTheConfirmationHoldStartsAfterTheInjectionLands() async {
        let store = makeStore()
        var dismissals = 0
        store.onAnswerDismissed = { dismissals += 1 }

        await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            try? await Task.sleep(for: .milliseconds(80))
            return true
        }

        XCTAssertEqual(store.resolutions["session-1"], .answered("Approved ✓"))
        XCTAssertEqual(dismissals, 0, "the hold cannot have expired before the answer was typed")

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.resolutions["session-1"])
        XCTAssertEqual(dismissals, 1)
    }

    /// A key Warp has no code for is rejected before the group container is ever touched — which
    /// is also what keeps this test off the user's real Warp database.
    func testAWarpAnswerWithNoKeystrokeIsRejectedBeforeAnyDatabaseRead() async {
        let injected = await ActionInjector().inject(.warp(cwd: "/repo", key: .text("0")))
        XCTAssertFalse(injected)
    }

    @MainActor
    private func makeStore() -> SessionStore {
        SessionStore(
            projectsDirectory: temporaryDirectory(),
            codexHome: temporaryDirectory(),
            antigravityHome: temporaryDirectory(),
            antigravityCLIHome: temporaryDirectory(),
            geminiHome: temporaryDirectory(),
            openCodeDatabaseURL: temporaryDirectory().appendingPathComponent("opencode.db"),
            kiroHome: temporaryDirectory(),
            cursorHome: temporaryDirectory(),
            processProvider: { [] }
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
