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
    /// Warp exposes no per-tab tty, so its tab is located by cwd through the state database.
    case warp(cwd: String, key: InjectionKey)
}

/// The half of an injection that has to happen on the main actor, once discovery has worked out
/// where the answer goes: AppleScript and `CGEvent` posting are main-thread APIs.
enum ActionInjectionDelivery: Equatable, Sendable {
    case iTerm(tty: String, key: InjectionKey)
    case terminal(tty: String, key: InjectionKey)
    /// The tab to switch to before the answer key is typed, already read off the main actor.
    case warpTab(index: Int, key: InjectionKey)
    /// tmux needs no main-thread API at all — `send-keys` is a subprocess — so it is delivered on
    /// the discovery queue and only its result travels back here.
    case finished(Bool)
}

/// Two halves, exactly like `Jumper`: work out where the answer goes (slow, off the main actor),
/// then type it (fast, necessarily on the main actor).
///
/// `@unchecked Sendable` because that split is the invariant: `warpTabLocator` is touched only from
/// `DiscoveryQueue`, `appleScript` and `warpFocuser` only from the main actor. Answering used to
/// run whole on the main thread — including the ~30MB copy of Warp's sqlite that locating a tab
/// costs — so every click on a card froze the entire app until it finished (#32).
struct ActionInjector: @unchecked Sendable {
    private let appleScript = AppleScriptRunner()
    private let warpTabLocator = WarpTabLocator()
    private let warpFocuser = WarpFocuser()

    /// How long the Warp tab switch is given to land before the answer key is posted. Without
    /// it the digit races the ⌘N tab switch and gets typed into whichever tab was focused
    /// before — answering the wrong session.
    private static let warpTabSettle: TimeInterval = 0.2

    static func plan(
        terminalName: String?,
        tty: String?,
        cwd: String? = nil,
        decision: ActionDecision
    ) -> ActionInjectionPlan? {
        plan(
            terminalName: terminalName,
            tty: tty,
            cwd: cwd,
            key: decision == .allow ? .text("1") : .escape
        )
    }

    static func plan(
        terminalName: String?,
        tty: String?,
        cwd: String? = nil,
        digit: String
    ) -> ActionInjectionPlan? {
        guard digit.count == 1, "123456789".contains(digit) else { return nil }
        return plan(terminalName: terminalName, tty: tty, cwd: cwd, key: .text(digit))
    }

    private static func plan(
        terminalName: String?,
        tty: String?,
        cwd: String?,
        key: InjectionKey
    ) -> ActionInjectionPlan? {
        guard let terminalName else { return nil }
        if terminalName.lowercased() == "warp" {
            guard let cwd, !cwd.isEmpty else { return nil }
            return .warp(cwd: cwd, key: key)
        }
        guard let tty, !tty.isEmpty else { return nil }
        let normalizedTTY = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        switch terminalName.lowercased() {
        case "iterm", "iterm2": return .iTerm(tty: normalizedTTY, key: key)
        case "tmux": return .tmux(tty: normalizedTTY, key: key)
        case "terminal", "terminal.app": return .terminal(tty: normalizedTTY, key: key)
        default: return nil
        }
    }

    /// Async because none of this may happen on the main thread: locating a Warp tab copies a
    /// ~30MB database out of another app's container, and doing that behind a click is what froze
    /// the app (#32). The caller acknowledges the click first and awaits this afterwards.
    func inject(_ decision: ActionDecision, into session: AgentSession) async -> Bool {
        guard let plan = Self.plan(
            terminalName: session.terminalName,
            tty: session.tty,
            cwd: session.cwd,
            decision: decision
        ) else { return false }
        return await inject(plan)
    }

    func inject(_ digit: String, into session: AgentSession) async -> Bool {
        guard let plan = Self.plan(
            terminalName: session.terminalName,
            tty: session.tty,
            cwd: session.cwd,
            digit: digit
        ) else { return false }
        return await inject(plan)
    }

    func inject(_ plan: ActionInjectionPlan) async -> Bool {
        guard let delivery = await DiscoveryQueue.run({ self.resolve(plan) }) else { return false }
        return await deliver(delivery)
    }

    /// Phase one, on the discovery queue: everything that spawns a subprocess or reads Warp's
    /// sqlite. Returning `nil` leaves the caller to fall back to a plain jump, so the user can
    /// still answer by hand when Accessibility is not granted or the tab cannot be located.
    private func resolve(_ plan: ActionInjectionPlan) -> ActionInjectionDelivery? {
        switch plan {
        case let .iTerm(tty, key):
            return .iTerm(tty: tty, key: key)
        case let .terminal(tty, key):
            return .terminal(tty: tty, key: key)
        case let .tmux(tty, key):
            return .finished(injectTmux(tty: tty, key: key))
        case let .warp(cwd, key):
            // Read fresh, never from a copy taken seconds ago: a tab opened since that copy would
            // be missing from it entirely, and answering a stale index types the digit into
            // someone else's tab (#23). A container refusal is still remembered for the launch, so
            // this can never re-prompt.
            guard WarpFocuser.keyCode(forAnswer: key) != nil,
                  let tabIndex = warpTabLocator.tabIndex(forCwd: cwd, reusingRecentCopy: false)
            else { return nil }
            return .warpTab(index: tabIndex, key: key)
        }
    }

    /// Phase two, on the main actor: one AppleScript, or the two keystrokes a Warp answer takes.
    @MainActor
    private func deliver(_ delivery: ActionInjectionDelivery) async -> Bool {
        switch delivery {
        case let .iTerm(tty, key):
            return injectITerm(tty: tty, key: key)
        case let .terminal(tty, key):
            return injectTerminal(tty: tty, key: key)
        case let .warpTab(index, key):
            guard warpFocuser.focus(tabIndex: index) else { return false }
            // Awaited, never slept: `Thread.sleep` here held the main thread for the settle, which
            // is the one thing this whole path exists to stop doing (#32).
            try? await Task.sleep(for: .seconds(Self.warpTabSettle))
            return warpFocuser.answer(key)
        case let .finished(result):
            return result
        }
    }

    @MainActor
    private func injectITerm(tty: String, key: InjectionKey) -> Bool {
        let target = AppleScriptRunner.stringLiteral("/dev/\(tty)")
        let write: String
        switch key {
        case .escape:
            write = "write text (character id 27) newline NO"
        case let .text(text):
            write = "write text \"\(AppleScriptRunner.stringLiteral(text))\" newline NO"
        }
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
        let keyName: String
        switch key {
        case .escape: keyName = "Escape"
        case let .text(text): keyName = text
        }
        return TTYResolver.output(
            "/usr/bin/env",
            ["tmux", "send-keys", "-t", pane, keyName]
        ) != nil
    }

    @MainActor
    private func injectTerminal(tty: String, key: InjectionKey) -> Bool {
        let target = AppleScriptRunner.stringLiteral("/dev/\(tty)")
        let keystroke: String
        switch key {
        case .escape:
            keystroke = "key code 53"
        case let .text(text):
            keystroke = "keystroke \"\(AppleScriptRunner.stringLiteral(text))\""
        }
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
