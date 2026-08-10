import Foundation
import XCTest
@testable import VibeNotch

final class CodexSessionIndexTests: XCTestCase {
    func testParsesValidLinesIncludingFractionalSecondTimestamps() {
        let json = """
        {"id":"019fe8a4-aaaa","thread_name":"Fix the flaky test","updated_at":"2026-08-09T22:28:49.803045Z"}
        {"id":"019fe8a4-bbbb","thread_name":null,"updated_at":"2026-08-09T20:00:00Z"}
        """
        let entries = CodexSessionIndex.parse(Data(json.utf8))

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, "019fe8a4-aaaa")
        XCTAssertEqual(entries[0].threadName, "Fix the flaky test")
        XCTAssertEqual(
            entries[0].updatedAt,
            ClaudeUsageParser.parseDate("2026-08-09T22:28:49.803045Z")
        )
        XCTAssertNil(entries[1].threadName)
        XCTAssertEqual(entries[1].updatedAt, ClaudeUsageParser.parseDate("2026-08-09T20:00:00Z"))
    }

    func testSkipsMalformedLinesWithoutDroppingValidOnes() {
        let json = """
        {"id":"good-1","updated_at":"2026-08-09T20:00:00Z"}
        not json at all
        {"thread_name":"missing id","updated_at":"2026-08-09T20:00:00Z"}
        {"id":"missing-date"}
        {"id":"bad-date","updated_at":"not-a-date"}
        {"id":"good-2","updated_at":"2026-08-09T21:00:00Z"}
        """
        let entries = CodexSessionIndex.parse(Data(json.utf8))
        XCTAssertEqual(entries.map(\.id), ["good-1", "good-2"])
    }

    func testEmptyOrMissingFileYieldsNoEntries() {
        XCTAssertEqual(CodexSessionIndex.parse(Data()), [])
        XCTAssertEqual(CodexSessionIndex.load(at: URL(fileURLWithPath: "/nonexistent/session_index.jsonl")), [])
    }
}

