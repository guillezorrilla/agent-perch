import Foundation
import XCTest
@testable import AgentPerch

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

/// The pure decision behind `FeaturedSessionCard.statusLine` (#31, #52). Two rules, one for each
/// half of "is this session actually working": a hookless session (`supportsLiveStatus == false`,
/// e.g. Codex or the `agy` CLI) may never claim it at all, and a hook-backed (Claude) one may only
/// claim it while a HOOK says so — `.working` — never on a status derived from a file's mtime.
final class SessionStatusPresentationTests: XCTestCase {
    func testClaudeWorkingWithNoActivityYetShowsTheSpinner() {
        XCTAssertEqual(SessionStatusPresentation.of(session(.working, currentActivity: nil)), .workingSpinner)
    }

    func testClaudeWorkingWithAnActivityDescriptionShowsIt() {
        XCTAssertEqual(
            SessionStatusPresentation.of(session(.working, currentActivity: "Editing main.swift")),
            .activity("Editing main.swift")
        )
    }

    func testClaudeNeedsActionAndDoneAreUnaffectedByLiveStatusSupport() {
        XCTAssertEqual(SessionStatusPresentation.of(session(.needsAction)), .needsAction)
        XCTAssertEqual(SessionStatusPresentation.of(session(.done)), .done)
        XCTAssertEqual(SessionStatusPresentation.of(session(.ended)), .done)
    }

    /// The regression at the heart of #31: a hookless session's `.active` is only "recently
    /// touched and a live process", never a verified turn — it must render `.neutral`, not the
    /// spinner, even though `.active` is normally a "busy" status.
    func testHooklessActiveSessionShowsNeutralNeverTheWorkingSpinner() {
        XCTAssertEqual(
            SessionStatusPresentation.of(session(.active, supportsLiveStatus: false)),
            .neutral
        )
    }

    func testHooklessIdleSessionAlsoShowsNeutral() {
        XCTAssertEqual(
            SessionStatusPresentation.of(session(.idle, supportsLiveStatus: false)),
            .neutral
        )
    }

    /// The regression #52 is about, and the one that matters most: a hook-backed session sitting
    /// idle between turns is NOT working. `.idle` is `SessionStatus.at` saying the transcript was
    /// written a while ago — it was never evidence of a turn — and presenting it as the spinner
    /// is what left a card claiming "Working…" five minutes after its last turn ended.
    func testClaudeIdleSessionNeverPresentsAsWorking() {
        XCTAssertEqual(SessionStatusPresentation.of(session(.idle)), .neutral)
        XCTAssertFalse(SessionStatusPresentation.of(session(.idle)).isWorking)
    }

    /// The other half of #52: a hook-backed `.active` is mtime-derived exactly like `.idle` — the
    /// status a fresh transcript write produces, including the write that overwrites a hook-set
    /// `.done` — so it is neutral too. This asserted `.workingSpinner` before #52.
    func testClaudeActiveSessionShowsNeutralBecauseMtimeIsNotEvidenceOfATurn() {
        XCTAssertEqual(SessionStatusPresentation.of(session(.active)), .neutral)
    }

    /// `isWorking` is what #53 lets the invader move on, so it must agree with the card exactly:
    /// only the two hook-verified in-flight presentations count.
    func testOnlyAHookVerifiedTurnCountsAsWorking() {
        XCTAssertTrue(SessionStatusPresentation.workingSpinner.isWorking)
        XCTAssertTrue(SessionStatusPresentation.activity("Editing main.swift").isWorking)
        XCTAssertFalse(SessionStatusPresentation.neutral.isWorking)
        XCTAssertFalse(SessionStatusPresentation.needsAction.isWorking)
        XCTAssertFalse(SessionStatusPresentation.done.isWorking)
    }

    private func session(
        _ status: SessionStatus,
        currentActivity: String? = nil,
        supportsLiveStatus: Bool = true
    ) -> AgentSession {
        AgentSession(
            sessionId: "id",
            agentName: "Claude",
            cwd: "/tmp/id",
            modifiedAt: Date(timeIntervalSince1970: 0),
            status: status,
            jumpRung: .newTab,
            title: "id",
            lastPrompt: nil,
            tty: nil,
            terminalName: nil,
            currentActivity: currentActivity,
            notificationMessage: nil,
            pendingToolName: nil,
            pendingToolInput: nil,
            resumeCommand: nil,
            supportsLiveStatus: supportsLiveStatus
        )
    }
}

