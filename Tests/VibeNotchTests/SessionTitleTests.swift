import Foundation
import XCTest
@testable import VibeNotch

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

    func testPromptIsUsedAndLimitedToFortyCharactersWithoutSummary() throws {
        let prompt = "1234567890123456789012345678901234567890extra"
        XCTAssertEqual(
            SessionTitle.resolve(
                sessionFileURL: nil,
                lastPrompt: prompt,
                cwd: "/tmp/folder-name"
            ),
            "1234567890123456789012345678901234567890"
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
        XCTAssertEqual(SessionTitle.resolveCodex(threadName: long, cwd: "/tmp").count, 60)
    }
}
