import AppKit
import os

enum JumpRung: Equatable, Sendable {
    case exactFocus(tty: String)
    case newTab

    var isExact: Bool {
        if case .exactFocus = self { return true }
        return false
    }
}

/// Two halves: work out where the session lives (slow, off the main actor), then focus it (fast,
/// necessarily on the main actor — AppleScript and `CGEvent` posting are main-thread APIs).
///
/// `@unchecked Sendable` because that split is the invariant: `resolver`, `terminalResolver` and
/// `warpTabLocator` are touched only from `discoveryQueue`, `appleScript` and `warpFocuser` only
/// from the main actor, and `processes` is thread-safe in its own right.
final class Jumper: @unchecked Sendable {
    private let resolver = TTYResolver()
    private let terminalResolver = TerminalNameResolver()
    private let appleScript = AppleScriptRunner()
    private let warpTabLocator = WarpTabLocator()
    private let warpFocuser = WarpFocuser()
    private let processes: ProcessTableCache
    /// Serial: two rapid clicks resolve one after the other rather than scanning on top of each
    /// other, which also keeps `terminalResolver`'s ancestry cache single-threaded.
    private let discoveryQueue = DispatchQueue(
        label: "dev.vibenotch.jump.discovery",
        qos: .userInitiated
    )
    private static let log = Logger(subsystem: "dev.vibenotch", category: "jump")

    init(processes: ProcessTableCache = .shared) {
        self.processes = processes
    }

    // Only iTerm2 and Terminal.app expose per-tab tty for exact focus. Warp uses its
    // state database below; anything else can only be reopened at the cwd.
    static func canExactFocus(_ terminal: String?) -> Bool {
        switch terminal {
        case nil, "iterm", "iterm2", "terminal", "terminal.app": return true
        default: return false
        }
    }

    // Reopen candidates, preferred terminal first so a session's own terminal wins.
    static func openerOrder(preferring terminal: String?) -> [String] {
        let defaults = ["iterm", "terminal", "warp"]
        guard let terminal else { return defaults }
        let key = terminal == "iterm2" ? "iterm" : (terminal == "terminal.app" ? "terminal" : terminal)
        guard defaults.contains(key) else { return defaults }
        return [key] + defaults.filter { $0 != key }
    }

    static func rung(for cwd: String, processes: [ClaudeProcess]) -> JumpRung {
        rung(for: cwd, preferredTTY: nil, processes: processes)
    }

    static func rung(
        for cwd: String,
        preferredTTY: String? = nil,
        agentName: String = "Claude",
        processes: [ClaudeProcess]
    ) -> JumpRung {
        rung(for: JumpTarget.resolve(
            agentName: agentName,
            sessionId: "",
            tty: preferredTTY,
            cwd: cwd,
            processes: processes
        ))
    }

    static func rung(for target: JumpTarget) -> JumpRung {
        target.tty.map { JumpRung.exactFocus(tty: $0) } ?? .newTab
    }

    /// `codex resume <id>` — Codex's reopen command when no live process is found for the
    /// session. The id is always a UUID today, but shell-quoting it keeps the composed
    /// command safe regardless.
    static func codexResumeCommand(sessionId: String) -> String {
        "codex resume \(AppleScriptRunner.shellQuote(sessionId))"
    }

    static func routeWarpJump(
        cwd: String,
        locate: (String) -> Int?,
        focus: (Int) -> Bool,
        fallback: () -> Bool
    ) -> Bool {
        guard let index = locate(cwd), focus(index) else { return fallback() }
        return true
    }

    @MainActor
    @discardableResult
    func jump(_ session: AgentSession) async -> Bool {
        perform(await plan(for: session))
    }

    /// Everything a jump has to find out — the process table, the terminal's identity, Warp's tab
    /// index — resolved off the main actor. This used to run inline on a click, `lsof` by `lsof`,
    /// with the UI frozen for the duration (#23).
    private func plan(for session: AgentSession) async -> JumpPlan {
        await withCheckedContinuation { continuation in
            discoveryQueue.async {
                continuation.resume(returning: self.resolvePlan(for: session))
            }
        }
    }

