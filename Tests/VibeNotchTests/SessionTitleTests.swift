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
