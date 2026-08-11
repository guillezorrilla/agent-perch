import Foundation
import SQLite3

// Cursor and Antigravity are both VS Code forks, so their `workspaceStorage` layout is the same
// MECHANISM, not a coincidence: one flat directory of per-workspace hashes, each holding a
// `workspace.json` that names the folder outright (`{"folder":"file:///abs/path"}`) and a
// `state.vscdb`. Antigravity's helpers (#27/#29) are reused verbatim rather than copied — a second
// implementation of the file-URI validation is a second place to get a remote/WSL host wrong, and
// a second directory-listing cap is a second thing to forget to bound. The aliases exist so the
// code below reads as what it is (#11).
private typealias WorkspaceJSON = AntigravityWorkspaceJSON
private typealias WorkspaceStorage = AntigravityWorkspaceDiscovery
private typealias WorkspaceLiveness = AntigravityLiveness

/// Read-only access to one workspace's `state.vscdb` — VS Code's `ItemTable` key/value store.
///
/// **Cursor is running while this reads.** A workspace the user has open right now has live
/// `-wal`/`-shm` sidecars beside its database, and the whole file is another process's working
/// state. Every open here therefore goes through a `file:…?mode=ro` URI (`SQLITE_OPEN_URI` +
/// `SQLITE_OPEN_READONLY`) so SQLite can never create, recover or checkpoint anything inside the
/// user's Cursor data. That is not theoretical: probing these stores with the plain `sqlite3` CLI —
/// which opens read-WRITE — leaves `-shm`/`-wal` files behind in the user's `Application Support`
/// directory, which is exactly the mess this source exists not to make (#11).
///
/// `immutable=1` is appended when, and only when, there is NO `-wal` file beside the database.
/// Verified against all 30 workspaces on this machine: a WAL-mode database with no `-shm` cannot be
/// opened by a read-only connection at all — SQLite would have to create the shared-memory index to
/// read it, which a read-only connection may not do, so the open fails with `SQLITE_CANTOPEN` — and
/// most of Cursor's stores are in exactly that state once their window has been closed. No `-wal`
/// means no live writer and nothing uncheckpointed, so the file is static by definition, which is
/// precisely the precondition `immutable=1` documents. A database that DOES have a `-wal` has a
/// live Cursor window behind it: it is opened with plain `mode=ro`, which reads through the WAL and
/// so sees current state rather than a stale snapshot.
enum CursorStateDatabase {
    static let generationsKey = "aiService.generations"
    static let promptsKey = "aiService.prompts"

    /// Every key in one open. Two opens would double the only expensive part of this source, and
    /// `ItemTable.key` is `TEXT UNIQUE`, so each lookup is an index probe rather than a scan — one
    /// key costs a handful of pages of a ~280KB file, not all of it.
    ///
    /// A missing file, a locked or corrupt database, a store with no `ItemTable` at all (older
    /// Cursor builds), and a key that simply isn't there all take the same path: fewer entries in
    /// the returned dictionary, never an error and never a thrown failure. `prepare` failing IS the
    /// schema check — there is no separate `sqlite_master` introspection to keep in sync.
    static func values(
        forKeys keys: [String],
        at databaseURL: URL,
        fileManager: FileManager = .default
    ) -> [String: String] {
        let hasLiveWAL = fileManager.fileExists(atPath: databaseURL.path + "-wal")
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(readOnlyURI(for: databaseURL, hasLiveWAL: hasLiveWAL), &database, flags, nil)
            == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ?1", -1, &statement, nil)
            == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var values: [String: String] = [:]
        for key in keys {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let bound = key.withCString {
                sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) else { continue }
            values[key] = String(cString: text)
        }
        return values
    }

    /// A SQLite URI filename. Only `?`, `#` and `%` are escaped, because those are the only three
    /// characters SQLite itself gives meaning to inside one — `?` and `#` end the path, `%` starts
    /// an escape. A space or an accent in a repo path passes through untouched and UTF-8 encoded,
    /// which is what SQLite expects and what hand-rolling this a byte at a time gets wrong.
    static func readOnlyURI(for databaseURL: URL, hasLiveWAL: Bool) -> String {
        let escaped = databaseURL.path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "?#%").inverted
        ) ?? databaseURL.path
        return "file:" + escaped + (hasLiveWAL ? "?mode=ro" : "?mode=ro&immutable=1")
    }
}

