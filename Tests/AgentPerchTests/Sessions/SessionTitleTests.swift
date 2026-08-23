import Foundation
import XCTest
@testable import AgentPerch

final class SessionTitleTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testMostRecentSummaryWins() throws {
        let file = temporaryDirectory().appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"summary","summary":"Older title"}"#,
            #"{"type":"user","message":"hello"}"#,
            #"{"type":"summary","summary":"Newest title"}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)

        XCTAssertEqual(
            SessionTitle.resolve(
                sessionFileURL: file,
                lastPrompt: "Prompt title",
                cwd: "/tmp/folder-name"
            ),
            "Newest title"
        )
    }

    func testNameBeatsSummary() throws {
        let file = temporaryDirectory().appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"custom-title","customTitle":"Named session"}"#,
            #"{"type":"summary","summary":"Summary title"}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)

        XCTAssertEqual(
            SessionTitle.resolve(
                sessionFileURL: file,
                lastPrompt: "Prompt title",
                cwd: "/tmp/folder-name"
            ),
            "Named session"
        )
    }

    func testMostRecentNameWinsByFilePosition() throws {
        let file = temporaryDirectory().appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"custom-title","customTitle":"Older custom title"}"#,
            #"{"type":"agent-name","agentName":"Newer agent name"}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)

        XCTAssertEqual(
            SessionTitle.resolve(
                sessionFileURL: file,
                lastPrompt: nil,
                cwd: "/tmp/folder-name"
            ),
            "Newer agent name"
        )
    }

    func testCustomTitleBeatsAgentNameAtEqualPosition() {
        let customTitle = SessionTitle.LocatedValue(value: "Custom title", position: 42)
        let agentName = SessionTitle.LocatedValue(value: "Agent name", position: 42)

        XCTAssertEqual(
            SessionTitle.preferredName(customTitle: customTitle, agentName: agentName),
            "Custom title"
        )
    }

    func testNameIsFoundInHeadWindowOfLargeFile() throws {
        let file = temporaryDirectory().appendingPathComponent("session.jsonl")
        let lines = [
            #"{"type":"agent-name","agentName":"Head name"}"#,
            #"{"type":"user","message":"\#(String(repeating: "x", count: 70_000))"}"#,
            #"{"type":"summary","summary":"Tail summary"}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)

        XCTAssertEqual(
            SessionTitle.resolve(
                sessionFileURL: file,
                lastPrompt: nil,
                cwd: "/tmp/folder-name"
            ),
            "Head name"
        )
    }

    // The 40-char cap has no space to break on, so the word-boundary truncation this now
    // shares with the subtitle path falls back to a hard cut — but still appends an ellipsis,
    // unlike the raw `prefix(40)` this used to be (that was the mid-word-cut bug in #21: a
    // compact row could show "…please? Wh" with no ellipsis at all).
    func testPromptIsUsedAndLimitedToFortyCharactersWithoutSummary() throws {
        let prompt = "1234567890123456789012345678901234567890extra"
        XCTAssertEqual(
            SessionTitle.resolve(
                sessionFileURL: nil,
                lastPrompt: prompt,
                cwd: "/tmp/folder-name"
            ),
            "1234567890123456789012345678901234567890…"
        )
    }

    // Regression for #21: a tool-heavy transcript can pack more lines into the byte-bounded
    // scan window than an arbitrary line-count cap allows, which used to make a real summary
    // inside that window get silently skipped in favor of the raw last-prompt fallback.
    func testSummaryBeyondOldFiftyLineTailWindowIsStillFound() throws {
        let file = temporaryDirectory().appendingPathComponent("session.jsonl")
        var lines = [#"{"type":"summary","summary":"Buried summary"}"#]
        lines.append(contentsOf: (0..<80).map { _ in #"{"type":"progress","message":"tool call"}"# })
        try Data(lines.joined(separator: "\n").utf8).write(to: file)

        XCTAssertEqual(
            SessionTitle.resolve(
                sessionFileURL: file,
                lastPrompt: "can you try again the project please? What else needs doing",
                cwd: "/tmp/folder-name"
            ),
            "Buried summary"
        )
    }

    func testFolderBasenameIsFinalFallback() {
        XCTAssertEqual(
            SessionTitle.resolve(
                sessionFileURL: nil,
                lastPrompt: nil,
                cwd: "/tmp/folder-name"
            ),
            "folder-name"
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

extension SessionTitleTests {
    func testMachinePromptsAreNotDisplayable() {
        XCTAssertNil(SessionTitle.displayablePrompt("<task-notification>\n<task-id>x</task-id>"))
        XCTAssertNil(SessionTitle.displayablePrompt("<system-reminder>stuff</system-reminder>"))
        XCTAssertNil(SessionTitle.displayablePrompt("<command-name>/model</command-name>"))
        XCTAssertNil(SessionTitle.displayablePrompt("[SYSTEM NOTIFICATION - NOT USER INPUT] x"))
        XCTAssertNil(SessionTitle.displayablePrompt("   "))
        XCTAssertNil(SessionTitle.displayablePrompt(nil))
    }

    func testRealPromptsPassThrough() {
        XCTAssertEqual(SessionTitle.displayablePrompt("fix the auth bug"), "fix the auth bug")
    }

    func testPromptAfterLeadingWrapperBlockIsExtracted() {
        let wrapped = "<local-command-caveat>ignore</local-command-caveat>\nplease fix hover"
        XCTAssertEqual(SessionTitle.displayablePrompt(wrapped), "please fix hover")
    }
}

final class CodexSessionTitleTests: XCTestCase {
    func testUsesThreadNameWhenItLooksLikeARealTitle() {
        XCTAssertEqual(
            SessionTitle.resolveCodex(threadName: "Fix the flaky test", cwd: "/Users/me/project"),
            "Fix the flaky test"
        )
    }

    func testFallsBackToCwdBasenameWhenThreadNameIsMissingOrEmpty() {
        XCTAssertEqual(SessionTitle.resolveCodex(threadName: nil, cwd: "/Users/me/project"), "project")
        XCTAssertEqual(SessionTitle.resolveCodex(threadName: "", cwd: "/Users/me/project"), "project")
        XCTAssertEqual(SessionTitle.resolveCodex(threadName: "   ", cwd: "/Users/me/project"), "project")
    }

    func testFallsBackToCwdBasenameWhenThreadNameIsJustAPath() {
        XCTAssertEqual(
            SessionTitle.resolveCodex(threadName: "/Users/me/project", cwd: "/Users/me/project"),
            "project"
        )
        XCTAssertEqual(
            SessionTitle.resolveCodex(threadName: "~/project", cwd: "/Users/me/project"),
            "project"
        )
    }

    func testNonPathCwdIsReturnedVerbatimAsFallback() {
        XCTAssertEqual(SessionTitle.resolveCodex(threadName: nil, cwd: "some-cwd"), "some-cwd")
    }

    func testTruncatesLongThreadNamesToSixtyCharacters() {
        let long = String(repeating: "a", count: 100)
        // One unbroken word has no earlier boundary, so it hard-cuts at 60 plus the ellipsis.
        XCTAssertEqual(SessionTitle.resolveCodex(threadName: long, cwd: "/tmp"), String(repeating: "a", count: 60) + "…")
    }

    // Regression for #24: an agent-spawned Codex thread's name carries a machine-generated
    // wrapper instead of a real title.
    func testStripsCodexCompanionTaskWrapperDownToTheTaskText() {
        XCTAssertEqual(
            SessionTitle.resolveCodex(
                threadName: "Codex Companion Task: Fix the login bug Repo: /Users/me/project",
                cwd: "/Users/me/project"
            ),
            "Fix the login bug"
        )
    }

    func testStripsCodexCompanionTaskWrapperCaseInsensitively() {
        XCTAssertEqual(
            SessionTitle.resolveCodex(
                threadName: "codex companion task: Fix the login bug repo: /Users/me/project",
                cwd: "/Users/me/project"
            ),
            "Fix the login bug"
        )
    }

    func testCodexCompanionTaskWrapperWithNoRepoSuffixKeepsTheTaskText() {
        XCTAssertEqual(
            SessionTitle.resolveCodex(threadName: "Codex Companion Task: Fix the login bug", cwd: "/Users/me/project"),
            "Fix the login bug"
        )
    }

    // The brief's literal example: an unfilled "<task>" template placeholder leaves nothing
    // sensible behind, so this must fall back to the cwd basename rather than showing "<task>".
    func testCodexCompanionTaskWrapperWithAnUnfilledPlaceholderFallsBackToCwdBasename() {
        XCTAssertEqual(
            SessionTitle.resolveCodex(
                threadName: "Codex Companion Task: <task> Repo: /Users/x/y",
                cwd: "/Users/x/y"
            ),
            "y"
        )
    }

    func testNormalThreadNameWithNoWrapperPassesThroughUnchanged() {
        XCTAssertEqual(
            SessionTitle.resolveCodex(threadName: "Fix the flaky test", cwd: "/Users/me/project"),
            "Fix the flaky test"
        )
    }
}

extension SessionTitleTests {
    func testTruncateBreaksAtWordBoundaryWithEllipsis() {
        XCTAssertEqual(
            SessionTitle.truncate("can you try again the project please? What else", max: 30),
            "can you try again the project…"
        )
    }

    // No space anywhere in the first `max` characters — no earlier boundary exists, so this
    // still hard-cuts, but (unlike a bare `prefix`) it always appends the ellipsis.
    func testTruncateHardCutsASingleOverlongWord() {
        XCTAssertEqual(
            SessionTitle.truncate("supercalifragilisticexpialidocious", max: 10),
            "supercalif…"
        )
    }

    func testTruncateLeavesAShortStringUnchanged() {
        XCTAssertEqual(SessionTitle.truncate("hello", max: 30), "hello")
    }

    func testTruncateLeavesAStringExactlyAtTheLimitUnchanged() {
        XCTAssertEqual(SessionTitle.truncate("12345", max: 5), "12345")
    }

    func testSubtitleIsNilForNilPrompt() {
        XCTAssertNil(SessionTitle.subtitle(forPrompt: nil))
    }

    func testSubtitleIsNilForEmptyOrWhitespacePrompt() {
        XCTAssertNil(SessionTitle.subtitle(forPrompt: ""))
        XCTAssertNil(SessionTitle.subtitle(forPrompt: "   \n  "))
    }

    func testSubtitleReturnsTrimmedPromptWhenPresent() {
        XCTAssertEqual(SessionTitle.subtitle(forPrompt: "  fix the auth bug  "), "fix the auth bug")
    }

    func testSubtitleTruncatesAtWordBoundary() {
        let prompt = String(repeating: "word ", count: 20)
        let subtitle = SessionTitle.subtitle(forPrompt: prompt, max: 20)
        XCTAssertEqual(subtitle, "word word word word…")
    }
}
