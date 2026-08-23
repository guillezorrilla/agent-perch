import Foundation
import XCTest
@testable import AgentPerch

/// #25: with Claude Code in auto/bypass permission mode the agent never asks for approval, yet
/// the ~60s "Claude is waiting for your input" nudge still fires. It is not a request and must
/// not be treated as one.
final class NotificationOutcomeTests: XCTestCase {
    private let questionInput = JSONValue.object([
        "questions": .array([.object([
            "question": .string("Which target?"),
            "options": .array([.object(["label": .string("Staging")])])
        ])])
    ])

    func testPermissionWordingIsAlwaysARequest() {
        XCTAssertEqual(
            NotificationOutcome.of(
                message: "Claude needs your permission to use Bash",
                currentStatus: .working,
                pendingToolName: "Bash",
                pendingToolInput: .object(["command": .string("rm -rf build")])
            ),
            .needsAction
        )
    }

    func testIdleNudgeEndsTheTurnInsteadOfDemandingAction() {
        for status in [SessionStatus.working, .active, .idle] {
            XCTAssertEqual(
                NotificationOutcome.of(
                    message: "Claude is waiting for your input",
                    currentStatus: status,
                    pendingToolName: "Bash",
                    pendingToolInput: .object(["command": .string("grep -n needle Sources")])
                ),
                .finished,
                "\(status)"
            )
        }
    }

    /// The tool call IS the wait — #14's cards must survive the change.
    func testAQuestionOrPlanKeepsTheSessionNeedingAction() {
        XCTAssertEqual(
            NotificationOutcome.of(
                message: "Claude is waiting for your input",
                currentStatus: .working,
                pendingToolName: "AskUserQuestion",
                pendingToolInput: questionInput
            ),
            .needsAction
        )
        XCTAssertEqual(
            NotificationOutcome.of(
                message: "Claude is waiting for your input",
                currentStatus: .working,
                pendingToolName: "ExitPlanMode",
                pendingToolInput: .object(["plan": .string("# Ship it")])
            ),
            .needsAction
        )
    }

    func testAnIdleNudgeAfterTheTurnEndedChangesNothing() {
        for status in [SessionStatus.done, .ended] {
            XCTAssertEqual(
                NotificationOutcome.of(
                    message: "Claude is waiting for your input",
                    currentStatus: status,
                    pendingToolName: nil,
                    pendingToolInput: nil
                ),
                .ignored,
                "\(status)"
            )
        }
    }

    /// The nudge is about the request already on screen; overwriting its message with "waiting
    /// for your input" would dissolve the very card the user is being nudged to answer.
    func testAnIdleNudgeDoesNotDisturbARequestAlreadyWaiting() {
        XCTAssertEqual(
            NotificationOutcome.of(
                message: "Claude is waiting for your input",
                currentStatus: .needsAction,
                pendingToolName: nil,
                pendingToolInput: nil
            ),
            .ignored
        )
    }
}

