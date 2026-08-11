import Foundation
import SQLite3

/// A read-only SQLite reader for `~/.local/share/opencode/opencode.db`, built the way
/// `WarpTabLocator` reads Warp's database: open read-only, verify the schema by introspection
/// before trusting a single query, and treat every failure as "no rows" rather than an error.
///
/// **THE SCHEMA BELOW IS UNVERIFIED (#11).** OpenCode is installed on this machine
/// (`~/.opencode/bin/opencode`, v1.18.16) but has never been run, so `opencode.db` does not exist
/// and its real table and column names could not be confirmed — only the documented shape
/// (`SessionTable` / `MessageTable` / `PartTable`, with cwd reached through
/// `SessionTable.projectId` → `Project.workingDirectory`) could be coded against. That is exactly
/// why `requiredColumns` is checked before the query runs: if the real schema differs in any of
/// these names, this reader answers "no sessions" and OpenCode simply contributes nothing, which is
/// the only failure mode allowed to happen to a source that cannot break the rest of the list.
///
/// Unlike Warp's, this database is NOT inside a TCC-gated group container — it is an ordinary file
/// under the user's own `~/.local/share`. So the copy-before-read dance (and the denial cache that
/// goes with it) buys nothing here and is deliberately not repeated: a read-only open is both safe
/// against a concurrently-writing OpenCode and cheap enough to do on a refresh tick.
enum OpenCodeDatabase {
    struct Row: Equatable, Sendable {
        let sessionId: String
        let title: String?
        let workingDirectory: String
        let updatedAt: Date
        /// `nil` for a session the user started; the parent's id for one OpenCode spawned itself.
        let parentId: String?
    }

    static let requiredColumns: [String: Set<String>] = [
        "SessionTable": ["id", "projectId", "title", "updated", "parentId"],
        "Project": ["id", "workingDirectory"]
    ]

    /// Newest first, capped — the caller shows at most ten rows, and reading more only to throw
    /// them away would put an unbounded query on a refresh tick.
    static func sessions(at databaseURL: URL, limit: Int = 20) -> [Row] {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }

        guard let tables = tableNames(in: database), tables.isSuperset(of: requiredColumns.keys) else {
            return []
        }
        for (table, required) in requiredColumns {
            guard let columns = columns(in: table, database: database),
                  columns.isSuperset(of: required) else { return [] }
        }