    private func resolvePlan(for session: AgentSession) -> JumpPlan {
        // A GUI workspace, not a terminal — none of the tty/Warp/cmux machinery below applies,
        // and running it anyway risks matching an unrelated terminal process that merely shares
        // this workspace's cwd (#3). A real `agy` CLI session (same `agentName`, different
        // `sessionId` prefix — see `AgentSession.isAntigravityWorkspace`) falls through to the
        // normal ladder below exactly like Claude/Codex (#29).
        if session.isAntigravityWorkspace {
            return JumpPlan(
                target: .openAntigravity(path: session.cwd, agyAvailable: session.resumeCommand != nil),
                cwd: session.cwd,
                terminal: nil,
                resumeCommand: session.resumeCommand
            )
        }

        let table = processes.processes()
        let target = JumpTarget.resolve(session: session, processes: table)
        if target.isAmbiguous {
            // Deterministic, but still a guess between real alternatives — say so rather than
            // let a wrong tab look like a bug with no explanation (#23).
            let message = """
                \(session.sessionId) at \(session.cwd): \(target.candidates.count) agent \
                processes \(target.candidates) share this cwd and none names the session; \
                chose pid \(target.pid ?? -1)
                """
            Self.log.debug("ambiguous jump target — \(message, privacy: .public)")
        }

        // Prefer the terminal the session actually runs in: hook-provided name, else resolve it
        // by walking the identified agent process's ancestry.
        let terminal = (session.terminalName
            ?? target.pid.flatMap { terminalResolver.terminalName(for: $0) })?.lowercased()

        if terminal == "warp" {
            // Re-read the tab index NOW rather than reusing a copy of Warp's database from a few
            // seconds ago: a tab opened since that copy was taken is not in it at all, and the
            // jump would land on a stale index or fall through to a duplicate tab (#23). A
            // refusal by the container is still remembered for the launch, so this never
            // re-prompts.
            guard let index = warpTabLocator.tabIndex(forCwd: session.cwd, reusingRecentCopy: false) else {
                return .newTab(cwd: session.cwd, terminal: terminal, resumeCommand: session.resumeCommand)
            }
            return JumpPlan(
                target: .warpTab(index),
                cwd: session.cwd,
                terminal: terminal,
                resumeCommand: session.resumeCommand
            )
        }

        // Same shape as Warp above, but there is no sqlite database or URL scheme to ask — only
        // a best-effort CLI focus attempt (cached, see `CmuxLauncher`), off the main actor right
        // here since it may spawn `cmux --help` and wait for it to exit.
        if terminal == "cmux", CmuxLauncher.attemptFocus(cwd: session.cwd) {
            return JumpPlan(target: .alreadyFocused, cwd: session.cwd, terminal: terminal, resumeCommand: session.resumeCommand)
        }

        // The session's own tty, else the tty of the process identified for it, else any shell
        // still sitting at the cwd — the user's open tab after the agent exited (#10). That last
        // one is the most expensive call we make and only iTerm/Terminal can use its answer, so
        // it is never made for a terminal that cannot be focused by tty.
        let tty = target.tty ?? (Self.canExactFocus(terminal) ? resolver.shellTTY(at: session.cwd) : nil)
        guard let tty, Self.canExactFocus(terminal) else {
            return .newTab(cwd: session.cwd, terminal: terminal, resumeCommand: session.resumeCommand)
        }
        return JumpPlan(
            target: .focusTTY(tty),
            cwd: session.cwd,
            terminal: terminal,
            resumeCommand: session.resumeCommand
        )
    }

    /// The main-actor half: one AppleScript or one keystroke, with the same fallback to a new tab
    /// the ladder always had when the tab it was told about turns out not to be there.
    @MainActor
    private func perform(_ plan: JumpPlan) -> Bool {
        switch plan.target {
        case let .focusTTY(tty):
            if focus(tty: tty) { return true }
        case let .warpTab(index):
            return Self.routeWarpJump(
                cwd: plan.cwd,
                // Already located off the main actor, moments ago.
                locate: { _ in index },
                focus: { warpFocuser.focus(tabIndex: $0) },
                fallback: { openNewTab(at: plan.cwd, preferring: plan.terminal, resumeCommand: plan.resumeCommand) }
            )
        case let .openAntigravity(path, agyAvailable):
            let (executable, arguments) = Self.antigravityLaunchCommand(path: path, agyAvailable: agyAvailable)
            return Self.runDetached(executable, arguments)
        case .alreadyFocused:
            return true
        case .newTab:
            break
        }
        return openNewTab(at: plan.cwd, preferring: plan.terminal, resumeCommand: plan.resumeCommand)
    }

