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
    private let appleScript = AppleScriptRunner()

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

    @MainActor
    @discardableResult
    func jump(_ session: AgentSession) -> Bool {
        let rung = Self.rung(
            for: session.cwd,
            preferredTTY: session.tty,
            processes: resolver.processes()
        )
        if case let .exactFocus(tty) = rung, focus(tty: tty) {
            return true
        }
        return openNewTab(at: session.cwd)
    }

    @MainActor
    private func focus(tty: String) -> Bool {
        let target = AppleScriptRunner.stringLiteral("/dev/\(tty)")

        if isInstalled("com.googlecode.iterm2"), appleScript.run("""
            tell application "iTerm2"
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

    @MainActor
    private func openNewTab(at cwd: String) -> Bool {
        let command = AppleScriptRunner.stringLiteral(
            "cd -- \(AppleScriptRunner.shellQuote(cwd)); exec \"${SHELL:-/bin/zsh}\" -l"
        )

        if isInstalled("com.googlecode.iterm2"), appleScript.run("""
            tell application "iTerm2"
                create window with default profile command "\(command)"
                activate
            end tell
            return true
            """) {
            return true
        }

        if isInstalled("com.apple.Terminal"), appleScript.run("""
            tell application "Terminal"
                do script "\(command)"
                activate
            end tell
            return true
            """) {
            return true
        }

        guard isInstalled("dev.warp.Warp-Stable", "dev.warp.Warp") else { return false }
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "action"
        components.path = "/new_tab"
        components.queryItems = [URLQueryItem(name: "path", value: cwd)]
        return components.url.map(NSWorkspace.shared.open) ?? false
    }

    @MainActor
    private func isInstalled(_ bundleIdentifiers: String...) -> Bool {
        bundleIdentifiers.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }
}
