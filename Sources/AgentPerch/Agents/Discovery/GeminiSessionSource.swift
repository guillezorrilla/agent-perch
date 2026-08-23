import Foundation

/// Parses the first line of a Gemini CLI chat file — its header record. Verbatim from a real
/// session on this machine (#11):
///
///     {"sessionId":"3c90ee3d-470e-4a30-8db7-282f0e65f93d",
///      "projectHash":"ddb0e09ea68fd887833fa91386c0919381d08970ed4af2f725f03b6ed70aff8c",
///      "startTime":"2026-06-07T23:59:13.730Z","lastUpdated":"2026-06-07T23:59:13.730Z",
///      "kind":"main"}
///
/// Every later line is either a `{"$set":{"messages":[…]}}` mutation or a bare message record —
/// see `GeminiTranscript`. `projectHash` is deliberately not read: it is `sha256(<project path>)`
/// (proven below) and therefore cannot be turned back into one.
enum GeminiChatHeader {
    /// The one `kind` that means "the user started this session themselves". Only two values occur
    /// across every real chat on this machine (#11) — `main` and `subagent` — and the subagent ones
    /// additionally live in a nested `chats/<parent-session-id>/` directory rather than beside their
    /// parent. Anything else is a value this has never seen, and per the same default-deny rule as
    /// #24 an unrecognized kind is NOT treated as a user session.
    static let userStartedKind = "main"

    struct Header: Equatable, Sendable {
        let sessionId: String
        let kind: String
        /// Workspace roots the header names itself (`"directories":["/Users/…/ciento-app"]`). Only
        /// ever observed on `subagent` headers, but it is the one place a chat file states its own
        /// cwd, so it is read for every kind and used when `.project_root` is missing.
        let directories: [String]

        var isUserStarted: Bool { kind == GeminiChatHeader.userStartedKind }
    }

    /// Reads only enough of the file to get past its first line, rather than loading a
    /// potentially long chat into memory (mirrors `CodexRolloutMeta.firstLineSessionMeta`).
    static func firstLine(at url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { return nil }
        let line = chunk.firstIndex(of: 0x0A).map { chunk[..<$0] } ?? chunk
        return parseLine(Data(line))
    }

    static func parseLine(_ line: Data) -> Header? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty else { return nil }
        let directories = ((object["directories"] as? [Any]) ?? [])
            .compactMap { $0 as? String }
            .filter { $0.hasPrefix("/") }
        return Header(
            sessionId: sessionId,
            // A header with no `kind` at all is not evidence of a user session — the empty string
            // fails `isUserStarted`, which is exactly the default-deny outcome wanted.
            kind: (object["kind"] as? String) ?? "",
            directories: directories
        )
    }
}

/// Resolves the absolute working directory behind a `~/.gemini/tmp/<projectKey>` directory.
///
/// `<projectKey>` is NOT reliably a hash: the real directories on this machine are a readable
/// `ciento-app` sitting next to two 64-hex names. Both forms were probed (#11), and the hex ones
/// are `sha256(<absolute project path>)` — `05d95252d74b…` is byte-for-byte
/// `sha256("/Users/…/Developer/ciento")`, and the header's own `projectHash` is the same function of
/// the same path. sha256 is one-way, so a hash-named directory can never be turned back into a
/// working directory, and no amount of care would make a guess honest.
///
/// That leaves exactly two truthful sources of a cwd: the `.project_root` file written beside
/// `chats/` (holds the absolute path; verified) and the chat header's own `directories`. When
/// neither answers, the session is DROPPED rather than shown — a row with no cwd cannot be jumped
/// to, and a fabricated one would jump somewhere wrong. That is the same call `AntigravityCLILog`
/// already makes for a log with no `workspace` line.
enum GeminiProjectRoot {
    static let markerFileName = ".project_root"