    /// `agy` (if on PATH) launches through the user's shell env exactly like a terminal command
    /// would; otherwise `open -a` asks LaunchServices for "Antigravity IDE" directly. Either one
    /// re-focuses an already-open window on this folder rather than spawning a second one — the
    /// same way opening a path macOS already has open in an app just brings it forward.
    static func antigravityLaunchCommand(path: String, agyAvailable: Bool) -> (executable: String, arguments: [String]) {
        agyAvailable
            ? ("/usr/bin/env", ["agy", path])
            : ("/usr/bin/open", ["-a", "Antigravity IDE", path])
    }

    /// Fire-and-forget: doesn't wait for the launched app to actually finish opening, matching
    /// every other opener above (the AppleScript `create window`/`do script` calls don't wait for
    /// the terminal to finish drawing either) — only whether the launch itself was accepted.
    @discardableResult
    private static func runDetached(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }

    @MainActor
    private func focus(tty: String) -> Bool {
        let target = AppleScriptRunner.stringLiteral("/dev/\(tty)")

        if isInstalled("com.googlecode.iterm2"), appleScript.run("""
            tell application id "com.googlecode.iterm2"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if tty of aSession is "\(target)" then
                                tell aWindow to select
                                tell aTab to select
                                tell aSession to select
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """) {
            return true
        }

        if isInstalled("com.apple.Terminal"), appleScript.run("""
            tell application "Terminal"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        if tty of aTab is "\(target)" then
                            set selected tab of aWindow to aTab
                            set index of aWindow to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """) {
            return true
        }

        return false
    }

    // iTerm's `command` parameter execs WITHOUT a shell — `cd x; exec y` word-splits and
    // dies (#10). Wrap it in an explicit shell; Terminal.app's `do script` already types
    // into a shell, so it takes the inner command as-is.
    static func newTabShellCommand(cwd: String, resumeCommand: String? = nil) -> String {
        "/bin/zsh -lc \(AppleScriptRunner.shellQuote(Self.newTabInnerCommand(cwd: cwd, resumeCommand: resumeCommand)))"
    }

    /// `resumeCommand` (e.g. `codex resume <id>`) replaces the plain login-shell relaunch when
    /// the session's own agent knows how to reopen itself; `nil` (Claude, today) keeps the
    /// original "just drop me at the cwd" behavior byte-identical.
    private static func newTabInnerCommand(cwd: String, resumeCommand: String?) -> String {
        let launch = resumeCommand ?? "exec \"${SHELL:-/bin/zsh}\" -l"
        return "cd -- \(AppleScriptRunner.shellQuote(cwd)); \(launch)"
    }

    @MainActor
    private func openNewTab(at cwd: String, preferring terminal: String?, resumeCommand: String? = nil) -> Bool {
        let command = AppleScriptRunner.stringLiteral(
            Self.newTabInnerCommand(cwd: cwd, resumeCommand: resumeCommand)
        )
        let shellWrapped = AppleScriptRunner.stringLiteral(
            Self.newTabShellCommand(cwd: cwd, resumeCommand: resumeCommand)
        )

        for opener in Self.openerOrder(preferring: terminal) {
            switch opener {
            case "iterm":
                if isInstalled("com.googlecode.iterm2"), appleScript.run("""
                    tell application id "com.googlecode.iterm2"
                        create window with default profile command "\(shellWrapped)"
                        activate
                    end tell
                    return true
                    """) {
                    return true
                }
            case "terminal":
                if isInstalled("com.apple.Terminal"), appleScript.run("""
                    tell application "Terminal"
                        do script "\(command)"
                        activate
                    end tell
                    return true
                    """) {
                    return true
                }
            case "warp":
                if isInstalled("dev.warp.Warp-Stable", "dev.warp.Warp") {
                    var components = URLComponents()
                    components.scheme = "warp"
                    components.host = "action"
                    components.path = "/new_tab"
                    components.queryItems = [URLQueryItem(name: "path", value: cwd)]
                    if let url = components.url {
                        NSWorkspace.shared.open(url)
                        return true
                    }
                }
            default:
                break
            }
        }
        return false
    }

    @MainActor
    private func isInstalled(_ bundleIdentifiers: String...) -> Bool {
        bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }
}