final class CodexRolloutMetaTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testParsesCwdAndSessionIdFromFirstLine() throws {
        let url = try writeRollout(firstLine: #"""
        {"timestamp":"2026-08-09T22:28:00.000Z","type":"session_meta","payload":{"session_id":"abc-123","id":"abc-123","timestamp":"2026-08-09T22:28:00.000Z","cwd":"/Users/me/project","originator":"Codex CLI","cli_version":"1.0.0"}}
        """#)

        let meta = CodexRolloutMeta.firstLineSessionMeta(at: url)
        XCTAssertEqual(meta?.sessionId, "abc-123")
        XCTAssertEqual(meta?.cwd, "/Users/me/project")
    }

    func testIgnoresLinesAfterTheFirst() throws {
        let url = try writeRollout(
            firstLine: #"{"type":"session_meta","payload":{"session_id":"abc","cwd":"/repo"}}"#,
            moreLines: [#"{"type":"session_meta","payload":{"session_id":"decoy","cwd":"/other"}}"#]
        )

        XCTAssertEqual(CodexRolloutMeta.firstLineSessionMeta(at: url)?.cwd, "/repo")
    }

    func testReturnsNilForMissingFile() {
        XCTAssertNil(CodexRolloutMeta.firstLineSessionMeta(at: URL(fileURLWithPath: "/nonexistent/rollout.jsonl")))
    }

    func testReturnsNilForCorruptFirstLine() throws {
        let url = try writeRollout(firstLine: "{not valid json at all")
        XCTAssertNil(CodexRolloutMeta.firstLineSessionMeta(at: url))
    }

    func testReturnsNilWhenFirstLineIsNotSessionMeta() throws {
        let url = try writeRollout(firstLine: #"{"type":"response_item","payload":{"cwd":"/repo"}}"#)
        XCTAssertNil(CodexRolloutMeta.firstLineSessionMeta(at: url))
    }

    func testReturnsNilWhenPayloadHasNoCwd() throws {
        let url = try writeRollout(firstLine: #"{"type":"session_meta","payload":{"session_id":"abc"}}"#)
        XCTAssertNil(CodexRolloutMeta.firstLineSessionMeta(at: url))
    }

    private func writeRollout(firstLine: String, moreLines: [String] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let url = directory.appendingPathComponent("rollout.jsonl")
        let content = ([firstLine] + moreLines).joined(separator: "\n")
        try Data(content.utf8).write(to: url)
        return url
    }
}

final class CodexRolloutLocatorTests: XCTestCase {
    func testLocatesRolloutByIdSuffixInFixtureTree() throws {
        let root = try makeTemporaryDirectory()
        let dayDirectory = root.appendingPathComponent("2026/08/09", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        let target = dayDirectory.appendingPathComponent("rollout-2026-08-09T10-00-00-abc-123.jsonl")
        try Data().write(to: target)
        try Data().write(to: dayDirectory.appendingPathComponent("rollout-2026-08-09T09-00-00-xyz-789.jsonl"))

        // Compare basenames, not full URLs: the enumerator can return a path through a
        // resolved symlink (e.g. `/var/folders/...` vs `/private/var/folders/...` for the
        // same temp directory), which is irrelevant to what this test actually verifies.
        XCTAssertEqual(
            CodexRolloutLocator.locate(sessionId: "abc-123", under: root)?.lastPathComponent,
            target.lastPathComponent
        )
        XCTAssertEqual(
            CodexRolloutLocator.locate(sessionId: "xyz-789", under: root)?.lastPathComponent,
            "rollout-2026-08-09T09-00-00-xyz-789.jsonl"
        )
    }

    func testReturnsNilWhenNoRolloutMatches() throws {
        let root = try makeTemporaryDirectory()
        try Data().write(to: root.appendingPathComponent("rollout-2026-08-09T10-00-00-other-id.jsonl"))
        XCTAssertNil(CodexRolloutLocator.locate(sessionId: "missing-id", under: root))
    }

    func testReturnsNilForNonexistentSessionsRoot() {
        XCTAssertNil(CodexRolloutLocator.locate(
            sessionId: "abc",
            under: URL(fileURLWithPath: "/nonexistent/sessions")
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

final class CodexSessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testDiscoversSessionFromFixtureTreeWithCwdAndResumeCommand() throws {
        let codexHome = try makeFixture(sessions: [
            (id: "abc-123", threadName: "Fix the flaky test", cwd: "/Users/me/project", ageSeconds: 60)
        ])
        let discovered = CodexSessionSource(codexHome: codexHome).discover(now: fixedNow)

        XCTAssertEqual(discovered.count, 1)
        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(session.sessionId, "abc-123")
        XCTAssertEqual(session.agentName, "Codex")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        XCTAssertEqual(session.title, "Fix the flaky test")
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.resumeCommand, Jumper.codexResumeCommand(sessionId: "abc-123"))
        XCTAssertNil(session.sessionFileURL)
    }

    func testFreshnessThresholdsMirrorTheClaudeThresholds() throws {
        let codexHome = try makeFixture(sessions: [
            (id: "active", threadName: nil, cwd: "/tmp/active", ageSeconds: 60),
            (id: "idle", threadName: nil, cwd: "/tmp/idle", ageSeconds: 30 * 60),
            (id: "hidden", threadName: nil, cwd: "/tmp/hidden", ageSeconds: 61 * 60)
        ])
        let discovered = CodexSessionSource(codexHome: codexHome).discover(now: fixedNow)
        let statusByID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.sessionId, $0.status) })

        XCTAssertEqual(statusByID["active"], .active)
        XCTAssertEqual(statusByID["idle"], .idle)
        XCTAssertNil(statusByID["hidden"], "sessions past the 60-minute threshold must be dropped, not hidden with a status")
        XCTAssertEqual(discovered.count, 2)
    }

    func testSkipsSessionsWithNoMatchingRolloutFile() throws {
        let codexHome = try makeTemporaryDirectory()
        try Data(#"{"id":"ghost","thread_name":"Nothing here","updated_at":"2026-08-09T22:00:00Z"}"#.utf8)
            .write(to: codexHome.appendingPathComponent("session_index.jsonl"))

        XCTAssertTrue(CodexSessionSource(codexHome: codexHome).discover(now: fixedNow).isEmpty)
    }

    func testSkipsSessionsWithACorruptRolloutFile() throws {
        let codexHome = try makeTemporaryDirectory()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: sessionsRoot.appendingPathComponent("rollout-broken.jsonl"))
        try Data(#"{"id":"broken","updated_at":"2026-08-09T22:00:00Z"}"#.utf8)
            .write(to: codexHome.appendingPathComponent("session_index.jsonl"))

        XCTAssertTrue(CodexSessionSource(codexHome: codexHome).discover(now: fixedNow).isEmpty)
    }

    func testTitleFallsBackToCwdBasenameWhenThreadNameIsAPath() throws {
        let codexHome = try makeFixture(sessions: [
            (id: "no-name", threadName: "/Users/me/project", cwd: "/Users/me/project", ageSeconds: 60)
        ])
        let discovered = CodexSessionSource(codexHome: codexHome).discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.title, "project")
    }

    func testMissingIndexFileYieldsNoSessions() {
        XCTAssertTrue(
            CodexSessionSource(codexHome: URL(fileURLWithPath: "/nonexistent/.codex")).discover(now: fixedNow).isEmpty
        )
    }

    // MARK: - Fixtures

    private func makeFixture(
        sessions: [(id: String, threadName: String?, cwd: String, ageSeconds: TimeInterval)]
    ) throws -> URL {
        let codexHome = try makeTemporaryDirectory()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

        var indexLines: [String] = []
        for session in sessions {
            let updatedAt = fixedNow.addingTimeInterval(-session.ageSeconds)
            let threadNameJSON = session.threadName.map { "\"\($0)\"" } ?? "null"
            indexLines.append(
                #"{"id":"\#(session.id)","thread_name":\#(threadNameJSON),"updated_at":"\#(iso8601(updatedAt))"}"#
            )

            let filenameTimestamp = iso8601(updatedAt).replacingOccurrences(of: ":", with: "-")
            let rolloutURL = sessionsRoot.appendingPathComponent("rollout-\(filenameTimestamp)-\(session.id).jsonl")
            let firstLine = #"""
            {"timestamp":"\#(iso8601(updatedAt))","type":"session_meta","payload":{"session_id":"\#(session.id)","id":"\#(session.id)","cwd":"\#(session.cwd)","originator":"Codex CLI"}}
            """#
            try Data(firstLine.utf8).write(to: rolloutURL)
            try FileManager.default.setAttributes(
                [.modificationDate: updatedAt],
                ofItemAtPath: rolloutURL.path
            )
        }
        try Data(indexLines.joined(separator: "\n").utf8)
            .write(to: codexHome.appendingPathComponent("session_index.jsonl"))
        return codexHome
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
