import Foundation
import SQLite3

struct WarpTabLocator {
    private let databaseURL: URL
    private let cache: WarpDatabaseAccessCache
    private let reuseWindow: TimeInterval
    private let now: () -> Date

    init(
        databaseURL: URL = WarpTabLocator.defaultDatabaseURL,
        cache: WarpDatabaseAccessCache = .shared,
        reuseWindow: TimeInterval = 5,
        now: @escaping () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.cache = cache
        self.reuseWindow = reuseWindow
        self.now = now
    }

    /// - Parameter reusingRecentCopy: whether a copy taken within `reuseWindow` is good enough.
    ///   Neither a jump nor an answer accepts one: a tab opened since that copy was taken is
    ///   missing from it entirely, so a stale index lands on — and types into — the wrong tab
    ///   (#23). Both read fresh, off the main actor, which is what makes the copy affordable
    ///   (#32); the window still governs how often the TCC-gated container is touched at all.
    func tabIndex(forCwd cwd: String, reusingRecentCopy: Bool = true) -> Int? {
        withDatabase(reusingRecentCopy: reusingRecentCopy) { tabIndex(in: $0, forCwd: cwd) }
    }

    /// Every terminal pane at `cwd`, as tab indices, ordered by pane id — which is Warp's own
    /// creation order.
    ///
    /// `tabIndex` answers "a tab at this cwd" and cannot do better, because two panes in one folder
    /// are indistinguishable in Warp's database: no tty, no pid, and identical `shell_launch_data`.
    /// So N sessions in a repo all resolved to one index and every card focused the same tab (#55).
    ///
    /// The information Warp lacks lives on our side — the process table knows each agent's start
    /// time — so the caller pairs these panes against those processes in the same creation order
    /// instead of asking about each session alone. Ordered and complete is all that takes; the
    /// pairing itself is `Jumper`'s job.
    func tabIndices(forCwd cwd: String, reusingRecentCopy: Bool = true) -> [Int] {
        withDatabase(reusingRecentCopy: reusingRecentCopy) { tabIndices(in: $0, forCwd: cwd) } ?? []
    }

    private func withDatabase<T>(reusingRecentCopy: Bool, _ body: (OpaquePointer) -> T?) -> T? {
        guard let copiedDatabaseURL = workingCopy(reusingRecentCopy: reusingRecentCopy) else {
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

        return body(database)
    }

    /// A readable snapshot of Warp's sqlite files. sqlite cannot safely open the live database
    /// another process is writing, so it is copied first — but the copy is what reaches into the
    /// TCC-gated group container, so it is made at most once per `reuseWindow` and never again
    /// once macOS has refused (#20).
    private func workingCopy(reusingRecentCopy: Bool) -> URL? {
        guard !cache.isDenied(databaseURL) else { return nil }

        let fileManager = FileManager.default
        if reusingRecentCopy,
           let reusable = cache.reusableCopy(for: databaseURL, now: now(), within: reuseWindow),
           fileManager.fileExists(atPath: reusable.path) {
            return reusable
        }

        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "AgentPerch-Warp-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

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
            // Every read the container refuses re-triggers the consent prompt, and the three
            // files share one gate — so any failure here retires this database for the launch
            // and the caller silently falls back to opening a new tab.
            cache.markDenied(databaseURL)
            try? fileManager.removeItem(at: directory)
            return nil
        }

        if let previous = cache.store(copy: copiedDatabaseURL, for: databaseURL, at: now()) {
            try? fileManager.removeItem(at: previous.deletingLastPathComponent())
        }
        return copiedDatabaseURL
    }

    /// Whether this database still has the tables and columns both queries below read. Warp's
    /// schema is not ours and can change under us; a missing column means fall back to opening a
    /// tab, never a crash.
    private func schemaIsUsable(_ database: OpaquePointer) -> Bool {
        let requiredColumns: [String: Set<String>] = [
            "terminal_panes": ["id", "cwd"],
            "pane_leaves": ["pane_node_id", "kind", "is_focused"],
            "pane_nodes": ["id", "tab_id"],
            "tabs": ["id", "window_id"]
        ]
        guard let tables = tableNames(in: database),
              tables.isSuperset(of: requiredColumns.keys) else { return false }

        for (table, required) in requiredColumns {
            guard let columns = columns(in: table, database: database),
                  columns.isSuperset(of: required) else { return false }
        }
        return true
    }

    /// One tab index per pane at `cwd`, in pane-creation order. Duplicates are kept: two panes in
    /// one window really can sit in the same tab, and dropping one would shift every later pairing.
    private func tabIndices(in database: OpaquePointer, forCwd cwd: String) -> [Int]? {
        guard schemaIsUsable(database) else { return nil }

        let sql = """
            SELECT (
                SELECT COUNT(*)
                FROM tabs t2
                WHERE t2.window_id = t.window_id AND t2.id <= t.id
            )
            FROM tabs t
            JOIN pane_nodes pn ON pn.tab_id = t.id
            JOIN pane_leaves pl
                ON pl.pane_node_id = pn.id AND pl.kind = 'terminal'
            JOIN terminal_panes tp ON tp.id = pl.pane_node_id
            WHERE tp.cwd = ?1
            ORDER BY tp.id ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard bind(cwd, to: statement) else { return nil }

        var indices: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            indices.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return indices
    }

    private func tabIndex(in database: OpaquePointer, forCwd cwd: String) -> Int? {
        guard schemaIsUsable(database) else { return nil }

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

        guard bind(cwd, to: statement), sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let index = Int(sqlite3_column_int64(statement, 0))
        return (1...9).contains(index) ? index : nil
    }

    /// SQLITE_TRANSIENT — sqlite copies the bytes, so the Swift string need not outlive the bind.
    private func bind(_ text: String, to statement: OpaquePointer) -> Bool {
        text.withCString {
            sqlite3_bind_text(
                statement,
                1,
                $0,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        } == SQLITE_OK
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
