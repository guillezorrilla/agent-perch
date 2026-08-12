import Foundation
import XCTest
@testable import VibeNotch

final class NotificationKindTests: XCTestCase {
    func testPermissionWordingExtractsTheToolName() {
        XCTAssertEqual(
            NotificationKind.classify("Claude needs your permission to use Bash"),
            .permission(tool: "Bash")
        )
        XCTAssertEqual(
            NotificationKind.classify("Claude needs your permission to use the Edit tool."),
            .permission(tool: "Edit")
        )
        XCTAssertEqual(
            NotificationKind.classify("Claude needs your permission to use mcp__ide__getDiagnostics."),
            .permission(tool: "mcp__ide__getDiagnostics")
        )
    }

    func testPermissionWordingWithoutAnExtractableToolName() {
        XCTAssertEqual(
            NotificationKind.classify("Permission required for this action"),
            .permission(tool: nil)
        )
        XCTAssertEqual(
            NotificationKind.classify("Claude needs permission before continuing"),
            .permission(tool: nil)
        )
    }

    func testWaitingWording() {
        XCTAssertEqual(
            NotificationKind.classify("Claude is waiting for your input"),
            .waiting
        )
        XCTAssertEqual(NotificationKind.classify("Claude Code is idle"), .waiting)
    }

    /// Wording we don't recognise must never become an Allow/Deny card: that card types a "1"
    /// into a shell that was not asking for one.
    func testUnknownWordingFallsBackToWaiting() {
        XCTAssertEqual(NotificationKind.classify("Approve Bash?"), .waiting)
        XCTAssertEqual(NotificationKind.classify("Something entirely new"), .waiting)
        XCTAssertEqual(NotificationKind.classify(""), .waiting)
        XCTAssertEqual(NotificationKind.classify(nil), .waiting)
    }
}

final class PendingActionResolveTests: XCTestCase {
    private let bashInput = JSONValue.object(["command": .string("grep -n needle Sources")])

    func testARecordedToolCallAloneIsNotAPermissionRequest() {
        XCTAssertNil(PendingAction.resolve(
            status: .needsAction,
            notificationMessage: nil,
            toolName: "Bash",
            toolInput: bashInput
        ))
    }

    func testWorkingSessionsNeverShowACard() {
        XCTAssertNil(PendingAction.resolve(
            status: .working,
            notificationMessage: "Claude needs your permission to use Bash",
            toolName: "Bash",
            toolInput: bashInput
        ))
    }

    func testMatchingToolNameKeepsThePreview() throws {
        let action = try XCTUnwrap(PendingAction.resolve(
            status: .needsAction,
            notificationMessage: "Claude needs your permission to use bash",
            toolName: "Bash",
            toolInput: bashInput
        ))

        guard case let .permission(request) = action else {
            return XCTFail("Expected a permission request")
        }
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.target, "grep -n needle Sources")
    }

    func testMismatchedToolNameDropsTheOtherToolsPreview() throws {
        let action = try XCTUnwrap(PendingAction.resolve(
            status: .needsAction,
            notificationMessage: "Claude needs your permission to use Edit",
            toolName: "Bash",
            toolInput: bashInput
        ))

        guard case let .permission(request) = action else {
            return XCTFail("Expected a permission request")
        }
        XCTAssertEqual(request.toolName, "Edit")
        XCTAssertEqual(request.target, "")
        XCTAssertEqual(request.details, "Claude needs your permission to use Edit")
        XCTAssertNil(request.diff)
    }

    /// The reported case: Claude Code's wording for a Write is a bare "Claude needs your
    /// permission", with nothing after "to use " to parse. The card used to render that sentence
    /// and nothing else, so the user pressed ⌘Y without being shown what they were approving.
    func testUnnamedPermissionShowsTheFileBeingWritten() throws {
        let action = try XCTUnwrap(PendingAction.resolve(
            status: .needsAction,
            notificationMessage: "Claude needs your permission",
            toolName: "Write",
            toolInput: .object([
                "file_path": .string("/tmp/question-demo/answer.txt"),
                "content": .string("Apple")
            ])
        ))

        guard case let .permission(request) = action else {
            return XCTFail("Expected a permission request")
        }
        XCTAssertEqual(request.toolName, "Write")
        XCTAssertEqual(request.target, "question-demo/answer.txt")
        XCTAssertNotNil(request.diff, "the content being written is the point of the card")
    }

    func testUnnamedPermissionAdoptsTheRecordedCall() throws {
        let action = try XCTUnwrap(PendingAction.resolve(
            status: .needsAction,
            notificationMessage: "Permission required for this action",
            toolName: "Bash",
            toolInput: bashInput
        ))

        guard case let .permission(request) = action else {
            return XCTFail("Expected a permission request")
        }
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.target, "grep -n needle Sources")
    }

    /// Nothing recorded to attribute it to — the message is genuinely all there is.
    func testUnnamedPermissionWithNothingRecordedStillShowsTheMessage() throws {
        let action = try XCTUnwrap(PendingAction.resolve(
            status: .needsAction,
            notificationMessage: "Permission required for this action",
            toolName: nil,
            toolInput: nil
        ))

        XCTAssertEqual(action, .permission(PermissionRequest(
            toolName: "",
            target: "",
            details: "Permission required for this action",
            diff: nil
        )))
    }
}

