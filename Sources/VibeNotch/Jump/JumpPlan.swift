import Foundation

/// Which terminal a session actually lives in, and how sure we are about it.
///
/// Matching on cwd alone is what sends a jump to the wrong tab: two sessions in one repo share a
/// cwd, and so does every shell the user happens to have open there. Per-session identity is
/// preferred at every step and cwd is the last resort — never the first (#23).
struct JumpTarget: Equatable, Sendable {
    enum Match: String, Equatable, Sendable {
        /// The session's own tty, reported by its hooks from inside the terminal it runs in.
        /// Exact by construction, and re-reported on every hook event, so it cannot go stale.
        case sessionTTY
        /// A live process naming this exact session on its command line (`codex resume <id>`).
        case sessionProcess
        /// The single agent process sitting at the session's cwd.
        case cwd
        /// Several agent processes share the cwd and nothing tells them apart. The most recently
        /// started one wins, deterministically — see `select`.
        case ambiguousCwd
        /// Nothing identifies a live terminal for this session; it can only be reopened.
        case none
    }

    let tty: String?
    let pid: Int32?
    let match: Match
    /// Everything that was in the running when `match == .ambiguousCwd`, so the choice can be
    /// reported rather than silently guessed.
    let candidates: [Int32]

    static let unresolved = JumpTarget(tty: nil, pid: nil, match: .none, candidates: [])

    var isAmbiguous: Bool { match == .ambiguousCwd }

    static func resolve(session: AgentSession, processes: [ClaudeProcess]) -> JumpTarget {
        resolve(
            agentName: session.agentName,
            sessionId: session.sessionId,
            tty: session.tty,
            cwd: session.cwd,
            processes: processes
        )
    }

    static func resolve(
        agentName: String,
        sessionId: String,
        tty: String?,
        cwd: String,
        processes: [ClaudeProcess]
    ) -> JumpTarget {
        // The hook tty outranks every process heuristic: the agent wrote it from inside its own
        // terminal, so it identifies THIS session even when a dozen others share the cwd.
        if let tty = normalized(tty) {
            return JumpTarget(
                tty: tty,
                pid: processes.first { normalized($0.tty) == tty }?.pid,
                match: .sessionTTY,
                candidates: []
            )
        }

        let candidates = processes.filter {
            TTYResolver.isAgentCLI(agentName, command: $0.command)
                && CanonicalPath.equal($0.cwd, cwd)
                && !namesAnotherSession(sessionId: sessionId, command: $0.command)
        }

        // `codex resume <id>` carries the session id, so a process that names this one identifies
        // it as exactly as a tty would.
        if let named = candidates.first(where: { names(sessionId: sessionId, command: $0.command) }) {
            return JumpTarget(
                tty: normalized(named.tty),
                pid: named.pid,
                match: .sessionProcess,
                candidates: []
            )
        }

        guard let chosen = select(from: candidates) else { return .unresolved }
        return JumpTarget(
            tty: normalized(chosen.tty),
            pid: chosen.pid,
            match: candidates.count == 1 ? .cwd : .ambiguousCwd,
            candidates: candidates.count == 1 ? [] : candidates.map(\.pid).sorted()
        )
    }

    /// The tie-break, when nothing but the cwd is known: a process with a terminal beats one
    /// without (jumping somewhere is better than jumping nowhere), then the highest pid — the
    /// most recently started, and the only recency signal a process listing carries without
    /// another subprocess call. Total and deterministic, so the same listing always jumps to the
    /// same place instead of following whatever order `pgrep` happened to print.
    private static func select(from candidates: [ClaudeProcess]) -> ClaudeProcess? {
        candidates.max {
            let left = (normalized($0.tty) != nil, $0.pid)
            let right = (normalized($1.tty) != nil, $1.pid)
            if left.0 != right.0 { return !left.0 }
            return left.1 < right.1
        }
    }

    private static func normalized(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "??" else { return nil }
        return tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    private static func names(sessionId: String, command: String) -> Bool {
        !sessionId.isEmpty && resumedSessionId(in: command) == sessionId
    }

    /// Only ever true when we know which session we're looking for AND the command names a
    /// different one — an id-less interactive launch is never excluded. Shared with
    /// `CodexLiveness`, which asks the same question about the same command lines.
    static func namesAnotherSession(sessionId: String, command: String) -> Bool {
        guard !sessionId.isEmpty, let resumed = resumedSessionId(in: command) else { return false }
        return resumed != sessionId
    }

    private static func resumedSessionId(in command: String) -> String? {
        guard let range = command.range(of: "resume ") else { return nil }
        let token = command[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first
            .map(String.init)
        return token?.isEmpty == false ? token : nil
    }
}

/// A jump reduced to the part that must happen on the main actor. Everything expensive —
/// `pgrep`, `lsof`, `ps`, Warp's sqlite — has already run on `Jumper`'s discovery queue by the
/// time one of these exists, which is why it has to cross back as a `Sendable` value.
struct JumpPlan: Equatable, Sendable {
    /// The two terminals that can only be focused by cwd (#4).
    ///
    /// cmux is a Ghostty fork and its scripting dictionary is identical to Ghostty's in every part
    /// used here — same `terminal` class, same `working directory` property, same top-level
    /// `focus` command — which is why one AppleScript routine drives both instead of two near
    /// copies. They differ in exactly one behavior, below.
    enum CwdFocusApp: String, Equatable, Sendable {
        case ghostty
        case cmux

        var bundleIdentifier: String {
            switch self {
            case .ghostty: return "com.mitchellh.ghostty"
            case .cmux: return "com.cmuxterm.app"
            }
        }

        /// Whether failing to find a matching surface still counts as a handled jump.
        ///
        /// cmux keeps the floor it has had since #3: bring cmux itself to the front. Letting a
        /// miss fall through to `openNewTab` would surface an *iTerm* window instead of the cmux
        /// app the session actually lives in — a regression, not a fallback. Ghostty never had
        /// that floor and reopening at the cwd is a reasonable answer there, so its miss stays a
        /// miss and the existing ladder fires.
        var activatesOnMiss: Bool { self == .cmux }
    }

    enum Target: Equatable, Sendable {
        /// AppleScript-select the iTerm/Terminal tab holding this tty.
        case focusTTY(String)
        /// AppleScript-focus the Ghostty or cmux surface sitting at this cwd. Both expose a
        /// surface's `working directory` and no tty at all, so this is strictly weaker than
        /// `focusTTY` — see `Jumper.focusTerminalByCwd` (#4).
        case focusTerminalByCwd(app: CwdFocusApp, cwd: String)
        /// ⌘-digit Warp's tab, located moments ago so a just-opened tab is included.
        case warpTab(Int)
        /// A GUI workspace, not a terminal — Antigravity has no tty to focus at all. `agy <path>`
        /// when it's on PATH, else `open -a "Antigravity IDE" <path>`; either one re-focuses an
        /// already-open window on this folder rather than spawning a second one.
        case openAntigravity(path: String, agyAvailable: Bool)
        /// Already focused off the main actor — cmux's own CLI subcommand, if one was found, or
        /// (lacking one) plain activation. `perform` only needs to report success.
        case alreadyFocused
        /// Nothing live to focus: reopen at the cwd.
        case newTab
    }

    let target: Target
    let cwd: String
    let terminal: String?
    let resumeCommand: String?

    static func newTab(cwd: String, terminal: String?, resumeCommand: String?) -> JumpPlan {
        JumpPlan(target: .newTab, cwd: cwd, terminal: terminal, resumeCommand: resumeCommand)
    }
}
