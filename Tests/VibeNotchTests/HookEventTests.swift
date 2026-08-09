import Foundation
import XCTest
@testable import VibeNotch

final class HookEventTests: XCTestCase {
    func testParsesTTYAndNestedPayload() throws {
        let event = try HookEvent.parse(Data(#"""
        {
            "event":"PreToolUse",
            "tty":"ttys004",
            "ts":1234,
            "payload":{
                "session_id":"session-1",
                "tool_name":"Bash",
                "tool_input":{"command":"swift test","flags":["--quiet"]}
            }
        }
        """#.utf8))

        XCTAssertEqual(event.event, "PreToolUse")
        XCTAssertEqual(event.tty, "ttys004")
        XCTAssertEqual(event.timestamp, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(event.sessionID, "session-1")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(
            event.toolInput,
            .object([
                "command": .string("swift test"),
                "flags": .array([.string("--quiet")])
            ])
        )
    }

    func testExtractsPlanMarkdownFromPreToolUseFixture() throws {
        let event = try HookEvent.parse(Data(#"""
        {
            "event":"PreToolUse",
            "tty":"ttys004",
            "ts":1234,
            "payload":{
                "session_id":"session-1",
                "tool_name":"ExitPlanMode",
                "tool_input":{"plan":"# Ship it\n\n- Build\n- Verify"}
            }
        }
        """#.utf8))

        XCTAssertEqual(
            PendingAction.parse(toolName: event.toolName, input: event.toolInput),
            .plan("# Ship it\n\n- Build\n- Verify")
        )
    }
}

final class ActivityLineTests: XCTestCase {
    func testDescribesFileToolsWithBasename() {
        let input = JSONValue.object(["file_path": .string("/repo/Sources/App.swift")])

        for tool in ["Edit", "MultiEdit", "Write", "NotebookEdit"] {
            XCTAssertEqual(ActivityLine.describe(toolName: tool, toolInput: input), "Writing App.swift")
        }
        XCTAssertEqual(ActivityLine.describe(toolName: "Read", toolInput: input), "Reading App.swift")
    }

    func testDescribesBashWithSingleLineTruncatedCommand() {
        let command = "swift test\n--filter ActivityLineTests and-more-text"

        XCTAssertEqual(
            ActivityLine.describe(
                toolName: "Bash",
                toolInput: .object(["command": .string(command)])
            ),
            "Running swift test --filter ActivityLineTests an"
        )
    }

    func testDescribesSearchTools() {
        XCTAssertEqual(
            ActivityLine.describe(
                toolName: "Grep",
                toolInput: .object(["pattern": .string("currentActivity")])
            ),
            "Searching currentActivity"
        )
        XCTAssertEqual(
            ActivityLine.describe(
                toolName: "Glob",
                toolInput: .object(["path": .string("Sources/VibeNotch")])
            ),
            "Searching Sources/VibeNotch"
        )
    }

    func testDescribesWebTools() {
        XCTAssertEqual(
            ActivityLine.describe(
                toolName: "WebFetch",
                toolInput: .object(["url": .string("https://docs.swift.org/swift-book")])
            ),
            "Fetching docs.swift.org"
        )
        XCTAssertEqual(
            ActivityLine.describe(toolName: "WebSearch", toolInput: nil),
            "Searching the web"
        )
    }

    func testDescribesWorkflowTools() {
        XCTAssertEqual(
            ActivityLine.describe(toolName: "TodoWrite", toolInput: nil),
            "Updating the plan"
        )
        XCTAssertEqual(
            ActivityLine.describe(toolName: "Task", toolInput: nil),
            "Delegating a subtask"
        )
        XCTAssertEqual(
            ActivityLine.describe(toolName: "ExitPlanMode", toolInput: nil),
            "Awaiting plan approval"
        )
    }

    func testReturnsNilForUnknownOrMissingTools() {
        XCTAssertNil(ActivityLine.describe(toolName: "CustomTool", toolInput: .object([:])))
        XCTAssertNil(ActivityLine.describe(toolName: nil, toolInput: nil))
    }
}

final class SessionTransitionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    func testHookStateTransitionsAndEndedGraceRemoval() throws {
        let store = SessionStore(
            projectsDirectory: temporaryDirectory(),
            processProvider: { [] }
        )

        try send(to: store,
            "PreToolUse",
            timestamp: 100,
            fields: #", "tool_name":"Bash", "tool_input":{"command":"make app"}"#
        )
        XCTAssertEqual(store.sessions.first?.currentActivity, "Running make app")
        try send(to: store,
            "Notification",
            timestamp: 101,
            fields: #", "message":"Approve Bash?""#
        )
        XCTAssertEqual(store.sessions.first?.status, .needsAction)
        XCTAssertNil(store.sessions.first?.currentActivity)
        XCTAssertEqual(store.sessions.first?.notificationMessage, "Approve Bash?")
        XCTAssertEqual(store.sessions.first?.pendingToolName, "Bash")
        XCTAssertEqual(
            store.sessions.first?.pendingToolInput,
            .object(["command": .string("make app")])
        )

        try send(to: store,
            "UserPromptSubmit",
            timestamp: 102,
            fields: #", "prompt":"Please continue with the implementation""#
        )
        XCTAssertEqual(store.sessions.first?.status, .working)
        XCTAssertEqual(
            store.sessions.first?.lastPrompt,
            "Please continue with the implementation"
        )
        XCTAssertNil(store.sessions.first?.pendingToolName)
        XCTAssertNil(store.sessions.first?.pendingToolInput)

        try send(to: store,
            "PreToolUse",
            timestamp: 102,
            fields: #", "tool_name":"Write", "tool_input":{"file_path":"/tmp/repo/App.swift"}"#
        )
        XCTAssertEqual(store.sessions.first?.pendingToolName, "Write")
        XCTAssertEqual(store.sessions.first?.currentActivity, "Writing App.swift")

        try send(to: store, "Stop", timestamp: 103)
        XCTAssertEqual(store.sessions.first?.status, .done)
        XCTAssertNil(store.sessions.first?.currentActivity)
        XCTAssertNil(store.sessions.first?.pendingToolName)
        XCTAssertNil(store.sessions.first?.pendingToolInput)

        try send(to: store, "SessionEnd", timestamp: 104)
        XCTAssertEqual(store.sessions.first?.status, .ended)
        XCTAssertNil(store.sessions.first?.currentActivity)
        store.removeEndedSessions(now: Date(timeIntervalSince1970: 133))
        XCTAssertEqual(store.sessions.count, 1)
        store.removeEndedSessions(now: Date(timeIntervalSince1970: 134))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor
    func testNewerFileActivityWinsOverOlderHookState() throws {
        let projects = temporaryDirectory()
        let project = projects.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionFile = project.appendingPathComponent("session-1.jsonl")
        try Data().write(to: sessionFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: sessionFile.path
        )
        let store = SessionStore(projectsDirectory: projects, processProvider: { [] })

        try send(to: store,
            "Notification",
            timestamp: 100,
            fields: #", "message":"Old notice""#
        )
        store.refresh(now: Date(timeIntervalSince1970: 201))

        XCTAssertEqual(store.sessions.first?.status, .active)
    }

    @MainActor
    func testHookWinsOverFileMtimeFromTheSameWholeSecond() throws {
        let projects = temporaryDirectory()
        let project = projects.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sessionFile = project.appendingPathComponent("session-1.jsonl")
        try Data().write(to: sessionFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100.9)],
            ofItemAtPath: sessionFile.path
        )
        let store = SessionStore(projectsDirectory: projects, processProvider: { [] })
        store.refresh(now: Date(timeIntervalSince1970: 101))

        try send(to: store,
            "Notification",
            timestamp: 100,
            fields: #", "message":"Needs input""#
        )

        XCTAssertEqual(store.sessions.first?.status, .needsAction)
    }

    private func event(
        _ name: String,
        timestamp: Int,
        fields: String = ""
    ) throws -> HookEvent {
        try HookEvent.parse(Data("""
        {"event":"\(name)","tty":"ttys001","ts":\(timestamp),"payload":{"session_id":"session-1","cwd":"/tmp/repo"\(fields)}}
        """.utf8))
    }

    @MainActor
    private func send(
        to store: SessionStore,
        _ name: String,
        timestamp: Int,
        fields: String = ""
    ) throws {
        let hookEvent = try event(name, timestamp: timestamp, fields: fields)
        store.handle(hookEvent, now: hookEvent.timestamp)
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
