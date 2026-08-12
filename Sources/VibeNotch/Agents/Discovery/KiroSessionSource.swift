import Foundation

/// Parses one `~/.kiro/sessions/cli/<id>.json` — Kiro CLI's per-session metadata record.
///
/// **THE SHAPE BELOW IS UNVERIFIED (#11).** `kiro-cli` is installed on this machine
/// (`~/.local/bin/kiro-cli` → `/Applications/Kiro CLI.app`) but `~/.kiro` contains only
/// `settings/` and `agents/` — there is no `sessions/` directory at all, so no real record could be
/// inspected. This parses the documented shape (`workingDirectory`, plus a sibling `.jsonl`
/// transcript and a `.lock` while the session is running) and, crucially, requires the one field it
/// cannot do without: a record with no absolute `workingDirectory` is dropped, never shown with a
/// guessed cwd.
enum KiroSessionRecord {
    struct Record: Equatable, Sendable {
        let sessionId: String
        let workingDirectory: String
        let title: String?
        /// `nil` for a session the user started; the parent's id for one Kiro spawned itself.
        let parentSessionId: String?
    }

    /// `fallbackSessionId` is the file's own basename, which is the id in the documented layout —
    /// used whenever the JSON does not repeat it inside.
    static func parse(_ data: Data, fallbackSessionId: String) -> Record? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workingDirectory = object["workingDirectory"] as? String,
              workingDirectory.hasPrefix("/") else { return nil }
        let sessionId = (object["sessionId"] as? String) ?? (object["id"] as? String) ?? fallbackSessionId
        guard !sessionId.isEmpty else { return nil }
        return Record(
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            title: (object["title"] as? String) ?? (object["name"] as? String),
            parentSessionId: object["parentSessionId"] as? String
        )
    }

    static func read(at url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, fallbackSessionId: url.deletingPathExtension().lastPathComponent)
    }
}

/// Bounded discovery of `~/.kiro/sessions/cli` — ONE directory listing, never recursive, capped at
/// the newest `maxFiles` records by mtime. The layout is flat, so unlike Codex's day directories
/// there is no date-partitioned naming to get wrong; freshness still comes from mtime alone and
/// never from a filename (#30's lesson, applied pre-emptively).
enum KiroSessionDiscovery {
    struct Candidate: Equatable {
        let metadataURL: URL
        /// The `.jsonl` transcript beside the record, if it exists — a truer `lastActivity` than
        /// the metadata file, which is written once at session start in the documented shape.
        let transcriptURL: URL?
        /// Whether the `.lock` beside the record exists. Per the documented layout this is held
        /// for as long as the session is running, which is a far better liveness signal than the
        /// mtime heuristics Codex has to settle for.
        let isLocked: Bool
        let modifiedAt: Date
    }

    static func candidates(
        sessionsDirectory: URL,
        fileManager: FileManager,
        maxFiles: Int = 20
    ) -> [Candidate] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { $0.pathExtension == "json" }
            .map { metadataURL -> Candidate in
                let base = metadataURL.deletingPathExtension()
                let transcriptURL = base.appendingPathExtension("jsonl")
                let hasTranscript = fileManager.fileExists(atPath: transcriptURL.path)
                return Candidate(
                    metadataURL: metadataURL,
                    transcriptURL: hasTranscript ? transcriptURL : nil,
                    isLocked: fileManager.fileExists(atPath: base.appendingPathExtension("lock").path),
                    modifiedAt: max(
                        modificationDate(of: metadataURL),
                        hasTranscript ? modificationDate(of: transcriptURL) : .distantPast
                    )
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .map { $0 }
    }

    static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}

/// Discovers Kiro CLI sessions from `~/.kiro/sessions/cli`, enriched by any live `kiro-cli` process
/// in the table.
///
/// **Fixture-only: the on-disk layout this reads is UNVERIFIED** — see `KiroSessionRecord`. As with
/// every source here, being wrong about it costs nothing: the directory does not exist on this
/// machine, so discovery lists nothing and Kiro contributes no rows.
///
/// - Membership: session records on disk, plus every live `kiro-cli` process on a `ttys*`, the
///   latter claiming its record so one session never appears twice.
/// - User-vs-sub-agent: a record with a `parentSessionId` was spawned by another session and is
///   hidden unless `showSubAgentSessions` is on — the same default-deny rule as #24.
/// - Liveness: the `.lock` file. Note what it is NOT allowed to do on its own: a lock left behind
///   by a crashed process would otherwise pin a dead session to "Working…" forever, so a locked
///   session still goes through `HooklessLiveness`, where `.active` additionally requires a recent
///   transcript write (#31). A stale lock can therefore only ever produce `.idle`.
final class KiroSessionSource: AgentSessionSource {
    let agentName = "Kiro"

    static let liveSessionIdPrefix = "kiro-live:"

    /// How long a session with neither a lock nor a live process stays on screen.
    static let visibleWindow: TimeInterval = 60 * 60.0

    private let sessionsDirectory: URL
    private let fileManager: FileManager
    private let processProvider: () -> [ClaudeProcess]
    private let showSubAgentSessions: () -> Bool
    private let binaryPath: String