    static func read(projectDirectory: URL) -> String? {
        guard let data = try? Data(contentsOf: projectDirectory.appendingPathComponent(markerFileName)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only an absolute path is a jumpable answer; anything else is as good as no answer.
        return path.hasPrefix("/") ? path : nil
    }
}

/// Pulls the first thing the USER actually typed out of a chat file, for its title.
///
/// Bounded, and read only for chats that already survived every visibility filter — unlike the
/// header, the first real prompt is not at the top of the file. Gemini opens every session with a
/// `<session_context>` block that embeds the workspace's directory tree (19,405 bytes into the real
/// chats measured here), so the prompt after it sits tens of kilobytes in. `promptScanBytes`
/// comfortably clears that on real data while keeping a refresh tick's cost fixed.
enum GeminiTranscript {
    static let promptScanBytes = 262_144

    /// Text Gemini writes into the transcript AS a user message that the user never typed. Both
    /// were observed verbatim (#11): every session opens with a `<session_context>` block, and a
    /// mode switch is recorded as `User has manually exited Plan Mode. …` — which was the ONLY
    /// user-typed-looking text in one real chat, and would have titled it.
    static let machineGeneratedPrompts = ["<session_context>", "User has manually exited "]

    static func firstUserPrompt(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: promptScanBytes), !chunk.isEmpty else { return nil }
        return firstUserPrompt(in: chunk)
    }

    /// A line the bounded read cut in half simply fails to parse and is skipped, exactly like a
    /// genuinely malformed one — no separate truncation handling is needed or wanted.
    static func firstUserPrompt(in data: Data) -> String? {
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            // Messages arrive two ways in the same file: batched inside a `$set` mutation, and
            // later on appended as bare records of their own.
            let messages = ((object["$set"] as? [String: Any])?["messages"] as? [Any]) ?? [object]
            for message in messages.compactMap({ $0 as? [String: Any] }) {
                guard message["type"] as? String == "user",
                      let text = userText(in: message["content"]) else { continue }
                return text
            }
        }
        return nil
    }

    /// `content` is an array of `{"text": …}` parts on real data, but a bare string is cheap
    /// enough to accept too. `nil` for anything empty or machine-generated, so the caller keeps
    /// looking rather than titling the session with Gemini's own preamble.
    private static func userText(in content: Any?) -> String? {
        let joined: String
        switch content {
        case let text as String:
            joined = text
        case let parts as [Any]:
            joined = parts
                .compactMap { ($0 as? [String: Any])?["text"] as? String }
                .joined(separator: " ")
        default:
            return nil
        }
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !machineGeneratedPrompts.contains(where: trimmed.hasPrefix) else { return nil }
        return trimmed
    }
}

/// Bounded discovery of `~/.gemini/tmp/<projectKey>/chats/session-*.jsonl`.
///
/// Two directory listings deep — the project keys, then each one's `chats/` — and never recursive.
/// Non-recursive is also what excludes sub-agent chats structurally: they live one level further
/// down in `chats/<parent-session-id>/<id>.jsonl` and carry no `session-` prefix, so they are never
/// even opened (`GeminiChatHeader.userStartedKind` is the second, explicit guard).
///
/// Freshness is decided by FILE MTIME only. A chat's name embeds the date its session STARTED
/// (`session-2026-06-07T23-22-8f28e924.jsonl`), and Codex taught this repo the hard way that
/// deciding what to look at from such a name hides every session that outlives its own start date
/// (#30) — so the name is never used to bound anything.
enum GeminiChatDiscovery {
    static let sessionFilePrefix = "session-"

    struct Candidate: Equatable {
        let url: URL
        let projectDirectory: URL
        let modifiedAt: Date
    }

    static func candidateFiles(
        tmpRoot: URL,
        fileManager: FileManager,
        maxFiles: Int = 30,
        maxProjectDirectories: Int = 20
    ) -> [Candidate] {
        let projectDirectories = subdirectories(of: tmpRoot, fileManager: fileManager)
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            .prefix(maxProjectDirectories)

        let candidates = projectDirectories.flatMap { projectDirectory -> [Candidate] in
            chatFiles(in: projectDirectory.appendingPathComponent("chats", isDirectory: true), fileManager: fileManager)
                .map { Candidate(url: $0, projectDirectory: projectDirectory, modifiedAt: modificationDate(of: $0)) }
        }
        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .map { $0 }
    }

