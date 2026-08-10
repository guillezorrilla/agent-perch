import Foundation

/// Parses `$CODEX_HOME/session_index.jsonl` — one JSON object per line, newest sessions
/// appended last: `{"id":"...","thread_name":"...","updated_at":"<ISO8601 w/ fractional secs>"}`.
enum CodexSessionIndex {
    struct Entry: Equatable, Sendable {
        let id: String
        let threadName: String?
        let updatedAt: Date
    }

    static func load(at url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [Entry] {
        data.split(separator: 0x0A).compactMap(parseLine)
    }

    private static func parseLine(_ line: Data) -> Entry? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty,
              let updatedRaw = object["updated_at"] as? String,
              // Reuses the same flexible ISO8601 (with-or-without-fractional-seconds) parser
              // the Claude usage endpoint's timestamps already need.
              let updatedAt = ClaudeUsageParser.parseDate(updatedRaw) else { return nil }
        let threadName = object["thread_name"] as? String
        return Entry(id: id, threadName: threadName, updatedAt: updatedAt)
    }
}

/// Parses the first line of a Codex rollout file — a `session_meta` record carrying the
/// session's authoritative `cwd`.
enum CodexRolloutMeta {
    struct SessionMeta: Equatable, Sendable {
        let sessionId: String
        let cwd: String
    }

    /// Reads only enough of the file to get past its first line, rather than loading a
    /// potentially large transcript into memory.
    static func firstLineSessionMeta(at url: URL) -> SessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { return nil }
        let line = chunk.firstIndex(of: 0x0A).map { chunk[..<$0] } ?? chunk
        return parseLine(Data(line))
    }

    private static func parseLine(_ line: Data) -> SessionMeta? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        let sessionId = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? ""
        guard !sessionId.isEmpty else { return nil }
        return SessionMeta(sessionId: sessionId, cwd: cwd)
    }
}

/// Locates a session's rollout file under `$CODEX_HOME/sessions/**`.
enum CodexRolloutLocator {
    /// Rollout filenames are `rollout-<ISO-timestamp>-<session-id>.jsonl` under
    /// `sessionsRoot/YYYY/MM/DD/`; matching the id as a filename suffix finds the file
    /// without needing to know its date subdirectory or timestamp prefix.
    static func locate(
        sessionId: String,
        under sessionsRoot: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let suffix = "-\(sessionId).jsonl"
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            return url
        }
        return nil
    }
}

/// Discovers OpenAI Codex CLI sessions from `$CODEX_HOME` (defaults to `~/.codex`) — no hooks
/// exist for Codex, so liveness comes entirely from watching these files: `session_index.jsonl`
/// for the session list, and each rollout file's mtime for freshness (mirroring the Claude
/// thresholds exactly via the shared `SessionStatus.at`).
final class CodexSessionSource: AgentSessionSource {
    let agentName = "Codex"
    let codexHome: URL
    private let sessionsRoot: URL
    private let fileManager: FileManager
    /// Session id -> resolved rollout path. A rollout file never moves once written, so once
    /// found there is no need to re-glob `sessions/**` for it on every poll.
    private var idToRolloutPath: [String: URL] = [:]

    init(codexHome: URL = CodexSessionSource.defaultCodexHome(), fileManager: FileManager = .default) {
        self.codexHome = codexHome
        self.sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        self.fileManager = fileManager
    }

    static func defaultCodexHome() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    func discover(now: Date) -> [DiscoveredSession] {
        let indexURL = codexHome.appendingPathComponent("session_index.jsonl")
        // Sort before resolving rollout paths (the expensive part on a cache miss) so a huge
        // history file never costs more than the ~10 sessions we can actually show; the small
        // buffer above 10 absorbs entries whose rollout is missing/corrupt or has gone stale.
        let candidates = CodexSessionIndex.load(at: indexURL)
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(20)

        var discovered: [DiscoveredSession] = []
        for candidate in candidates {
            guard let rolloutURL = rolloutPath(forSessionId: candidate.id),
                  let meta = CodexRolloutMeta.firstLineSessionMeta(at: rolloutURL),
                  let values = try? rolloutURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  let status = SessionStatus.at(modifiedAt: modifiedAt, now: now) else { continue }

            discovered.append(DiscoveredSession(
                sessionId: candidate.id,
                agentName: agentName,
                cwd: meta.cwd,
                title: SessionTitle.resolveCodex(threadName: candidate.threadName, cwd: meta.cwd),
                lastActivity: modifiedAt,
                status: status,
                resumeCommand: Jumper.codexResumeCommand(sessionId: candidate.id),
                sessionFileURL: nil
            ))
        }
        return Array(discovered.prefix(10))
    }

    private func rolloutPath(forSessionId id: String) -> URL? {
        if let cached = idToRolloutPath[id], fileManager.fileExists(atPath: cached.path) {
            return cached
        }
        guard let located = CodexRolloutLocator.locate(
            sessionId: id,
            under: sessionsRoot,
            fileManager: fileManager
        ) else { return nil }
        idToRolloutPath[id] = located
        return located
    }
}
