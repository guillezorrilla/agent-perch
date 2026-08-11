import Foundation
import XCTest
@testable import VibeNotch

final class ProgressViewTests: XCTestCase {
    // MARK: - Token summing

    /// The exact shape a real transcript writes, trimmed of fields nothing reads. Note
    /// `cache_read_input_tokens` dwarfing everything else — that is the whole point of it.
    private func usageLine(
        messageID: String,
        input: Int = 2,
        output: Int = 1_056,
        cacheCreation: Int = 22_066,
        cacheRead: Int = 22_113
    ) -> String {
        """
        {"type":"assistant","message":{"id":"\(messageID)","role":"assistant","usage":\
        {"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreation),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output),\
        "service_tier":"standard"}}}
        """
    }

    func testTokenSumCountsInputCreationAndOutputButNeverCacheReads() {
        let usage: [String: Any] = [
            "input_tokens": 2,
            "cache_creation_input_tokens": 22_066,
            "cache_read_input_tokens": 22_113,
            "output_tokens": 1_056
        ]

        // Cache reads are the same context re-read every turn; including them reported 6.5M for a
        // real 932KB transcript whose actual spend was 204k.
        XCTAssertEqual(TranscriptTokens.tokens(in: usage), 2 + 22_066 + 1_056)
    }

    func testMissingUsageFieldsCountAsZeroRatherThanFailing() {
        XCTAssertEqual(TranscriptTokens.tokens(in: [:]), 0)
        XCTAssertEqual(TranscriptTokens.tokens(in: ["output_tokens": 12]), 12)
    }

    func testRepeatedLinesForOneResponseAreCountedOnce() {
        // Claude Code writes one line per content block — text, thinking, each tool_use — and
        // every one of them repeats the same `usage`. A 932KB transcript had 165 such lines for
        // 63 responses; summing lines inflated it 2.6x.
        let chunk = [
            usageLine(messageID: "msg_a"),
            usageLine(messageID: "msg_a"),
            usageLine(messageID: "msg_a"),
            usageLine(messageID: "msg_b", input: 2, output: 361, cacheCreation: 2_930, cacheRead: 44_179)
        ].joined(separator: "\n")

        let scanned = TranscriptTokens.scan(chunk, after: nil)

        XCTAssertEqual(scanned.added, (2 + 22_066 + 1_056) + (2 + 2_930 + 361))
        XCTAssertEqual(scanned.lastMessageID, "msg_b")
    }

    func testAResponseSplitAcrossTwoChunksIsNotCountedTwice() {
        let first = TranscriptTokens.scan(usageLine(messageID: "msg_a"), after: nil)
        // The next read starts with the rest of that same response's lines.
        let second = TranscriptTokens.scan(
            [usageLine(messageID: "msg_a"), usageLine(messageID: "msg_b")].joined(separator: "\n"),
            after: first.lastMessageID
        )

        XCTAssertEqual(first.added, 2 + 22_066 + 1_056)
        XCTAssertEqual(second.added, 2 + 22_066 + 1_056)
        XCTAssertEqual(second.lastMessageID, "msg_b")
    }

    func testLinesWithoutUsageAreIgnored() {
        let chunk = [
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            usageLine(messageID: "msg_a"),
            "not json at all"
        ].joined(separator: "\n")

        XCTAssertEqual(TranscriptTokens.scan(chunk, after: nil).added, 2 + 22_066 + 1_056)
    }

    func testTallyReadsOnlyTheBytesAppendedSinceTheLastLook() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-\(UUID().uuidString).jsonl")
        try (usageLine(messageID: "msg_a") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tally = TranscriptTokenTally()
        let start = Date()
        let first = tally.tokens(forSessionID: "s1", transcript: url, now: start)
        XCTAssertEqual(first, 2 + 22_066 + 1_056)

        // Same file, nothing appended — and past the throttle, so it really did re-open it.
        let unchanged = tally.tokens(forSessionID: "s1", transcript: url, now: start.addingTimeInterval(2))
        XCTAssertEqual(unchanged, first)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((usageLine(messageID: "msg_b", output: 100, cacheCreation: 0, cacheRead: 99_999) + "\n").utf8))
        try handle.close()

