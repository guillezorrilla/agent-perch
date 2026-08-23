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
/// `warpTabLocator` are touched only from `DiscoveryQueue` (which answering shares — see
/// `ActionInjector`), `appleScript` and `warpFocuser` only from the main actor, and `processes`
/// and `terminalResolver` are thread-safe in their own right.
final class Jumper: @unchecked Sendable {
    private let resolver = TTYResolver()
    private let terminalResolver = TerminalNameResolver.shared
    private let appleScript: AppleScripting
    /// Returns where an app bundle lives, or `nil` if it is not installed. A URL rather than a
    /// `Bool` because Ghostty's reopen runs the CLI *inside* its bundle.
    private let appURL: @Sendable (String) -> URL?
    /// Launching a detached process — the reopen mechanism for every terminal that has a CLI
    /// rather than a scripting dictionary, and for the workspace IDEs. Injected for the same
    /// reason as `appleScript`: without it none of those paths can be asserted on.
    private let launch: @Sendable (String, [String]) -> Bool
    /// Handing a URL to LaunchServices — Warp's reopen mechanism. Injected so a test asserting the
    /// reopen ladder does not actually open Warp on the machine running it.
    private let openURL: @Sendable (URL) -> Bool
    private let warpTabLocator = WarpTabLocator()
    private let warpFocuser = WarpFocuser()
    private let processes: ProcessTableCache
    private static let log = Logger(subsystem: "dev.agentperch", category: "jump")

