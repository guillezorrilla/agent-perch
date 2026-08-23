import Foundation
import SQLite3
import XCTest
@testable import AgentPerch

/// Fixtures live in the test's OWN temporary directory — the real `~/.local/share/opencode` is
/// never read from and never written to by this suite (#11).
fileprivate extension XCTestCase {
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Builds a SQLite file from raw statements. The schema written here is the DOCUMENTED,
    /// UNVERIFIED OpenCode shape (#11): the binary is installed on this machine but has never been
    /// run, so no real `opencode.db` exists to check it against. These fixtures pin the contract
    /// the reader was written to, and the mismatch tests below pin what happens when reality turns
    /// out to differ.
    func makeDatabase(at url: URL, statements: [String]) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return XCTFail("could not create the fixture database at \(url.path)")
        }
        defer { sqlite3_close(database) }
        for statement in statements {
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                return XCTFail("fixture statement failed: \(statement)")
            }
        }
    }
}

final class OpenCodeDatabaseTests: XCTestCase {
    func testReadsSessionsJoinedToTheirProjectNewestFirst() throws {
        let url = try makeFixtureDatabase(sessions: [
            Fixture(id: "older", title: "Older work", updated: 1_000, projectId: "p1"),
            Fixture(id: "newer", title: "Newer work", updated: 2_000, projectId: "p1")
        ])

        let rows = OpenCodeDatabase.sessions(at: url)
        XCTAssertEqual(rows.map(\.sessionId), ["newer", "older"])
        XCTAssertEqual(rows.first?.title, "Newer work")
        XCTAssertEqual(rows.first?.workingDirectory, "/Users/me/project")
        XCTAssertEqual(rows.first?.updatedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertNil(rows.first?.parentId)
    }

    func testCarriesParentIdSoSubAgentSessionsCanBeFiltered() throws {
        let url = try makeFixtureDatabase(sessions: [
            Fixture(id: "child", title: "Spawned", updated: 1_000, projectId: "p1", parentId: "parent-1")
        ])
        XCTAssertEqual(OpenCodeDatabase.sessions(at: url).first?.parentId, "parent-1")
    }

    /// Whether OpenCode stores epoch seconds or milliseconds is part of the unverified schema, so
    /// both must land on the same instant rather than one being guessed at.
    func testEpochSecondsAndMillisecondsBothResolveToTheSameInstant() {
        XCTAssertEqual(OpenCodeDatabase.date(fromEpoch: 1_786_000_000), Date(timeIntervalSince1970: 1_786_000_000))
        XCTAssertEqual(
            OpenCodeDatabase.date(fromEpoch: 1_786_000_000_000),
            Date(timeIntervalSince1970: 1_786_000_000)
        )
    }

    func testRowsWithoutAnAbsoluteWorkingDirectoryAreDropped() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("opencode.db")
        try makeDatabase(at: url, statements: [
            "CREATE TABLE Project (id TEXT PRIMARY KEY, workingDirectory TEXT)",
            """
            CREATE TABLE SessionTable (
                id TEXT PRIMARY KEY, projectId TEXT, title TEXT, updated INTEGER, parentId TEXT
            )
            """,
            "INSERT INTO Project VALUES ('p1', 'relative/path'), ('p2', '/Users/me/ok')",
            """
            INSERT INTO SessionTable VALUES
                ('bad', 'p1', 'Relative', 1000, NULL),
                ('good', 'p2', 'Absolute', 2000, NULL)
            """
        ])

        XCTAssertEqual(OpenCodeDatabase.sessions(at: url).map(\.sessionId), ["good"])
    }

    /// The schema is unverified, so being wrong about it must cost nothing. A missing table, a
    /// missing column, a file that is not a database at all, and a file that is not there at all
    /// must every one of them answer "no sessions".
    func testAnyDatabaseThatDoesNotMatchTheExpectedSchemaYieldsNoSessions() throws {
        let directory = try makeTemporaryDirectory()

        let missingTable = directory.appendingPathComponent("missing-table.db")
        try makeDatabase(at: missingTable, statements: [
            "CREATE TABLE SessionTable (id TEXT, projectId TEXT, title TEXT, updated INTEGER, parentId TEXT)"
        ])
        XCTAssertTrue(OpenCodeDatabase.sessions(at: missingTable).isEmpty, "no Project table")

        let missingColumn = directory.appendingPathComponent("missing-column.db")
        try makeDatabase(at: missingColumn, statements: [
            "CREATE TABLE Project (id TEXT, workingDirectory TEXT)",
            // No `parentId`: the very column the user-vs-sub-agent filter depends on.
            "CREATE TABLE SessionTable (id TEXT, projectId TEXT, title TEXT, updated INTEGER)"
        ])
        XCTAssertTrue(OpenCodeDatabase.sessions(at: missingColumn).isEmpty, "no parentId column")

        let notADatabase = directory.appendingPathComponent("garbage.db")
        try Data("this is definitely not sqlite".utf8).write(to: notADatabase)
        XCTAssertTrue(OpenCodeDatabase.sessions(at: notADatabase).isEmpty, "not a database")

        XCTAssertTrue(
            OpenCodeDatabase.sessions(at: URL(fileURLWithPath: "/nonexistent/opencode.db")).isEmpty,
            "no file at all"
        )
    }

