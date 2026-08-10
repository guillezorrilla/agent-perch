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

    func testThreadNamesByIDKeepsOnlyEntriesWithAName() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("session_index.jsonl")
        let json = """
        {"id":"has-name","thread_name":"Fix the flaky test","updated_at":"2026-08-09T20:00:00Z"}
        {"id":"no-name","thread_name":null,"updated_at":"2026-08-09T20:00:00Z"}
        """
        try Data(json.utf8).write(to: url)

        XCTAssertEqual(CodexSessionIndex.threadNamesByID(at: url), ["has-name": "Fix the flaky test"])
    }

    func testThreadNamesByIDOnMissingFileIsEmpty() {
        XCTAssertEqual(
            CodexSessionIndex.threadNamesByID(at: URL(fileURLWithPath: "/nonexistent/session_index.jsonl")),
            [:]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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

    func testParsesOriginatorAndStringSource() throws {
        let url = try writeRollout(
            firstLine: #"{"type":"session_meta","payload":{"session_id":"abc","cwd":"/repo","originator":"codex-tui","source":"cli"}}"#
        )

        let meta = try XCTUnwrap(CodexRolloutMeta.firstLineSessionMeta(at: url))
        XCTAssertEqual(meta.originator, "codex-tui")
        XCTAssertEqual(meta.source, .string("cli"))
    }

    func testParsesObjectShapedSource() throws {
        let url = try writeRollout(
            firstLine: #"""
            {"type":"session_meta","payload":{"session_id":"abc","cwd":"/repo","originator":"codex-tui","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-1","depth":1}}}}}
            """#
        )

        let meta = try XCTUnwrap(CodexRolloutMeta.firstLineSessionMeta(at: url))
        guard case let .object(fields) = meta.source else {
            return XCTFail("expected an object-shaped source")
        }
        XCTAssertNotNil(fields["subagent"])
    }

    func testMissingOriginatorAndSourceAreNil() throws {
        let url = try writeRollout(firstLine: #"{"type":"session_meta","payload":{"session_id":"abc","cwd":"/repo"}}"#)
        let meta = try XCTUnwrap(CodexRolloutMeta.firstLineSessionMeta(at: url))
        XCTAssertNil(meta.originator)
        XCTAssertNil(meta.source)
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

final class CodexSessionOriginTests: XCTestCase {
    func testInteractiveSessionStartedByTheUser() {
        XCTAssertEqual(
            CodexSessionOrigin.classify(originator: "codex-tui", source: .string("cli")),
            .interactive
        )
    }

    func testAgentSpawnedByAnotherAgentOrIDE() {
        XCTAssertEqual(
            CodexSessionOrigin.classify(originator: "Claude Code", source: .string("vscode")),
            .agentSpawned
        )
    }

    func testCodexsOwnSubagentIsAnObjectShapedSourceRegardlessOfOriginator() {
        let source = JSONValue.object(["subagent": .object(["thread_spawn": .object([
            "parent_thread_id": .string("parent-1"),
            "depth": .number(1)
        ])])])
        XCTAssertEqual(CodexSessionOrigin.classify(originator: "codex-tui", source: source), .subagent)
        // The object shape alone is decisive — an unexpected originator paired with it must
        // still read as a sub-agent, not silently fall through to agentSpawned.
        XCTAssertEqual(CodexSessionOrigin.classify(originator: "something-else", source: source), .subagent)
    }

    func testUnknownOriginatorDefaultsToAgentSpawned() {
        XCTAssertEqual(
            CodexSessionOrigin.classify(originator: "some-future-originator", source: .string("cli")),
            .agentSpawned
        )
    }

    func testMissingFieldsDefaultToAgentSpawned() {
        XCTAssertEqual(CodexSessionOrigin.classify(originator: nil, source: nil), .agentSpawned)
        XCTAssertEqual(CodexSessionOrigin.classify(originator: "codex-tui", source: nil), .agentSpawned)
        XCTAssertEqual(CodexSessionOrigin.classify(originator: nil, source: .string("cli")), .agentSpawned)
    }

    func testSourceStringThatIsNotCliIsNotInteractiveEvenWithTheRightOriginator() {
        XCTAssertEqual(
            CodexSessionOrigin.classify(originator: "codex-tui", source: .string("vscode")),
            .agentSpawned
        )
    }
}

final class CodexLivenessTests: XCTestCase {
    func testBareLiveCodexProcessAtCwdIsActive() {
        let processes = [ClaudeProcess(pid: 1, command: "/usr/local/bin/codex", cwd: "/repo", tty: nil)]
        XCTAssertTrue(CodexLiveness.hasLiveProcess(sessionId: "abc", cwd: "/repo", processes: processes))
    }

    func testNoProcessAtCwdIsNotLive() {
        XCTAssertFalse(CodexLiveness.hasLiveProcess(sessionId: "abc", cwd: "/repo", processes: []))
        let elsewhere = [ClaudeProcess(pid: 1, command: "/usr/local/bin/codex", cwd: "/other", tty: nil)]
        XCTAssertFalse(CodexLiveness.hasLiveProcess(sessionId: "abc", cwd: "/repo", processes: elsewhere))
    }

    func testResumeCommandNamingThisSessionIsLive() {
        let processes = [ClaudeProcess(pid: 1, command: "/usr/local/bin/codex resume abc-123", cwd: "/repo", tty: nil)]
        XCTAssertTrue(CodexLiveness.hasLiveProcess(sessionId: "abc-123", cwd: "/repo", processes: processes))
    }

    func testResumeCommandNamingADifferentSessionAtTheSameCwdIsNotLiveForThisOne() {
        let processes = [ClaudeProcess(pid: 1, command: "/usr/local/bin/codex resume other-session", cwd: "/repo", tty: nil)]
        XCTAssertFalse(CodexLiveness.hasLiveProcess(sessionId: "abc-123", cwd: "/repo", processes: processes))
    }

    func testChatGPTHelperAtTheSameCwdDoesNotCountAsLive() {
        let processes = [ClaudeProcess(
            pid: 1,
            command: "/Applications/ChatGPT.app/Contents/Resources/codex app-server",
            cwd: "/repo",
            tty: nil
        )]
        XCTAssertFalse(CodexLiveness.hasLiveProcess(sessionId: "abc", cwd: "/repo", processes: processes))
    }

    func testStatusIsActiveWithALiveProcessRegardlessOfStaleMtime() {
        let now = Date(timeIntervalSince1970: 10_000)
        let processes = [ClaudeProcess(pid: 1, command: "/usr/local/bin/codex", cwd: "/repo", tty: nil)]
        XCTAssertEqual(
            CodexLiveness.status(
                sessionId: "abc",
                cwd: "/repo",
                modifiedAt: now.addingTimeInterval(-10_000),
                now: now,
                processes: processes
            ),
            .active
        )
    }

    func testStatusDegradesToIdleWithoutALiveProcessEvenWhenFresh() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(
            CodexLiveness.status(sessionId: "abc", cwd: "/repo", modifiedAt: now, now: now, processes: []),
            .idle
        )
    }

    func testStatusIsHiddenPastTheThresholdWithoutALiveProcess() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(
            CodexLiveness.status(
                sessionId: "abc",
                cwd: "/repo",
                modifiedAt: now.addingTimeInterval(-3_600),
                now: now,
                processes: []
            )
        )
    }
}

final class CodexSessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testDiscoversOnlyTheInteractiveSessionByDefaultAndAllThreeWhenToggleIsOn() throws {
        let codexHome = try makeFixture(sessions: [
            Fixture(id: "interactive-1", cwd: "/Users/me/project", originator: "codex-tui", source: .string("cli")),
            Fixture(id: "agent-spawned-1", cwd: "/Users/me/other", originator: "Claude Code", source: .string("vscode")),
            Fixture(id: "subagent-1", cwd: "/Users/me/sub", originator: "codex-tui", source: .object(["subagent": .object([:])]))
        ])

        let hiddenByDefault = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [] },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)
        XCTAssertEqual(hiddenByDefault.map(\.sessionId), ["interactive-1"])

        let shownWithToggle = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [] },
            showSubAgentSessions: { true }
        ).discover(now: fixedNow)
        XCTAssertEqual(
            Set(shownWithToggle.map(\.sessionId)),
            Set(["interactive-1", "agent-spawned-1", "subagent-1"])
        )
    }

    func testDiscoveredSessionCarriesCwdTitleAndResumeCommand() throws {
        let codexHome = try makeFixture(sessions: [
            Fixture(id: "abc-123", cwd: "/Users/me/project", originator: "codex-tui", source: .string("cli"), threadName: "Fix the flaky test")
        ])
        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [] },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)

        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(session.sessionId, "abc-123")
        XCTAssertEqual(session.agentName, "Codex")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        XCTAssertEqual(session.title, "Fix the flaky test")
        XCTAssertEqual(session.status, .idle, "no live process was supplied, so this must degrade to idle, not active")
        XCTAssertEqual(session.resumeCommand, Jumper.codexResumeCommand(sessionId: "abc-123"))
        XCTAssertNil(session.sessionFileURL)
    }

    func testActiveRequiresALiveMatchingProcess() throws {
        let codexHome = try makeFixture(sessions: [
            Fixture(id: "abc-123", cwd: "/Users/me/project", originator: "codex-tui", source: .string("cli"))
        ])
        let liveProcess = ClaudeProcess(pid: 1, command: "/usr/local/bin/codex", cwd: "/Users/me/project", tty: nil)

        let withLiveProcess = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [liveProcess] },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)
        XCTAssertEqual(withLiveProcess.first?.status, .active)

        let withoutLiveProcess = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [] },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)
        XCTAssertEqual(withoutLiveProcess.first?.status, .idle)
    }

    func testHiddenThresholdDropsStaleSessionsEvenWithoutALiveProcess() throws {
        let codexHome = try makeFixture(sessions: [
            Fixture(id: "stale", cwd: "/Users/me/project", originator: "codex-tui", source: .string("cli"), ageSeconds: 61 * 60.0)
        ])
        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [] },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)
        XCTAssertTrue(discovered.isEmpty)
    }

    func testDiscoveryIgnoresARolloutWithAMissingOrCorruptFirstLine() throws {
        let codexHome = try makeTemporaryDirectory()
        let dayDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(CodexRolloutDiscovery.dayDirectoryPath(for: fixedNow), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        try Data("not valid json at all".utf8)
            .write(to: dayDirectory.appendingPathComponent("rollout-2026-08-06T10-00-00-broken.jsonl"))
        try Data().write(to: dayDirectory.appendingPathComponent("rollout-2026-08-06T10-00-01-empty.jsonl"))

        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [] },
            showSubAgentSessions: { true }
        ).discover(now: fixedNow)
        XCTAssertTrue(discovered.isEmpty)
    }

    func testMissingSessionsDirectoryYieldsNoSessions() {
        XCTAssertTrue(
            CodexSessionSource(
                codexHome: URL(fileURLWithPath: "/nonexistent/.codex"),
                processProvider: { [] },
                showSubAgentSessions: { true }
            ).discover(now: fixedNow).isEmpty
        )
    }

    func testMissingSessionIndexStillDiscoversFromRolloutsAlone() throws {
        let codexHome = try makeTemporaryDirectory()
        let dayDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(CodexRolloutDiscovery.dayDirectoryPath(for: fixedNow), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        let firstLine = #"{"type":"session_meta","payload":{"session_id":"no-index","cwd":"/Users/me/project","originator":"codex-tui","source":"cli"}}"#
        try Data(firstLine.utf8).write(to: dayDirectory.appendingPathComponent("rollout-2026-08-06T10-00-00-no-index.jsonl"))
        // No session_index.jsonl written at all — must still discover the session, title
        // falling back to the cwd basename.

        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [] },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.sessionId, "no-index")
        XCTAssertEqual(discovered.first?.title, "project")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let id: String
        let cwd: String
        let originator: String?
        let source: JSONValue?
        var threadName: String?
        var ageSeconds: TimeInterval = 60
    }

    private func makeFixture(sessions: [Fixture]) throws -> URL {
        let codexHome = try makeTemporaryDirectory()
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)

        var indexLines: [String] = []
        for session in sessions {
            let updatedAt = fixedNow.addingTimeInterval(-session.ageSeconds)
            let dayDirectory = sessionsRoot.appendingPathComponent(
                CodexRolloutDiscovery.dayDirectoryPath(for: updatedAt),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

            if let threadName = session.threadName {
                indexLines.append(
                    #"{"id":"\#(session.id)","thread_name":"\#(threadName)","updated_at":"\#(iso8601(updatedAt))"}"#
                )
            }

            let rolloutURL = dayDirectory.appendingPathComponent(
                "rollout-\(iso8601(updatedAt).replacingOccurrences(of: ":", with: "-"))-\(session.id).jsonl"
            )
            let payload = sessionMetaPayloadJSON(
                sessionId: session.id,
                cwd: session.cwd,
                originator: session.originator,
                source: session.source
            )
            try Data(#"{"type":"session_meta","payload":\#(payload)}"#.utf8).write(to: rolloutURL)
            try FileManager.default.setAttributes(
                [.modificationDate: updatedAt],
                ofItemAtPath: rolloutURL.path
            )
        }
        if !indexLines.isEmpty {
            try Data(indexLines.joined(separator: "\n").utf8)
                .write(to: codexHome.appendingPathComponent("session_index.jsonl"))
        }
        return codexHome
    }

    /// Builds a `session_meta` payload's JSON body by hand (rather than `JSONEncoder`) so the
    /// fixture stays plain, ordinary JSON text — exactly what a real rollout file's first line
    /// looks like — with `source` written as either a bare string or a nested object.
    private func sessionMetaPayloadJSON(
        sessionId: String,
        cwd: String,
        originator: String?,
        source: JSONValue?
    ) -> String {
        var fields = [#""session_id":"\#(sessionId)""#, #""cwd":"\#(cwd)""#]
        if let originator {
            fields.append(#""originator":"\#(originator)""#)
        }
        if let source {
            fields.append(#""source":\#(jsonText(source))"#)
        }
        return "{\(fields.joined(separator: ","))}"
    }

    private func jsonText(_ value: JSONValue) -> String {
        switch value {
        case let .string(value): return "\"\(value)\""
        case let .number(value): return "\(value)"
        case let .bool(value): return "\(value)"
        case let .object(fields):
            return "{" + fields.map { #""\#($0.key)":\#(jsonText($0.value))"# }.joined(separator: ",") + "}"
        case let .array(values):
            return "[" + values.map(jsonText).joined(separator: ",") + "]"
        case .null:
            return "null"
        }
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

final class CodexRolloutDiscoveryTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testFindsFilesInTodaysDayDirectory() throws {
        let root = try makeTemporaryDirectory()
        let dayDirectory = root.appendingPathComponent(
            CodexRolloutDiscovery.dayDirectoryPath(for: fixedNow),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        let target = dayDirectory.appendingPathComponent("rollout-today.jsonl")
        try Data().write(to: target)

        let files = CodexRolloutDiscovery.candidateFiles(sessionsRoot: root, now: fixedNow, fileManager: .default)
        XCTAssertEqual(files.map(\.lastPathComponent), ["rollout-today.jsonl"])
    }

    func testFallsBackToTheNewestDayDirectoriesWhenTodayAndYesterdayAreMissing() throws {
        let root = try makeTemporaryDirectory()
        let oldDirectory = root.appendingPathComponent("2020/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let target = oldDirectory.appendingPathComponent("rollout-old.jsonl")
        try Data().write(to: target)

        let files = CodexRolloutDiscovery.candidateFiles(sessionsRoot: root, now: fixedNow, fileManager: .default)
        XCTAssertEqual(files.map(\.lastPathComponent), ["rollout-old.jsonl"])
    }

    func testIgnoresFilesNotMatchingTheRolloutNamingConvention() throws {
        let root = try makeTemporaryDirectory()
        let dayDirectory = root.appendingPathComponent(
            CodexRolloutDiscovery.dayDirectoryPath(for: fixedNow),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        try Data().write(to: dayDirectory.appendingPathComponent("rollout-real.jsonl"))
        try Data().write(to: dayDirectory.appendingPathComponent("notes.txt"))
        try Data().write(to: dayDirectory.appendingPathComponent("rollout-wrong-extension.txt"))

        let files = CodexRolloutDiscovery.candidateFiles(sessionsRoot: root, now: fixedNow, fileManager: .default)
        XCTAssertEqual(files.map(\.lastPathComponent), ["rollout-real.jsonl"])
    }

    func testCapsAtMaxFilesNewestFirst() throws {
        let root = try makeTemporaryDirectory()
        let dayDirectory = root.appendingPathComponent(
            CodexRolloutDiscovery.dayDirectoryPath(for: fixedNow),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        for index in 0..<5 {
            let url = dayDirectory.appendingPathComponent("rollout-\(index).jsonl")
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: fixedNow.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }

        let files = CodexRolloutDiscovery.candidateFiles(
            sessionsRoot: root,
            now: fixedNow,
            fileManager: .default,
            maxFiles: 2
        )
        XCTAssertEqual(files.map(\.lastPathComponent), ["rollout-4.jsonl", "rollout-3.jsonl"])
    }

    func testNonexistentSessionsRootYieldsNoFiles() {
        XCTAssertTrue(
            CodexRolloutDiscovery.candidateFiles(
                sessionsRoot: URL(fileURLWithPath: "/nonexistent/sessions"),
                now: fixedNow,
                fileManager: .default
            ).isEmpty
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