final class PendingActionStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The reported bug: a grep Claude auto-approved, followed by an unrelated idle nudge. The
    /// nudge shows no card (#22) and, since #25, does not mark the session needs-action either —
    /// nothing is blocked, the turn is simply over.
    @MainActor
    func testIdleNotificationAfterAnAutoApprovedToolShowsNoPermissionCard() throws {
        let store = makeStore()

        try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude is waiting for your input""#
        )

        XCTAssertEqual(store.sessions.first?.status, .done)
        XCTAssertEqual(store.sessions.first?.pendingToolName, "Bash")
        XCTAssertNil(store.sessions.first?.pendingAction)
        XCTAssertFalse(store.hasUnresolvedPendingAction)
    }

    @MainActor
    func testPermissionNotificationForTheRecordedToolKeepsThePreview() throws {
        let store = makeStore()

        try send(
            to: store,
            "PreToolUse",
            timestamp: 100,
            fields: #", "tool_name":"Edit", "tool_input":{"file_path":"/repo/Sources/App.swift", "old_string":"old", "new_string":"new"}"#
        )
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude needs your permission to use Edit""#
        )

        guard case let .permission(request)? = store.sessions.first?.pendingAction else {
            return XCTFail("Expected a permission request")
        }
        XCTAssertEqual(request.toolName, "Edit")
        XCTAssertEqual(request.target, "Sources/App.swift")
        XCTAssertEqual(request.diff?.addedCount, 1)
        XCTAssertTrue(store.hasUnresolvedPendingAction)
    }

    @MainActor
    func testPermissionNotificationForAnotherToolShowsNoPreview() throws {
        let store = makeStore()

        try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude needs your permission to use Edit""#
        )

        guard case let .permission(request)? = store.sessions.first?.pendingAction else {
            return XCTFail("Expected a permission request")
        }
        XCTAssertEqual(request.toolName, "Edit")
        XCTAssertNil(request.diff)
        XCTAssertEqual(request.details, "Claude needs your permission to use Edit")
    }

    /// A question blocks on the user by definition, so the idle wording that accompanies it must
    /// not suppress it.
    @MainActor
    func testQuestionSurvivesAWaitingNotification() throws {
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

        guard case let .question(prompt)? = store.sessions.first?.pendingAction else {
            return XCTFail("Expected a question prompt")
        }
        XCTAssertEqual(prompt.options, ["Staging", "Production"])
    }

    @MainActor
    func testPlanSurvivesAWaitingNotification() throws {
        let store = makeStore()

        try send(
            to: store,
            "PreToolUse",
            timestamp: 100,
            fields: ##", "tool_name":"ExitPlanMode", "tool_input":{"plan":"# Ship it"}"##
        )
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude is waiting for your input""#
        )

        XCTAssertEqual(store.sessions.first?.pendingAction, .plan("# Ship it"))
    }

    @MainActor
    func testPendingActionClearsWhenTheAgentMovesOn() throws {
        for (index, moveOn) in [
            (name: "UserPromptSubmit", fields: #", "prompt":"carry on""#),
            (name: "Stop", fields: ""),
            (name: "SessionEnd", fields: ""),
            (name: "PreToolUse", fields: #", "tool_name":"Write", "tool_input":{"file_path":"/repo/New.swift"}"#)
        ].enumerated() {
            let store = makeStore()
            try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
            try send(
                to: store,
                "Notification",
                timestamp: 101,
                fields: #", "message":"Claude needs your permission to use Bash""#
            )
            XCTAssertNotNil(store.sessions.first?.pendingAction, "setup \(index)")

            try send(to: store, moveOn.name, timestamp: 102, fields: moveOn.fields)

            XCTAssertNil(store.sessions.first?.notificationMessage, moveOn.name)
            XCTAssertNil(store.sessions.first?.pendingAction, moveOn.name)
            XCTAssertFalse(store.hasUnresolvedPendingAction, moveOn.name)
        }
    }

    @MainActor
    func testAnsweringResolvesTheCardThenDropsItBackToTheNormalBody() throws {
        let store = makeStore()
        var dismissals = 0
        store.onAnswerDismissed = { dismissals += 1 }
        try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude needs your permission to use Bash""#
        )

        store.markAnswered("session-1", label: "Approved ✓")

        XCTAssertEqual(store.resolutions["session-1"], .answered("Approved ✓"))
        // Answered cards no longer hold the dwell open — their own hold does.
        XCTAssertFalse(store.hasUnresolvedPendingAction)

        store.dismissAnswered("session-1")

        XCTAssertNil(store.resolutions["session-1"])
        XCTAssertNil(store.sessions.first?.pendingAction)
        XCTAssertNil(store.sessions.first?.pendingToolName)
        XCTAssertEqual(dismissals, 1)
    }

    @MainActor
    func testFailedInjectionMarksTheFailureAndKeepsTheCardUntilTheAgentMovesOn() throws {
        let store = makeStore()
        try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude needs your permission to use Bash""#
        )

        store.markUnanswerable("session-1")

        XCTAssertEqual(store.resolutions["session-1"], .failed)
        XCTAssertNotNil(store.sessions.first?.pendingAction)
        // Still the user's problem to solve, so the panel stays open for it.
        XCTAssertTrue(store.hasUnresolvedPendingAction)

        try send(to: store, "Stop", timestamp: 102)

        XCTAssertNil(store.resolutions["session-1"])
    }

    /// A second request arriving inside the confirmation's hold must win: a stale "Approved ✓"
    /// sitting on top of it would swallow the new question entirely.
    @MainActor
    func testANewNotificationDuringTheHoldReplacesTheConfirmation() throws {
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
            "PreToolUse",
            timestamp: 102,
            fields: #", "tool_name":"Write", "tool_input":{"file_path":"/repo/New.swift", "content":"hi"}"#
        )
        try send(
            to: store,
            "Notification",
            timestamp: 103,
            fields: #", "message":"Claude needs your permission to use Write""#
        )

        XCTAssertNil(store.resolutions["session-1"])
        guard case let .permission(request)? = store.sessions.first?.pendingAction else {
            return XCTFail("Expected the new permission request")
        }
        XCTAssertEqual(request.toolName, "Write")
    }

    @MainActor
    func testJumpingFromAFailedCardClearsItsBanner() throws {
        let store = makeStore()
        try send(to: store, "PreToolUse", timestamp: 100, fields: bashFields)
        try send(
            to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Claude needs your permission to use Bash""#
        )
        store.markUnanswerable("session-1")

        store.clearResolution("session-1")

        XCTAssertNil(store.resolutions["session-1"])
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
            processProvider: { [] }
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
