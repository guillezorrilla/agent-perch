import Foundation

/// A live agent CLI process that is, on its own, proof of a session the user is sitting in.
///
/// Codex and `agy` write no hooks, so until now the only evidence this app had that either was
/// running was a transcript file on disk — which is evidence of the WRONG thing. A transcript is a
/// record of writes, not of sessions: `agy` writes several logs per run and leaves the old ones
/// behind (so one session read as four), while a Codex session the user is actively sitting in but
/// hasn't prompted for an hour stops being written to entirely (so a live session read as none).
/// The process table answers the question directly, and a controlling terminal is what separates
/// the user's own session from everything else running under the same binary name (#33).
struct LiveAgentProcess: Equatable, Sendable {
    let agentName: String
    let pid: Int32
    /// The full command line, kept so a `codex resume <id>` launch can still be matched to the
    /// exact transcript it names rather than merely the newest one at this cwd.
    let command: String
    /// Canonical (see `CanonicalPath`) — one spelling, so a transcript's own recorded cwd and
    /// `lsof`'s resolved one compare equal.
    let cwd: String
    /// Always a real `ttys*` device; a process without a controlling terminal never becomes one
    /// of these.
    let tty: String
    /// When the process was launched — the honest `lastActivity` for a session no transcript could
    /// be matched to. `nil` when `ps` didn't report it.
    let startedAt: Date?
}

/// Turns one already-taken process listing into the hookless sessions it proves exist.
///
/// Deliberately pure and synchronous: the listing comes from the shared `ProcessTableCache`
/// snapshot every source and every click already share (#23), so first-class process discovery
/// costs no additional subprocess call at all.
enum LiveAgentScan {
    /// Executable BASENAME -> agent, and the script markers for agents the basename lookup
    /// cannot see. Both derived from `AgentRegistry` rather than restated: an agent missing from
    /// here was invisible, with no row and no error, and nothing tied this table to the four
    /// others keyed on the same name.
    static var agentsByExecutableName: [String: String] { AgentRegistry.agentsByExecutableName }

    static var agentsByScriptMarker: [(marker: String, agentName: String)] {
        AgentRegistry.agentsByScriptMarker
    }

    /// Lowercased command-line markers that mean "this is not a user's CLI session" even though
    /// the executable's basename matches an agent exactly.
    ///
    /// ChatGPT.app ships a binary literally named `codex` and runs it as an internal `app-server`
    /// (pid 21321 on the machine this was diagnosed against), plus a `Codex Framework.framework`
    /// full of helpers; Antigravity's Electron IDE ships its own bundle the same way. None of them
    /// is a session, and one of them was showing up as a row titled `/`.
    ///
    /// `.app/contents/` is the general form of the four bundle markers beside it, and it earns its
    /// place: this machine also runs `~/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/
    /// SkyComputerUseService`, whose path contains a SPACE, so splitting the command line on
    /// whitespace hands the basename check the word `Codex` and it matches. Nothing a user launches
    /// from a terminal lives inside an application bundle's `Contents`.
    static let rejectedCommandMarkers = [
        "chatgpt.app",
        "codex framework.framework",
        "antigravity ide.app",
        "antigravity.app",
        ".app/contents/",
        "app-server"
    ]

    /// A controlling terminal named `ttys*` is what a user's own interactive session has and what
    /// a background or agent-spawned one lacks (`ps` prints `??` for those). `TTYResolver` already
    /// drops `??` on the way in, but this must reject it independently: an injected listing —
    /// a test's, or some future caller's — has never been through that filter.
    static func sessionTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "??" else { return nil }
        let device = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        return device.hasPrefix("ttys") ? device : nil
    }

    /// The agent this command line runs, or `nil` when it runs none of them.
    ///
    /// Path rejection happens FIRST, because it is the only check that can tell
    /// `/Applications/ChatGPT.app/Contents/Resources/codex` from `/opt/homebrew/bin/codex` — both
    /// have the basename `codex`, and both really are the same product's binary.
    static func agentName(forCommand command: String) -> String? {
        let lowercased = command.lowercased()
        guard !rejectedCommandMarkers.contains(where: lowercased.contains) else { return nil }
        let tokens = lowercased.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        let executable = tokens.first.map(String.init) ?? ""
        if let agentName = agentsByExecutableName[URL(fileURLWithPath: executable).lastPathComponent] {
            return agentName
        }
        // Only the INSTALL-PATH markers apply to argv[1], never the basename map: `claude
        // /Users/me/agy` would otherwise read as an Antigravity session on the strength of an
        // argument that merely happens to end in an agent's name.
        guard let script = tokens.dropFirst().first.map(String.init) else { return nil }
        return agentsByScriptMarker.first { script.contains($0.marker) }?.agentName
    }

    /// Every hookless session the listing proves exists, one per `(agent, canonical cwd, tty)`.
    ///
    /// Deduplicated on that key because a single terminal can hold more than one process of the
    /// same agent (a wrapper and the binary it exec'd, say) and they are one session, not two.
    /// The lowest pid wins that tie — the outermost process, the one whose ancestry walk reaches
    /// the terminal app soonest.
    static func liveSessions(in processes: [ClaudeProcess]) -> [LiveAgentProcess] {
        var seen: Set<String> = []
        var sessions: [LiveAgentProcess] = []
        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            guard let agentName = agentName(forCommand: process.command),
                  let tty = sessionTTY(process.tty) else { continue }
            let cwd = CanonicalPath.canonical(process.cwd)
            // The filesystem root is what a process with no meaningful working directory reports,
            // never a folder anybody works in — and a row titled `/` is one of the exact symptoms
            // this scan exists to remove.
            guard !cwd.isEmpty, cwd != "/" else { continue }
            guard seen.insert("\(agentName)\u{0}\(cwd)\u{0}\(tty)").inserted else { continue }
            sessions.append(LiveAgentProcess(
                agentName: agentName,
                pid: process.pid,
                command: process.command,
                cwd: cwd,
                tty: tty,
                startedAt: process.startedAt
            ))
        }
        return sessions
    }
}

/// The visibility and status rules for an agent with no hooks (Codex, `agy`).
///
/// Two separate questions that used to be answered by one signal:
///
/// - IS there a session? A live process on a `ttys*` says yes, whatever its transcript's mtime.
///   The 60-minute freshness threshold only ever applied because a transcript was all we had; it
///   belongs to sessions with NO live process, which represent recently-finished work worth
///   keeping on screen for a while. Applying it to a live session is what hid a Codex session the
///   user was sitting in whose rollout happened to be 71 minutes old (#33).
/// - Is it WORKING? Only a recent transcript write suggests that, and even then only weakly — a
///   TUI parked at an idle prompt keeps its process alive indefinitely (#31). So a live-but-quiet
///   session is `.idle`, never `.active`, and `supportsLiveStatus: false` keeps even `.active`
///   from rendering as "Working…".
enum HooklessLiveness {
    /// A transcript is appended continuously while a turn is in flight, so a write inside this
    /// window is the closest thing to an "is something happening" signal a hookless CLI offers.
    static let activeWriteWindow: TimeInterval = 90.0

    /// The status of a session with a LIVE process: never hidden, and never better than `.idle`
    /// unless a transcript write backs it up. `nil` `lastWriteAt` means no transcript was matched
    /// at all, which is a perfectly ordinary quiet session — not a reason to hide it.
    static func liveStatus(lastWriteAt: Date?, now: Date) -> SessionStatus {
        guard let lastWriteAt, now.timeIntervalSince(lastWriteAt) < activeWriteWindow else { return .idle }
        return .active
    }
}
