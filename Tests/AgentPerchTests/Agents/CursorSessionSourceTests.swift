import Foundation
import SQLite3
import XCTest
@testable import AgentPerch

/// Cursor's `state.vscdb` is VS Code's key/value store, and it is opened READ-ONLY through a
/// `file:…?mode=ro` URI so that reading a live IDE's database can never create a `-wal`/`-shm`
/// sidecar in the user's own `Application Support` directory (#11). Every fixture below is a real
/// SQLite file with the real `ItemTable` shape, built in a temp directory — the reader is never
/// stubbed out from under itself.
final class CursorStateDatabaseTests: XCTestCase {
    func testReadsSeveralKeysFromOneOpen() throws {
        let url = try makeDatabase(items: [
            "aiService.generations": #"[{"unixMs":1779660556917,"textDescription":"hello"}]"#,
            "aiService.prompts": #"[{"text":"a prompt","commandType":4}]"#,
            "unrelated": "ignored"
        ])

        let values = CursorStateDatabase.values(
            forKeys: [CursorStateDatabase.generationsKey, CursorStateDatabase.promptsKey],
            at: url
        )

        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values[CursorStateDatabase.generationsKey]?.contains("hello") == true)
        XCTAssertTrue(values[CursorStateDatabase.promptsKey]?.contains("a prompt") == true)
    }

    func testAKeyThatIsNotThereIsSimplyAbsent() throws {
        let url = try makeDatabase(items: ["other": "value"])
        XCTAssertEqual(CursorStateDatabase.values(forKeys: [CursorStateDatabase.generationsKey], at: url), [:])
    }

    /// A store with no `ItemTable` at all — an older Cursor build, or something else entirely that
    /// happens to be named `state.vscdb`. `prepare` failing IS the schema check.
    func testADatabaseWithoutItemTableContributesNothing() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("state.vscdb")
        try execute("CREATE TABLE somethingElse (a TEXT)", at: url)
        XCTAssertEqual(CursorStateDatabase.values(forKeys: ["anything"], at: url), [:])
    }

    func testAMissingFileContributesNothing() {
        XCTAssertEqual(
            CursorStateDatabase.values(forKeys: ["k"], at: URL(fileURLWithPath: "/nonexistent/state.vscdb")),
            [:]
        )
    }

    /// Garbage where a database should be must be a miss, not a crash — a truncated file is
    /// exactly what a store copied mid-write looks like.
    func testACorruptFileContributesNothing() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("state.vscdb")
        try Data("this is definitely not a sqlite file".utf8).write(to: url)
        XCTAssertEqual(CursorStateDatabase.values(forKeys: ["k"], at: url), [:])
    }

    // MARK: - The read-only URI itself

    /// `immutable=1` only when there is no live `-wal`. Measured against all 30 real workspaces on
    /// this machine: a WAL-mode database whose `-shm` is gone cannot be opened by a read-only
    /// connection at all without it, and most of Cursor's stores are in that state once their
    /// window closes. A store that DOES have a `-wal` has a live writer, so it must be read
    /// THROUGH the WAL rather than as a stale snapshot.
    func testURIIsReadOnlyAndImmutableOnlyWithoutALiveWAL() {
        let url = URL(fileURLWithPath: "/tmp/ws/state.vscdb")
        XCTAssertEqual(
            CursorStateDatabase.readOnlyURI(for: url, hasLiveWAL: false),
            "file:/tmp/ws/state.vscdb?mode=ro&immutable=1"
        )
        XCTAssertEqual(
            CursorStateDatabase.readOnlyURI(for: url, hasLiveWAL: true),
            "file:/tmp/ws/state.vscdb?mode=ro"
        )
    }

    /// `?` and `#` end a SQLite URI's path and `%` starts an escape, so those three must be
    /// escaped. Anything else may be escaped or not — SQLite %-decodes the path back to the same
    /// bytes either way — so what this pins is the three that MUST be, not the ones that happen
    /// not to be. `testReadsThroughAPathFullOfCharactersSQLiteParses` proves the round trip.
    func testURIEscapesEveryCharacterSQLiteParses() {
        let uri = CursorStateDatabase.readOnlyURI(
            for: URL(fileURLWithPath: "/tmp/we?ird#name/100%/My Repo/state.vscdb"),
            hasLiveWAL: true
        )
        XCTAssertEqual(uri, "file:/tmp/we%3Fird%23name/100%25/My Repo/state.vscdb?mode=ro")
    }

    func testReadsThroughAPathFullOfCharactersSQLiteParses() throws {
        let awkward = try makeTemporaryDirectory()
            .appendingPathComponent("we?ird#name 100% café", isDirectory: true)
        try FileManager.default.createDirectory(at: awkward, withIntermediateDirectories: true)
        let url = awkward.appendingPathComponent("state.vscdb")
        try execute(
            "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB);INSERT INTO ItemTable VALUES ('k','v')",
            at: url
        )

        XCTAssertEqual(CursorStateDatabase.values(forKeys: ["k"], at: url), ["k": "v"])
    }

    /// The promise that matters most, in the exact shape the real store is in: a WAL-mode database
    /// whose window has been closed, so its `-wal`/`-shm` are gone. A plain read-only connection
    /// cannot open one of those at all — it would have to create the shared-memory index — which is
    /// why `immutable=1` is there. It must read, and it must leave nothing behind (#11).
    func testReadingACheckpointedWALDatabaseCreatesNoSidecarFiles() throws {
        let url = try makeDatabase(items: ["aiService.prompts": #"[{"text":"kept"}]"#], walMode: true)
        let directory = url.deletingLastPathComponent()
        for leftover in try sidecars(in: directory) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(leftover))
        }
        // WAL is a property of the file header, so this is still a WAL database with no sidecars.
        XCTAssertEqual(try sidecars(in: directory), [])

        let values = CursorStateDatabase.values(forKeys: [CursorStateDatabase.promptsKey], at: url)

        XCTAssertTrue(values[CursorStateDatabase.promptsKey]?.contains("kept") == true)
        XCTAssertEqual(try sidecars(in: directory), [], "a read must never leave -wal/-shm behind")
    }

    /// The other half: a workspace open in Cursor right now, whose newest state is still only in
    /// the `-wal`. This must be read THROUGH the WAL — `immutable=1` here would silently serve the
    /// pre-WAL snapshot, which is the whole reason it is conditional.
    func testReadsCurrentStateFromALiveWALRatherThanAStaleSnapshot() throws {
        let url = try makeDatabase(items: ["aiService.prompts": #"[{"text":"old"}]"#], walMode: true)
        // A second connection standing in for the running IDE: it writes and does NOT checkpoint,
        // so the new value exists only in the -wal for as long as it stays open.
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &writer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let database = try XCTUnwrap(writer)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(database, "INSERT INTO ItemTable VALUES ('aiService.prompts','[{\"text\":\"new\"}]')", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertTrue(try sidecars(in: url.deletingLastPathComponent()).contains("state.vscdb-wal"))

        let values = CursorStateDatabase.values(forKeys: [CursorStateDatabase.promptsKey], at: url)

        XCTAssertTrue(values[CursorStateDatabase.promptsKey]?.contains("new") == true)
    }

    // MARK: - Fixtures

    private func sidecars(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") || $0.hasSuffix("-journal") }
            .sorted()
    }

    private func makeDatabase(items: [String: String], walMode: Bool = false) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("state.vscdb")
        var statements = ["CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"]
        if walMode { statements.insert("PRAGMA journal_mode=WAL", at: 0) }
        for (key, value) in items.sorted(by: { $0.key < $1.key }) {
            statements.append("INSERT INTO ItemTable VALUES ('\(key)', '\(value.replacingOccurrences(of: "'", with: "''"))')")
        }
        try execute(statements.joined(separator: ";"), at: url)
        return url
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw XCTSkip("could not create the sqlite fixture at \(url.path)")
        }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? ""
        sqlite3_close(database)
        XCTAssertEqual(result, SQLITE_OK, "fixture sql failed: \(message)")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

final class CursorAIStateTests: XCTestCase {
    /// `unixMs` is MILLISECONDS — an Int division here would land the row in 1970.
    func testNewestGenerationIsParsedAsMilliseconds() {
        let json = #"""
        [{"unixMs":1779660556917,"generationUUID":"a","type":"composer","textDescription":"older"},
         {"unixMs":1779660999000,"generationUUID":"b","type":"composer","textDescription":"newest"}]
        """#
        let newest = CursorAIState.newestGeneration(json)
        XCTAssertEqual(newest?.timestamp, Date(timeIntervalSince1970: 1_779_660_999.0))
        XCTAssertEqual(newest?.description, "newest")
    }

    func testNewestWinsRegardlessOfArrayOrder() {
        let json = #"""
        [{"unixMs":1779660999000,"textDescription":"newest"},
         {"unixMs":1779660556917,"textDescription":"older"}]
        """#
        XCTAssertEqual(CursorAIState.newestGeneration(json)?.description, "newest")
    }

    func testAbsentEmptyAndMalformedGenerationsAreNil() {
        XCTAssertNil(CursorAIState.newestGeneration(nil))
        // The workspace open in Cursor right now literally stores this — `aiService.generations`
        // is a legacy key current Cursor no longer writes (#11).
        XCTAssertNil(CursorAIState.newestGeneration("[]"))
        XCTAssertNil(CursorAIState.newestGeneration("not json at all"))
        XCTAssertNil(CursorAIState.newestGeneration(#"{"unixMs":1779660556917}"#))
        XCTAssertNil(CursorAIState.newestGeneration(#"[{"textDescription":"no timestamp"}]"#))
        XCTAssertNil(CursorAIState.newestGeneration(#"[{"unixMs":"not a number"}]"#))
        XCTAssertNil(CursorAIState.newestGeneration(#"[{"unixMs":0}]"#))
    }

    /// `aiService.prompts` carries no timestamps, so the last entry is the only "most recent"
    /// there is.
    func testLastPromptIsTheLastEntry() {
        let json = #"[{"text":"first","commandType":4},{"text":"last","commandType":4}]"#
        XCTAssertEqual(CursorAIState.lastPrompt(json), "last")
        XCTAssertNil(CursorAIState.lastPrompt("[]"))
        XCTAssertNil(CursorAIState.lastPrompt("garbage"))
    }

    func testSnapshotPrefersTheGenerationDescriptionAndFallsBackToThePrompt() {
        let generations = #"[{"unixMs":1779660999000,"textDescription":"from a generation"}]"#
        let prompts = #"[{"text":"from a prompt"}]"#

        XCTAssertEqual(
            CursorAIState.snapshot(generationsJSON: generations, promptsJSON: prompts).title,
            "from a generation"
        )
        XCTAssertEqual(
            CursorAIState.snapshot(generationsJSON: "[]", promptsJSON: prompts).title,
            "from a prompt"
        )
        XCTAssertEqual(CursorAIState.snapshot(generationsJSON: nil, promptsJSON: nil), .empty)
    }

    /// The newest `textDescription` in this machine's real store is an @-mention of a path, not a
    /// title — so the generation still supplies the TIMESTAMP while the prompt supplies the text.
    func testAPathMentionIsNotATitleButStillCarriesItsTimestamp() {
        let generations = #"""
        [{"unixMs":1779660999000,"textDescription":"@~/.cursor/projects/Users-me-repo/terminals/1"}]
        """#
        let snapshot = CursorAIState.snapshot(
            generationsJSON: generations,
            promptsJSON: #"[{"text":"a real prompt"}]"#
        )
        XCTAssertEqual(snapshot.title, "a real prompt")
        XCTAssertEqual(snapshot.lastGeneration, Date(timeIntervalSince1970: 1_779_660_999.0))
    }

    func testUsableTitleRejectsPathsAndBlanksAndKeepsOnlyTheFirstLine() {
        XCTAssertNil(CursorAIState.usableTitle(nil))
        XCTAssertNil(CursorAIState.usableTitle("   \n  "))
        XCTAssertNil(CursorAIState.usableTitle("@src/main.swift"))
        XCTAssertNil(CursorAIState.usableTitle("/Users/me/repo"))
        XCTAssertNil(CursorAIState.usableTitle("~/repo"))
        XCTAssertEqual(CursorAIState.usableTitle("  a real prompt  "), "a real prompt")
        XCTAssertEqual(CursorAIState.usableTitle("\n\nfirst line\nsecond line"), "first line")
    }
}

final class CursorSessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: - Happy path

    func testDiscoversCwdTitleAndTimestampFromTheDatabase() throws {
        let home = try makeTemporaryDirectory()
        let generatedAt = fixedNow.addingTimeInterval(-120)
        try makeWorkspace(
            in: home,
            hash: "abc123",
            folderPath: "/Users/me/project",
            ageSeconds: 600,
            generations: [(generatedAt, "Im updating expo to version 56")]
        )

        let session = try XCTUnwrap(makeSource(home: home).discover(now: fixedNow).first)

        XCTAssertEqual(session.agentName, "Cursor")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        XCTAssertEqual(session.sessionId, "cursor:abc123")
        // Every title carries the "— workspace" qualifier, exactly as Antigravity's does: a
        // compact row (the only shape one of these is ever allowed to take) has no secondary
        // text line to say so instead (#29).
        XCTAssertEqual(session.title, "Im updating expo to version 56 — workspace")
        // The generation is NEWER than the ten-minute-old mtimes, so it wins — to the millisecond.
        XCTAssertEqual(session.lastActivity.timeIntervalSince1970, generatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(session.sessionFileURL)
    }

    func testTitleFallsBackToThePromptThenToTheFolderBasename() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(
            in: home, hash: "prompted", folderPath: "/Users/me/prompted", ageSeconds: 60,
            generations: [], prompts: ["what does this function do"]
        )
        try makeWorkspace(in: home, hash: "bare", folderPath: "/Users/me/bare", ageSeconds: 60)

        let titles = Dictionary(
            uniqueKeysWithValues: makeSource(home: home).discover(now: fixedNow).map { ($0.cwd, $0.title) }
        )

        XCTAssertEqual(titles["/Users/me/prompted"], "what does this function do — workspace")
        XCTAssertEqual(titles["/Users/me/bare"], "bare — workspace")
    }

    func testLongTitlesTruncateOnAWordBoundaryWithinSixtyCharacters() throws {
        let home = try makeTemporaryDirectory()
        let longName = Array(repeating: "word", count: 20).joined(separator: "-")
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/\(longName)", ageSeconds: 60)

        let title = try XCTUnwrap(makeSource(home: home).discover(now: fixedNow).first?.title)

        XCTAssertTrue(title.hasSuffix("— workspace"))
        XCTAssertLessThanOrEqual(title.count, 60)
    }

    func testResumeCommandPresentOnlyWhenTheCursorCLIIsAvailable() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 60)

        XCTAssertEqual(
            makeSource(home: home, cursorAvailable: true).discover(now: fixedNow).first?.resumeCommand,
            "cursor '/Users/me/project'"
        )
        XCTAssertNil(makeSource(home: home).discover(now: fixedNow).first?.resumeCommand)
    }

    // MARK: - Timestamps

    /// The signal that actually moves: `state.vscdb`'s own mtime goes STALE on a live workspace,
    /// because Cursor writes to the `-wal` beside it — both workspaces open on this machine have a
    /// `state.vscdb` from two months ago and a `-wal` from minutes ago (#11).
    func testFallsBackToDirectoryMtimeWhenTheGenerationsKeyIsMissing() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 300)

        let session = try XCTUnwrap(makeSource(home: home).discover(now: fixedNow).first)

        XCTAssertEqual(
            session.lastActivity.timeIntervalSince1970,
            fixedNow.addingTimeInterval(-300).timeIntervalSince1970,
            accuracy: 1
        )
    }

    /// A generation is a floor on activity, never a ceiling — `aiService.generations` is a legacy
    /// key current Cursor no longer writes, so a two-month-old entry beside a mtime from a minute
    /// ago must not drag the row back two months.
    func testAStaleGenerationNeverOverridesAFresherMtime() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(
            in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 60,
            generations: [(fixedNow.addingTimeInterval(-60 * 60.0 * 24 * 60), "two months ago")]
        )

        let session = try XCTUnwrap(makeSource(home: home).discover(now: fixedNow).first)

        XCTAssertEqual(
            session.lastActivity.timeIntervalSince1970,
            fixedNow.addingTimeInterval(-60).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(session.status, .idle)
    }

    func testAnUnparseableGenerationsValueDegradesToTheMtime() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(
            in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 120,
            rawGenerations: "{not json"
        )

        let session = try XCTUnwrap(makeSource(home: home).discover(now: fixedNow).first)

        XCTAssertEqual(
            session.lastActivity.timeIntervalSince1970,
            fixedNow.addingTimeInterval(-120).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(session.title, "project — workspace")
    }

    // MARK: - Liveness

    func testAFreshWorkspaceIsIdleNeverActive() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "a", folderPath: "/Users/me/a", ageSeconds: 5)
        try makeWorkspace(in: home, hash: "b", folderPath: "/Users/me/b", ageSeconds: 90)

        let discovered = makeSource(home: home).discover(now: fixedNow)

        XCTAssertEqual(discovered.count, 2)
        XCTAssertTrue(discovered.allSatisfy { $0.status == .idle })
    }

    func testAStaleWorkspaceIsDroppedAndItsDatabaseIsNeverOpened() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 61 * 60.0)

        var opens = 0
        let discovered = makeSource(home: home, countingOpensInto: { _ in opens += 1 }).discover(now: fixedNow)

        XCTAssertTrue(discovered.isEmpty)
        XCTAssertEqual(opens, 0, "a workspace outside the visibility window must not cost a database open")
    }

    func testRowsAreOrderedMostRecentFirst() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "old", folderPath: "/Users/me/old", ageSeconds: 900)
        try makeWorkspace(in: home, hash: "new", folderPath: "/Users/me/new", ageSeconds: 30)
        try makeWorkspace(in: home, hash: "mid", folderPath: "/Users/me/mid", ageSeconds: 300)

        XCTAssertEqual(
            makeSource(home: home).discover(now: fixedNow).map(\.cwd),
            ["/Users/me/new", "/Users/me/mid", "/Users/me/old"]
        )
    }

    // MARK: - Never crash the list

    /// Cursor keeps a literal `empty-window` entry for windowless sessions, and it is one of the
    /// most recently touched directories in the real store — without the skip it would head the
    /// list with no folder at all (#11).
    func testEntriesWithNoResolvableFolderAreSkipped() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "good", folderPath: "/Users/me/kept", ageSeconds: 60)

        let storage = home.appendingPathComponent("User/workspaceStorage", isDirectory: true)
        // `empty-window`: a directory with a state.vscdb and no workspace.json at all.
        let emptyWindow = storage.appendingPathComponent("empty-window", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyWindow, withIntermediateDirectories: true)
        try Data().write(to: emptyWindow.appendingPathComponent("state.vscdb"))
        // Malformed JSON where a workspace.json should be.
        try writeWorkspaceJSON("not json at all", named: "corrupt", in: storage)
        // A folder key that names no local folder: a remote/WSL host, and a non-file scheme.
        try writeWorkspaceJSON(#"{"folder":"file://remote-host/Users/me/elsewhere"}"#, named: "remote", in: storage)
        try writeWorkspaceJSON(#"{"folder":"vscode-remote://ssh/Users/me/elsewhere"}"#, named: "scheme", in: storage)
        // A well-formed JSON object with no `folder` key.
        try writeWorkspaceJSON(#"{"workspace":"/Users/me/elsewhere"}"#, named: "nofolder", in: storage)

        XCTAssertEqual(makeSource(home: home).discover(now: fixedNow).map(\.cwd), ["/Users/me/kept"])
    }

    /// A `folder` that points at a path which no longer exists is still a perfectly good answer —
    /// the row says where the workspace WAS, and the jump reopens it. What must not happen is a
    /// crash or a silent loss of the workspaces around it.
    func testADeletedFolderStillYieldsARowAndDoesNotDisturbItsNeighbours() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "gone", folderPath: "/Users/me/deleted-months-ago", ageSeconds: 60)
        try makeWorkspace(in: home, hash: "here", folderPath: "/Users/me/here", ageSeconds: 90)

        XCTAssertEqual(
            makeSource(home: home).discover(now: fixedNow).map(\.cwd).sorted(),
            ["/Users/me/deleted-months-ago", "/Users/me/here"]
        )
    }

    /// A workspace whose database is unreadable — locked, truncated, replaced by a directory —
    /// keeps its row on the strength of its mtime rather than taking the list down with it.
    func testAnUnreadableDatabaseStillYieldsAnMtimeOnlyRow() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 60)
        let database = home
            .appendingPathComponent("User/workspaceStorage/abc/state.vscdb")
        try FileManager.default.removeItem(at: database)
        try Data("truncated garbage".utf8).write(to: database)

        let session = try XCTUnwrap(makeSource(home: home).discover(now: fixedNow).first)

        XCTAssertEqual(session.cwd, "/Users/me/project")
        XCTAssertEqual(session.title, "project — workspace")
        XCTAssertEqual(session.status, .idle)
    }

    func testAWorkspaceWithNoDatabaseAtAllStillYieldsARow() throws {
        let home = try makeTemporaryDirectory()
        let directory = home.appendingPathComponent("User/workspaceStorage/nodb", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent("workspace.json")
        try Data(#"{"folder":"file:///Users/me/nodb"}"#.utf8).write(to: json)
        let mtime = fixedNow.addingTimeInterval(-60)
        for url in [directory, json] {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }

        XCTAssertEqual(makeSource(home: home).discover(now: fixedNow).map(\.cwd), ["/Users/me/nodb"])
    }

    func testMissingWorkspaceStorageDirectoryYieldsNoSessions() {
        XCTAssertTrue(
            CursorSessionSource(
                cursorHome: URL(fileURLWithPath: "/nonexistent/Cursor"),
                cursorAvailableProvider: { true },
                showWorkspaces: { true }
            ).discover(now: fixedNow).isEmpty
        )
    }

    // MARK: - Opt-in gate

    /// A workspace directory's mtime is not evidence of agent activity, so nothing at all is
    /// contributed until the user opts in — Cursor must not be louder than Antigravity (#27, #11).
    func testContributesNothingWhenTheSettingIsOff() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 30)

        let discovered = CursorSessionSource(
            cursorHome: home,
            cursorAvailableProvider: { XCTFail("must not probe for the CLI when opted out"); return true },
            showWorkspaces: { false },
            readState: { _ in XCTFail("must not open a database when opted out"); return .empty }
        ).discover(now: fixedNow)

        XCTAssertTrue(discovered.isEmpty)
    }

    /// Opted out, the directory listing itself must not happen — the gate is ahead of all disk
    /// work, not a filter after it.
    func testOptedOutNeverEnumeratesTheWorkspaceStorageDirectory() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 30)

        let fileManager = CountingFileManager()
        _ = CursorSessionSource(
            cursorHome: home,
            fileManager: fileManager,
            cursorAvailableProvider: { false },
            showWorkspaces: { false }
        ).discover(now: fixedNow)

        XCTAssertEqual(fileManager.listings, 0)
    }

    func testDefaultsToOffSoAFreshInstallShowsNothing() throws {
        let key = "showCursorWorkspaces"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        addTeardownBlock {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
        }

        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 30)

        XCTAssertTrue(
            CursorSessionSource(cursorHome: home, cursorAvailableProvider: { false })
                .discover(now: fixedNow)
                .isEmpty
        )
    }

    // MARK: - Cost bound

    /// The bound: resolve every candidate from the cheap files only, drop everything already
    /// outside the one-hour window, and only then open databases — never more of them than the
    /// `maxRows` rows this source can contribute. Thirty workspaces of which two are recent must
    /// cost two opens, not thirty (#11).
    func testOnlyRecentWorkspacesCostADatabaseOpen() throws {
        let home = try makeTemporaryDirectory()
        for index in 0..<28 {
            try makeWorkspace(
                in: home, hash: "old\(index)", folderPath: "/Users/me/old\(index)",
                ageSeconds: 60 * 60.0 + TimeInterval(index)
            )
        }
        try makeWorkspace(in: home, hash: "recentA", folderPath: "/Users/me/a", ageSeconds: 30)
        try makeWorkspace(in: home, hash: "recentB", folderPath: "/Users/me/b", ageSeconds: 60)

        var opened: [String] = []
        let discovered = makeSource(home: home, countingOpensInto: { opened.append($0) })
            .discover(now: fixedNow)

        XCTAssertEqual(discovered.map(\.cwd), ["/Users/me/a", "/Users/me/b"])
        XCTAssertEqual(opened.sorted(), ["recentA", "recentB"])
    }

    /// The pathological case — every workspace touched within the hour — is still capped, and the
    /// cap is the row cap, so no database is ever opened for a row the panel would throw away.
    func testDatabaseOpensAreCappedAtTheRowCap() throws {
        let home = try makeTemporaryDirectory()
        for index in 0..<25 {
            try makeWorkspace(
                in: home, hash: "ws\(index)", folderPath: "/Users/me/ws\(index)",
                ageSeconds: TimeInterval(index + 1) * 10
            )
        }

        var opens = 0
        let discovered = makeSource(home: home, countingOpensInto: { _ in opens += 1 })
            .discover(now: fixedNow)

        XCTAssertEqual(opens, CursorSessionSource.maxRows)
        XCTAssertEqual(discovered.count, CursorSessionSource.maxRows)
        // Newest first: the cap drops the oldest of the recent workspaces, never the freshest.
        XCTAssertEqual(discovered.first?.cwd, "/Users/me/ws0")
    }

    // MARK: - Fixtures

    private final class CountingFileManager: FileManager, @unchecked Sendable {
        var listings = 0
        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions = []
        ) throws -> [URL] {
            listings += 1
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }

    private func makeSource(
        home: URL,
        cursorAvailable: Bool = false,
        countingOpensInto record: ((String) -> Void)? = nil
    ) -> CursorSessionSource {
        CursorSessionSource(
            cursorHome: home,
            cursorAvailableProvider: { cursorAvailable },
            showWorkspaces: { true },
            readState: { databaseURL in
                record?(databaseURL.deletingLastPathComponent().lastPathComponent)
                return CursorSessionSource.readState(at: databaseURL)
            }
        )
    }

    /// A real workspace directory: `workspace.json` plus a real SQLite `state.vscdb` with the real
    /// `ItemTable` shape, every mtime pinned so the fixture's age is what it says it is.
    private func makeWorkspace(
        in cursorHome: URL,
        hash: String,
        folderPath: String,
        ageSeconds: TimeInterval,
        generations: [(Date, String)] = [],
        prompts: [String] = [],
        rawGenerations: String? = nil
    ) throws {
        let directory = cursorHome
            .appendingPathComponent("User/workspaceStorage", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspaceJSON = directory.appendingPathComponent("workspace.json")
        try Data(#"{"folder":"file://\#(folderPath)"}"#.utf8).write(to: workspaceJSON)

        var items: [String: String] = [:]
        if let rawGenerations {
            items[CursorStateDatabase.generationsKey] = rawGenerations
        } else if !generations.isEmpty {
            items[CursorStateDatabase.generationsKey] = "[" + generations.map { moment, description in
                let milliseconds = (moment.timeIntervalSince1970 * 1000.0).rounded()
                return #"{"unixMs":\#(String(format: "%.0f", milliseconds)),"generationUUID":"\#(UUID().uuidString)","type":"composer","textDescription":"\#(description)"}"#
            }.joined(separator: ",") + "]"
        }
        if !prompts.isEmpty {
            items[CursorStateDatabase.promptsKey] = "[" + prompts
                .map { #"{"text":"\#($0)","commandType":4}"# }
                .joined(separator: ",") + "]"
        }
        let database = directory.appendingPathComponent("state.vscdb")
        try makeStateDatabase(at: database, items: items)

        // The directory and every file just written into it need an explicit mtime — otherwise
        // each carries the real wall-clock time it was created, which (being "now", not
        // `fixedNow`) would always outrank whatever age this fixture asked for.
        let mtime = fixedNow.addingTimeInterval(-ageSeconds)
        for url in [directory, workspaceJSON, database] {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    private func writeWorkspaceJSON(_ contents: String, named name: String, in storage: URL) throws {
        let directory = storage.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: directory.appendingPathComponent("workspace.json"))
    }

    private func makeStateDatabase(at url: URL, items: [String: String]) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw XCTSkip("could not create the sqlite fixture at \(url.path)")
        }
        defer { sqlite3_close(database) }

        var sql = ["CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"]
        for (key, value) in items.sorted(by: { $0.key < $1.key }) {
            sql.append("INSERT INTO ItemTable VALUES ('\(key)', '\(value.replacingOccurrences(of: "'", with: "''"))')")
        }
        XCTAssertEqual(sqlite3_exec(database, sql.joined(separator: ";"), nil, nil, nil), SQLITE_OK)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// The jump seam, mirroring `AntigravityJumpRoutingTests`: a Cursor row is a GUI folder, so it must
/// never resolve against the process table — a Claude CLI process that merely shares the folder
/// would otherwise be mistaken for it and imply a terminal pill and an exact-focus rung that do not
/// exist for it (#3, #11).
final class CursorJumpRoutingTests: XCTestCase {
    private struct FakeSource: AgentSessionSource {
        let agentName: String
        let sessions: [DiscoveredSession]
        func discover(now: Date) -> [DiscoveredSession] { sessions }
    }

    @MainActor
    func testCursorRowNeverSelectsATTYFocusRungEvenWhenATerminalProcessSharesItsCwd() throws {
        let discovered = DiscoveredSession(
            sessionId: "cursor:abc",
            agentName: "Cursor",
            cwd: "/repo",
            title: "repo — workspace",
            lastActivity: Date(timeIntervalSince1970: 1_000),
            status: .idle,
            resumeCommand: nil,
            sessionFileURL: nil
        )
        let claudeAtSameCwd = ClaudeProcess(pid: 42, command: "/usr/local/bin/claude", cwd: "/repo", tty: "ttys009")

        let store = SessionStore(
            sources: [FakeSource(agentName: "Cursor", sessions: [discovered])],
            processProvider: { [claudeAtSameCwd] }
        )
        store.refresh(now: Date(timeIntervalSince1970: 1_060))

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.agentName, "Cursor")
        XCTAssertEqual(session.workspaceIDE, .cursor)
        XCTAssertEqual(session.jumpRung, .newTab)
        XCTAssertNil(session.terminalName, "a Cursor row must never imply terminal semantics")
        XCTAssertNil(session.tty)
    }

    /// A real agent session is untouched by the classification — only prefixed workspace ids and
    /// the two IDE agent names are workspaces.
    func testOnlyWorkspaceRowsAreClassifiedAsIDEWorkspaces() {
        XCTAssertEqual(AgentSession.workspaceIDE(agentName: "Cursor", sessionId: "cursor:abc"), .cursor)
        XCTAssertEqual(AgentSession.workspaceIDE(agentName: "Antigravity", sessionId: "antigravity:abc"), .antigravity)
        XCTAssertNil(AgentSession.workspaceIDE(agentName: "Antigravity", sessionId: "agy:ttys001:/repo"))
        XCTAssertNil(AgentSession.workspaceIDE(agentName: "Cursor", sessionId: "something-else"))
        XCTAssertNil(AgentSession.workspaceIDE(agentName: "Claude", sessionId: "cursor:abc"))
    }
}

final class CursorLaunchCommandTests: XCTestCase {
    func testUsesTheCursorCLIWhenAvailable() {
        let plan = Jumper.workspaceIDELaunchCommand(.cursor, path: "/repo", cliAvailable: true)
        XCTAssertEqual(plan.executable, "/usr/bin/env")
        XCTAssertEqual(plan.arguments, ["cursor", "/repo"])
    }

    /// `/Applications/Cursor.app`, whose display name is plain "Cursor".
    func testFallsBackToOpenWhenTheCLIIsUnavailable() {
        let plan = Jumper.workspaceIDELaunchCommand(.cursor, path: "/repo", cliAvailable: false)
        XCTAssertEqual(plan.executable, "/usr/bin/open")
        XCTAssertEqual(plan.arguments, ["-a", "Cursor", "/repo"])
    }
}

/// A Cursor row must never be promoted to a full card, for the same reason an Antigravity
/// workspace row must not: it is a folder that was open recently, not a session (#29, #11).
final class CursorSessionLayoutTests: XCTestCase {
    func testACursorWorkspaceIsNeverTheFallbackFullCard() {
        let workspace = session("cursor:abc", agentName: "Cursor", at: 900)
        let real = session("claude-1", agentName: "Claude", at: 100)

        let split = SessionLayout.split(sessions: [workspace, real])

        XCTAssertEqual(split.fullCards.map(\.sessionId), ["claude-1"])
        XCTAssertEqual(split.compactRows.map(\.sessionId), ["cursor:abc"])
    }

    func testAllCursorWorkspacesStayCompactWhenNothingElseQualifies() {
        let split = SessionLayout.split(sessions: [
            session("cursor:a", agentName: "Cursor", at: 500),
            session("cursor:b", agentName: "Cursor", at: 100)
        ])

        XCTAssertTrue(split.fullCards.isEmpty)
        XCTAssertEqual(split.compactRows.count, 2)
    }

    private func session(_ id: String, agentName: String, at seconds: TimeInterval) -> AgentSession {
        AgentSession(
            sessionId: id,
            agentName: agentName,
            cwd: "/repo",
            modifiedAt: Date(timeIntervalSince1970: seconds),
            status: .idle,
            jumpRung: .newTab,
            title: id,
            lastPrompt: nil,
            tty: nil,
            terminalName: nil,
            currentActivity: nil,
            notificationMessage: nil,
            pendingToolName: nil,
            pendingToolInput: nil,
            resumeCommand: nil
        )
    }
}
