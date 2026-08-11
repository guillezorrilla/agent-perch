import AppKit
import Foundation
import os

enum ActionDecision: Equatable, Sendable {
    case allow
    case deny
}

enum InjectionKey: Equatable, Sendable {
    case text(String)
    case escape

    /// The literal bytes this key is, for the two terminals that take text rather than key codes
    /// (WezTerm and Kitty). A TUI permission prompt reads Escape as one raw byte, so that is
    /// exactly what gets sent — no `\e` spelling any of the CLIs would have to interpret (#42).
    var characters: String {
        switch self {
        case .escape: "\u{1B}"
        case let .text(text): text
        }
    }
}

enum ActionInjectionPlan: Equatable, Sendable {
    case iTerm(tty: String, key: InjectionKey)
    case tmux(tty: String, key: InjectionKey)
    case terminal(tty: String, key: InjectionKey)
    /// Warp exposes no per-tab tty, so its tab is located by cwd through the state database.
    case warp(cwd: String, key: InjectionKey)
    /// `wezterm cli send-text --pane-id`, addressed by the pane holding this tty (#42).
    case wezTerm(tty: String, key: InjectionKey)
    /// `kitty @ send-text`, addressed by window id (#42). Unverified — see `KittyRemote`.
    case kitty(tty: String, key: InjectionKey)
    /// Ghostty and cmux have no text API at all: focus the surface sitting at this cwd, then post
    /// the key — the mechanism Warp has used since #20 (#42).
    case surface(app: JumpPlan.CwdFocusApp, cwd: String, key: InjectionKey)
    /// Terminal unresolved, tty known: try the same iTerm→Terminal ladder a jump takes. Answering
    /// used to refuse outright here, so a session whose terminal name had not resolved could be
    /// JUMPED to and never ANSWERED — the whole of #42.
    case ttyLadder(tty: String, key: InjectionKey)

    /// One token for the answer log. Deliberately never includes the key: which option the user
    /// picked is theirs, not ours to record (#42).
    var logDescription: String {
        switch self {
        case let .iTerm(tty, _): "iTerm \(tty)"
        case let .tmux(tty, _): "tmux \(tty)"
        case let .terminal(tty, _): "Terminal \(tty)"
        case .warp: "Warp by cwd"
        case let .wezTerm(tty, _): "WezTerm \(tty)"
        case let .kitty(tty, _): "Kitty \(tty)"
        case let .surface(app, _, _): "\(app.rawValue) by cwd"
        case let .ttyLadder(tty, _): "unnamed terminal \(tty)"
        }
    }
}

/// The half of an injection that has to happen on the main actor, once discovery has worked out
/// where the answer goes: AppleScript and `CGEvent` posting are main-thread APIs.
enum ActionInjectionDelivery: Equatable, Sendable {
    case iTerm(tty: String, key: InjectionKey)
    case terminal(tty: String, key: InjectionKey)
    /// iTerm then Terminal, the two that can be addressed by tty alone — `Jumper.focus(tty:)`'s
    /// ladder, now that answering shares its notion of what a nameless session can be aimed at.
    case ttyLadder(tty: String, key: InjectionKey)
    /// The tab to switch to before the answer key is typed, already read off the main actor.
    case warpTab(index: Int, key: InjectionKey)
    /// Focus the Ghostty/cmux surface at this cwd, then post the key. Nothing has been located off
    /// the main actor for this one: both apps answer only over AppleScript, which cannot run there.
    case surface(app: JumpPlan.CwdFocusApp, cwd: String, key: InjectionKey)
    /// tmux, WezTerm and Kitty need no main-thread API at all — each has a CLI that takes text —
    /// so they are delivered on the discovery queue and only their result travels back here.
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

    /// Nothing here logs session content, prompts or the answer itself — only which route was
    /// chosen and whether it landed. This path used to log nothing at all, which is why a real
    /// failure had to be inferred from a missing pill in the UI (#42).
    private static let log = Logger(subsystem: "dev.vibenotch", category: "answer")

