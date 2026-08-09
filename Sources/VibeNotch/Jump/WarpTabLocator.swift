import Foundation
import SQLite3

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

        return tabIndex(in: database, forCwd: cwd)
    }

    private func tabIndex(in database: OpaquePointer, forCwd cwd: String) -> Int? {
        let requiredColumns: [String: Set<String>] = [
            "terminal_panes": ["id", "cwd"],
            "pane_leaves": ["pane_node_id", "kind", "is_focused"],
            "pane_nodes": ["id", "tab_id"],
            "tabs": ["id", "window_id"]
        ]
        guard let tables = tableNames(in: database),
              tables.isSuperset(of: requiredColumns.keys) else { return nil }

        for (table, required) in requiredColumns {
            guard let columns = columns(in: table, database: database),
                  columns.isSuperset(of: required) else { return nil }
        }

        let sql = """
            WITH target AS (
                SELECT t.window_id, t.id AS tab_id
                FROM tabs t
                JOIN pane_nodes pn ON pn.tab_id = t.id
                JOIN pane_leaves pl
                    ON pl.pane_node_id = pn.id AND pl.kind = 'terminal'
                JOIN terminal_panes tp ON tp.id = pl.pane_node_id
                WHERE tp.cwd = ?1
                ORDER BY
                    CASE WHEN pl.is_focused = 1 THEN 1 ELSE 0 END DESC,
                    t.id DESC,
                    pl.pane_node_id DESC
                LIMIT 1
            )
            SELECT (
                SELECT COUNT(*)
                FROM tabs t2
                WHERE t2.window_id = target.window_id
                    AND t2.id <= target.tab_id
            )
            FROM target
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let bindResult = cwd.withCString {
            sqlite3_bind_text(
                statement,
                1,
                $0,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let index = Int(sqlite3_column_int64(statement, 0))
        return (1...9).contains(index) ? index : nil
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
