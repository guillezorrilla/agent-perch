import Foundation

enum ActionDecision: Equatable, Sendable {
    case allow
    case deny
}

enum InjectionKey: Equatable, Sendable {
    case text(String)
    case escape
}

enum ActionInjectionPlan: Equatable, Sendable {
    case iTerm(tty: String, key: InjectionKey)
    case tmux(tty: String, key: InjectionKey)
    case terminal(tty: String, key: InjectionKey)
}

struct ActionInjector {
    private let appleScript = AppleScriptRunner()

    static func plan(
        terminalName: String?,
        tty: String?,
        decision: ActionDecision
    ) -> ActionInjectionPlan? {
        guard let terminalName, let tty, !tty.isEmpty else { return nil }
        let normalizedTTY = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let key: InjectionKey = decision == .allow ? .text("1") : .escape
        switch terminalName.lowercased() {
        case "iterm", "iterm2": return .iTerm(tty: normalizedTTY, key: key)
        case "tmux": return .tmux(tty: normalizedTTY, key: key)
        case "terminal", "terminal.app": return .terminal(tty: normalizedTTY, key: key)
        default: return nil
        }
    }

    @MainActor
    func inject(_ decision: ActionDecision, into session: AgentSession) -> Bool {
        guard let plan = Self.plan(
            terminalName: session.terminalName,
            tty: session.tty,
            decision: decision
        ) else { return false }

        switch plan {
        case let .iTerm(tty, key): return injectITerm(tty: tty, key: key)
        case let .tmux(tty, key): return injectTmux(tty: tty, key: key)
        case let .terminal(tty, key): return injectTerminal(tty: tty, key: key)
        }
    }

    private func injectITerm(tty: String, key: InjectionKey) -> Bool {
        let target = AppleScriptRunner.stringLiteral("/dev/\(tty)")
        let write = key == .escape
            ? "write text (character id 27) newline NO"
            : "write text \"1\" newline NO"
        return appleScript.run("""
        tell application id "com.googlecode.iterm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if tty of aSession is "\(target)" then
                            tell aWindow to select
                            tell aTab to select
                            tell aSession to select
                            tell aSession to \(write)
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """)
    }

    private func injectTmux(tty: String, key: InjectionKey) -> Bool {
        guard let listing = TTYResolver.output(
            "/usr/bin/env",
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_tty}"]
        ) else { return false }
        let pane = listing.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            let paneTTY = fields[1].hasPrefix("/dev/") ? fields[1].dropFirst(5) : fields[1][...]
            return paneTTY == tty[...] ? String(fields[0]) : nil
        }.first
        guard let pane else { return false }
        let keyName = key == .escape ? "Escape" : "1"
        return TTYResolver.output(
            "/usr/bin/env",
            ["tmux", "send-keys", "-t", pane, keyName]
        ) != nil
    }

    private func injectTerminal(tty: String, key: InjectionKey) -> Bool {
        let target = AppleScriptRunner.stringLiteral("/dev/\(tty)")
        let keystroke = key == .escape ? "key code 53" : "keystroke \"1\""
        return appleScript.run("""
        tell application "Terminal"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if tty of aTab is "\(target)" then
                        set selected tab of aWindow to aTab
                        set index of aWindow to 1
                        activate
                        tell application "System Events" to \(keystroke)
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """)
    }
}