    /// How long a focused surface is given to settle before the answer key is posted. Without it
    /// the digit races the ⌘N tab switch and gets typed into whichever tab was focused before —
    /// answering the wrong session. Shared by every focus-then-type route (#42) because they all
    /// run that same race; Warp's value and its place in the sequence are unchanged.
    private static let focusSettle: TimeInterval = 0.2

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

    /// Where an answer goes, or `nil` when nowhere safe does.
    ///
    /// A missing `terminalName` is NOT fatal any more. `Jumper.canExactFocus` has always allowed a
    /// nameless session to be aimed at by tty, and this guard used to disagree with it: the card
    /// that could be jumped to reported "Couldn't answer" and typed nothing, because no AppleEvent
    /// was ever sent (#42). The two now agree, and `Jumper` stays the single owner of that rule.
    private static func plan(
        terminalName: String?,
        tty: String?,
        cwd: String?,
        key: InjectionKey
    ) -> ActionInjectionPlan? {
        let terminal = terminalName?.lowercased()

        // The two cwd-addressed terminals first: neither has a per-surface tty to prefer, so a tty
        // that happens to be known must not divert them.
        if terminal == "warp" {
            guard let cwd, !cwd.isEmpty else { return refuse("Warp with no cwd", terminal: terminal) }
            return built(.warp(cwd: cwd, key: key))
        }
        if let app = terminal.flatMap(JumpPlan.CwdFocusApp.init(rawValue:)) {
            guard let cwd, !cwd.isEmpty else { return refuse("\(app.rawValue) with no cwd", terminal: terminal) }
            return built(.surface(app: app, cwd: cwd, key: key))
        }

        guard let tty, !tty.isEmpty else { return refuse("no tty", terminal: terminal) }
        let normalizedTTY = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        switch terminal {
        case "iterm", "iterm2": return built(.iTerm(tty: normalizedTTY, key: key))
        case "tmux": return built(.tmux(tty: normalizedTTY, key: key))
        case "terminal", "terminal.app": return built(.terminal(tty: normalizedTTY, key: key))
        case "wezterm": return built(.wezTerm(tty: normalizedTTY, key: key))
        case "kitty": return built(.kitty(tty: normalizedTTY, key: key))
        default:
            // `Jumper` owns the answer to "can a session with this terminal name be aimed at by
            // tty alone" — reused rather than restated, so the two can never drift apart again.
            // For a NAMED terminal this is false and the answer is refused: guessing which app to
            // type into is the one failure worse than typing nothing (#42).
            guard Jumper.canExactFocus(terminal) else {
                return refuse("unsupported terminal", terminal: terminal)
            }
            return built(.ttyLadder(tty: normalizedTTY, key: key))
        }
    }

    private static func built(_ plan: ActionInjectionPlan) -> ActionInjectionPlan {
        log.debug("answer plan: \(plan.logDescription, privacy: .public)")
        return plan
    }

