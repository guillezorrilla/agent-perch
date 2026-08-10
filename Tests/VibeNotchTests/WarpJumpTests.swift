import Foundation
import SQLite3
import XCTest
@testable import VibeNotch

final class WarpTabLocatorTests: XCTestCase {
    func testFixtureDatabaseCountsNonTerminalTabBeforeTarget() throws {
        try withFixtureDatabase { databaseURL, database in
            try createFixtureSchema(in: database)
            try execute("""
                INSERT INTO tabs VALUES (10, 1), (20, 1), (30, 1);
                INSERT INTO pane_nodes VALUES (100, 10), (300, 30);
                INSERT INTO terminal_panes VALUES (100, '/other'), (300, '/repo');
                INSERT INTO pane_leaves VALUES
                    (100, 'terminal', 0), (300, 'terminal', 1);
                """, in: database)

            XCTAssertEqual(WarpTabLocator(databaseURL: databaseURL).tabIndex(forCwd: "/repo"), 3)
        }
    }

    func testFixtureDatabasePrefersFocusedCwdMatchAcrossWindows() throws {
        try withFixtureDatabase { databaseURL, database in
            try createFixtureSchema(in: database)
            try execute("""
                INSERT INTO tabs VALUES (10, 1), (30, 2), (40, 2);
                INSERT INTO pane_nodes VALUES (100, 10), (400, 40);
                INSERT INTO terminal_panes VALUES (100, '/repo'), (400, '/repo');
                INSERT INTO pane_leaves VALUES
                    (100, 'terminal', 0), (400, 'terminal', 1);
                """, in: database)

            XCTAssertEqual(WarpTabLocator(databaseURL: databaseURL).tabIndex(forCwd: "/repo"), 2)
        }
    }

    func testFixtureDatabaseUsesMostRecentCwdMatchWhenNoneIsFocused() throws {
        try withFixtureDatabase { databaseURL, database in
            try createFixtureSchema(in: database)
            try execute("""
                INSERT INTO tabs VALUES (10, 1), (100, 2), (110, 2);
                INSERT INTO pane_nodes VALUES (1000, 10), (1100, 110);
                INSERT INTO terminal_panes VALUES (1000, '/repo'), (1100, '/repo');
                INSERT INTO pane_leaves VALUES
                    (1000, 'terminal', 0), (1100, 'terminal', 0);
                """, in: database)

            XCTAssertEqual(WarpTabLocator(databaseURL: databaseURL).tabIndex(forCwd: "/repo"), 2)
        }
    }

    func testFixtureDatabaseReturnsNilForTabIndexAboveNine() throws {
        try withFixtureDatabase { databaseURL, database in
            try createFixtureSchema(in: database)
            try execute("""
                INSERT INTO tabs VALUES
                    (1, 1), (2, 1), (3, 1), (4, 1), (5, 1),
                    (6, 1), (7, 1), (8, 1), (9, 1), (10, 1);
                INSERT INTO pane_nodes VALUES (100, 10);
                INSERT INTO terminal_panes VALUES (100, '/repo');
                INSERT INTO pane_leaves VALUES (100, 'terminal', 1);
                """, in: database)

            XCTAssertNil(WarpTabLocator(databaseURL: databaseURL).tabIndex(forCwd: "/repo"))
        }
    }

    func testFixtureDatabaseReturnsNilForMissingCwd() throws {
        try withFixtureDatabase { databaseURL, database in
            try createFixtureSchema(in: database)
            try execute("""
                INSERT INTO tabs VALUES (10, 1);
                INSERT INTO pane_nodes VALUES (100, 10);
                INSERT INTO terminal_panes VALUES (100, '/other');
                INSERT INTO pane_leaves VALUES (100, 'terminal', 1);
                """, in: database)

            XCTAssertNil(WarpTabLocator(databaseURL: databaseURL).tabIndex(forCwd: "/missing"))
        }
    }