    private static func chatFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix(sessionFilePrefix) && $0.pathExtension == "jsonl"
        }
    }

    private static func subdirectories(of url: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}

/// The visibility rule for a Gemini chat with NO live process behind it.
///
/// Simpler than `CodexLiveness` on purpose: a chat only reaches this having failed to be claimed by
/// any live `gemini` process, so by construction it is recently-finished work, never something in
/// flight. It is worth a row for an hour — the same window every other hookless source uses — and
/// can never be better than `.idle`.
enum GeminiLiveness {
    static let visibleWindow: TimeInterval = 60 * 60.0

    static func finishedStatus(modifiedAt: Date, now: Date) -> SessionStatus? {
        now.timeIntervalSince(modifiedAt) < visibleWindow ? .idle : nil
    }
}

/// Discovers Google Gemini CLI sessions from the process table first and `~/.gemini/tmp` second,
/// deliberately shaped like `CodexSessionSource` because the two agents answer the same way (#11).
///
/// - Membership, first pass: every live `gemini` process on a `ttys*` (see `LiveAgentScan`). A
///   session the user is sitting in exists whether or not its chat file has been written to lately.
/// - Membership, second pass: chat files with no live process behind them (bounded, see
///   `GeminiChatDiscovery`) — recently-finished work, worth a row for an hour. Only `kind == "main"`
///   chats show by default; `showSubAgentSessions` additionally reveals the rest, matching #24.
/// - cwd: `.project_root`, else the header's own `directories` — and a chat that can supply neither
///   is dropped outright rather than shown with a guessed path (see `GeminiProjectRoot`).
/// - Liveness: `HooklessLiveness` for a live session, `GeminiLiveness` for a chat-only one. Gemini
///   has no hooks, so `supportsLiveStatus` is `false` for both (#31).
final class GeminiSessionSource: AgentSessionSource {
    let agentName = "Gemini"

    /// The `sessionId` prefix for a live session no chat file could be matched to — the process's
    /// own `(tty, cwd)`, which is exactly what identifies it and stays stable across refreshes.
    static let liveSessionIdPrefix = "gemini-live:"

    private let tmpRoot: URL
    private let fileManager: FileManager
    private let processProvider: () -> [ClaudeProcess]
    private let showSubAgentSessions: () -> Bool
    private let resumeCommand: String