    init(
        kiroHome: URL = KiroSessionSource.defaultKiroHome(),
        fileManager: FileManager = .default,
        processProvider: @escaping () -> [ClaudeProcess] = { TTYResolver().processes() },
        showSubAgentSessions: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: "showSubAgentSessions")
        },
        binaryPath: String = KiroSessionSource.defaultBinaryPath()
    ) {
        self.sessionsDirectory = kiroHome.appendingPathComponent("sessions/cli", isDirectory: true)
        self.fileManager = fileManager
        self.processProvider = processProvider
        self.showSubAgentSessions = showSubAgentSessions
        self.binaryPath = binaryPath
    }

    static func defaultKiroHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro", isDirectory: true)
    }

    /// `kiro-cli` is tried alongside `kiro` because `kiro` is NOT a binary on this machine — the
    /// issue's notes documented the resume command as `kiro --resume <id>`, but a login shell here
    /// finds only `~/.local/bin/kiro-cli`. Naming the one that exists is what keeps the new-tab
    /// fallback from opening a tab that prints "command not found".
    static func defaultBinaryPath() -> String {
        let directories = AgentBinary.standardDirectories(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return AgentBinary.firstExecutable(named: "kiro", in: directories)
            ?? AgentBinary.firstExecutable(named: "kiro-cli", in: directories)
            ?? "kiro"
    }

    private struct Session {
        let record: KiroSessionRecord.Record
        let candidate: KiroSessionDiscovery.Candidate
        /// Canonical (see `CanonicalPath`), so a recorded working directory and `lsof`'s resolved
        /// cwd compare equal.
        let canonicalCwd: String
    }

    func discover(now: Date) -> [DiscoveredSession] {
        let sessions = visibleSessions(includeSubAgentSessions: showSubAgentSessions())
        let liveProcesses = LiveAgentScan.liveSessions(in: processProvider()).filter { $0.agentName == agentName }
        guard !sessions.isEmpty || !liveProcesses.isEmpty else { return [] }

        var claimed: Set<String> = []
        let live: [DiscoveredSession] = liveProcesses.map { process in
            let match = sessions.first {
                !claimed.contains($0.record.sessionId) && $0.canonicalCwd == process.cwd
            }
            if let match { claimed.insert(match.record.sessionId) }
            return DiscoveredSession(
                sessionId: match?.record.sessionId ?? Self.liveSessionId(tty: process.tty, cwd: process.cwd),
                agentName: agentName,
                cwd: match?.record.workingDirectory ?? process.cwd,
                title: Self.title(match?.record.title, cwd: match?.record.workingDirectory ?? process.cwd),
                lastActivity: match?.candidate.modifiedAt ?? process.startedAt ?? now,
                status: HooklessLiveness.liveStatus(lastWriteAt: match?.candidate.modifiedAt, now: now),
                resumeCommand: match.map { resumeCommand(sessionId: $0.record.sessionId) } ?? binaryPath,
                sessionFileURL: nil,
                // No hooks: `.active` here only ever means "live + recent write" (#31).
                supportsLiveStatus: false,
                tty: process.tty
            )
        }

        let onDisk: [DiscoveredSession] = sessions.compactMap { session in
            guard !claimed.contains(session.record.sessionId),
                  let status = Self.status(
                      isLocked: session.candidate.isLocked,
                      modifiedAt: session.candidate.modifiedAt,
                      now: now
                  ) else { return nil }
            return DiscoveredSession(
                sessionId: session.record.sessionId,
                agentName: agentName,
                cwd: session.record.workingDirectory,
                title: Self.title(session.record.title, cwd: session.record.workingDirectory),
                lastActivity: session.candidate.modifiedAt,
                status: status,
                resumeCommand: resumeCommand(sessionId: session.record.sessionId),
                sessionFileURL: nil,
                supportsLiveStatus: false
            )
        }

        return Array((live + onDisk).prefix(10))
    }

    /// A held `.lock` means the session is running, so it is never hidden by age — the same rule
    /// `HooklessLiveness` applies to a live process, and for the same reason (#33). Without one,
    /// the session is finished work: `.idle` for an hour, then gone.
    static func status(isLocked: Bool, modifiedAt: Date, now: Date) -> SessionStatus? {
        guard !isLocked else { return HooklessLiveness.liveStatus(lastWriteAt: modifiedAt, now: now) }
        return now.timeIntervalSince(modifiedAt) < visibleWindow ? .idle : nil
    }

    /// `kiro --resume <id>`, shell-quoted for the same reason `Jumper.codexResumeCommand` quotes
    /// its own id.
    func resumeCommand(sessionId: String) -> String {
        "\(binaryPath) --resume \(AppleScriptRunner.shellQuote(sessionId))"
    }

    private func visibleSessions(includeSubAgentSessions: Bool) -> [Session] {
        KiroSessionDiscovery
            .candidates(sessionsDirectory: sessionsDirectory, fileManager: fileManager)
            .compactMap { candidate in
                guard let record = KiroSessionRecord.read(at: candidate.metadataURL),
                      record.parentSessionId == nil || includeSubAgentSessions else { return nil }
                return Session(
                    record: record,
                    candidate: candidate,
                    canonicalCwd: CanonicalPath.canonical(record.workingDirectory)
                )
            }
    }

    private static func title(_ stored: String?, cwd: String) -> String {
        SessionTitle.resolve(sessionFileURL: nil, lastPrompt: stored, cwd: cwd)
    }

    private static func liveSessionId(tty: String, cwd: String) -> String {
        "\(liveSessionIdPrefix)\(tty):\(cwd)"
    }
}
