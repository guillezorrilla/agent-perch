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

    // MARK: - Step derivation

    func testFirstToolCallIsInFlightAndTheNextOneFinishesIt() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(read("/repo/Alpha.swift", at: 110))

        XCTAssertEqual(progress.steps, [ProgressStep(label: "Reading Alpha.swift", isComplete: false)])

        progress.apply(read("/repo/Beta.swift", at: 120))

        XCTAssertEqual(progress.steps, [
            ProgressStep(label: "Reading Alpha.swift", isComplete: true),
            ProgressStep(label: "Reading Beta.swift", isComplete: false)
        ])
    }

    func testStopFinishesTheInFlightStepAndStopsTheClock() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(read("/repo/Alpha.swift", at: 110))
        progress.apply(event("Stop", at: 130))

        XCTAssertEqual(progress.steps, [ProgressStep(label: "Reading Alpha.swift", isComplete: true)])
        XCTAssertNil(progress.turnStartedAt)
    }

    func testAPermissionNotificationLeavesTheInFlightStepInFlight() {
        // The tool call hasn't run — it is waiting on the user. Ticking it ✓ would claim it had.
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(read("/repo/Alpha.swift", at: 110))
        progress.apply(event("Notification", at: 115))

        XCTAssertEqual(progress.steps, [ProgressStep(label: "Reading Alpha.swift", isComplete: false)])
        XCTAssertEqual(progress.turnStartedAt, Date(timeIntervalSince1970: 100))
    }

    func testTheTurnClockStartsAtThePromptAndRestartsOnTheNextOne() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(read("/repo/Alpha.swift", at: 110))
        XCTAssertEqual(progress.turnStartedAt, Date(timeIntervalSince1970: 100))

        progress.apply(event("UserPromptSubmit", at: 500))
        XCTAssertEqual(progress.turnStartedAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(progress.steps, [])
        XCTAssertEqual(progress.droppedSteps, 0)
    }

    func testStartingMidTurnDatesTheTurnFromTheFirstToolCallSeen() {
        // VibeNotch launched after the prompt went in — "at least this old" beats no clock at all.
        var progress = SessionProgress()
        progress.apply(read("/repo/Alpha.swift", at: 400))

        XCTAssertEqual(progress.turnStartedAt, Date(timeIntervalSince1970: 400))
    }

    func testAToolWithNoActivityPhrasingStillGetsAStepNamedAfterTheTool() {
        var progress = SessionProgress()
        progress.apply(event("PreToolUse", at: 110, tool: "SomeUnknownTool"))

        XCTAssertEqual(progress.steps, [ProgressStep(label: "SomeUnknownTool", isComplete: false)])
    }

    // MARK: - Bounding

    func testOnlyTheLastFewStepsAreKeptAndTheRestAreCounted() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        for index in 1...9 {
            progress.apply(read("/repo/File\(index).swift", at: 100 + Double(index)))
        }

        XCTAssertEqual(progress.steps.count, SessionProgress.retainedSteps)
        XCTAssertEqual(progress.steps.last?.label, "Reading File9.swift")
        XCTAssertEqual(progress.droppedSteps, 9 - SessionProgress.retainedSteps)
    }

    func testRowsAreBoundedAndTheOverflowIsCounted() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        for index in 1...9 {
            progress.apply(read("/repo/File\(index).swift", at: 100 + Double(index)))
        }

        let rows = SessionProgress.rows(progress, limit: 3)

        XCTAssertEqual(rows, [
            .step(ProgressStep(label: "Reading File7.swift", isComplete: true)),
            .step(ProgressStep(label: "Reading File8.swift", isComplete: true)),
            .step(ProgressStep(label: "Reading File9.swift", isComplete: false)),
            .more(6)
        ])
    }

    func testRowBudgetIsFour() {
        XCTAssertEqual(SessionProgress.maxRows, 4)
    }

    // MARK: - Checklist

    /// Claude Code's documented `TodoWrite` shape. Nothing on this machine has ever written one
    /// to a transcript (probed: zero `"name":"TodoWrite"` and zero `"todos":` across all 284
    /// transcripts), so this is the hand-written fixture the checklist path is built against —
    /// it arrives through the hook payload, which carries the full `tool_input`.
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

    func testTodosRenderByStatusAboveTheStepList() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(todoWrite(at: 110, [
            ("Probe the data", "Probing the data", "completed"),
            ("Write the model", "Writing the model", "in_progress"),
            ("Wire the view", "Wiring the view", "pending")
        ]))

        XCTAssertEqual(progress.todos, [
            ProgressTodo(label: "Probe the data", state: .completed),
            // in_progress shows `activeForm` — the present-tense phrasing exists for exactly this.
            ProgressTodo(label: "Writing the model", state: .inProgress),
            ProgressTodo(label: "Wire the view", state: .pending)
        ])

        progress.apply(read("/repo/Alpha.swift", at: 120))

        XCTAssertEqual(SessionProgress.rows(progress, limit: 4), [
            .todo(ProgressTodo(label: "Probe the data", state: .completed)),
            .todo(ProgressTodo(label: "Writing the model", state: .inProgress)),
            .todo(ProgressTodo(label: "Wire the view", state: .pending)),
            .step(ProgressStep(label: "Reading Alpha.swift", isComplete: false))
        ])
    }

    func testTodoWriteItselfIsNotAlsoAStep() {
        // The checklist rendered above it IS that call's output.
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(todoWrite(at: 110, [("Probe the data", "Probing the data", "pending")]))

        XCTAssertEqual(progress.steps, [])
    }

    func testALongChecklistIsWindowedOnTheItemInFlight() {
        var progress = SessionProgress()
        progress.apply(todoWrite(at: 110, (1...8).map { index in
            let status = index < 5 ? "completed" : (index == 5 ? "in_progress" : "pending")
            return ("Task \(index)", "Doing task \(index)", status)
        }))

        // Not "Task 1…Task 3", which would be three ✓ and no news.
        XCTAssertEqual(SessionProgress.rows(progress, limit: 3), [
            .todo(ProgressTodo(label: "Task 4", state: .completed)),
            .todo(ProgressTodo(label: "Doing task 5", state: .inProgress)),
            .todo(ProgressTodo(label: "Task 6", state: .pending)),
            .more(5)
        ])
    }

    func testAChecklistThatFillsTheBudgetLeavesNoRoomForSteps() {
        var progress = SessionProgress()
        progress.apply(todoWrite(at: 110, (1...4).map { ("Task \($0)", "Doing task \($0)", "pending") }))
        progress.apply(read("/repo/Alpha.swift", at: 120))

        let rows = SessionProgress.rows(progress, limit: 4)

        XCTAssertEqual(rows.filter { if case .step = $0 { return true } else { return false } }, [])
        XCTAssertEqual(rows.last, .more(1))
    }

    func testASessionWithNoTodosRendersNoChecklistSectionAtAll() {
        var progress = SessionProgress()
        progress.apply(event("UserPromptSubmit", at: 100))
        progress.apply(read("/repo/Alpha.swift", at: 110))

        XCTAssertEqual(progress.todos, [])
        XCTAssertEqual(SessionProgress.rows(progress), [
            .step(ProgressStep(label: "Reading Alpha.swift", isComplete: false))
        ])
    }

    func testANewPromptDropsTheOldChecklistRatherThanLeavingItFullyTicked() {
        var progress = SessionProgress()
        progress.apply(todoWrite(at: 110, [("Probe the data", "Probing the data", "completed")]))
        progress.apply(event("UserPromptSubmit", at: 500))

        XCTAssertEqual(progress.todos, [])
    }

    func testAMalformedTodoPayloadYieldsNoChecklistRatherThanPlaceholderRows() {
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
    }

    // MARK: - Empty panel

    func testAnEmptyProgressRendersNothingAtAll() {
        let progress = SessionProgress()

        XCTAssertFalse(progress.hasAnythingToShow)
        XCTAssertEqual(SessionProgress.rows(progress), [])
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

    func testTokensAloneAreEnoughToShowThePanelAfterATurnEnds() {
        var progress = SessionProgress()
        progress.tokens = 12_140

        XCTAssertTrue(progress.hasAnythingToShow)
        XCTAssertEqual(SessionProgress.headerText(progress, now: Date()), "12.1k tokens")
    }

    // MARK: - Fixtures

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

    private func read(_ path: String, at ts: TimeInterval) -> HookEvent {
        event("PreToolUse", at: ts, tool: "Read", input: .object(["file_path": .string(path)]))
    }
}
