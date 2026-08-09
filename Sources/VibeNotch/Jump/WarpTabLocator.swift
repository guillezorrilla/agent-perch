import Foundation
import SQLite3

struct WarpTabRow: Equatable, Sendable {
    let windowID: Int64
    let tabID: Int64
    let cwd: String
    let isFocused: Bool?
}

struct WarpTabLocator {
    private let databaseURL: URL

    init(databaseURL: URL = WarpTabLocator.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    func tabIndex(forCwd cwd: String) -> Int? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "VibeNotch-Warp-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer { try? fileManager.removeItem(at: directory) }

        let copiedDatabaseURL = directory.appendingPathComponent(databaseURL.lastPathComponent)
        do {
            try fileManager.copyItem(at: databaseURL, to: copiedDatabaseURL)
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: databaseURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(
                    at: source,
                    to: URL(fileURLWithPath: copiedDatabaseURL.path + suffix)
                )
            }
        } catch {
            return nil
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(copiedDatabaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        guard let rows = rows(in: database) else { return nil }
        return Self.tabIndex(forCwd: cwd, rows: rows)
    }

    static func tabIndex(forCwd cwd: String, rows: [WarpTabRow]) -> Int? {
        let ordered = rows.sorted {
            ($0.windowID, $0.tabID) < ($1.windowID, $1.tabID)
        }
        guard let firstWindowID = ordered.first?.windowID else { return nil }
        let windowRows = ordered.filter { $0.windowID == firstWindowID }
        let matches = windowRows.filter { $0.cwd == cwd }
        guard let match = matches.first(where: { $0.isFocused == true }) ?? matches.first else {
            return nil
        }

        let tabIDs = windowRows.reduce(into: [Int64]()) { result, row in
            if result.last != row.tabID { result.append(row.tabID) }
        }
        return tabIDs.firstIndex(of: match.tabID).map { $0 + 1 }
    }

    private func rows(in database: OpaquePointer) -> [WarpTabRow]? {
        let requiredColumns: [String: Set<String>] = [
            "terminal_panes": ["id", "cwd"],
            "pane_leaves": ["pane_node_id"],
            "pane_nodes": ["id", "tab_id"],
            "tabs": ["id", "window_id"]
        ]
        guard let tables = tableNames(in: database),
              tables.isSuperset(of: requiredColumns.keys) else { return nil }

        var columnsByTable: [String: Set<String>] = [:]
        for (table, required) in requiredColumns {
            guard let columns = columns(in: table, database: database),
                  columns.isSuperset(of: required) else { return nil }
            columnsByTable[table] = columns
        }

        let hasFocusColumn = columnsByTable["pane_leaves"]?.contains("is_focused") == true
        let focusColumn = hasFocusColumn ? "pl.is_focused" : "NULL"
        let sql = """
            SELECT t.window_id, t.id, tp.cwd, \(focusColumn)
            FROM terminal_panes tp
            JOIN pane_nodes pn ON pn.id = tp.id
            JOIN tabs t ON t.id = pn.tab_id
            LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id
            ORDER BY t.window_id ASC, t.id ASC, tp.id ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [WarpTabRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cwd = sqlite3_column_text(statement, 2) else { return nil }
            rows.append(WarpTabRow(
                windowID: sqlite3_column_int64(statement, 0),
                tabID: sqlite3_column_int64(statement, 1),
                cwd: String(cString: cwd),
                isFocused: sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_int(statement, 3) != 0
            ))
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            return nil
        }
        return rows
    }

    private func tableNames(in database: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type = 'table'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else { return nil }
            names.insert(String(cString: name))
        }
        return sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE
            ? names
            : nil
    }

    private func columns(in table: String, database: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\"\(table)\")",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { return nil }
            names.insert(String(cString: name))
        }
        return sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE
            ? names
            : nil
    }

    private static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/2BBY89MBSN.dev.warp")
        .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable/warp.sqlite")
}