    private static func refuse(_ reason: String, terminal: String?) -> ActionInjectionPlan? {
        log.debug("no answer plan: \(reason, privacy: .public) (terminal \(terminal ?? "unresolved", privacy: .public))")
        return nil
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
        guard let delivery = await DiscoveryQueue.run({ self.resolve(plan) }) else {
            Self.log.error("answer not delivered: \(plan.logDescription, privacy: .public) could not be located")
            return false
        }
        let delivered = await deliver(delivery)
        if delivered {
            Self.log.debug("answer delivered: \(plan.logDescription, privacy: .public)")
        } else {
            Self.log.error("answer not delivered: \(plan.logDescription, privacy: .public) refused the keystroke")
        }
        return delivered
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
        case let .ttyLadder(tty, key):
            return .ttyLadder(tty: tty, key: key)
        case let .tmux(tty, key):
            return .finished(injectTmux(tty: tty, key: key))
        case let .wezTerm(tty, key):
            // Addressed by pane id, so no focus and no race: `send-text` cannot land anywhere but
            // the pane holding this tty, and a tty that matches no pane refuses (#42).
            return .finished(WezTermFocuser.sendText(key.characters, tty: tty))
        case let .kitty(tty, key):
            // Kitty reports each window's foreground process ids and never a tty, so the agent pid
            // is the bridge — the same pid the terminal pill was resolved from, which is why it is
            // in the table at all by the time a Kitty plan exists.
            return .finished(KittyRemote.sendText(key.characters, agentPID: Self.pid(forTTY: tty)))
        case let .surface(app, cwd, key):
            // Refuse before anything is focused, exactly as Warp does below: a key with no code is
            // a keystroke that cannot be posted, and focusing for it would only steal the user's
            // window for nothing.
            guard WarpFocuser.keyCode(forAnswer: key) != nil else { return nil }
            return .surface(app: app, cwd: cwd, key: key)
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

    @MainActor
    private static func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// The agent process sitting on `tty`, from the snapshot every jump and refresh already share.
    /// Blocking, and deliberately so: this only ever runs on the discovery queue (#42).
    private static func pid(forTTY tty: String) -> Int32? {
        ProcessTableCache.shared.processes().first {
            guard let processTTY = $0.tty else { return false }
            return (processTTY.hasPrefix("/dev/") ? String(processTTY.dropFirst(5)) : processTTY) == tty
        }?.pid
    }

    /// Phase two, on the main actor: one AppleScript, or the two keystrokes a focus-then-type
    /// answer takes.
    @MainActor
    private func deliver(_ delivery: ActionInjectionDelivery) async -> Bool {
        switch delivery {
        case let .iTerm(tty, key):
            return injectITerm(tty: tty, key: key)
        case let .terminal(tty, key):
            return injectTerminal(tty: tty, key: key)
        case let .ttyLadder(tty, key):
            // Same order, same two apps, same install guard and same tty predicate as
            // `Jumper.focus(tty:)`. Either one owns the tty or neither does; a miss types nothing
            // at all rather than falling through to a terminal that merely shares the cwd.
            if Self.isInstalled("com.googlecode.iterm2"), injectITerm(tty: tty, key: key) { return true }
            return Self.isInstalled("com.apple.Terminal") && injectTerminal(tty: tty, key: key)
        case let .warpTab(index, key):
            guard warpFocuser.focus(tabIndex: index) else { return false }
            // Awaited, never slept: `Thread.sleep` here held the main thread for the settle, which
            // is the one thing this whole path exists to stop doing (#32).
            try? await Task.sleep(for: .seconds(Self.focusSettle))
            return warpFocuser.answer(key)
        case let .surface(app, cwd, key):
            guard focusSurface(app: app, cwd: cwd) else { return false }
            try? await Task.sleep(for: .seconds(Self.focusSettle))
            return SurfaceKeystroke.post(key, toBundleIdentifier: app.bundleIdentifier)
        case let .finished(result):
            return result
        }
    }

    /// The Ghostty/cmux surface at `cwd`, brought to the front — `Jumper.focusTerminalByCwd`'s
    /// script, minus its fallback, and the difference is the point.
    ///
    /// A jump that matches no surface may still activate cmux: landing in the right app is better
    /// than nothing. An ANSWER may not. Activating and then posting a digit types it into whatever
    /// surface happened to be in front, which answers a prompt nobody was looking at — strictly
    /// worse than leaving the card saying nothing was typed (#42). So: no surface, no keystroke.
    ///
    /// Both apps report a surface's `working directory` and no tty, so two surfaces sitting in the
    /// same directory are indistinguishable here and the first found wins — the same limit the
    /// jump path documents, and the reason Warp's settle delay is repeated for this route.
    @MainActor
    private func focusSurface(app: JumpPlan.CwdFocusApp, cwd: String) -> Bool {
        guard Self.isInstalled(app.bundleIdentifier) else { return false }
        let candidates = Jumper.cwdSpellings(cwd)
            .map { "\"\(AppleScriptRunner.stringLiteral($0))\"" }
            .joined(separator: ", ")
        return appleScript.run("""
        tell application id "\(app.bundleIdentifier)"
            repeat with aTerminal in terminals
                if {\(candidates)} contains (working directory of aTerminal) then
                    focus aTerminal
                    return true
                end if
            end repeat
        end tell
        return false
        """)
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
