import Foundation

/// Parses `$CODEX_HOME/session_index.jsonl` — one JSON object per line, newest sessions
/// appended last: `{"id":"...","thread_name":"...","updated_at":"<ISO8601 w/ fractional secs>"}`.
///
/// This index only ever records sessions Codex itself spawned on someone's behalf (an IDE
/// integration, another agent's delegation, Codex's own sub-agent threads) — never a real
/// interactive `codex` session (issue #24). `CodexSessionSource` therefore no longer treats it
/// as the list of sessions to show; it's kept around purely as an optional `thread_name` source
/// for titles, via `threadNamesByID`.
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

    /// `session id -> thread_name`, for sessions that have both. A missing entry (every real
    /// interactive session, per issue #24) is completely normal, not an error.
    static func threadNamesByID(at url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for entry in load(at: url) {
            guard let threadName = entry.threadName else { continue }
            result[entry.id] = threadName
        }
        return result
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

/// Converts a `JSONSerialization` tree (`String`, `NSNumber`, `Bool`, `[String: Any]`,
/// `[Any]`, `NSNull`) into a `JSONValue`, so a rollout's arbitrarily-shaped `source` field
/// (a plain string for an ordinary session, an object for a sub-agent one) can be classified
/// by `CodexSessionOrigin` without the parser needing to know its shape up front.
extension JSONValue {
    /// `Bool` must be tested before `NSNumber`: on Darwin, a JSON `true`/`false` bridges to
    /// `Any` as an `NSNumber` that ALSO satisfies `as? Bool`, so testing `NSNumber` first would
    /// silently turn every boolean into `1.0`/`0.0`.
    init(jsonSerialized value: Any) {
        switch value {
        case let value as Bool: self = .bool(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as String: self = .string(value)
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(jsonSerialized: $0) })
        case let value as [Any]: self = .array(value.map { JSONValue(jsonSerialized: $0) })
        default: self = .null
        }
    }
}

/// Parses the first line of a Codex rollout file — a `session_meta` record carrying the
/// session's authoritative `cwd`, plus the `originator`/`source` fields `CodexSessionOrigin`
/// needs to tell a real interactive session apart from one Codex spawned itself.
enum CodexRolloutMeta {
    struct SessionMeta: Equatable, Sendable {
        let sessionId: String
        let cwd: String
        let originator: String?
        let source: JSONValue?
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
        let originator = payload["originator"] as? String
        let source = payload["source"].map { JSONValue(jsonSerialized: $0) }
        return SessionMeta(sessionId: sessionId, cwd: cwd, originator: originator, source: source)
    }
}

/// How Codex itself classifies a rollout's `session_meta`, mirroring three shapes observed live
/// on real `$CODEX_HOME/sessions` data (issue #24):
///
/// - the user's own interactive session: `originator == "codex-tui"`, `source == "cli"`
/// - one spawned on their behalf by another agent/IDE: e.g. `originator == "Claude Code"`,
///   `source == "vscode"`
/// - one Codex spawned as its own internal sub-agent thread: `originator == "codex-tui"`,
///   `source` is an OBJECT (`{"subagent": {...}}`) rather than a string
///
/// Anything this hasn't seen before — an unrecognized originator, a missing field, a `source`
/// shape that's neither a string nor an object — defaults to `.agentSpawned`, never
/// `.interactive`: surfacing something that can't positively be identified as the user's own
/// session is exactly the bug this classifier exists to prevent.
enum CodexSessionOrigin: Equatable, Sendable {
    case interactive
    case agentSpawned
    case subagent

    static func classify(originator: String?, source: JSONValue?) -> CodexSessionOrigin {
        // A subagent's `source` is an object regardless of originator — checked first since
        // it's the only shape distinguishable by `source`'s TYPE rather than its string value.
        if case .object = source {
            return .subagent
        }
        if originator == "codex-tui", source?.string == "cli" {
            return .interactive
        }
        return .agentSpawned
    }
}

/// Bounded discovery of rollout files under `$CODEX_HOME/sessions/YYYY/MM/DD/`. A full
/// recursive walk of `sessions/**` costs one stat per rollout a power user has ever written —
/// years of Codex usage can mean tens of thousands. A session can only be `.active`/`.idle`
/// (see `CodexLiveness`) if it was touched within the last hour, so today's and yesterday's
/// date directories (named for `now`, not file mtime — a session started yesterday and still
/// open today lives in yesterday's folder) already cover everything that could possibly
/// matter; the newest-N-directories fallback only exists for the rare miss (e.g. the guessed
/// dates don't exist yet, or the local clock and the directory names disagree about "today").
enum CodexRolloutDiscovery {
    static func candidateFiles(
        sessionsRoot: URL,
        now: Date,
        fileManager: FileManager,
        maxFiles: Int = 30,
        fallbackDayDirectoryCount: Int = 7
    ) -> [URL] {
        let dayDirectories = recentDayDirectories(
            sessionsRoot: sessionsRoot,
            now: now,
            fileManager: fileManager,
            fallbackCount: fallbackDayDirectoryCount
        )
        let files = dayDirectories.flatMap { rolloutFiles(in: $0, fileManager: fileManager) }
        return files
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            .prefix(maxFiles)
            .map { $0 }
    }

    static func dayDirectoryPath(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func recentDayDirectories(
        sessionsRoot: URL,
        now: Date,
        fileManager: FileManager,
        fallbackCount: Int
    ) -> [URL] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let direct = [today, yesterday].compactMap { date -> URL? in
            let url = sessionsRoot.appendingPathComponent(
                dayDirectoryPath(for: date, calendar: calendar),
                isDirectory: true
            )
            return isDirectory(url, fileManager: fileManager) ? url : nil
        }
        guard direct.isEmpty else { return direct }

        return allDayDirectories(sessionsRoot: sessionsRoot, fileManager: fileManager)
            .sorted { $0.path > $1.path }
            .prefix(fallbackCount)
            .map { $0 }
    }

