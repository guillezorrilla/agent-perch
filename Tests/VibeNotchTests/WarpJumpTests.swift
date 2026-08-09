import Foundation
import SQLite3
import XCTest
@testable import VibeNotch

final class WarpTabLocatorTests: XCTestCase {
    func testFixtureDatabaseFindsFocusedMatchingTabAndReturnsNilForMiss() throws {
        try withFixtureDatabase { databaseURL, database in
            try execute("""
                CREATE TABLE terminal_panes (id INTEGER PRIMARY KEY, cwd TEXT NOT NULL);
                CREATE TABLE pane_leaves (pane_node_id INTEGER NOT NULL, is_focused INTEGER);
                CREATE TABLE pane_nodes (id INTEGER PRIMARY KEY, tab_id INTEGER NOT NULL);
                CREATE TABLE tabs (id INTEGER PRIMARY KEY, window_id INTEGER NOT NULL);
                INSERT INTO tabs VALUES (10, 1), (20, 1), (30, 1);
                INSERT INTO pane_nodes VALUES (100, 10), (200, 20), (300, 30);
                INSERT INTO terminal_panes VALUES
                    (100, '/other'), (200, '/repo'), (300, '/repo');
                INSERT INTO pane_leaves VALUES (100, 0), (200, 0), (300, 1);
                """, in: database)

            let locator = WarpTabLocator(databaseURL: databaseURL)
            XCTAssertEqual(locator.tabIndex(forCwd: "/repo"), 3)
            XCTAssertNil(locator.tabIndex(forCwd: "/missing"))
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

    func testPureRowMappingUsesFirstWindowAndFocusedMatchingPane() {
        let rows = [
            WarpTabRow(windowID: 2, tabID: 40, cwd: "/repo", isFocused: true),
            WarpTabRow(windowID: 1, tabID: 30, cwd: "/repo", isFocused: true),
            WarpTabRow(windowID: 1, tabID: 10, cwd: "/other", isFocused: false),
            WarpTabRow(windowID: 1, tabID: 20, cwd: "/repo", isFocused: false)
        ]

        XCTAssertEqual(WarpTabLocator.tabIndex(forCwd: "/repo", rows: rows), 3)
        XCTAssertNil(WarpTabLocator.tabIndex(forCwd: "/missing", rows: rows))
        XCTAssertEqual(
            WarpTabLocator.tabIndex(
                forCwd: "/repo",
                rows: rows.map {
                    WarpTabRow(
                        windowID: $0.windowID,
                        tabID: $0.tabID,
                        cwd: $0.cwd,
                        isFocused: nil
                    )
                }
            ),
            2
        )
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