/// What a workspace's `state.vscdb` says about AI activity in it.
///
/// **`aiService.generations` is a LEGACY key and it is measured here, not assumed.** On this
/// machine the workspace open in Cursor *right now* has `aiService.generations` = `[]` and
/// `aiService.prompts` = `[]`, while the one beside it has 50 generations whose newest is two
/// months old — current Cursor keeps its chat state in `~/.cursor/chats/<id>/store.db` (protobuf
/// blobs, deliberately not decoded here) instead. So a generation timestamp is a floor on activity
/// and never a ceiling: `CursorSessionSource` takes the LATER of it and the workspace directory's
/// mtimes rather than preferring it, which is what keeps a live workspace from reading as two
/// months stale (#11).
enum CursorAIState {
    struct Snapshot: Equatable, Sendable {
        /// The newest `unixMs` in `aiService.generations`, or `nil` when the key is absent, empty
        /// or unparseable. Never a fabricated "now".
        let lastGeneration: Date?
        /// The newest generation's `textDescription`, else the last `aiService.prompts` text —
        /// whichever is actually usable as a title. `nil` leaves the cwd basename to stand.
        let title: String?

        static let empty = Snapshot(lastGeneration: nil, title: nil)
    }

    static func snapshot(generationsJSON: String?, promptsJSON: String?) -> Snapshot {
        let newest = newestGeneration(generationsJSON)
        return Snapshot(
            lastGeneration: newest?.timestamp,
            title: usableTitle(newest?.description) ?? usableTitle(lastPrompt(promptsJSON))
        )
    }

    /// `unixMs` is MILLISECONDS since the epoch — `60 * 60.0`-style `Double` literals throughout,
    /// because an Int division here would silently truncate a real timestamp into 1970.
    static func newestGeneration(_ json: String?) -> (timestamp: Date, description: String?)? {
        guard let entries = array(json) else { return nil }
        var newestMilliseconds = 0.0
        var description: String?
        for entry in entries {
            guard let milliseconds = entry["unixMs"] as? Double, milliseconds > 0,
                  milliseconds >= newestMilliseconds else { continue }
            newestMilliseconds = milliseconds
            description = entry["textDescription"] as? String
        }
        guard newestMilliseconds > 0 else { return nil }
        return (Date(timeIntervalSince1970: newestMilliseconds / 1000.0), description)
    }

    /// `aiService.prompts` carries no timestamps at all — it is an append-ordered list, so the last
    /// entry is the most recent thing the user typed and there is nothing else to sort by.
    static func lastPrompt(_ json: String?) -> String? {
        array(json)?.last?["text"] as? String
    }

    /// Cursor's stored AI text is very often not a title: the newest `textDescription` in this
    /// machine's own store is `@~/.cursor/projects/…/terminals/1`, an @-mention of a path rather
    /// than anything a user would recognize. A leading `@`, `/` or `~/` means the text is a file
    /// reference, and the cwd basename is a better answer than a path fragment (#11).
    ///
    /// Only the first non-empty LINE survives: a prompt is free-form and routinely multi-line, and
    /// a compact row is one line high — the rest would be invisible anyway, and it would defeat
    /// `SessionTitle.truncate`'s word-boundary search, which looks for a space and not a newline.
    static func usableTitle(_ text: String?) -> String? {
        guard let text else { return nil }
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine, !["@", "/", "~/"].contains(where: { firstLine.hasPrefix($0) }) else { return nil }
        return firstLine
    }

    private static func array(_ json: String?) -> [[String: Any]]? {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty else { return nil }
        return array
    }
}

/// Whether Cursor's own CLI is on `PATH`. `DiscoveredSession.resumeCommand` uses this to prefer
/// `cursor <path>` over the `open -a Cursor` fallback the Jumper lands on when it is absent — the
/// same two-step, and the same once-per-launch caching, as `AntigravityCLI.isAgyAvailable` (#32):
/// `which` is a subprocess spawn, `discover` runs on the main actor on every refresh, and a CLI
/// does not appear on `PATH` mid-run.
enum CursorCLI {
    private static var cachedAvailability: Bool?