    // MARK: - Fixtures

    private struct Fixture {
        let id: String
        let title: String
        let updated: Int
        let projectId: String
        var parentId: String?
    }

    private func makeFixtureDatabase(sessions: [Fixture]) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("opencode.db")
        let rows = sessions.map { session in
            let parent = session.parentId.map { "'\($0)'" } ?? "NULL"
            return "('\(session.id)', '\(session.projectId)', '\(session.title)', \(session.updated), \(parent))"
        }
        try makeDatabase(at: url, statements: [
            "CREATE TABLE Project (id TEXT PRIMARY KEY, workingDirectory TEXT)",
            """
            CREATE TABLE SessionTable (
                id TEXT PRIMARY KEY, projectId TEXT, title TEXT, updated INTEGER, parentId TEXT
            )
            """,
            "INSERT INTO Project VALUES ('p1', '/Users/me/project')",
            "INSERT INTO SessionTable VALUES \(rows.joined(separator: ", "))"
        ])
        return url
    }
}

final class OpenCodeCLIRecognitionTests: XCTestCase {
    func testRecognizesTheInstalledBinaryPath() {
        let command = "/Users/me/.opencode/bin/opencode"
        XCTAssertTrue(TTYResolver.isOpenCodeCLI(command: command))
        XCTAssertTrue(TTYResolver.isAgentCLI("OpenCode", command: command))
        XCTAssertEqual(LiveAgentScan.agentName(forCommand: command), "OpenCode")
    }

    func testUnrelatedCommandsAreNotOpenCode() {
        XCTAssertFalse(TTYResolver.isOpenCodeCLI(command: "/bin/zsh"))
        XCTAssertFalse(TTYResolver.isOpenCodeCLI(command: "/Applications/Some.app/Contents/MacOS/opencode"))
        XCTAssertNil(LiveAgentScan.agentName(forCommand: "/Applications/Some.app/Contents/MacOS/opencode"))
    }
}

final class OpenCodeSessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testDiscoversAUserStartedSessionWithItsCwdTitleAndResumeCommand() throws {
        let url = try makeFixtureDatabase(sessions: [
            Row(id: "abc-123", title: "Fix the flaky test", age: 60)
        ])

        let discovered = makeSource(databaseURL: url).discover(now: fixedNow)
        let session = try XCTUnwrap(discovered.first)

