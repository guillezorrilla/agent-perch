import AppKit

enum JumpRung: Equatable, Sendable {
    case exactFocus(tty: String)
    case newTab

    var isExact: Bool {
        if case .exactFocus = self { return true }
        return false
    }
}

final class Jumper {
    private let resolver = TTYResolver()
    private let terminalResolver = TerminalNameResolver()
    private let appleScript = AppleScriptRunner()
    private let warpTabLocator = WarpTabLocator()
    private let warpFocuser = WarpFocuser()

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
        preferredTTY: String?,
        processes: [ClaudeProcess]
    ) -> JumpRung {
        if let preferredTTY, !preferredTTY.isEmpty, preferredTTY != "??" {
            return .exactFocus(tty: preferredTTY)
        }
        if let tty = TTYResolver.tty(for: cwd, in: processes) {
            return .exactFocus(tty: tty)
        }
        return .newTab
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
    func jump(_ session: AgentSession) -> Bool {
        let processes = resolver.processes()
        let match = processes.first {
            TTYResolver.isClaudeCLI(command: $0.command)
                && $0.cwd == session.cwd
                && $0.tty?.isEmpty == false
                && $0.tty != "??"
        }
        // Prefer the terminal the session actually runs in: hook-provided name, else
        // resolve it by walking the live claude process's ancestry.
        let terminal = (session.terminalName
            ?? match.flatMap { terminalResolver.terminalName(for: $0.pid) })?.lowercased()

        if terminal == "warp" {
            return Self.routeWarpJump(
                cwd: session.cwd,
                locate: { warpTabLocator.tabIndex(forCwd: $0) },
                focus: { warpFocuser.focus(tabIndex: $0) },
                fallback: { openNewTab(at: session.cwd, preferring: terminal) }
            )
        }

        // Hook tty, else live claude tty, else any shell still sitting at the cwd —
        // the user's open tab after the agent exited (#10).
        let tty = (session.tty?.isEmpty == false ? session.tty : nil)
            ?? match?.tty
            ?? resolver.shellTTY(at: session.cwd)
        if let tty, tty != "??", Self.canExactFocus(terminal), focus(tty: tty) {
            return true
        }
        return openNewTab(at: session.cwd, preferring: terminal)
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
    static func newTabShellCommand(cwd: String) -> String {
        let inner = "cd -- \(AppleScriptRunner.shellQuote(cwd)); exec \"${SHELL:-/bin/zsh}\" -l"
        return "/bin/zsh -lc \(AppleScriptRunner.shellQuote(inner))"
    }

    @MainActor
    private func openNewTab(at cwd: String, preferring terminal: String?) -> Bool {
        let command = AppleScriptRunner.stringLiteral(
            "cd -- \(AppleScriptRunner.shellQuote(cwd)); exec \"${SHELL:-/bin/zsh}\" -l"
        )
        let shellWrapped = AppleScriptRunner.stringLiteral(Self.newTabShellCommand(cwd: cwd))

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
