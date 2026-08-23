import Foundation

/// Parses a `cli-*.log`'s `workspace <path>` marker — the only place Antigravity's own CLI (`agy`)
/// records the folder a run is working in.
///
/// The real line is a Go-style log line where the marker sits mid-line, not at the line's start,
/// e.g. (byte-for-byte from a real log):
/// `ERROR: logging before google.Init: I0810 09:16:58.692555       1 manager.go:367] Initializing
/// CLI store manager for workspace /Users/gzorrilla/Developer/personal/agent-perch`
enum AntigravityCLILog {
    private static let marker = "workspace "

    /// The FIRST matching line's path, when a log somehow carries more than one; `nil` when it
    /// carries none at all — there is nothing to jump to, so the caller must skip the session
    /// outright rather than show a cwd-less row.
    ///
    /// "Matching" means the line contains `workspace ` ANYWHERE, not just as a prefix — the
    /// marker is preceded by unrelated log preamble in the real format above. When the marker
    /// itself appears more than once on that line, the LAST occurrence wins, and the path is
    /// everything after it to end-of-line (trimmed) — never truncated further, since a path may
    /// itself contain spaces. A line with the marker whose remainder isn't an absolute path
    /// (empty, or relative) yields `nil` outright rather than falling through to a later line.
    static func workspacePath(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let markerRange = line.range(of: marker, options: .backwards) else { continue }
            let candidate = line[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.hasPrefix("/") ? candidate : nil
        }
        return nil
    }

    /// Reads only a bounded prefix of the log — the `workspace` marker is written near the start
    /// of a run, so there is no reason to load a potentially long-running session's entire log
    /// into memory just to find it (mirrors `CodexRolloutMeta.firstLineSessionMeta`'s bounded
    /// read). Verified on a real log: the marker sat at byte offset 8077 of a 27,194-byte file —
    /// comfortably inside this bound, but close enough to it that the bound must stay generous
    /// rather than shrink.
    static func workspacePath(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty,
              let text = String(data: chunk, encoding: .utf8) else { return nil }
        return workspacePath(in: text)
    }
}

/// Bounded discovery of `~/.gemini/antigravity-cli/{log,implicit}` — one directory listing each,
/// never recursive, mirroring `CodexRolloutDiscovery`/`AntigravityWorkspaceDiscovery`'s same rule:
/// a power user can accumulate one log and one `.pb` per `agy` invocation ever made.
enum AntigravityCLIDiscovery {
    static func candidateLogFiles(
        logDirectory: URL,
        fileManager: FileManager,
        maxFiles: Int = 20
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let logs = entries.filter {
            $0.lastPathComponent.hasPrefix("cli-") && $0.pathExtension == "log"
        }
        return logs
            .sorted { modificationDate(of: $0, fileManager: fileManager) > modificationDate(of: $1, fileManager: fileManager) }
            .prefix(maxFiles)
            .map { $0 }
    }