        let sql = """
            SELECT s.id, s.title, p.workingDirectory, s.updated, s.parentId
            FROM SessionTable s
            JOIN Project p ON p.id = s.projectId
            ORDER BY s.updated DESC
            LIMIT \(limit)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionId = text(statement, 0), !sessionId.isEmpty,
                  let workingDirectory = text(statement, 2), workingDirectory.hasPrefix("/") else { continue }
            rows.append(Row(
                sessionId: sessionId,
                title: text(statement, 1),
                workingDirectory: workingDirectory,
                updatedAt: date(fromEpoch: sqlite3_column_double(statement, 3)),
                parentId: text(statement, 4)
            ))
        }
        return rows
    }

    /// OpenCode records times as an epoch, but whether in seconds or milliseconds is part of the
    /// unverified schema — so both are accepted rather than one being guessed. Any plausible
    /// session timestamp in SECONDS is far below this threshold (it is the year 5138), and any in
    /// MILLISECONDS is far above it (it passed in 1973), so the two cannot be confused.
    static func date(fromEpoch value: Double) -> Date {
        Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000.0 : value)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func tableNames(in database: OpaquePointer) -> Set<String>? {
        rows(in: database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'", column: 0)
    }

    private static func columns(in table: String, database: OpaquePointer) -> Set<String>? {
        rows(in: database, sql: "PRAGMA table_info(\"\(table)\")", column: 1)
    }

    private static func rows(in database: OpaquePointer, sql: String, column: Int32) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, column) else { return nil }
            names.insert(String(cString: name))
        }
        let code = sqlite3_errcode(database)
        return code == SQLITE_OK || code == SQLITE_DONE ? names : nil
    }
}

/// Discovers OpenCode sessions from `~/.local/share/opencode/opencode.db`, enriched by any live
/// `opencode` process in the table.
///
/// **Fixture-only: the database schema this reads is UNVERIFIED** — see `OpenCodeDatabase`. The
/// source is written so that being wrong about it costs nothing: a missing file, an unreadable
/// database, a different schema and an empty table all take the same path and contribute no rows.
///
/// - Membership: rows from the database, plus every live `opencode` process on a `ttys*` (see
///   `LiveAgentScan`), the latter claiming its row so one session never appears twice.
/// - User-vs-sub-agent: a row with a `parentId` was spawned by another session, so it is hidden
///   unless `showSubAgentSessions` is on — the same default-deny rule as #24.
/// - Liveness: `HooklessLiveness` for a live session (never hidden, `.active` still needs a recent
///   write per #31); a row with no process behind it is `.idle` for an hour and then hidden.
final class OpenCodeSessionSource: AgentSessionSource {
    let agentName = "OpenCode"

    /// The `sessionId` prefix for a live session no database row could be matched to.
    static let liveSessionIdPrefix = "opencode-live:"

    /// How long a session with no live process behind it stays on screen, matching every other
    /// hookless source.
    static let visibleWindow: TimeInterval = 60 * 60.0

    private let databaseURL: URL
    private let fileManager: FileManager
    private let processProvider: () -> [ClaudeProcess]
    private let showSubAgentSessions: () -> Bool
    private let binaryPath: String

    init(
        databaseURL: URL = OpenCodeSessionSource.defaultDatabaseURL(),
        fileManager: FileManager = .default,
        processProvider: @escaping () -> [ClaudeProcess] = { TTYResolver().processes() },
        showSubAgentSessions: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: "showSubAgentSessions")
        },
        binaryPath: String = OpenCodeSessionSource.defaultBinaryPath()
    ) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
        self.processProvider = processProvider
        self.showSubAgentSessions = showSubAgentSessions
        self.binaryPath = binaryPath
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// `~/.opencode/bin` FIRST, because that is where the installer puts it and a login shell does
    /// not have that directory on `PATH` — verified here: `zsh -lc 'which opencode'` finds nothing
    /// while `~/.opencode/bin/opencode` is present and executable. The standard directories are
    /// still searched after it for a Homebrew-style install.
    static func defaultBinaryPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AgentBinary.firstExecutable(
            named: "opencode",
            in: [home.appendingPathComponent(".opencode/bin", isDirectory: true)]
                + AgentBinary.standardDirectories(homeDirectory: home)
        ) ?? "opencode"
    }

    func discover(now: Date) -> [DiscoveredSession] {
        // A `stat` before the open, so the overwhelmingly common case on a machine that has never
        // run OpenCode costs one filesystem check rather than a SQLite open that must fail.
        let rows = fileManager.fileExists(atPath: databaseURL.path)
            ? OpenCodeDatabase.sessions(at: databaseURL)
            : []
        let visibleRows = rows.filter { $0.parentId == nil || showSubAgentSessions() }
        let liveProcesses = LiveAgentScan.liveSessions(in: processProvider()).filter { $0.agentName == agentName }
        guard !visibleRows.isEmpty || !liveProcesses.isEmpty else { return [] }

        var claimed: Set<String> = []
        let live: [DiscoveredSession] = liveProcesses.map { process in
            let match = visibleRows.first {
                !claimed.contains($0.sessionId) && CanonicalPath.equal($0.workingDirectory, process.cwd)
            }
            if let match { claimed.insert(match.sessionId) }
            return DiscoveredSession(
                sessionId: match?.sessionId ?? Self.liveSessionId(tty: process.tty, cwd: process.cwd),
                agentName: agentName,
                cwd: match?.workingDirectory ?? process.cwd,
                title: Self.title(match?.title, cwd: match?.workingDirectory ?? process.cwd),
                lastActivity: match?.updatedAt ?? process.startedAt ?? now,
                status: HooklessLiveness.liveStatus(lastWriteAt: match?.updatedAt, now: now),
                // Without a row there is no id to resume, so a bare relaunch at the cwd is the most
                // this can honestly promise — exactly what `CodexSessionSource` falls back to.
                resumeCommand: match.map { resumeCommand(sessionId: $0.sessionId) } ?? binaryPath,
                sessionFileURL: nil,
                // No hooks: `.active` here only ever means "live process + recent write" (#31).
                supportsLiveStatus: false,
                tty: process.tty
            )
        }

        let finished: [DiscoveredSession] = visibleRows.compactMap { row in
            guard !claimed.contains(row.sessionId),
                  now.timeIntervalSince(row.updatedAt) < Self.visibleWindow else { return nil }
            return DiscoveredSession(
                sessionId: row.sessionId,
                agentName: agentName,
                cwd: row.workingDirectory,
                title: Self.title(row.title, cwd: row.workingDirectory),
                lastActivity: row.updatedAt,
                status: .idle,
                resumeCommand: resumeCommand(sessionId: row.sessionId),
                sessionFileURL: nil,
                supportsLiveStatus: false
            )
        }

        return Array((live + finished).prefix(10))
    }

    /// `opencode --session <id>`. Shell-quoted for the same reason `Jumper.codexResumeCommand`
    /// quotes its own: the id is a UUID today, and a composed command must stay safe if it ever
    /// stops being one.
    func resumeCommand(sessionId: String) -> String {
        "\(binaryPath) --session \(AppleScriptRunner.shellQuote(sessionId))"
    }

    /// The stored title when there is one, else the cwd's basename — the same two-step every other
    /// title-less source uses, routed through `SessionTitle` rather than reimplemented.
    private static func title(_ stored: String?, cwd: String) -> String {
        SessionTitle.resolve(sessionFileURL: nil, lastPrompt: stored, cwd: cwd)
    }

    private static func liveSessionId(tty: String, cwd: String) -> String {
        "\(liveSessionIdPrefix)\(tty):\(cwd)"
    }
}