/// The path that actually produced the bug in #52, driven through the real `SessionStore`: `Stop`
/// sets `.done`, then a transcript write landing after it wins `reconcile`'s `hookWins` check and
/// replaces that `.done` with a freshness-derived `.active`. The status is genuinely `.active` and
/// that is fine — what must not happen is the card turning that back into "Working…".
final class IdleCardNeverClaimsWorkTests: XCTestCase {
    private struct FakeSource: AgentSessionSource {
        let agentName: String
        let sessions: [DiscoveredSession]
        func discover(now: Date) -> [DiscoveredSession] { sessions }
    }

    private let t0 = Date(timeIntervalSince1970: 1_786_000_000)

    @MainActor
    func testATranscriptWriteAfterStopOverwritesDoneAndTheCardStillDoesNotClaimToBeWorking() throws {
        // A second after the turn ended — the transcript's last flush, exactly the ordering the
        // `hookWins` comparison stands down for.
        let store = makeStore(discoveredLastActivity: t0.addingTimeInterval(1))

        try send(to: store, "Stop", at: t0)
        let finished = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(SessionStatusPresentation.of(finished), .done, "the hook alone gets this right")

        store.refresh(now: t0.addingTimeInterval(2))

        let overwritten = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(overwritten.status, .active, "discovery outranks the older hook — unchanged")
        XCTAssertNil(overwritten.currentActivity)
        XCTAssertEqual(SessionStatusPresentation.of(overwritten), .neutral)
        XCTAssertFalse(SessionStatusPresentation.of(overwritten).isWorking)
    }

    /// The case the spinner exists for, through the same store: a hook says the turn started, no
    /// tool has been named yet. #52 must not take this away.
    @MainActor
    func testAHookVerifiedTurnWithNoToolNamedYetStillSpins() throws {
        let store = makeStore(discoveredLastActivity: t0.addingTimeInterval(1))

        try send(to: store, "UserPromptSubmit", at: t0.addingTimeInterval(5))

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(SessionStatusPresentation.of(session), .workingSpinner)
        XCTAssertTrue(SessionStatusPresentation.of(session).isWorking)
    }

    @MainActor
    private func makeStore(discoveredLastActivity: Date) -> SessionStore {
        SessionStore(
            sources: [FakeSource(agentName: "Claude", sessions: [
                DiscoveredSession(
                    sessionId: "session-1",
                    agentName: "Claude",
                    cwd: "/tmp/repo",
                    title: "repo",
                    // What `SessionStatus.at` hands back for a transcript touched seconds ago —
                    // the status that lands on the card once discovery outranks the hook.
                    lastActivity: discoveredLastActivity,
                    status: .active,
                    resumeCommand: nil,
                    sessionFileURL: nil
                )
            ])],
            processProvider: { [] },
            terminalResolver: TerminalNameResolver(process: { _ in nil })
        )
    }

    @MainActor
    private func send(to store: SessionStore, _ name: String, at timestamp: Date) throws {
        let event = try HookEvent.parse(Data("""
        {"event":"\(name)","tty":"ttys001","ts":\(Int(timestamp.timeIntervalSince1970)),\
        "payload":{"session_id":"session-1","cwd":"/tmp/repo"}}
        """.utf8))
        store.handle(event, now: event.timestamp)
    }
}

/// The invader's animation (#53) is one pure function of `(isWorking, phase)` plus two pixel grids
/// that must occupy the same box. Both are tested here; nothing about SwiftUI's rendering is.
final class InvaderGlyphAnimationTests: XCTestCase {
    /// The requirement movement is supposed to carry: a session that is not working never leaves
    /// the resting pose, whatever the clock is doing.
    func testANonWorkingGlyphIsAlwaysOnTheStaticFrame() {
        for phase in 0..<8 {
            XCTAssertEqual(InvaderGlyph.frame(isWorking: false, phase: phase), .rest)
        }
    }

    func testAWorkingGlyphAlternatesBetweenTheTwoFramesEveryBeat() {
        XCTAssertEqual(InvaderGlyph.frame(isWorking: true, phase: 0), .rest)
        XCTAssertEqual(InvaderGlyph.frame(isWorking: true, phase: 1), .step)
        XCTAssertEqual(InvaderGlyph.frame(isWorking: true, phase: 2), .rest)
        XCTAssertEqual(InvaderGlyph.frame(isWorking: true, phase: 3), .step)
    }