        let grown = tally.tokens(forSessionID: "s1", transcript: url, now: start.addingTimeInterval(4))
        XCTAssertEqual(grown, first + 2 + 100)
    }

    func testTallyIgnoresAHalfWrittenTrailingLineUntilItIsComplete() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-partial-\(UUID().uuidString).jsonl")
        // The second line has no terminating newline yet — the agent is still writing it.
        let partial = usageLine(messageID: "msg_a") + "\n" + String(usageLine(messageID: "msg_b").prefix(40))
        try partial.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tally = TranscriptTokenTally()
        let start = Date()
        XCTAssertEqual(tally.tokens(forSessionID: "s1", transcript: url, now: start), 2 + 22_066 + 1_056)

        // Finish the line; the tally must pick it up whole rather than having skipped it.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(usageLine(messageID: "msg_b").dropFirst(40)) + "\n").utf8))
        try handle.close()

        XCTAssertEqual(
            tally.tokens(forSessionID: "s1", transcript: url, now: start.addingTimeInterval(2)),
            2 * (2 + 22_066 + 1_056)
        )
    }

    func testATranscriptLargerThanOnePassConvergesOverSuccessiveReads() throws {
        // Real transcripts run to tens of megabytes; a cold one must never land in a single
        // main-actor pass, so it is read `maxBytesPerPass` at a time and the number climbs. Each
        // response is three lines here, exactly as Claude Code writes them.
        let responses = 700
        let body = (1...responses)
            .flatMap { index in Array(repeating: usageLine(messageID: "msg_\(index)"), count: 3) }
            .joined(separator: "\n") + "\n"
        XCTAssertGreaterThan(body.utf8.count, TranscriptTokenTally.maxBytesPerPass)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-big-\(UUID().uuidString).jsonl")
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tally = TranscriptTokenTally()
        let expected = responses * (2 + 22_066 + 1_056)
        var total = 0
        var passes = 0
        let start = Date()
        while total < expected, passes < 40 {
            passes += 1
            total = tally.tokens(
                forSessionID: "s1",
                transcript: url,
                now: start.addingTimeInterval(Double(passes) * 2)
            )
        }

        XCTAssertGreaterThan(passes, 1, "a file this size should not be read in one pass")
        // No line straddling a pass boundary is lost, duplicated, or double-counted.
        XCTAssertEqual(total, expected)
    }

    func testTallyThrottlesRepeatedReadsWithinASecond() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-throttle-\(UUID().uuidString).jsonl")
        try (usageLine(messageID: "msg_a") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let tally = TranscriptTokenTally()
        let start = Date()
        let first = tally.tokens(forSessionID: "s1", transcript: url, now: start)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((usageLine(messageID: "msg_b") + "\n").utf8))
        try handle.close()

        // Reconcile fires several times a second during a busy turn; only the first pays.
        XCTAssertEqual(tally.tokens(forSessionID: "s1", transcript: url, now: start.addingTimeInterval(0.2)), first)
        XCTAssertGreaterThan(tally.tokens(forSessionID: "s1", transcript: url, now: start.addingTimeInterval(1.5)), first)
    }

    // MARK: - Formatting

    func testElapsedTextAtEveryMagnitude() {
        XCTAssertEqual(SessionProgress.elapsedText(0), "0s")
        XCTAssertEqual(SessionProgress.elapsedText(48), "48s")
        XCTAssertEqual(SessionProgress.elapsedText(59.9), "59s")
        XCTAssertEqual(SessionProgress.elapsedText(60), "1m 00s")
        XCTAssertEqual(SessionProgress.elapsedText(286), "4m 46s")
        XCTAssertEqual(SessionProgress.elapsedText(59 * 60.0 + 59), "59m 59s")
        XCTAssertEqual(SessionProgress.elapsedText(60 * 60.0), "1h 00m")
        XCTAssertEqual(SessionProgress.elapsedText(60 * 60.0 + 4 * 60.0), "1h 04m")
        XCTAssertEqual(SessionProgress.elapsedText(26 * 60 * 60.0), "26h 00m")
    }

    func testElapsedTextNeverGoesNegativeOnAClockSkew() {
        XCTAssertEqual(SessionProgress.elapsedText(-30), "0s")
    }

    func testTokenText() {
        XCTAssertEqual(SessionProgress.tokenText(0), "0")
        XCTAssertEqual(SessionProgress.tokenText(812), "812")
        XCTAssertEqual(SessionProgress.tokenText(999), "999")
        XCTAssertEqual(SessionProgress.tokenText(12_140), "12.1k")
        XCTAssertEqual(SessionProgress.tokenText(203_842), "203.8k")
        XCTAssertEqual(SessionProgress.tokenText(1_691_993), "1.7M")
    }

    func testHeaderTextCombinesElapsedAndTokensAndOmitsWhatItDoesNotHave() {
        let now = Date(timeIntervalSince1970: 1_000)
        var progress = SessionProgress()
        progress.turnStartedAt = now.addingTimeInterval(-286)
        progress.tokens = 12_140
        XCTAssertEqual(SessionProgress.headerText(progress, now: now), "4m 46s · 12.1k tokens")

        progress.tokens = 0
        XCTAssertEqual(SessionProgress.headerText(progress, now: now), "4m 46s")

        progress.turnStartedAt = nil
        progress.tokens = 12_140
        XCTAssertEqual(SessionProgress.headerText(progress, now: now), "12.1k tokens")

        progress.tokens = 0
        XCTAssertNil(SessionProgress.headerText(progress, now: now))
    }

    // MARK: - The turn clock

    func testStopStopsTheClock() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(bash("swift test", at: 110))
        progress.apply(event("Stop", at: 130))

        XCTAssertNil(progress.turnStartedAt)
    }

    func testAPermissionNotificationDoesNotEndTheTurn() {
        // The tool call hasn't run — it is waiting on the user, and the clock is still that turn's.
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(bash("swift test", at: 110))
        progress.apply(event("Notification", at: 115))

        XCTAssertEqual(progress.turnStartedAt, Date(timeIntervalSince1970: 100))
    }

    func testTheTurnClockStartsAtThePromptAndRestartsOnTheNextOne() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(bash("swift test", at: 110))
        XCTAssertEqual(progress.turnStartedAt, Date(timeIntervalSince1970: 100))

        progress.apply(event("UserPromptSubmit", at: 500))
        XCTAssertEqual(progress.turnStartedAt, Date(timeIntervalSince1970: 500))
    }

    func testStartingMidTurnDatesTheTurnFromTheFirstToolCallSeen() {
        // VibeNotch launched after the prompt went in — "at least this old" beats no clock at all.
        var progress = SessionProgress()
        progress.apply(bash("swift test", at: 400))

        XCTAssertEqual(progress.turnStartedAt, Date(timeIntervalSince1970: 400))
    }

    // MARK: - The current action

    func testNoToolCallEverBecomesAChecklistRow() {
        // The whole of #41: a finished `ls` is not an accomplishment, so the panel has no row for
        // it — not a ✓, not a ■, not a `+N more`.
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        for index in 1...9 {
            progress.apply(bash("ls dir\(index)", at: 100 + Double(index)))
        }
        progress.apply(event("PreToolUse", at: 200, tool: "SomeUnknownTool"))

        XCTAssertEqual(progress.todos, [])
        XCTAssertEqual(SessionProgress.checklist(progress), [])
    }

    @MainActor
    func testTheCardShowsTheCurrentActionOnceAndThePanelNeverRepeatsIt() throws {
        // #15 put the in-flight step in the panel as continuity under the status line. With the
        // trail gone the two said the same words twice, so the panel gave the line up (#41).
        let store = makeStore()
        try send(to: store, "UserPromptSubmit", timestamp: 100)
        try send(to: store, "PreToolUse", timestamp: 110, fields: bashFields)

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(
            SessionStatusPresentation.of(session),
            .activity("Running grep -n needle Sources")
        )
        XCTAssertEqual(SessionProgress.checklist(session.progress), [])
        // The panel is still there — it is showing the turn's cost, not its tool calls.
        XCTAssertTrue(session.progress.hasAnythingToShow)
    }

    @MainActor
    func testNoActionInFlightLeavesTheCardWithNoActionLineAnywhere() throws {
        let store = makeStore()
        try send(to: store, "UserPromptSubmit", timestamp: 100)
        try send(to: store, "Stop", timestamp: 110)

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(SessionStatusPresentation.of(session), .done)
        XCTAssertEqual(SessionProgress.checklist(session.progress), [])
    }

    // MARK: - Checklist

    @MainActor
    func testARealPublishedPlanReachesTheCardFromTheHookPayload() throws {
        // End to end on the payloads Claude Code 2.1.227 actually delivers — captured by driving a
        // real agent through a real `PreToolUse` hook (#41) — from raw hook JSON through
        // `SessionStore` to the rows the panel draws.
        let store = makeStore()
        try send(to: store, "UserPromptSubmit", timestamp: 100)
        try send(to: store, "PreToolUse", timestamp: 110, fields: taskCreateFields("Probe the data", "Probing the data"))
        try send(to: store, "PreToolUse", timestamp: 111, fields: taskCreateFields("Write the model", "Writing the model"))
        try send(to: store, "PreToolUse", timestamp: 112, fields: taskCreateFields("Wire the view", "Wiring the view"))
        try send(to: store, "PreToolUse", timestamp: 113, fields: taskUpdateFields("1", "completed"))
        try send(to: store, "PreToolUse", timestamp: 114, fields: taskUpdateFields("2", "in_progress"))

        let rows = SessionProgress.checklist(try XCTUnwrap(store.sessions.first).progress)

        // ✓ / ■ / □, and the in-flight row in its present tense.
        XCTAssertEqual(rows.map(\.state), [.completed, .inProgress, .pending])
        XCTAssertEqual(rows.map(\.text), ["Probe the data", "Writing the model", "Wire the view"])
    }

    func testAnUpdateForATaskWeNeverSawCreatedChangesNothing() {
        // VibeNotch attached mid-session: the create was never seen, so the id addresses nothing
        // and the panel would rather say less than tick the wrong row.
        var progress = SessionProgress()
        progress.apply(taskCreate("Probe the data", "Probing the data", at: 110))
        progress.apply(taskUpdate("7", "completed", at: 120))

        XCTAssertEqual(SessionProgress.checklist(progress).map(\.state), [.pending])
    }

    func testADeletedTaskLeavesTheChecklistWithoutShiftingTheOnesAfterIt() {
        var progress = SessionProgress()
        progress.apply(taskCreate("Probe the data", "Probing the data", at: 110))
        progress.apply(taskCreate("Write the model", "Writing the model", at: 111))
        progress.apply(taskCreate("Wire the view", "Wiring the view", at: 112))
        progress.apply(taskUpdate("2", "deleted", at: 120))
        // Still id 3 to Claude Code, so it must still be row 3 here.
        progress.apply(taskUpdate("3", "in_progress", at: 121))

        XCTAssertEqual(SessionProgress.checklist(progress).map(\.text), [
            "Probe the data",
            "Wiring the view"
        ])
        XCTAssertEqual(SessionProgress.checklist(progress).map(\.state), [.pending, .inProgress])
    }

    func testTodoWriteStillPublishesAWholeChecklistAtOnce() {
        // Older Claude Code, and any agent that writes the whole array every call.
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(todoWrite(at: 110, [
            ("Probe the data", "Probing the data", "completed"),
            ("Write the model", "Writing the model", "in_progress"),
            ("Wire the view", "Wiring the view", "pending")
        ]))

        XCTAssertEqual(SessionProgress.checklist(progress).map(\.state), [
            .completed, .inProgress, .pending
        ])
        XCTAssertEqual(SessionProgress.checklist(progress).map(\.text), [
            "Probe the data", "Writing the model", "Wire the view"
        ])
    }

    func testALongChecklistIsWindowedOnTheItemInFlight() {
        var progress = SessionProgress()
        progress.apply(todoWrite(at: 110, (1...8).map { index in
            let status = index < 5 ? "completed" : (index == 5 ? "in_progress" : "pending")
            return ("Task \(index)", "Doing task \(index)", status)
        }))

        // Not "Task 1…Task 3", which would be three ✓ and no news.
        XCTAssertEqual(SessionProgress.checklist(progress, limit: 3).map(\.text), [
            "Task 4",
            "Doing task 5",
            "Task 6"
        ])
    }

    func testRowBudgetIsFour() {
        XCTAssertEqual(SessionProgress.maxRows, 4)
    }

    func testASessionWithNoTodosRendersNoChecklistSectionAtAll() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(bash("swift test", at: 110))

        XCTAssertEqual(progress.todos, [])
        XCTAssertEqual(SessionProgress.checklist(progress), [])
    }

    func testANewPromptDropsAFinishedChecklistAndKeepsOneStillInFlight() {
        var progress = SessionProgress()
        progress.apply(taskCreate("Probe the data", "Probing the data", at: 110))
        progress.apply(taskUpdate("1", "in_progress", at: 111))
        progress.apply(event("UserPromptSubmit", at: 500))

        // `TaskCreate`/`TaskUpdate` never re-publish the list, so dropping this would lose it.
        XCTAssertEqual(SessionProgress.checklist(progress).map(\.state), [.inProgress])

        progress.apply(taskUpdate("1", "completed", at: 510))
        progress.apply(event("UserPromptSubmit", at: 900))

        // Fully ✓ and the user has moved on: it would sit there ticked forever.
        XCTAssertEqual(progress.todos, [])
    }

    func testAMalformedChecklistPayloadYieldsNoRowsRatherThanPlaceholderOnes() {
        XCTAssertEqual(SessionProgress.todos(in: nil), [])
        XCTAssertEqual(SessionProgress.todos(in: .object(["todos": .string("nope")])), [])
        XCTAssertEqual(
            SessionProgress.todos(in: .object(["todos": .array([.object(["content": .string("")])])])),
            []
        )
        // An unknown status is still a real item — show it as pending rather than dropping it.
        XCTAssertEqual(
            SessionProgress.todos(in: .object(["todos": .array([
                .object(["content": .string("Do it"), "status": .string("banana")])
            ])])),
            [ProgressTodo(label: "Do it", state: .pending)]
        )

        // A `TaskCreate` with no subject and a `TaskUpdate` with no id are both no-ops.
        var progress = SessionProgress()
        progress.apply(event("PreToolUse", at: 110, tool: "TaskCreate", input: .object([:])))
        progress.apply(event("PreToolUse", at: 111, tool: "TaskUpdate", input: .object([:])))
        XCTAssertEqual(progress.todos, [])
    }

    func testStoredChecklistItemsAreCappedSoASessionCannotAccumulateForever() {
        var progress = SessionProgress()
        for index in 1...(SessionProgress.retainedTodos + 10) {
            progress.apply(taskCreate("Task \(index)", "Doing task \(index)", at: 100 + Double(index)))
        }

        XCTAssertEqual(progress.todos.count, SessionProgress.retainedTodos)
        XCTAssertEqual(SessionProgress.checklist(progress).count, SessionProgress.maxRows)
    }

    // MARK: - Empty panel

    func testAnEmptyProgressRendersNothingAtAll() {
        let progress = SessionProgress()

        XCTAssertFalse(progress.hasAnythingToShow)
        XCTAssertEqual(SessionProgress.checklist(progress), [])
        XCTAssertNil(SessionProgress.headerText(progress, now: Date()))
    }

    func testASessionDefaultsToAnEmptyProgressSoHooklessCardsShowNoPanel() {
        let session = AgentSession(
            sessionId: "codex-1",
            agentName: "Codex",
            cwd: "/repo",
            modifiedAt: Date(),
            status: .active,
            jumpRung: .newTab,
            title: "repo",
            lastPrompt: nil,
            tty: nil,
            terminalName: nil,
            currentActivity: nil,
            notificationMessage: nil,
            pendingToolName: nil,
            pendingToolInput: nil,
            resumeCommand: nil,
            supportsLiveStatus: false
        )

        XCTAssertFalse(session.progress.hasAnythingToShow)
    }

    func testAChecklistOfNothingButDeletedItemsIsNoPanelAtAll() {
        var progress = SessionProgress()
        progress.apply(taskCreate("Probe the data", "Probing the data", at: 110))
        progress.apply(taskUpdate("1", "deleted", at: 120))
        progress.turnStartedAt = nil

        XCTAssertFalse(progress.hasAnythingToShow)
    }

    func testTokensAloneAreEnoughToShowThePanelAfterATurnEnds() {
        var progress = SessionProgress()
        progress.tokens = 12_140

        XCTAssertTrue(progress.hasAnythingToShow)
        XCTAssertEqual(SessionProgress.headerText(progress, now: Date()), "12.1k tokens")
    }

    // MARK: - Fixtures

    /// The exact `tool_input` Claude Code 2.1.227 sends for a published plan, captured off a live
    /// `PreToolUse` hook (#41): `TaskCreate` carries `subject`/`description`/`activeForm` and no id
    /// at all, and `TaskUpdate` addresses an item by the 1-based id assigned in creation order.
    private func taskCreateFields(_ subject: String, _ activeForm: String) -> String {
        #", "tool_name":"TaskCreate", "tool_input":{"subject":"\#(subject)", "description":"\#(subject)", "activeForm":"\#(activeForm)"}"#
    }

    private func taskUpdateFields(_ id: String, _ status: String) -> String {
        #", "tool_name":"TaskUpdate", "tool_input":{"taskId":"\#(id)", "status":"\#(status)"}"#
    }

    private func taskCreate(_ subject: String, _ activeForm: String, at ts: TimeInterval) -> HookEvent {
        event("PreToolUse", at: ts, tool: "TaskCreate", input: .object([
            "subject": .string(subject),
            "description": .string(subject),
            "activeForm": .string(activeForm)
        ]))
    }

    private func taskUpdate(_ id: String, _ status: String, at ts: TimeInterval) -> HookEvent {
        event("PreToolUse", at: ts, tool: "TaskUpdate", input: .object([
            "taskId": .string(id),
            "status": .string(status)
        ]))
    }

    /// Claude Code's older whole-list shape, kept working for agents and versions that still emit
    /// it — it arrives through the same hook payload, which carries the full `tool_input`.
    private func todoWrite(at ts: TimeInterval, _ entries: [(String, String, String)]) -> HookEvent {
        event("PreToolUse", at: ts, tool: "TodoWrite", input: .object([
            "todos": .array(entries.map { content, activeForm, status in
                .object([
                    "content": .string(content),
                    "activeForm": .string(activeForm),
                    "status": .string(status)
                ])
            })
        ]))
    }

    private func event(
        _ name: String,
        at ts: TimeInterval,
        tool: String? = nil,
        input: JSONValue? = nil
    ) -> HookEvent {
        var payload: [String: JSONValue] = ["session_id": .string("s1"), "cwd": .string("/repo")]
        if let tool { payload["tool_name"] = .string(tool) }
        if let input { payload["tool_input"] = input }
        return HookEvent(event: name, tty: "ttys001", ts: ts, payload: payload)
    }

    private func bash(_ command: String, at ts: TimeInterval) -> HookEvent {
        event("PreToolUse", at: ts, tool: "Bash", input: .object(["command": .string(command)]))
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
            processProvider: { [] }
        )
    }

    /// The bytes the hook script writes, verbatim: its own envelope wrapped around whatever Claude
    /// Code piped to its stdin.
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
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