    static func isCursorAvailable() -> Bool {
        if let cached = cachedAvailability { return cached }
        let output = TTYResolver.output("/usr/bin/which", ["cursor"])
        let available = !(output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cachedAvailability = available
        return available
    }
}

/// Discovers Cursor (Anysphere's VS Code-fork AI IDE) workspaces from
/// `~/Library/Application Support/Cursor`.
///
/// This surfaces WORKSPACES the IDE has open or recently had open, not agent turns — the same thing
/// `AntigravitySessionSource` surfaces, for the same reason, and it makes exactly the same promises:
///
/// - Membership: one directory listing of `workspaceStorage` (never recursive, capped — see
///   `AntigravityWorkspaceDiscovery`), each candidate's `workspace.json` decoded for its folder
///   path. Cursor names the folder outright, so there is no hash to invert; an entry with no
///   resolvable folder (the `empty-window` entry Cursor keeps for windowless sessions, a deleted
///   store, a remote/WSL `file://host/…` URI) simply contributes nothing.
/// - Recency: the newest mtime in the workspace's storage directory, RAISED by
///   `aiService.generations`' newest `unixMs` when the database has one. It is deliberately not the
///   other way round — see `CursorAIState` for the measurement that settled it — and it is
///   deliberately not `state.vscdb`'s own mtime, which goes stale on a live workspace because
///   Cursor writes to the `-wal` beside it (both workspaces open on this machine right now have a
///   `state.vscdb` mtime two months old and a `-wal` from minutes ago).
/// - Liveness: capped at `.idle`, never `.active`, via the same `AntigravityLiveness` rule (#29).
///
/// OFF BY DEFAULT (#27/#11), for the reason Antigravity's is: a workspace directory's mtime moves
/// for reasons that have nothing to do with an agent — the IDE rewrites state there on window
/// focus, on settings sync, on quit — so "workspace touched in the last hour" is not evidence of
/// agent activity the way a Claude transcript append or a Codex rollout write is. Cursor must not
/// be louder than Antigravity. `showCursorWorkspaces` is the opt-in; when it is off this source
/// enumerates nothing, opens nothing and contributes nothing.
final class CursorSessionSource: AgentSessionSource {
    let agentName = "Cursor"
    let cursorHome: URL
    private let fileManager: FileManager
    private let cursorAvailableProvider: () -> Bool
    private let showWorkspaces: () -> Bool
    private let readState: (URL) -> CursorAIState.Snapshot

    /// Every `sessionId` this source hands out starts with this — how `AgentSession.workspaceIDE`
    /// tells a Cursor row apart from a tty-backed agent session. Unlike Antigravity, Cursor has no
    /// CLI-session counterpart in this app, so every row from this source is a workspace.
    static let workspaceSessionIdPrefix = "cursor:"

    static func isWorkspaceSessionId(_ sessionId: String) -> Bool {
        sessionId.hasPrefix(workspaceSessionIdPrefix)
    }

    /// The most rows this source will ever contribute, AND the most databases it will ever open in
    /// one refresh — deliberately the same number.
    ///
    /// The cost bound is: resolve every candidate folder from the cheap files only (`workspace.json`
    /// plus directory mtimes — no SQLite at all), drop everything already outside the one-hour
    /// visibility window, and only then open databases, newest first, at most `maxRows` of them. A
    /// directory's newest mtime is an upper bound on any timestamp recorded inside it, so a
    /// workspace filtered out that way could never have produced a row anyway — the prefilter is
    /// free of false negatives, not merely cheap. On this machine that is 2 opens out of 30
    /// workspaces; the pathological "touched 30 repos within the hour" case is 10. Measured against
    /// the real store, all 30 opens together cost 31ms, so the cap is headroom rather than a
    /// tightrope. Never opening more databases than rows shown is the invariant worth keeping: it
    /// means no work is ever done for a row the panel would throw away.
    static let maxRows = 10