final class IdleNotificationStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Amber pulse, macOS notification and needs-action auto-expand all hang off a transition
    /// INTO `.needsAction` — so the absence of one is the absence of all three.
    @MainActor
    func testAnIdleNudgeNeitherGoesAmberNorNotifies() throws {
        let store = makeStore()
        var transitions: [SessionStatus] = []
        store.onTransition = { transitions.append($0.session.status) }

        try send(to: store, "UserPromptSubmit", timestamp: 100, fields: #", "prompt":"go""#)
        try send(
            to: store,
            "Notification",
            timestamp: 160,
            fields: #", "message":"Claude is waiting for your input""#
        )

        XCTAssertEqual(store.sessions.first?.status, .done)
        XCTAssertNil(store.sessions.first?.notificationMessage)
        XCTAssertNil(store.sessions.first?.pendingAction)
        XCTAssertFalse(store.hasUnresolvedPendingAction)
        XCTAssertFalse(transitions.contains(.needsAction))
    }

    @MainActor
    func testAPermissionNotificationStillNeedsAction() throws {
        let store = makeStore()
        var transitions: [SessionStatus] = []
        store.onTransition = { transitions.append($0.session.status) }

        try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude needs your permission to use Bash""#
        )

        XCTAssertEqual(store.sessions.first?.status, .needsAction)
        XCTAssertNotNil(store.sessions.first?.pendingAction)
        XCTAssertEqual(transitions.last, .needsAction)
    }

    /// #14: an `AskUserQuestion` is blocked on the user whatever the notification says.
    @MainActor
    func testAQuestionStillNeedsActionUnderAnIdleNudge() throws {
        let store = makeStore()

        try send(
            to: store,
            "PreToolUse",
            timestamp: 100,
            fields: #", "tool_name":"AskUserQuestion", "tool_input":{"questions":[{"question":"Which target?", "options":[{"label":"Staging"},{"label":"Production"}]}]}"#
        )
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude is waiting for your input""#
        )

        XCTAssertEqual(store.sessions.first?.status, .needsAction)
        XCTAssertTrue(store.hasUnresolvedPendingAction)
        guard case .question? = store.sessions.first?.pendingAction else {
            return XCTFail("Expected the question card to survive")
        }
    }

    /// The nudge arrives ~60s after the turn ended, so it lands on a session that is already
    /// done. It must change nothing at all — not the status, not the sort order, not the clock
    /// the ended-session grace period runs on.
    @MainActor
    func testAnIdleNudgeAfterStopDoesNotResurrectTheSession() throws {
        let store = makeStore()
        var transitions: [SessionStatus] = []

        try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
        try send(to: store, "Stop", timestamp: 101)
        store.onTransition = { transitions.append($0.session.status) }
        let modifiedAt = store.sessions.first?.modifiedAt

        try send(
            to: store,
            "Notification",
            timestamp: 161,
            fields: #", "message":"Claude is waiting for your input""#
        )

        XCTAssertEqual(store.sessions.first?.status, .done)
        XCTAssertEqual(store.sessions.first?.modifiedAt, modifiedAt)
        XCTAssertTrue(transitions.isEmpty)
    }

    @MainActor
    func testAnIdleNudgeAfterSessionEndKeepsItEndedAndOnItsOriginalGrace() throws {
        let store = makeStore()

        try send(to: store, "SessionEnd", timestamp: 100)
        try send(
            to: store,
            "Notification",
            timestamp: 160,
            fields: #", "message":"Claude is waiting for your input""#
        )

        XCTAssertEqual(store.sessions.first?.status, .ended)
        // Still measured from the SessionEnd at t=100, not from the nudge at t=160.
        store.removeEndedSessions(now: Date(timeIntervalSince1970: 130))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// An answered card's confirmation is only cut short by something new to answer.
    @MainActor
    func testAnIdleNudgeDoesNotCutAnAnsweredConfirmationShort() throws {
        let store = makeStore()
        try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude needs your permission to use Bash""#
        )
        store.markAnswered("session-1", label: "Approved ✓")

        try send(
            to: store,
            "Notification",
            timestamp: 102,
            fields: #", "message":"Claude is waiting for your input""#
        )

        XCTAssertEqual(store.resolutions["session-1"], .answered("Approved ✓"))
    }

    private let bashFields = #", "tool_name":"Bash", "tool_input":{"command":"grep -n needle Sources"}"#

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
            // A live process for the session these tests drive: without one, sustained absence
            // retires the row and every assertion below becomes vacuously true.
            processProvider: { [ClaudeProcess(pid: 1, command: "claude", cwd: "/tmp/repo", tty: "ttys001")] }
        )
    }

    @MainActor
    private func send(
        to store: SessionStore,
        _ name: String,
        timestamp: Int,
        fields: String = ""
    ) throws {
        let event = try HookEvent.parse(Data("""
        {"event":"\(name)","tty":"ttys001","ts":\(timestamp),"payload":{"session_id":"session-1","cwd":"/tmp/repo"\(fields)}}
        """.utf8))
        store.handle(event, now: event.timestamp)
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
