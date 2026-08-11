import Darwin
import Foundation

/// Parses a workspace's `workspace.json` — `{"folder":"file:///abs/path"}` — into the absolute
/// path Antigravity has open there.
enum AntigravityWorkspaceJSON {
    static func decodeFolderPath(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = object["folder"] as? String else { return nil }
        return decodeFileURI(folder)
    }

    /// `URLComponents` percent-decodes `.path` for us, so `file:///Users/me/My%20Repo` already
    /// comes back as `/Users/me/My Repo`. A URI with a real host (not empty, not `localhost`) —
    /// a remote or WSL workspace — is rejected: it names a folder nothing on this Mac could open,
    /// and anything that isn't a `file://` URI at all (or has no path) is just as unusable.
    static func decodeFileURI(_ uriString: String) -> String? {
        guard let components = URLComponents(string: uriString),
              components.scheme == "file",
              components.host == nil || components.host!.isEmpty || components.host == "localhost"
        else { return nil }
        let path = components.path
        return path.isEmpty ? nil : path
    }
}

/// Cross-references `globalStorage/storage.json`'s `backupWorkspaces.folders[]` — Antigravity's
/// own most-recent-first record of opened folders — for a recency signal `workspaceStorage`'s
/// directory mtimes alone don't carry.
enum AntigravityGlobalStorage {
    /// `canonical folder path -> its index in backupWorkspaces.folders` (0 = most recent). A
    /// workspace not listed there at all has no rank and sorts after everything that does — see
    /// `AntigravityRecency`.
    static func recencyRank(contentsAt url: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return recencyRank(data)
    }

    static func recencyRank(_ data: Data) -> [String: Int] {
        var rank: [String: Int] = [:]
        for (index, uri) in folderURIs(data).enumerated() {
            guard let path = AntigravityWorkspaceJSON.decodeFileURI(uri) else { continue }
            let key = CanonicalPath.canonical(path)
            if rank[key] == nil { rank[key] = index }
        }
        return rank
    }

    static func folderURIs(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backup = object["backupWorkspaces"] as? [String: Any],
              let folders = backup["folders"] as? [[String: Any]] else { return [] }
        return folders.compactMap { $0["folderUri"] as? String }
    }
}

/// The final ordering of discovered workspaces: `storage.json`'s own recency list wins when both
/// sides appear in it (lower index = more recent); a workspace missing from that list sorts after
/// one that's present; when neither is listed, the newer `lastActivity` wins.
enum AntigravityRecency {
    static func isOrderedBefore(
        cwd: String,
        lastActivity: Date,
        otherCwd: String,
        otherLastActivity: Date,
        recencyRank: [String: Int]
    ) -> Bool {
        let lhsRank = recencyRank[CanonicalPath.canonical(cwd)]
        let rhsRank = recencyRank[CanonicalPath.canonical(otherCwd)]
        switch (lhsRank, rhsRank) {
        case let (lhs?, rhs?): return lhs < rhs
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lastActivity > otherLastActivity
        }
    }
}

/// Bounded discovery of workspace directories under `workspaceStorage/`. One directory listing,
/// never recursive, capped to the newest-touched `maxDirectories` — a power user can accumulate
/// hundreds of these over the IDE's lifetime, most for folders not opened in months, mirroring
/// why `CodexRolloutDiscovery` caps rollout files the same way.
enum AntigravityWorkspaceDiscovery {
    static func candidateWorkspaceDirectories(
        workspaceStorageRoot: URL,
        fileManager: FileManager,
        maxDirectories: Int = 30
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: workspaceStorageRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return directories
            .sorted { modificationDate(of: $0, fileManager: fileManager) > modificationDate(of: $1, fileManager: fileManager) }
            .prefix(maxDirectories)
            .map { $0 }
    }