    init(
        cursorHome: URL = CursorSessionSource.defaultCursorHome(),
        fileManager: FileManager = .default,
        cursorAvailableProvider: @escaping () -> Bool = CursorCLI.isCursorAvailable,
        // Keyed identically to `AppSettings.showCursorWorkspaces` — @AppStorage is backed by
        // `UserDefaults.standard`, so the Settings toggle reaches discovery with no plumbing, the
        // same way `showAntigravityWorkspaces` does.
        showWorkspaces: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: "showCursorWorkspaces")
        },
        // Injected only so a test can COUNT the opens — the cost bound above is the kind of promise
        // that rots silently unless something asserts on it. The default is the real reader.
        readState: @escaping (URL) -> CursorAIState.Snapshot = CursorSessionSource.readState
    ) {
        self.cursorHome = cursorHome
        self.fileManager = fileManager
        self.cursorAvailableProvider = cursorAvailableProvider
        self.showWorkspaces = showWorkspaces
        self.readState = readState
    }

    static func defaultCursorHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
    }

    static func readState(at databaseURL: URL) -> CursorAIState.Snapshot {
        let values = CursorStateDatabase.values(
            forKeys: [CursorStateDatabase.generationsKey, CursorStateDatabase.promptsKey],
            at: databaseURL
        )
        return CursorAIState.snapshot(
            generationsJSON: values[CursorStateDatabase.generationsKey],
            promptsJSON: values[CursorStateDatabase.promptsKey]
        )
    }

    private var workspaceStorageRoot: URL {
        cursorHome.appendingPathComponent("User/workspaceStorage", isDirectory: true)
    }

    func discover(now: Date) -> [DiscoveredSession] {
        // Before the directory listing, not after: opted out means no disk work at all.
        guard showWorkspaces() else { return [] }

        let directories = WorkspaceStorage.candidateWorkspaceDirectories(
            workspaceStorageRoot: workspaceStorageRoot,
            fileManager: fileManager
        )
        guard !directories.isEmpty else { return [] }

        // Phase one, cheap: folder + mtimes only. Nothing here opens a database.
        let candidates: [(cwd: String, storageDirectory: URL, touchedAt: Date)] = directories
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("workspace.json")),
                      let path = WorkspaceJSON.decodeFolderPath(from: data) else { return nil }
                let touchedAt = WorkspaceStorage.lastActivity(of: directory, fileManager: fileManager)
                guard WorkspaceLiveness.status(modifiedAt: touchedAt, now: now) != nil else { return nil }
                return (cwd: path, storageDirectory: directory, touchedAt: touchedAt)
            }
            .sorted { $0.touchedAt > $1.touchedAt }
            .prefix(Self.maxRows)
            .map { $0 }
        guard !candidates.isEmpty else { return [] }

        // Costs a subprocess spawn — never paid unless there is at least one real workspace to
        // show for it.
        let cursorAvailable = cursorAvailableProvider()

        // Phase two: at most `maxRows` read-only database opens, for workspaces already known to be
        // inside the visibility window.
        let discovered: [DiscoveredSession] = candidates.compactMap { candidate in
            let state = readState(candidate.storageDirectory.appendingPathComponent("state.vscdb"))
            // The later of the two, never one substituted for the other: a generation is evidence
            // an AI turn happened at that instant, and an mtime is evidence the folder was touched
            // at that instant. Neither invents a time the other doesn't have.
            let lastActivity = max(candidate.touchedAt, state.lastGeneration ?? .distantPast)
            // Can only ever succeed — `lastActivity` is `touchedAt` or newer, and phase one already
            // proved `touchedAt` was inside the window. It is written as a guard rather than a
            // force because this is where `status` comes from, and because the day someone makes
            // the two timestamps combine differently, this is the line that should stop them.
            guard let status = WorkspaceLiveness.status(modifiedAt: lastActivity, now: now) else { return nil }

            let basename = candidate.cwd.hasPrefix("/")
                ? URL(fileURLWithPath: candidate.cwd).lastPathComponent
                : candidate.cwd
            return DiscoveredSession(
                sessionId: Self.workspaceSessionIdPrefix + candidate.storageDirectory.lastPathComponent,
                agentName: agentName,
                cwd: candidate.cwd,
                title: Self.workspaceTitle(state.title ?? basename),
                lastActivity: lastActivity,
                status: status,
                resumeCommand: cursorAvailable ? "cursor \(AppleScriptRunner.shellQuote(candidate.cwd))" : nil,
                sessionFileURL: nil
            )
        }

        return discovered.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// A workspace row must never read like a real agent session (#29) — the qualifier lives IN the
    /// title itself because a compact row (the only shape one of these is ever allowed to take; see
    /// `SessionLayout`) has no secondary text line to carry it instead. Identical budget arithmetic
    /// to Antigravity's, for the identical reason: `SessionTitle.truncate` can return up to
    /// `limit + 1` characters (a hard cut plus its own "…"), so the text's budget has to leave room
    /// for that on top of the qualifier or a long, space-free title overshoots 60 by one.
    static func workspaceTitle(_ text: String) -> String {
        let qualifier = " — workspace"
        let limit = max(1, 60 - qualifier.count - 1)
        return SessionTitle.truncate(text, max: limit) + qualifier
    }
}