    /// Stopping is a return to a real pose, not a freeze wherever the beat left the glyph: the
    /// same phase that draws `.step` while working draws `.rest` the moment it stops.
    func testStoppingMidBeatLandsOnTheRestingPoseRatherThanHoldingTheOtherFrame() {
        XCTAssertEqual(InvaderGlyph.frame(isWorking: true, phase: 7), .step)
        XCTAssertEqual(InvaderGlyph.frame(isWorking: false, phase: 7), .rest)
    }

    /// The phase has to advance exactly once per beat, or the two frames would swap at some other
    /// rate than the one the beat documents.
    func testPhaseAdvancesOnceEveryBeat() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(InvaderGlyph.phase(at: start), 0)
        XCTAssertEqual(InvaderGlyph.phase(at: start.addingTimeInterval(InvaderGlyph.beat)), 1)
        XCTAssertEqual(InvaderGlyph.phase(at: start.addingTimeInterval(InvaderGlyph.beat * 4)), 4)
        // Mid-beat is still the same beat — the pose holds for the whole interval.
        XCTAssertEqual(InvaderGlyph.phase(at: start.addingTimeInterval(InvaderGlyph.beat * 0.5)), 0)
    }

    /// Slow enough to stay clear of `NotchHoverController`'s 0.1s poll and its two-tick exit
    /// grace (#49) — if this ever gets tightened, that is the thing to re-check.
    func testTheBeatStaysSlow() {
        XCTAssertGreaterThanOrEqual(InvaderGlyph.beat, 0.25)
        XCTAssertLessThanOrEqual(InvaderGlyph.beat, 1.0)
    }

    /// The anti-jitter invariant: both poses are the same 11×8 grid, so alternating them can
    /// never resize the glyph or change a card's height.
    func testBothFramesOccupyIdenticalBounds() {
        for pixels in [InvaderGlyph.restPixels, InvaderGlyph.stepPixels] {
            XCTAssertEqual(pixels.count, InvaderGlyph.rows)
            XCTAssertEqual(Set(pixels.map(\.count)), [InvaderGlyph.columns])
        }
    }

    /// Two poses, not one drawn twice — otherwise "animating" would be indistinguishable from
    /// standing still.
    func testTheTwoFramesActuallyDiffer() {
        XCTAssertNotEqual(InvaderGlyph.restPixels, InvaderGlyph.stepPixels)
    }
}

/// A card must not claim to be alive when nothing is running behind it (#64).
///
/// `.active` comes from transcript mtime — `SessionStatus.at` grants it for five whole minutes —
/// so four finished demo sessions sat in the panel with green dots, indistinguishable from the
/// three live ones. This is #52's rule one level out: liveness reaches the dot now, not just
/// retirement and ordering.
final class DeadRowsLookDeadTests: XCTestCase {
    private func session(_ status: SessionStatus) -> AgentSession {
        AgentSession(
            sessionId: "s", agentName: "Claude", cwd: "/tmp/s",
            modifiedAt: Date(timeIntervalSince1970: 0), status: status,
            jumpRung: .newTab, title: "s", lastPrompt: nil, tty: nil, terminalName: nil,
            currentActivity: nil, notificationMessage: nil, pendingToolName: nil,
            pendingToolInput: nil, resumeCommand: nil
        )
    }

    func testASustainedlyAbsentProcessMakesAnActiveRowFinished() {
        XCTAssertEqual(
            SessionRetirement.told(session(.active), sustainedlyAbsent: true).status,
            .done
        )
        XCTAssertEqual(
            SessionRetirement.told(session(.working), sustainedlyAbsent: true).status,
            .done
        )
    }

    /// The whole reason absence has to be SUSTAINED: one missed `pgrep`/`lsof` pass must never
    /// grey out a session that is genuinely working.
    func testAPresentProcessLeavesTheStatusAlone() {
        XCTAssertEqual(
            SessionRetirement.told(session(.active), sustainedlyAbsent: false).status,
            .active
        )
        XCTAssertEqual(
            SessionRetirement.told(session(.working), sustainedlyAbsent: false).status,
            .working
        )
    }

    /// Dissolving a card the user is looking at is a worse surprise than one that sorts last —
    /// `ordered` already sinks a dead row's stale prompt below every live session.
    func testAPendingRequestIsNotDowngraded() {
        XCTAssertEqual(
            SessionRetirement.told(session(.needsAction), sustainedlyAbsent: true).status,
            .needsAction
        )
    }

    func testAlreadyFinishedStatesAreUntouched() {
        for status in [SessionStatus.idle, .done, .ended] {
            XCTAssertEqual(
                SessionRetirement.told(session(status), sustainedlyAbsent: true).status,
                status
            )
        }
    }
}
