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
}