    init(
        geminiHome: URL = GeminiSessionSource.defaultGeminiHome(),
        fileManager: FileManager = .default,
        processProvider: @escaping () -> [ClaudeProcess] = { TTYResolver().processes() },
        showSubAgentSessions: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: "showSubAgentSessions")
        },
        resumeCommand: String = GeminiSessionSource.defaultResumeCommand()
    ) {
        self.tmpRoot = geminiHome.appendingPathComponent("tmp", isDirectory: true)
        self.fileManager = fileManager
        self.processProvider = processProvider
        self.showSubAgentSessions = showSubAgentSessions
        self.resumeCommand = resumeCommand
    }

    static func defaultGeminiHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
    }

    /// A BARE relaunch, not a resume — despite what the issue's notes assumed, `gemini --resume`
    /// does not take a session id at all. Its own `--help` reads: `Resume a previous session. Use
    /// "latest" for most recent or index number (e.g. --resume 5)`. An index is positional and
    /// shifts as sessions come and go, so composing one from a session id could only ever reopen
    /// the wrong conversation. Opening `gemini` at the right cwd is the most this can honestly
    /// promise, and the jump ladder prefers the live tty anyway — exactly what `CodexSessionSource`
    /// falls back to when it has no id to resume.
    static func defaultResumeCommand() -> String {
        AgentBinary.firstExecutable(
            named: "gemini",
            in: AgentBinary.standardDirectories(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        ) ?? "gemini"
    }

    /// A chat file reduced to what discovery needs of it, so its header is parsed once whether it
    /// ends up enriching a live session or standing in for a finished one.
    private struct Chat {
        let header: GeminiChatHeader.Header
        let url: URL
        let cwd: String
        /// Canonical (see `CanonicalPath`), so a recorded project root and `lsof`'s resolved cwd
        /// compare equal.
        let canonicalCwd: String
        let modifiedAt: Date
    }

    func discover(now: Date) -> [DiscoveredSession] {
        let liveProcesses = LiveAgentScan.liveSessions(in: processProvider()).filter { $0.agentName == agentName }
        let chats = visibleChats(includeSubAgentSessions: showSubAgentSessions())
        guard !liveProcesses.isEmpty || !chats.isEmpty else { return [] }

        // Live sessions first, and they claim their chats, so the file pass below can never emit a
        // second row for a session already on screen.
        var claimed: Set<String> = []
        let live: [DiscoveredSession] = liveProcesses.map { process in
            let match = chats.first { !claimed.contains($0.header.sessionId) && $0.canonicalCwd == process.cwd }
            if let match { claimed.insert(match.header.sessionId) }
            return DiscoveredSession(
                sessionId: match?.header.sessionId ?? Self.liveSessionId(tty: process.tty, cwd: process.cwd),
                agentName: agentName,
                cwd: match?.cwd ?? process.cwd,
                title: title(for: match, cwd: match?.cwd ?? process.cwd),
                lastActivity: match?.modifiedAt ?? process.startedAt ?? now,
                status: HooklessLiveness.liveStatus(lastWriteAt: match?.modifiedAt, now: now),
                resumeCommand: resumeCommand,
                sessionFileURL: nil,
                // No hooks: `.active` here only ever means "live process + recent write" (#31).
                supportsLiveStatus: false,
                tty: process.tty
            )
        }

        let finished: [DiscoveredSession] = chats.compactMap { chat in
            guard !claimed.contains(chat.header.sessionId),
                  let status = GeminiLiveness.finishedStatus(modifiedAt: chat.modifiedAt, now: now) else {
                return nil
            }
            return DiscoveredSession(
                sessionId: chat.header.sessionId,
                agentName: agentName,
                cwd: chat.cwd,
                title: title(for: chat, cwd: chat.cwd),
                lastActivity: chat.modifiedAt,
                status: status,
                resumeCommand: resumeCommand,
                sessionFileURL: nil,
                supportsLiveStatus: false
            )
        }

        return Array((live + finished).prefix(10))
    }

    /// The bounded chat candidates this user is allowed to see, newest first — header parsed once,
    /// cwd resolved once, and anything that cannot answer either question dropped here rather than
    /// leaking a half-known session into the list.
    private func visibleChats(includeSubAgentSessions: Bool) -> [Chat] {
        // `.project_root` is one small read per PROJECT, not per chat, so a project with a dozen
        // chats still costs a single one.
        var projectRoots: [URL: String?] = [:]

        return GeminiChatDiscovery
            .candidateFiles(tmpRoot: tmpRoot, fileManager: fileManager)
            .compactMap { candidate in
                guard let header = GeminiChatHeader.firstLine(at: candidate.url),
                      header.isUserStarted || includeSubAgentSessions else { return nil }
                let root = projectRoots[candidate.projectDirectory]
                    ?? GeminiProjectRoot.read(projectDirectory: candidate.projectDirectory)
                projectRoots[candidate.projectDirectory] = root
                guard let cwd = root ?? header.directories.first else { return nil }
                return Chat(
                    header: header,
                    url: candidate.url,
                    cwd: cwd,
                    canonicalCwd: CanonicalPath.canonical(cwd),
                    modifiedAt: candidate.modifiedAt
                )
            }
    }

    /// Deliberately called only for chats that are actually being emitted: unlike the header, the
    /// first user prompt is tens of kilobytes into the file (see `GeminiTranscript`), so paying for
    /// it up front for every candidate would multiply a refresh tick's cost for rows nobody sees.
    /// `SessionTitle.resolve` then applies the same prompt-vs-cwd rules every other source uses.
    private func title(for chat: Chat?, cwd: String) -> String {
        SessionTitle.resolve(
            sessionFileURL: nil,
            lastPrompt: chat.flatMap { GeminiTranscript.firstUserPrompt(at: $0.url) },
            cwd: cwd
        )
    }

    private static func liveSessionId(tty: String, cwd: String) -> String {
        "\(liveSessionIdPrefix)\(tty):\(cwd)"
    }
}