    func testFixtureDatabaseReturnsNilWhenExpectedSchemaIsMissing() throws {
        try withFixtureDatabase { databaseURL, database in
            try execute("""
                CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY);
                CREATE TABLE pane_leaves (pane_node_id INTEGER NOT NULL);
                CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER NOT NULL);
                CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);
                """, in: database)

            XCTAssertNil(WarpTabLocator(databaseURL: databaseURL).tabIndex(forCwd: "/repo"))
        }
    }

    private func createFixtureSchema(in database: OpaquePointer) throws {
        try execute("""
            CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, cwd TEXT NOT NULL);
            CREATE TABLE pane_leaves (
                pane_node_id INTEGER NOT NULL,
                kind TEXT NOT NULL,
                is_focused INTEGER
            );
            CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER NOT NULL);
            CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);
            """, in: database)
    }

    private func withFixtureDatabase(
        _ body: (URL, OpaquePointer) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("warp.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let openedDatabase = try XCTUnwrap(database)
        defer { sqlite3_close(openedDatabase) }
        try execute("PRAGMA journal_mode=WAL;", in: openedDatabase)
        try body(databaseURL, openedDatabase)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "WarpTabLocatorTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}

final class WarpFocuserTests: XCTestCase {
    func testTabIndexesMapToWarpDigitKeyCodes() {
        XCTAssertEqual(
            (1...9).compactMap { WarpFocuser.keyCode(forTabIndex: $0) },
            [18, 19, 20, 21, 23, 22, 26, 28, 25]
        )
        XCTAssertNil(WarpFocuser.keyCode(forTabIndex: 0))
        XCTAssertNil(WarpFocuser.keyCode(forTabIndex: 10))
    }

    func testAnswerKeysMapToDigitKeyCodesAndEscape() {
        XCTAssertEqual(WarpFocuser.keyCode(forAnswer: .text("1")), 18)
        XCTAssertEqual(
            (1...9).compactMap { WarpFocuser.keyCode(forAnswer: .text(String($0))) },
            [18, 19, 20, 21, 23, 22, 26, 28, 25]
        )
        XCTAssertEqual(WarpFocuser.keyCode(forAnswer: .escape), 53)
    }

    func testAnswerKeysRejectAnythingButASingleDigit() {
        XCTAssertNil(WarpFocuser.keyCode(forAnswer: .text("0")))
        XCTAssertNil(WarpFocuser.keyCode(forAnswer: .text("10")))
        XCTAssertNil(WarpFocuser.keyCode(forAnswer: .text("y")))
        XCTAssertNil(WarpFocuser.keyCode(forAnswer: .text("")))
    }
}

/// Reading Warp's group container is TCC-gated and re-prompts on every attempt, so these cover
/// the "ask once per launch" contract (#20) against fixture databases only — never the real one.
final class WarpDatabaseAccessCacheTests: XCTestCase {
    func testDenialIsRememberedAndNeverRetried() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("warp.sqlite")
        let cache = WarpDatabaseAccessCache()
        let locator = WarpTabLocator(databaseURL: databaseURL, cache: cache)

        // Nothing readable there yet: this stands in for macOS refusing the container.
        XCTAssertNil(locator.tabIndex(forCwd: "/repo"))
        XCTAssertTrue(cache.isDenied(databaseURL))

        // Make the database perfectly readable. A retry would now succeed — so still getting
        // nil is what proves the container is never touched again this launch.
        try makeFixtureDatabase(at: databaseURL, tabs: ["/repo"])
        XCTAssertNil(locator.tabIndex(forCwd: "/repo"))
    }

    func testSuccessfulReadIsReusedWithinTheWindowAndRefreshedAfterIt() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("warp.sqlite")
        try makeFixtureDatabase(at: databaseURL, tabs: ["/repo"])

        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let locator = WarpTabLocator(
            databaseURL: databaseURL,
            cache: WarpDatabaseAccessCache(),
            reuseWindow: 5,
            now: { clock }
        )

        XCTAssertEqual(locator.tabIndex(forCwd: "/repo"), 1)

        // Move the target to tab 2 in the source. Still seeing 1 proves the cached copy was
        // reused rather than the group container being read a second time.
        try makeFixtureDatabase(at: databaseURL, tabs: ["/other", "/repo"])
        clock = Date(timeIntervalSinceReferenceDate: 4)
        XCTAssertEqual(locator.tabIndex(forCwd: "/repo"), 1)

        clock = Date(timeIntervalSinceReferenceDate: 6)
        XCTAssertEqual(locator.tabIndex(forCwd: "/repo"), 2)
    }

    /// A jump asks for the index fresh: a tab opened since the last copy was taken is not in that
    /// copy at all, so reusing it focuses a stale index — the wrong-tab half of #23. The refusal
    /// gate is still the first thing checked, so this can never re-prompt.
    func testAJumpReadsPastTheReuseWindowButNeverPastADenial() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("warp.sqlite")
        try makeFixtureDatabase(at: databaseURL, tabs: ["/repo"])

        let clock = Date(timeIntervalSinceReferenceDate: 0)
        let cache = WarpDatabaseAccessCache()
        let locator = WarpTabLocator(
            databaseURL: databaseURL,
            cache: cache,
            reuseWindow: 5,
            now: { clock }
        )

        XCTAssertEqual(locator.tabIndex(forCwd: "/repo"), 1)

        // A new tab appears in front of it, well inside the reuse window.
        try makeFixtureDatabase(at: databaseURL, tabs: ["/other", "/repo"])
        XCTAssertEqual(locator.tabIndex(forCwd: "/repo"), 1)
        XCTAssertEqual(locator.tabIndex(forCwd: "/repo", reusingRecentCopy: false), 2)

        cache.markDenied(databaseURL)
        XCTAssertNil(locator.tabIndex(forCwd: "/repo", reusingRecentCopy: false))
    }