    /// The newest mtime among a workspace's storage directory contents, or the directory itself
    /// when that's newer (or the directory is empty) — one level deep, never recursive.
    static func lastActivity(of storageDirectory: URL, fileManager: FileManager) -> Date {
        let contents = (try? fileManager.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let newestContent = contents.map { modificationDate(of: $0, fileManager: fileManager) }.max() ?? .distantPast
        return max(newestContent, modificationDate(of: storageDirectory, fileManager: fileManager))
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date {
        if let resourceValue = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            return resourceValue
        }
        return (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
}

/// A workspace row is capped at `.idle` — it may NEVER read as `.active`, however fresh its mtime
/// or however recently Antigravity itself was seen running (#29). A workspace directory's mtime
/// moves for reasons that have nothing to do with an agent — the IDE rewrites state there on
/// window focus, on settings sync, on quit — and a live Antigravity process says nothing about
/// WHICH open workspace, if any, an agent is actually working in (an Electron app's own process
/// cwd is its Resources directory, not the folder the user opened, so per-workspace attribution by
/// process was never possible the way it is for Claude/Codex's tty or `resume <id>` command line).
/// Presenting a merely-open folder as "Working…" is exactly what tipped a real user off that this
/// needed capping HERE, in the source, rather than only hidden by the view: a real
/// `AntigravityCLISessionSource` session for the very same folder sat right beside a workspace row
/// that also claimed to be active. `SessionStatus`'s usual `< 60 minutes` freshness window still
/// gates `.idle` vs. hidden — it just can never promote past `.idle`.
enum AntigravityLiveness {
    static func status(modifiedAt: Date, now: Date) -> SessionStatus? {
        guard now.timeIntervalSince(modifiedAt) < 60 * 60.0 else { return nil }
        return .idle
    }
}

/// Whether an Antigravity IDE process is alive right now. Not currently consulted by
/// `AntigravitySessionSource` — a workspace row is capped at `.idle` regardless of whether
/// Antigravity itself is running (#29) — but kept as a tested, standalone building block (#27):
/// two independent checks, since either alone can miss. `code.lock` names the primary instance's
/// pid directly but can go stale after a crash; the process listing finds any process running out
/// of the IDE's bundle but says nothing about which pid is the real one. Either one seeing a live
/// process is enough.
enum AntigravityProcessCheck {
    static func isRunningNow(codeLockURL: URL) -> Bool {
        isRunning(codeLockURL: codeLockURL, fileManager: .default) || isRunningByExecutablePath()
    }

    static func isRunning(
        codeLockURL: URL,
        fileManager: FileManager,
        pidAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> Bool {
        guard fileManager.fileExists(atPath: codeLockURL.path),
              let data = try? Data(contentsOf: codeLockURL),
              let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return pidAlive(pid)
    }

    /// Matches on the EXECUTABLE PATH, never the process name. Antigravity's main process is
    /// `/Applications/Antigravity IDE.app/Contents/MacOS/Electron`, whose process name is plain
    /// `Electron` — `pgrep Antigravity` never matched it at all, and only ever found the helper
    /// processes that happen to carry the product in their own names. Matching the bundle in the
    /// path finds the real one, and still refuses the unrelated `Electron` processes (Claude.app,
    /// Docker.app, …) that a bare name match on `Electron` would sweep up.
    static func isRunningByExecutablePath(
        listing: () -> String? = { TTYResolver.output("/bin/ps", ["-axo", "comm="]) }
    ) -> Bool {
        guard let output = listing() else { return false }
        return output.split(separator: "\n").contains {
            isAntigravityExecutable($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A path is Antigravity's only when one of its bundle names is a whole path component —
    /// `/Applications/Antigravity IDE.app/…` yes, `/Applications/Claude.app/…/Electron` no.
    static func isAntigravityExecutable(_ executablePath: String) -> Bool {
        ["Antigravity IDE.app/", "Antigravity.app/"].contains { bundle in
            executablePath.hasPrefix(bundle) || executablePath.contains("/" + bundle)
        }
    }
}

/// Whether `agy` — Antigravity's own CLI, if installed — is on `PATH`. `DiscoveredSession`'s
/// `resumeCommand` uses this to prefer `agy <path>` over the `open -a` fallback the Jumper falls
/// back to when it's absent.
enum AntigravityCLI {
    static func isAgyAvailable() -> Bool {
        guard let output = TTYResolver.output("/usr/bin/which", ["agy"]) else { return false }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Discovers Antigravity (Google's VS Code-fork agentic IDE) workspaces from
/// `~/Library/Application Support/Antigravity IDE`.
///
/// Antigravity has no per-session transcript to read — its agent turns are ephemeral and never
/// persisted anywhere on disk — so unlike Claude/Codex this surfaces WORKSPACES the IDE has open
/// or has recently had open, not agent turns. A row from this source can never be more than a
/// hint that a folder was opened recently, so `DiscoveredSession.title` says so outright (see
/// `workspaceTitle`) and `status` never claims more than `.idle` (see `AntigravityLiveness`) —
/// unlike `AntigravityCLISessionSource`'s real `agy` terminal sessions, which behave exactly like
/// Claude/Codex's.
///
/// - Membership: one directory listing of `workspaceStorage` (never recursive, capped — see
///   `AntigravityWorkspaceDiscovery`), each candidate's `workspace.json` decoded for its folder
///   path (see `AntigravityWorkspaceJSON`).
/// - Recency: `globalStorage/storage.json`'s `backupWorkspaces.folders[]` order, when a workspace
///   appears there (see `AntigravityGlobalStorage`/`AntigravityRecency`).
/// - Liveness: see `AntigravityLiveness` — capped at `.idle`, never `.active` (#29).
///
/// OFF BY DEFAULT (#27). A `workspaceStorage` directory's mtime moves for reasons that have
/// nothing to do with an agent — the IDE rewrites state there on window focus, on settings sync,
/// on quit — and Antigravity persists no per-agent state at that location at all, so "workspace
/// touched in the last hour" is not evidence of agent activity the way a Claude transcript append
/// or a Codex rollout write is. `showAntigravityWorkspaces` is the opt-in; when it is off this
/// source enumerates nothing and contributes nothing. `AntigravityCLISessionSource` is NOT gated
/// by this setting — it represents real sessions, not merely-open folders — and a workspace row
/// for the same folder as a live CLI session is suppressed in `SessionStore` (see
/// `isWorkspaceSessionId` and `SessionStore`'s dedup) so the two never show side by side.
final class AntigravitySessionSource: AgentSessionSource {
    let agentName = "Antigravity"
    let antigravityHome: URL
    private let fileManager: FileManager
    private let agyAvailableProvider: () -> Bool
    private let showWorkspaces: () -> Bool

    /// Every `sessionId` this source hands out starts with this — how `SessionStore` and
    /// `AgentSession.isAntigravityWorkspace` tell an IDE-workspace row apart from a real
    /// `AntigravityCLISessionSource` session, both of which share `agentName == "Antigravity"` on
    /// purpose (one Settings toggle, one pill).
    static let workspaceSessionIdPrefix = "antigravity:"

    static func isWorkspaceSessionId(_ sessionId: String) -> Bool {
        sessionId.hasPrefix(workspaceSessionIdPrefix)
    }

    init(
        antigravityHome: URL = AntigravitySessionSource.defaultAntigravityHome(),
        fileManager: FileManager = .default,
        agyAvailableProvider: @escaping () -> Bool = AntigravityCLI.isAgyAvailable,
        // Keyed identically to `AppSettings.showAntigravityWorkspaces` — @AppStorage is backed by
        // `UserDefaults.standard`, so the Settings toggle reaches discovery with no plumbing, the
        // same way `showSubAgentSessions` reaches `CodexSessionSource`.
        showWorkspaces: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: "showAntigravityWorkspaces")
        }
    ) {
        self.antigravityHome = antigravityHome
        self.fileManager = fileManager
        self.agyAvailableProvider = agyAvailableProvider
        self.showWorkspaces = showWorkspaces
    }

    static func defaultAntigravityHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity IDE", isDirectory: true)
    }

    private var workspaceStorageRoot: URL {
        antigravityHome.appendingPathComponent("User/workspaceStorage", isDirectory: true)
    }

    private var globalStorageJSONURL: URL {
        antigravityHome.appendingPathComponent("User/globalStorage/storage.json", isDirectory: false)
    }

    func discover(now: Date) -> [DiscoveredSession] {
        // Before the directory listing, not after: opted out means no disk work at all.
        guard showWorkspaces() else { return [] }

        let directories = AntigravityWorkspaceDiscovery.candidateWorkspaceDirectories(
            workspaceStorageRoot: workspaceStorageRoot,
            fileManager: fileManager
        )
        guard !directories.isEmpty else { return [] }

        let workspaces: [(cwd: String, storageDirectory: URL, lastActivity: Date)] = directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("workspace.json")),
                  let path = AntigravityWorkspaceJSON.decodeFolderPath(from: data) else { return nil }
            let lastActivity = AntigravityWorkspaceDiscovery.lastActivity(of: directory, fileManager: fileManager)
            return (cwd: path, storageDirectory: directory, lastActivity: lastActivity)
        }
        guard !workspaces.isEmpty else { return [] }

        // Costs a subprocess spawn — never paid unless there is at least one real workspace to
        // show for it.
        let agyAvailable = agyAvailableProvider()
        let recencyRank = AntigravityGlobalStorage.recencyRank(contentsAt: globalStorageJSONURL)

        let discovered: [DiscoveredSession] = workspaces.compactMap { workspace in
            guard let status = AntigravityLiveness.status(modifiedAt: workspace.lastActivity, now: now)
            else { return nil }

            let basename = workspace.cwd.hasPrefix("/")
                ? URL(fileURLWithPath: workspace.cwd).lastPathComponent
                : workspace.cwd
            return DiscoveredSession(
                sessionId: Self.workspaceSessionIdPrefix + workspace.storageDirectory.lastPathComponent,
                agentName: agentName,
                cwd: workspace.cwd,
                title: Self.workspaceTitle(basename: basename),
                lastActivity: workspace.lastActivity,
                status: status,
                resumeCommand: agyAvailable ? "agy \(AppleScriptRunner.shellQuote(workspace.cwd))" : nil,
                sessionFileURL: nil
            )
        }

        let ordered = discovered.sorted {
            AntigravityRecency.isOrderedBefore(
                cwd: $0.cwd,
                lastActivity: $0.lastActivity,
                otherCwd: $1.cwd,
                otherLastActivity: $1.lastActivity,
                recencyRank: recencyRank
            )
        }
        return Array(ordered.prefix(10))
    }

    /// A workspace row must never read like a real agent session (#29) — the qualifier lives IN
    /// the title itself because a compact row (the only shape one of these is ever allowed to
    /// take; see `SessionLayout`) has no secondary text line to carry it instead.
    private static func workspaceTitle(basename: String) -> String {
        let qualifier = " — workspace"
        // `SessionTitle.truncate` can return up to `limit + 1` characters (a hard cut plus its
        // own "…"), so the budget for the basename has to leave room for that on top of the
        // qualifier — otherwise a long, space-free basename overshoots 60 by one.
        let limit = max(1, 60 - qualifier.count - 1)
        return SessionTitle.truncate(basename, max: limit) + qualifier
    }
}

extension AgentSession {
    /// True only for an `AntigravitySessionSource` IDE-workspace row — never for a real
    /// `AntigravityCLISessionSource` terminal session, even though both share
    /// `agentName == "Antigravity"` on purpose. See `AntigravitySessionSource.isWorkspaceSessionId`.
    var isAntigravityWorkspace: Bool {
        agentName == "Antigravity" && AntigravitySessionSource.isWorkspaceSessionId(sessionId)
    }
}