    init(
        processes: ProcessTableCache = .shared,
        appleScript: AppleScripting = AppleScriptRunner(),
        appURL: @escaping @Sendable (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        launch: @escaping @Sendable (String, [String]) -> Bool = { Jumper.runDetached($0, $1) },
        openURL: @escaping @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.processes = processes
        self.appleScript = appleScript
        self.appURL = appURL
        self.launch = launch
        self.openURL = openURL
    }

    /// Only iTerm2 and Terminal.app expose per-tab tty to AppleScript, so only they can be focused
    /// by the tty ladder. An unknown terminal keeps the original benefit of the doubt.
    ///
    /// Derived from `TerminalRegistry` rather than restated: this was one of six independent
    /// tables keyed on the same string, and the one that made WezTerm — which *is* tty-exact, via
    /// its own CLI — look like an oversight rather than a different scripting interface.
    static func canExactFocus(_ terminal: String?) -> Bool {
        guard let capability = TerminalRegistry.capability(for: terminal) else { return terminal == nil }
        return capability.isAppleScriptTTYFocusable
    }

    /// Reopen candidates, the session's own terminal first. See `TerminalRegistry.openerOrder` —
    /// the version this replaced silently dropped any terminal that was not already one of the
    /// three generic openers, which is how a Ghostty session came to reopen in iTerm.
    static func openerOrder(preferring terminal: String?) -> [String] {
        TerminalRegistry.openerOrder(preferring: terminal).map(\.key)
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

    /// The agent processes sitting in one folder, oldest first — the order Warp created their tabs
    /// in, as far as anything outside Warp can know it. `startedAt` comes from the same batched
    /// `ps` the table is built from; pid only breaks ties, to keep the answer stable between
    /// reconciles when two agents started inside the same second.
    static func agentsSharingCwd(_ cwd: String, in processes: [ClaudeProcess]) -> [ClaudeProcess] {
        let wanted = CanonicalPath.canonical(cwd)
        return processes
            .filter { CanonicalPath.canonical($0.cwd) == wanted }
            .sorted {
                ($0.startedAt ?? .distantPast, $0.pid) < ($1.startedAt ?? .distantPast, $1.pid)
            }
    }

    /// Which of the panes at a cwd belongs to `pid`, by pairing the two creation orders.
    ///
    /// Warp's database cannot tell two panes in one folder apart — no tty, no pid, identical
    /// `shell_launch_data` — so every session in a repo used to resolve to the same tab and every
    /// card focused it (#55). Neither side alone is enough: Warp knows the panes and we know the
    /// processes. Lining both up by creation order and taking the same position in each is the one
    /// correspondence available.
    ///
    /// A heuristic, and it is wrong when the two orders have diverged — a pane closed and reopened,
    /// or a session resumed into a different tab. That is why it demands the counts agree first: a
    /// mismatch means one order has moved and positions no longer mean the same thing, and `nil`
    /// then sends the caller to a fresh tab rather than to a confidently wrong one. Focusing the
    /// wrong tab is not a cosmetic miss — the answer path types ⌘Y into whatever it focused.
    static func pairedWarpTab(pid: Int32?, peers: [ClaudeProcess], tabIndices: [Int]) -> Int? {
        guard let pid,
              !tabIndices.isEmpty,
              peers.count == tabIndices.count,
              let rank = peers.firstIndex(where: { $0.pid == pid }) else { return nil }
        let index = tabIndices[rank]
        // Warp binds ⌘1…⌘9 and nothing beyond, which is the only way this app can focus a tab.
        return (1...9).contains(index) ? index : nil
    }

    /// The three terminals #4 taught this ladder about, split out of `resolvePlan` the way
    /// `routeWarpJump` already is so the routing can be tested without a live WezTerm, Ghostty or
    /// cmux. `nil` means "not handled here" — the caller carries on down the ladder, so none of
    /// these can dead-end a jump.
    ///
    /// WezTerm is focused right here, off the main actor, and reports back as `.alreadyFocused`;
    /// the other two can only be focused by AppleScript, which has to cross to the main actor, so
    /// they hand `perform` the app and the cwd to match.
    static func routeTerminalJump(
        terminal: String?,
        cwd: String,
        tty: String?,
        focusWezTerm: (String?, String) -> Bool,
        cmuxAvailable: () -> Bool
    ) -> JumpPlan.Target? {
        switch terminal {
        case "wezterm":
            return focusWezTerm(tty, cwd) ? .alreadyFocused : nil
        case "cmux":
            // cmux not installed at all still falls through to the pre-cmux ladder, exactly as it
            // did before (#3).
            return cmuxAvailable() ? .focusTerminalByCwd(app: .cmux, cwd: cwd) : nil
        case "ghostty":
            return .focusTerminalByCwd(app: .ghostty, cwd: cwd)
        default:
            return nil
        }
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
        await DiscoveryQueue.run { self.resolvePlan(for: session) }
    }

    private func resolvePlan(for session: AgentSession) -> JumpPlan {
        // A GUI workspace, not a terminal — none of the tty/Warp/cmux machinery below applies,
        // and running it anyway risks matching an unrelated terminal process that merely shares
        // this workspace's cwd (#3). A real `agy` CLI session (same `agentName`, different
        // `sessionId` prefix — see `AgentSession.workspaceIDE`) falls through to the normal ladder
        // below exactly like Claude/Codex (#29). Cursor rows are all workspaces (#11).
        if let ide = session.workspaceIDE {
            return JumpPlan(
                target: .openWorkspaceIDE(ide, path: session.cwd, cliAvailable: session.resumeCommand != nil),
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
            let peers = Self.agentsSharingCwd(session.cwd, in: table)
            if peers.count > 1 {
                switch Self.pairedWarpTab(
                    pid: target.pid,
                    peers: peers,
                    tabIndices: warpTabLocator.tabIndices(forCwd: session.cwd, reusingRecentCopy: false)
                ) {
                case .some(let index):
                    return JumpPlan(
                        target: .warpTab(index),
                        cwd: session.cwd,
                        terminal: terminal,
                        resumeCommand: session.resumeCommand
                    )
                case .none:
                    // Deliberately NOT the cwd query's answer. With peers in the folder that index
                    // is a tab one of them is sitting in, and focusing it would hand this session's
                    // ⌘Y to somebody else's prompt. A fresh tab is merely unhelpful (#55).
                    return .newTab(cwd: session.cwd, terminal: terminal, resumeCommand: session.resumeCommand)
                }
            }

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

        if let routed = Self.routeTerminalJump(
            terminal: terminal,
            cwd: session.cwd,
            tty: target.tty,
            // Runs right here, off the main actor: it shells out to `wezterm cli` and waits (#4).
            focusWezTerm: { WezTermFocuser.attemptFocus(tty: $0, cwd: $1) },
            cmuxAvailable: { CmuxLauncher.isAvailable() }
        ) {
            return JumpPlan(
                target: routed,
                cwd: session.cwd,
                terminal: terminal,
                resumeCommand: session.resumeCommand
            )
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
    func perform(_ plan: JumpPlan) -> Bool {
        switch plan.target {
        case let .focusTTY(tty):
            if focus(tty: tty) { return true }
        case let .focusTerminalByCwd(app, cwd):
            if focusTerminalByCwd(app: app, cwd: cwd) { return true }
        case let .warpTab(index):
            return Self.routeWarpJump(
                cwd: plan.cwd,
                // Already located off the main actor, moments ago.
                locate: { _ in index },
                focus: { warpFocuser.focus(tabIndex: $0) },
                fallback: { openNewTab(at: plan.cwd, preferring: plan.terminal, resumeCommand: plan.resumeCommand) }
            )
        case let .openWorkspaceIDE(ide, path, cliAvailable):
            let (executable, arguments) = Self.workspaceIDELaunchCommand(
                ide, path: path, cliAvailable: cliAvailable
            )
            return launch(executable, arguments)
        case .alreadyFocused:
            return true
        case .newTab:
            break
        }
        return openNewTab(at: plan.cwd, preferring: plan.terminal, resumeCommand: plan.resumeCommand)
    }

    /// The IDE's own CLI (if on PATH) launches through the user's shell env exactly like a terminal
    /// command would; otherwise `open -a` asks LaunchServices for the app directly. Either one
    /// re-focuses an already-open window on this folder rather than spawning a second one — the
    /// same way opening a path macOS already has open in an app just brings it forward. One
    /// launcher for both forks: `agy` and `cursor` take a path and behave identically here (#11).
    static func workspaceIDELaunchCommand(
        _ ide: JumpPlan.WorkspaceIDE,
        path: String,
        cliAvailable: Bool
    ) -> (executable: String, arguments: [String]) {
        cliAvailable
            ? ("/usr/bin/env", [ide.cli, path])
            : ("/usr/bin/open", ["-a", ide.applicationName, path])
    }

    /// Fire-and-forget: doesn't wait for the launched app to actually finish opening, matching
    /// every other opener above (the AppleScript `create window`/`do script` calls don't wait for
    /// the terminal to finish drawing either) — only whether the launch itself was accepted.
    @discardableResult
    static func runDetached(_ executable: String, _ arguments: [String]) -> Bool {
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

    /// Ghostty and cmux expose a surface's `working directory` but NO tty (#4), so this is a cwd
    /// match and nothing better is available. Be clear about what that costs: two surfaces sitting
    /// in the same directory are indistinguishable here and the first one found wins, so this can
    /// land on the wrong surface. iTerm, Terminal and WezTerm stay tty-exact and are unaffected.
    ///
    /// `focus` brings the surface's window to the front by itself — verified against both apps
    /// while another app held focus — so there is no separate `activate`. An app whose scripting
    /// is switched off (cmux ships with `macos-applescript` disabled) reports no surfaces at all
    /// rather than erroring, which arrives here as an ordinary miss.
    @MainActor
    private func focusTerminalByCwd(app: JumpPlan.CwdFocusApp, cwd: String) -> Bool {
        guard isInstalled(app.bundleIdentifier) else { return false }
        let candidates = Self.cwdSpellings(cwd)
            .map { "\"\(AppleScriptRunner.stringLiteral($0))\"" }
            .joined(separator: ", ")

        if appleScript.run("""
            tell application id "\(app.bundleIdentifier)"
                repeat with aTerminal in terminals
                    if {\(candidates)} contains (working directory of aTerminal) then
                        focus aTerminal
                        return true
                    end if
                end repeat
            end tell
            return false
            """) {
            return true
        }

        return app.activatesOnMiss ? CmuxLauncher.activate() : false
    }

    /// Every spelling of `cwd` the AppleScript comparison above may have to match.
    ///
    /// `CanonicalPath` is the codebase's answer to one path arriving spelled several ways, but it
    /// cannot run inside an AppleScript string comparison — so the differences it would have
    /// collapsed are enumerated here instead. The one that actually bites is macOS's `/private`
    /// aliasing: a surface reports its real cwd (`/private/tmp`) while a hook reports the shell's
    /// (`/tmp`). Keeping the original spelling alongside the resolved one covers a user symlink,
    /// where the shell's `PWD` is the unresolved name (#4).
    static func cwdSpellings(_ cwd: String) -> [String] {
        let canonical = CanonicalPath.canonical(cwd)
        var spellings = [canonical]
        for root in ["/var", "/tmp", "/etc"]
        where canonical == root || canonical.hasPrefix(root + "/") {
            spellings.append("/private" + canonical)
        }
        if cwd != canonical { spellings.append(cwd) }
        return spellings
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

        for capability in TerminalRegistry.openerOrder(preferring: terminal) {
            if reopen(
                capability,
                cwd: cwd,
                command: command,
                shellWrapped: shellWrapped,
                resumeCommand: resumeCommand
            ) {
                return true
            }
        }
        return false
    }

    /// One arm per reopen strategy. The switch is exhaustive with no `default:`, so a terminal
    /// added to `TerminalRegistry` with a mechanism nobody implemented is a build failure — which
    /// is the whole point. The version this replaced keyed on a bare string and simply skipped
    /// anything it did not recognise, which is how a Ghostty session came to reopen in iTerm.
    @MainActor
    private func reopen(
        _ capability: TerminalCapability,
        cwd: String,
        command: String,
        shellWrapped: String,
        resumeCommand: String?
    ) -> Bool {
        switch capability.reopen {
        case .iTermAppleScript:
            guard isInstalled(capability.bundleIdentifiers) else { return false }
            return appleScript.run("""
                tell application id "com.googlecode.iterm2"
                    create window with default profile command "\(shellWrapped)"
                    activate
                end tell
                return true
                """)

        case .terminalAppleScript:
            guard isInstalled(capability.bundleIdentifiers) else { return false }
            return appleScript.run("""
                tell application "Terminal"
                    do script "\(command)"
                    activate
                end tell
                return true
                """)

        case .warpURLScheme:
            guard isInstalled(capability.bundleIdentifiers) else { return false }
            var components = URLComponents()
            components.scheme = "warp"
            components.host = "action"
            components.path = "/new_tab"
            components.queryItems = [URLQueryItem(name: "path", value: cwd)]
            guard let url = components.url else { return false }
            return openURL(url)

        case .ghosttyBundledCLI:
            // `ghostty +new-window` opens in the ALREADY-RUNNING instance and documents
            // `--working-directory`, `--command` and `-e`. `-e` swallows every following
            // argument as the command, so it goes last. Arguments are passed as an array, so
            // nothing here needs shell quoting.
            guard let bundle = installedBundle(capability) else { return false }
            var arguments = ["+new-window", "--working-directory=\(cwd)"]
            if let resumeCommand {
                arguments += ["-e", "/bin/zsh", "-lc", Self.newTabInnerCommand(cwd: cwd, resumeCommand: resumeCommand)]
            }
            return launch(
                bundle.appendingPathComponent("Contents/MacOS/ghostty").path,
                arguments
            )

        case .wezTermCLI:
            // The CLI inside the bundle, NOT `/usr/bin/env wezterm`. `runDetached` reports whether
            // the launch was accepted, and `env` always launches — it exits 127 for a missing
            // command long after we have said "handled" and stopped the ladder. Addressing the
            // binary directly makes a missing WezTerm a failed `run()`, so the ladder carries on
            // exactly as it did before WezTerm had a reopen arm at all.
            guard let bundle = installedBundle(capability) else { return false }
            var arguments = ["start", "--cwd", cwd]
            if let resumeCommand {
                arguments += ["--", "/bin/zsh", "-lc", Self.newTabInnerCommand(cwd: cwd, resumeCommand: resumeCommand)]
            }
            return launch(bundle.appendingPathComponent("Contents/MacOS/wezterm").path, arguments)

        case .activateApp:
            // No new-window mechanism, but surfacing the app the session actually lives in beats
            // opening a different vendor's terminal.
            return CmuxLauncher.activate()

        case .unsupported:
            return false
        }
    }

    @MainActor
    private func isInstalled(_ bundleIdentifiers: String...) -> Bool {
        isInstalled(bundleIdentifiers)
    }

    @MainActor
    private func isInstalled(_ bundleIdentifiers: [String]) -> Bool {
        bundleIdentifiers.contains { appURL($0) != nil }
    }

    /// Where an installed terminal's bundle lives, taking the first identifier that resolves —
    /// Warp ships under two.
    @MainActor
    private func installedBundle(_ capability: TerminalCapability) -> URL? {
        capability.bundleIdentifiers.lazy.compactMap { self.appURL($0) }.first
    }
}