    /// Only three directory listings deep (year, then month, then day) — never a full
    /// recursive walk of the tree.
    private static func allDayDirectories(sessionsRoot: URL, fileManager: FileManager) -> [URL] {
        let years = subdirectories(of: sessionsRoot, fileManager: fileManager)
        let months = years.flatMap { subdirectories(of: $0, fileManager: fileManager) }
        return months.flatMap { subdirectories(of: $0, fileManager: fileManager) }
    }

    private static func subdirectories(of url: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func rolloutFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl"
        }
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var flag: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}

/// Codex has no hooks, so unlike Claude a stale rollout mtime alone cannot tell a session
/// that's still running from one whose terminal was simply left open — `.active` needs an
/// actual matching live process. `SessionStatus.at`'s mtime thresholds still gate `.idle` vs.
/// hidden; they just can no longer promote a session to `.active` on their own.
enum CodexLiveness {
    static func status(
        sessionId: String,
        cwd: String,
        modifiedAt: Date,
        now: Date,
        processes: [ClaudeProcess]
    ) -> SessionStatus? {
        if hasLiveProcess(sessionId: sessionId, cwd: cwd, processes: processes) {
            return .active
        }
        guard now.timeIntervalSince(modifiedAt) < 60 * 60.0 else { return nil }
        return .idle
    }

    /// A live, ordinary `codex` process at this session's cwd counts — UNLESS its command line
    /// explicitly resumes a DIFFERENT session (`codex resume <other-id>`, the form `Jumper`
    /// itself launches), the only way two Codex sessions sharing a cwd could otherwise be
    /// confused for each other. A bare interactive launch carries no id at all, so it always
    /// counts.
    static func hasLiveProcess(sessionId: String, cwd: String, processes: [ClaudeProcess]) -> Bool {
        processes.contains {
            TTYResolver.isCodexCLI(command: $0.command)
                && $0.cwd == cwd
                && !namesADifferentSession(sessionId: sessionId, command: $0.command)
        }
    }

    private static func namesADifferentSession(sessionId: String, command: String) -> Bool {
        guard let range = command.range(of: "resume ") else { return false }
        let token = command[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first.map(String.init) ?? ""
        return !token.isEmpty && token != sessionId
    }
}

/// Discovers OpenAI Codex CLI sessions from `$CODEX_HOME` (defaults to `~/.codex`).
///
/// - Membership: enumerate rollout files directly (bounded, see `CodexRolloutDiscovery`), not
///   `session_index.jsonl` — that index only records sessions Codex spawned on someone else's
///   behalf, never a real interactive one (issue #24), so treating it as the source of truth
///   both hid the user's own sessions and surfaced ones that were never theirs. Each
///   candidate's first-line `session_meta` is classified by `CodexSessionOrigin.classify`; only
///   `.interactive` sessions show by default, and `showSubAgentSessions` additionally reveals
///   `.agentSpawned`/`.subagent` ones.
/// - Liveness: `.active` requires an actual live process match (`CodexLiveness`); mtime alone
///   only gates `.idle` vs. hidden, mirroring the Claude thresholds via the shared
///   `SessionStatus.at`.
///
/// `session_index.jsonl` is kept around ONLY as an optional `thread_name` source for titles.
final class CodexSessionSource: AgentSessionSource {
    let agentName = "Codex"
    let codexHome: URL
    private let sessionsRoot: URL
    private let fileManager: FileManager
    private let processProvider: () -> [ClaudeProcess]
    private let showSubAgentSessions: () -> Bool

    init(
        codexHome: URL = CodexSessionSource.defaultCodexHome(),
        fileManager: FileManager = .default,
        processProvider: @escaping () -> [ClaudeProcess] = { TTYResolver().processes() },
        showSubAgentSessions: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: "showSubAgentSessions")
        }
    ) {
        self.codexHome = codexHome
        self.sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        self.fileManager = fileManager
        self.processProvider = processProvider
        self.showSubAgentSessions = showSubAgentSessions
    }

    static func defaultCodexHome() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    func discover(now: Date) -> [DiscoveredSession] {
        let files = CodexRolloutDiscovery.candidateFiles(
            sessionsRoot: sessionsRoot,
            now: now,
            fileManager: fileManager
        )
        guard !files.isEmpty else { return [] }

        let includeSubAgentSessions = showSubAgentSessions()
        let threadNames = CodexSessionIndex.threadNamesByID(
            at: codexHome.appendingPathComponent("session_index.jsonl")
        )
        let processes = processProvider()

        var discovered: [DiscoveredSession] = []
        for file in files {
            guard let meta = CodexRolloutMeta.firstLineSessionMeta(at: file),
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate else { continue }

            let origin = CodexSessionOrigin.classify(originator: meta.originator, source: meta.source)
            guard origin == .interactive || includeSubAgentSessions else { continue }

            guard let status = CodexLiveness.status(
                sessionId: meta.sessionId,
                cwd: meta.cwd,
                modifiedAt: modifiedAt,
                now: now,
                processes: processes
            ) else { continue }

            discovered.append(DiscoveredSession(
                sessionId: meta.sessionId,
                agentName: agentName,
                cwd: meta.cwd,
                title: SessionTitle.resolveCodex(threadName: threadNames[meta.sessionId], cwd: meta.cwd),
                lastActivity: modifiedAt,
                status: status,
                resumeCommand: Jumper.codexResumeCommand(sessionId: meta.sessionId),
                sessionFileURL: nil
            ))
        }
        return Array(discovered.prefix(10))
    }
}
