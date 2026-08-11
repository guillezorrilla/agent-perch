import Foundation
import XCTest
@testable import VibeNotch

final class SessionLayoutTests: XCTestCase {
    func testEmptySessionsProducesEmptySplit() {
        let split = SessionLayout.split(sessions: [])
        XCTAssertEqual(split.fullCards, [])
        XCTAssertEqual(split.compactRows, [])
    }

    func testNoBusySessionsFallsBackToMostRecentFullCard() {
        // SessionStore hands sessions over already sorted needsAction-first, then by recency —
        // neither status here is needsAction, so this is straight recency order.
        let recent = session("recent", .idle, at: 500)
        let older = session("older", .done, at: 300)

        let split = SessionLayout.split(sessions: [recent, older])

        XCTAssertEqual(split.fullCards, [recent])
        XCTAssertEqual(split.compactRows, [older])
    }

    func testEveryBusySessionGetsAFullCardUpToTheCap() {
        // Store order: needsAction group by recency, then everyone else by recency.
        let needsActionNewer = session("needsAction-newer", .needsAction, at: 500)
        let needsActionOlder = session("needsAction-older", .needsAction, at: 400)
        let idleNewest = session("idle-newest", .idle, at: 700)
        let workingNewer = session("working-newer", .working, at: 600)
        let workingOlder = session("working-older", .working, at: 300)
        let activeOldest = session("active-oldest", .active, at: 200)

        let storeOrder = [
            needsActionNewer, needsActionOlder, idleNewest, workingNewer, workingOlder, activeOldest
        ]

        let split = SessionLayout.split(sessions: storeOrder, cap: 3)

        // needsAction first, then working/active by most recent — capped at 3.
        XCTAssertEqual(split.fullCards, [needsActionNewer, needsActionOlder, workingNewer])
        // Idle sessions and busy overflow beyond the cap fall back to compact rows, ordered
        // by most recent.
        XCTAssertEqual(split.compactRows, [idleNewest, workingOlder, activeOldest])
    }

    func testFullCardCapIsThree() {
        XCTAssertEqual(SessionLayout.maxFullCards, 3)
    }

    func testIdleDoneAndEndedAreNeverFullCardsWhenSomethingElseIsBusy() {
        let working = session("working", .working, at: 100)
        let idle = session("idle", .idle, at: 500)
        let done = session("done", .done, at: 400)
        let ended = session("ended", .ended, at: 300)

        let split = SessionLayout.split(sessions: [idle, done, working, ended])

        XCTAssertEqual(split.fullCards, [working])
        XCTAssertEqual(split.compactRows, [idle, done, ended])
    }

    func testCapOfOneStillPutsTheSingleBusySessionInFullCards() {
        let working = session("working", .working, at: 100)
        let idle = session("idle", .idle, at: 500)

        let split = SessionLayout.split(sessions: [idle, working], cap: 1)

        XCTAssertEqual(split.fullCards, [working])
        XCTAssertEqual(split.compactRows, [idle])
    }

    /// An Antigravity IDE-workspace row must never become a full card, even as the sole fallback
    /// when nothing else is busy — it is capped at `.idle` in the source precisely so it can
    /// never be mistaken for a real session (#29).
    func testAntigravityWorkspaceRowIsNeverTheFallbackFullCardEvenAsTheMostRecentSession() {
        let workspace = session("antigravity:abc", .idle, at: 900, agentName: "Antigravity")
        let older = session("older", .idle, at: 100)

        let split = SessionLayout.split(sessions: [workspace, older])

        XCTAssertEqual(split.fullCards, [older])
        XCTAssertEqual(split.compactRows, [workspace])
    }

    /// When EVERY session is an Antigravity workspace row, none becomes a full card — they all
    /// stay compact rather than vanishing entirely.
    func testAllAntigravityWorkspaceRowsStayCompactWhenNothingElseQualifies() {
        let a = session("antigravity:a", .idle, at: 500, agentName: "Antigravity")
        let b = session("antigravity:b", .idle, at: 100, agentName: "Antigravity")

        let split = SessionLayout.split(sessions: [a, b])

        XCTAssertEqual(split.fullCards, [])
        XCTAssertEqual(split.compactRows, [a, b])
    }

    private func session(
        _ id: String,
        _ status: SessionStatus,
        at seconds: TimeInterval,
        agentName: String = "Claude"
    ) -> AgentSession {
        AgentSession(
            sessionId: id,
            agentName: agentName,
            cwd: "/tmp/\(id)",
            modifiedAt: Date(timeIntervalSince1970: seconds),
            status: status,
            jumpRung: .newTab,
            title: id,
            lastPrompt: nil,
            tty: nil,
            terminalName: nil,
            currentActivity: nil,
            notificationMessage: nil,
            pendingToolName: nil,
            pendingToolInput: nil,
            resumeCommand: nil
        )
    }
}
