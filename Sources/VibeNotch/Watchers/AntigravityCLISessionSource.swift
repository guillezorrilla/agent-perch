import Foundation

/// Parses a `cli-*.log`'s `workspace <path>` line — the only place Antigravity's own CLI (`agy`)
/// records the folder a run is working in.
enum AntigravityCLILog {
    /// The FIRST `workspace <path>` line's path, when a log somehow carries more than one; `nil`
    /// when it carries none at all — there is nothing to jump to, so the caller must skip the
    /// session outright rather than show a cwd-less row.
    static func workspacePath(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("workspace ") else { continue }
            let path = trimmed.dropFirst("workspace ".count).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        return nil
    }

    /// Reads only a bounded prefix of the log — the `workspace` line is written near the start of
    /// a run, so there is no reason to load a potentially long-running session's entire log into
    /// memory just to find it (mirrors `CodexRolloutMeta.firstLineSessionMeta`'s bounded read).
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

/// Mirrors `CodexLiveness` exactly: `agy` has no hooks either, so a stale-vs-fresh mtime alone
/// cannot tell a session that's still running from one whose terminal was simply left open — only
/// an actual live process match may promote past `.idle`.
enum AntigravityCLILiveness {
    static func status(cwd: String, modifiedAt: Date, now: Date, processes: [ClaudeProcess]) -> SessionStatus? {
        if hasLiveProcess(cwd: cwd, processes: processes) {
            return .active
        }
        guard now.timeIntervalSince(modifiedAt) < 60 * 60.0 else { return nil }
        return .idle
    }

    static func hasLiveProcess(cwd: String, processes: [ClaudeProcess]) -> Bool {
        processes.contains {
            TTYResolver.isAgentCLI("Antigravity", command: $0.command) && CanonicalPath.equal($0.cwd, cwd)
        }
    }
}

/// Discovers real `agy` (Antigravity's own CLI) sessions from
/// `~/.gemini/antigravity-cli/{log,implicit}`.
///
/// Unlike `AntigravitySessionSource`'s IDE workspaces — folders the app merely has open, with no
/// per-agent state on disk at all — these run in a terminal exactly like a Claude or Codex CLI
/// session: a real per-run log, a live process to focus by tty, `agy` itself to resume. So unlike
/// the IDE-workspace source, this one is ALWAYS ON (#29) and lets the normal jump ladder resolve
/// it (see `SessionStore.reconcile`, `Jumper.resolvePlan`).
///
/// - Membership: newest ~20 `log/cli-*.log` files by mtime (bounded, one directory listing). Each
///   log's first `workspace <path>` line is its cwd (see `AntigravityCLILog`); a log with none is
///   skipped outright — there is nothing to jump to.
/// - Session id: the `implicit/<uuid>.pb` whose mtime is closest to the log's own, when one
///   exists; otherwise a stable id derived from the log's own filename (its encoded timestamp is
///   already unique per run).
/// - Liveness: see `AntigravityCLILiveness` — mtime alone only gates `.idle` vs. hidden, matching
///   every other hookless CLI source in this app.
final class AntigravityCLISessionSource: AgentSessionSource {
    let agentName = "Antigravity"

    /// Every `sessionId` this source hands out starts with this — the CLI-session half of the
    /// `antigravity:`/`antigravity-cli:` prefix pair `SessionStore`'s dedup and
    /// `AgentSession.isAntigravityWorkspace` both key off.
    static let sessionIdPrefix = "antigravity-cli:"

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

    func discover(now: Date) -> [DiscoveredSession] {
        let logs = AntigravityCLIDiscovery.candidateLogFiles(logDirectory: logDirectory, fileManager: fileManager)
        guard !logs.isEmpty else { return [] }

        let implicitFiles = AntigravityCLIDiscovery.implicitFiles(in: implicitDirectory, fileManager: fileManager)
        let processes = processProvider()

        let discovered: [DiscoveredSession] = logs.compactMap { log -> DiscoveredSession? in
            guard let cwd = AntigravityCLILog.workspacePath(at: log) else { return nil }
            let modifiedAt = AntigravityCLIDiscovery.modificationDate(of: log, fileManager: fileManager)
            guard let status = AntigravityCLILiveness.status(
                cwd: cwd, modifiedAt: modifiedAt, now: now, processes: processes
            ) else { return nil }

            let fallbackID = log.deletingPathExtension().lastPathComponent
            let sessionId = Self.sessionIdPrefix
                + (AntigravityCLIDiscovery.closestImplicitID(to: modifiedAt, in: implicitFiles) ?? fallbackID)
            let basename = cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd

            return DiscoveredSession(
                sessionId: sessionId,
                agentName: agentName,
                cwd: cwd,
                title: SessionTitle.truncate(basename, max: 60),
                lastActivity: modifiedAt,
                status: status,
                // The cwd `cd` is already handled by `Jumper`'s shared "new tab" command
                // template — this only needs to name the launch itself, exactly like Codex's
                // `codex resume <id>` does for its own resumeCommand.
                resumeCommand: "agy",
                sessionFileURL: nil
            )
        }
        return Array(discovered.prefix(10))
    }
}