        XCTAssertEqual(session.sessionId, "abc-123")
        XCTAssertEqual(session.agentName, "OpenCode")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        XCTAssertEqual(session.title, "Fix the flaky test")
        XCTAssertEqual(session.status, .idle, "no live process was supplied, so this must never be active")
        XCTAssertEqual(session.resumeCommand, "/usr/bin/env-opencode --session 'abc-123'")
        XCTAssertFalse(session.supportsLiveStatus)
    }

    func testTitleFallsBackToTheCwdBasenameWhenThereIsNone() throws {
        let url = try makeFixtureDatabase(sessions: [Row(id: "abc-123", title: nil, age: 60)])
        XCTAssertEqual(makeSource(databaseURL: url).discover(now: fixedNow).first?.title, "project")
    }

    /// #24's rule: only sessions the user started show by default.
    func testSubAgentSessionsAreHiddenByDefaultAndRevealedByTheToggle() throws {
        let url = try makeFixtureDatabase(sessions: [
            Row(id: "mine", title: "Mine", age: 60),
            Row(id: "spawned", title: "Spawned", age: 60, parentId: "mine")
        ])

        XCTAssertEqual(
            makeSource(databaseURL: url).discover(now: fixedNow).map(\.sessionId),
            ["mine"]
        )
        XCTAssertEqual(
            Set(makeSource(databaseURL: url, showSubAgentSessions: true).discover(now: fixedNow).map(\.sessionId)),
            ["mine", "spawned"]
        )
    }

    func testStaleSessionsAreHiddenPastTheVisibilityWindow() throws {
        let url = try makeFixtureDatabase(sessions: [Row(id: "stale", title: "Old", age: 61 * 60.0)])
        XCTAssertTrue(makeSource(databaseURL: url).discover(now: fixedNow).isEmpty)
    }

    /// The property that matters most: OpenCode has never run here, so this is the case that
    /// actually happens, and it must be silent rather than fatal.
    func testAMissingDatabaseYieldsNoSessionsRatherThanFailing() {
        XCTAssertTrue(
            makeSource(databaseURL: URL(fileURLWithPath: "/nonexistent/opencode.db"))
                .discover(now: fixedNow)
                .isEmpty
        )
    }

    func testAnUnreadableOrForeignDatabaseYieldsNoSessions() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("opencode.db")
        try Data("not sqlite at all".utf8).write(to: url)
        XCTAssertTrue(makeSource(databaseURL: url).discover(now: fixedNow).isEmpty)
    }

    /// A live `opencode` process claims its row, so the session shows once — with a tty for the
    /// jump ladder — rather than twice.
    func testALiveProcessClaimsItsRowRatherThanDuplicatingIt() throws {
        let url = try makeFixtureDatabase(sessions: [Row(id: "abc-123", title: "Live work", age: 10)])
        let process = ClaudeProcess(
            pid: 1,
            command: "/Users/me/.opencode/bin/opencode",
            cwd: "/Users/me/project",
            tty: "ttys004"
        )

        let discovered = makeSource(databaseURL: url, processes: [process]).discover(now: fixedNow)
        XCTAssertEqual(discovered.map(\.sessionId), ["abc-123"])
        XCTAssertEqual(discovered.first?.tty, "ttys004")
        XCTAssertEqual(discovered.first?.status, .active)
    }

    /// #33's rule: a live session is never hidden for want of a database row, and dates itself by
    /// when its process started.
    func testALiveProcessWithNoDatabaseAtAllStillShows() {
        let startedAt = fixedNow.addingTimeInterval(-3 * 60 * 60.0)
        let process = ClaudeProcess(
            pid: 1,
            command: "/Users/me/.opencode/bin/opencode",
            cwd: "/Users/me/elsewhere",
            tty: "ttys009",
            startedAt: startedAt
        )

        let discovered = makeSource(
            databaseURL: URL(fileURLWithPath: "/nonexistent/opencode.db"),
            processes: [process]
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.count, 1)
        XCTAssertTrue(discovered[0].sessionId.hasPrefix(OpenCodeSessionSource.liveSessionIdPrefix))
        XCTAssertEqual(discovered[0].cwd, "/Users/me/elsewhere")
        XCTAssertEqual(discovered[0].title, "elsewhere")
        XCTAssertEqual(discovered[0].lastActivity, startedAt)
        // No row means no id to resume — a bare relaunch is all this can honestly promise.
        XCTAssertEqual(discovered[0].resumeCommand, "/usr/bin/env-opencode")
    }

    // MARK: - Fixtures

    private struct Row {
        let id: String
        let title: String?
        let age: TimeInterval
        var parentId: String?
    }

    private func makeSource(
        databaseURL: URL,
        processes: [ClaudeProcess] = [],
        showSubAgentSessions: Bool = false
    ) -> OpenCodeSessionSource {
        OpenCodeSessionSource(
            databaseURL: databaseURL,
            processProvider: { processes },
            showSubAgentSessions: { showSubAgentSessions },
            // Pinned rather than resolved, so the suite never depends on what is installed on the
            // machine running it.
            binaryPath: "/usr/bin/env-opencode"
        )
    }

    private func makeFixtureDatabase(sessions: [Row]) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("opencode.db")
        let values = sessions.map { session in
            let title = session.title.map { "'\($0)'" } ?? "NULL"
            let parent = session.parentId.map { "'\($0)'" } ?? "NULL"
            let updated = Int(fixedNow.addingTimeInterval(-session.age).timeIntervalSince1970)
            return "('\(session.id)', 'p1', \(title), \(updated), \(parent))"
        }
        try makeDatabase(at: url, statements: [
            "CREATE TABLE Project (id TEXT PRIMARY KEY, workingDirectory TEXT)",
            """
            CREATE TABLE SessionTable (
                id TEXT PRIMARY KEY, projectId TEXT, title TEXT, updated INTEGER, parentId TEXT
            )
            """,
            "INSERT INTO Project VALUES ('p1', '/Users/me/project')",
            "INSERT INTO SessionTable VALUES \(values.joined(separator: ", "))"
        ])
        return url
    }
}