    func testCacheIsKeyedPerDatabaseSoOneDenialDoesNotBlockAnother() throws {
        let directory = try makeTemporaryDirectory()
        let missingURL = directory.appendingPathComponent("missing.sqlite")
        let presentURL = directory.appendingPathComponent("present.sqlite")
        try makeFixtureDatabase(at: presentURL, tabs: ["/repo"])
        let cache = WarpDatabaseAccessCache()

        XCTAssertNil(WarpTabLocator(databaseURL: missingURL, cache: cache).tabIndex(forCwd: "/repo"))
        XCTAssertTrue(cache.isDenied(missingURL))
        XCTAssertFalse(cache.isDenied(presentURL))
        XCTAssertEqual(
            WarpTabLocator(databaseURL: presentURL, cache: cache).tabIndex(forCwd: "/repo"),
            1
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// One window, `tabs` in order, the last one focused.
    private func makeFixtureDatabase(at url: URL, tabs: [String]) throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let openedDatabase = try XCTUnwrap(database)
        defer { sqlite3_close(openedDatabase) }

        var sql = """
            CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, cwd TEXT NOT NULL);
            CREATE TABLE pane_leaves (
                pane_node_id INTEGER NOT NULL,
                kind TEXT NOT NULL,
                is_focused INTEGER
            );
            CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER NOT NULL);
            CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);

            """
        for (offset, cwd) in tabs.enumerated() {
            let tabID = (offset + 1) * 10
            let paneID = tabID * 10
            let isFocused = offset == tabs.count - 1 ? 1 : 0
            sql += """
                INSERT INTO tabs VALUES (\(tabID), 1);
                INSERT INTO pane_nodes VALUES (\(paneID), \(tabID));
                INSERT INTO terminal_panes VALUES (\(paneID), '\(cwd)');
                INSERT INTO pane_leaves VALUES (\(paneID), 'terminal', \(isFocused));

                """
        }

        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(openedDatabase, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "WarpDatabaseAccessCacheTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}