    /// The newest `maxFiles` implicit-state files by mtime, as `(id, mtime)` pairs — bounded the
    /// same way the logs are, so `closestImplicitID` only ever has to scan a small, still-relevant
    /// set rather than a power user's entire history of `agy` runs.
    static func implicitFiles(
        in directory: URL,
        fileManager: FileManager,
        maxFiles: Int = 20
    ) -> [(id: String, modifiedAt: Date)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { $0.pathExtension == "pb" }
            .map { (id: $0.deletingPathExtension().lastPathComponent, modifiedAt: modificationDate(of: $0, fileManager: fileManager)) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .map { $0 }
    }

    /// The implicit-state id whose mtime is nearest the log's own — a session's `.pb` file is
    /// touched around the same activity as its log, so "closest", not "newest", is the right
    /// question. Ties break toward whichever comes first in `files`; no caller has ever observed
    /// two genuinely sharing a millisecond.
    static func closestImplicitID(to logModifiedAt: Date, in files: [(id: String, modifiedAt: Date)]) -> String? {
        files.min { abs($0.modifiedAt.timeIntervalSince(logModifiedAt)) < abs($1.modifiedAt.timeIntervalSince(logModifiedAt)) }?.id
    }

    static func modificationDate(of url: URL, fileManager: FileManager) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// Discovers real `agy` (Antigravity's own CLI) sessions from the process table, using
/// `~/.gemini/antigravity-cli/{log,implicit}` only to fill in what a process listing can't say.
///
/// Unlike `AntigravitySessionSource`'s IDE workspaces — folders the app merely has open, with no
/// per-agent state on disk at all — these run in a terminal exactly like a Claude or Codex CLI
/// session: a live process to focus by tty, `agy` itself to resume. So unlike the IDE-workspace
/// source, this one is ALWAYS ON (#29) and lets the normal jump ladder resolve it (see
/// `SessionStore.reconcile`, `Jumper.resolvePlan`).
///
/// - Membership: live `agy` processes on a `ttys*`, one row per `(cwd, tty)` — see
///   `LiveAgentScan`. Emphatically NOT the log files. `agy` writes SEVERAL `cli-*.log` files per
///   run and leaves every one of them behind, some recording a workspace of literally `/`, so
///   enumerating logs as sessions turned one real session into four rows — one of them titled `/`
///   and two of them duplicates of each other (#33). Logs are a record of writes; only a process
///   is a session.
/// - Enrichment: the newest log whose `workspace` line (see `AntigravityCLILog`) names this
///   session's own cwd supplies `lastActivity` and, via the `implicit/<uuid>.pb` closest to it by
///   mtime, a session id. A session with no matching log still shows, dated by when its process
///   started — a log is a nicety, never the evidence.
/// - Liveness: see `HooklessLiveness` — a live session is never hidden by log age, and `.active`
///   still requires a recent log write (#31).
final class AntigravityCLISessionSource: AgentSessionSource {
    let agentName = "Antigravity"

    /// Every `sessionId` this source hands out starts with this — the CLI-session half of the
    /// `antigravity:`/`antigravity-cli:` prefix pair `SessionStore`'s dedup and
    /// `AgentSession.isAntigravityWorkspace` both key off.
    static let sessionIdPrefix = "antigravity-cli:"

    /// What follows `sessionIdPrefix` for a session no log could be matched to: the process's own
    /// `(tty, cwd)`, which is exactly what identifies it and stays stable across refreshes.
    static let liveSessionIdInfix = "tty:"

    private let logDirectory: URL
    private let implicitDirectory: URL
    private let fileManager: FileManager
    private let processProvider: () -> [ClaudeProcess]

    init(
        antigravityCLIHome: URL = AntigravityCLISessionSource.defaultAntigravityCLIHome(),
        fileManager: FileManager = .default,
        processProvider: @escaping () -> [ClaudeProcess] = { TTYResolver().processes() }
    ) {
        self.logDirectory = antigravityCLIHome.appendingPathComponent("log", isDirectory: true)
        self.implicitDirectory = antigravityCLIHome.appendingPathComponent("implicit", isDirectory: true)
        self.fileManager = fileManager
        self.processProvider = processProvider
    }

    static func defaultAntigravityCLIHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    /// A `cli-*.log` reduced to the two things it can tell a session about itself.
    private struct Log {
        let url: URL
        /// Canonical (see `CanonicalPath`), so a log's own recorded workspace and `lsof`'s
        /// resolved cwd compare equal.
        let workspace: String
        let modifiedAt: Date
    }

    func discover(now: Date) -> [DiscoveredSession] {
        let liveProcesses = LiveAgentScan.liveSessions(in: processProvider())
            .filter { $0.agentName == agentName }
        // No live `agy` process means no `agy` session, however many logs are lying around: every
        // one of them is a record of a run that has already ended.
        guard !liveProcesses.isEmpty else { return [] }

        let logs = candidateLogs()
        let implicitFiles = logs.isEmpty
            ? []
            : AntigravityCLIDiscovery.implicitFiles(in: implicitDirectory, fileManager: fileManager)

        var claimed: Set<URL> = []
        let discovered: [DiscoveredSession] = liveProcesses.map { process in
            let match = logs.first { !claimed.contains($0.url) && $0.workspace == process.cwd }
            if let match { claimed.insert(match.url) }

            let basename = URL(fileURLWithPath: process.cwd).lastPathComponent
            return DiscoveredSession(
                sessionId: Self.sessionIdPrefix + Self.sessionKey(for: match, implicitFiles: implicitFiles, process: process),
                agentName: agentName,
                cwd: process.cwd,
                title: SessionTitle.truncate(basename, max: 60),
                lastActivity: match?.modifiedAt ?? process.startedAt ?? now,
                status: HooklessLiveness.liveStatus(lastWriteAt: match?.modifiedAt, now: now),
                // The cwd `cd` is already handled by `Jumper`'s shared "new tab" command
                // template — this only needs to name the launch itself, exactly like Codex's
                // `codex resume <id>` does for its own resumeCommand.
                resumeCommand: "agy",
                sessionFileURL: nil,
                // No hooks: `.active` here only ever means "live process + recent write" (see
                // `HooklessLiveness`), never a verified in-flight turn (issue #31).
                supportsLiveStatus: false,
                tty: process.tty
            )
        }
        return Array(discovered.prefix(10))
    }

    /// The newest ~20 logs that name a real workspace, newest first.
    ///
    /// A workspace of literally `/` is dropped outright: `agy` records it for runs with no project
    /// context at all, and it can only ever produce a row titled `/` that jumps to the filesystem
    /// root (#33). One with no `workspace` line at all is dropped for the same reason it always
    /// was — it says nothing about which session it belongs to.
    private func candidateLogs() -> [Log] {
        AntigravityCLIDiscovery
            .candidateLogFiles(logDirectory: logDirectory, fileManager: fileManager)
            .compactMap { url in
                guard let workspace = AntigravityCLILog.workspacePath(at: url) else { return nil }
                let canonical = CanonicalPath.canonical(workspace)
                guard canonical != "/" else { return nil }
                return Log(
                    url: url,
                    workspace: canonical,
                    modifiedAt: AntigravityCLIDiscovery.modificationDate(of: url, fileManager: fileManager)
                )
            }
    }

    /// A matched log's `implicit/<uuid>.pb` (closest by mtime), else the log's own filename — its
    /// encoded timestamp is already unique per run — else the process's own `(tty, cwd)`.
    private static func sessionKey(
        for log: Log?,
        implicitFiles: [(id: String, modifiedAt: Date)],
        process: LiveAgentProcess
    ) -> String {
        guard let log else { return "\(liveSessionIdInfix)\(process.tty):\(process.cwd)" }
        return AntigravityCLIDiscovery.closestImplicitID(to: log.modifiedAt, in: implicitFiles)
            ?? log.url.deletingPathExtension().lastPathComponent
    }
}
