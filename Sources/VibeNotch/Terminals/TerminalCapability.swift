import Foundation

/// Everything this app knows about one terminal, on one row.
///
/// This knowledge used to be filed by *concern* rather than by terminal: recognition in
/// `TerminalNameResolver.knownName`, exact-focus eligibility in `Jumper.canExactFocus`, the reopen
/// candidates in `Jumper.openerOrder`, the reopen mechanism in `Jumper.openNewTab`, cwd-focus
/// bundle identifiers in `JumpPlan.CwdFocusApp`, and the routing in `Jumper.routeTerminalJump`.
/// Six tables, none referencing another, all keyed on the same lowercased string.
///
/// Nothing forced them to agree, and they did not. Ghostty appeared in the focus tables and in
/// neither reopen table, so `openerOrder(preferring: "ghostty")` failed its `defaults.contains`
/// guard, returned `["iterm", "terminal", "warp"]`, and a Ghostty session that missed its cwd
/// match opened an **iTerm** window — the exact outcome `CwdFocusApp.activatesOnMiss` calls "a
/// regression, not a fallback" for cmux.
///
/// A row makes that impossible to write by accident: a terminal with no reopen mechanism says
/// `.unsupported` out loud, which is a decision on a visible field rather than an omission from a
/// switch nobody remembered to extend.
struct TerminalCapability: Sendable, Equatable {
    /// How this terminal is recognised from a process's command line, replacing the if-chain that
    /// used to live in `TerminalNameResolver`. Kept as data so the rules are testable and so the
    /// row, not a chain elsewhere, owns the answer.
    struct ProcessMatch: Sendable, Equatable {
        /// Any one of these appearing in the lowercased command matches.
        var commandContains: [String] = []
        /// *All* of these must appear — tmux is only a terminal when it is the server process.
        var commandContainsAll: [String] = []
        /// Any one of these equalling the lowercased executable name matches.
        var executableEquals: [String] = []

        func matches(command: String, executable: String) -> Bool {
            if commandContains.contains(where: { command.contains($0) }) { return true }
            if !commandContainsAll.isEmpty, commandContainsAll.allSatisfy({ command.contains($0) }) {
                return true
            }
            return executableEquals.contains(executable)
        }
    }

    /// How a *live* session in this terminal is brought to the front.
    enum Focus: Sendable, Equatable {
        /// AppleScript, matching a tab by its tty. iTerm and Terminal only — they are the two that
        /// expose per-tab `tty` to scripting.
        case appleScriptTTY
        /// Warp's state database gives a tab index, focused with ⌘-digit.
        case warpTabIndex
        /// WezTerm's own CLI, off the main actor. Note this *is* tty-exact — it simply is not
        /// reachable through the AppleScript tty ladder, which is why `canExactFocus` says no.
        /// The old flat `canExactFocus` table made that read like an oversight rather than a fact
        /// about which scripting interface exposes a tty.
        case wezTermCLI
        /// AppleScript against a surface's `working directory`. Strictly weaker than a tty match:
        /// two surfaces in one directory are indistinguishable and the first found wins.
        /// `activatesOnMiss` is cmux's floor — bring the app itself forward rather than let a miss
        /// fall through and surface a different vendor's window.
        case cwdSurface(activatesOnMiss: Bool)
        /// Nothing scriptable to focus (tmux is a multiplexer, not a window server; Kitty's remote
        /// control is off unless the user turns it on).
        case unsupported
    }

    /// How a *dead* session is reopened at its cwd. The row names the strategy; `Jumper` holds the
    /// one switch that implements each, so a new terminal needing a new mechanism is a compiler
    /// error rather than a silent fall-through.
    enum Reopen: Sendable, Equatable {
        case iTermAppleScript
        case terminalAppleScript
        case warpURLScheme
        /// Ghostty ships its CLI inside the bundle and documents `--working-directory`.
        case ghosttyBundledCLI
        /// `wezterm start --cwd <dir>`, from the CLI on `PATH`.
        case wezTermCLI
        /// No way to open a new window at a cwd, but bringing the app forward beats opening
        /// somebody else's terminal.
        case activateApp
        /// Genuinely nothing to do — fall through to the generic ladder.
        case unsupported
    }

    /// How an answer — an allow/deny keystroke for a waiting card — is delivered to this terminal.
    ///
    /// This was `ActionInjector`'s third switch over the same string, and it sat two files away
    /// from the focus tables with only a comment tying the spellings together. Answering and
    /// jumping now read the same row, so a terminal cannot be jumpable and unanswerable by
    /// accident.
    enum Answer: Sendable, Equatable {
        /// Addressed by tty, over AppleScript.
        case iTermAppleScript
        case terminalAppleScript
        /// Addressed by tty, over the terminal's own CLI — no main-actor hop needed.
        case tmuxCLI
        case wezTermCLI
        case kittyRemote
        /// No per-tab tty: locate the tab by cwd in Warp's state database, then post the key.
        case warpTabByCwd
        /// No text API at all: focus the surface at this cwd, then post the key.
        case surfaceByCwd
        /// Refuse rather than guess. Typing into the wrong app is the one failure worse than
        /// typing nothing.
        case unsupported
    }

    /// Canonical, display-cased name. `TerminalNameResolver` emits this; everything downstream
    /// lowercases it, which is what `key` is for.
    let name: String
    /// Extra spellings that arrive from a hook's `terminalName` rather than from process ancestry.
    var aliases: [String] = []
    var bundleIdentifiers: [String] = []
    var processMatch: ProcessMatch = ProcessMatch()
    let focus: Focus
    let reopen: Reopen
    let answer: Answer

    var key: String { name.lowercased() }

    /// Every spelling that should resolve to this row.
    var keys: [String] { [key] + aliases }

    /// Whether the AppleScript tty ladder can focus this terminal. Only `.appleScriptTTY` can —
    /// see the note on `Focus.wezTermCLI` for why WezTerm is tty-exact and still answers `false`.
    var isAppleScriptTTYFocusable: Bool { focus == .appleScriptTTY }
}

/// The one place a terminal is described. Adding one is adding a row here.
///
/// Order is load-bearing for `recognise` only: it preserves the original if-chain's precedence,
/// where Ghostty is tested before cmux (a Ghostty fork).
enum TerminalRegistry {
    static let all: [TerminalCapability] = [
        TerminalCapability(
            name: "iTerm",
            aliases: ["iterm2"],
            bundleIdentifiers: ["com.googlecode.iterm2"],
            processMatch: .init(commandContains: ["iterm2"]),
            focus: .appleScriptTTY,
            reopen: .iTermAppleScript,
            answer: .iTermAppleScript
        ),
        TerminalCapability(
            name: "Terminal",
            aliases: ["terminal.app"],
            bundleIdentifiers: ["com.apple.Terminal"],
            processMatch: .init(commandContains: ["apple_terminal"], executableEquals: ["terminal"]),
            focus: .appleScriptTTY,
            reopen: .terminalAppleScript,
            answer: .terminalAppleScript
        ),
        TerminalCapability(
            name: "Warp",
            bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp"],
            processMatch: .init(commandContains: ["warpterminal", "warp.app/"]),
            focus: .warpTabIndex,
            reopen: .warpURLScheme,
            answer: .warpTabByCwd
        ),
        TerminalCapability(
            name: "tmux",
            processMatch: .init(commandContainsAll: ["tmux", "server"]),
            focus: .unsupported,
            reopen: .unsupported,
            answer: .tmuxCLI
        ),
        TerminalCapability(
            name: "Ghostty",
            bundleIdentifiers: ["com.mitchellh.ghostty"],
            processMatch: .init(commandContains: ["ghostty"]),
            focus: .cwdSurface(activatesOnMiss: false),
            reopen: .ghosttyBundledCLI,
            answer: .surfaceByCwd
        ),
        TerminalCapability(
            name: "WezTerm",
            bundleIdentifiers: ["com.github.wez.wezterm"],
            processMatch: .init(commandContains: ["wezterm"]),
            focus: .wezTermCLI,
            reopen: .wezTermCLI,
            answer: .wezTermCLI
        ),
        TerminalCapability(
            name: "Kitty",
            bundleIdentifiers: ["net.kovidgoyal.kitty"],
            processMatch: .init(commandContains: ["kitty.app/"], executableEquals: ["kitty"]),
            focus: .unsupported,
            reopen: .unsupported,
            answer: .kittyRemote
        ),
        TerminalCapability(
            name: "cmux",
            bundleIdentifiers: ["com.cmuxterm.app"],
            processMatch: .init(commandContains: ["cmux.app/"], executableEquals: ["cmux"]),
            focus: .cwdSurface(activatesOnMiss: true),
            reopen: .activateApp,
            answer: .surfaceByCwd
        ),
    ]

    private static let byKey: [String: TerminalCapability] = {
        var index: [String: TerminalCapability] = [:]
        for capability in all {
            for key in capability.keys { index[key] = capability }
        }
        return index
    }()

    /// `nil` for an unknown terminal, which callers treat as "assume the conservative default"
    /// exactly as they did when each table had its own `default:` arm.
    static func capability(for terminal: String?) -> TerminalCapability? {
        guard let terminal else { return nil }
        return byKey[terminal.lowercased()]
    }

    /// The canonical name for a process command line, replacing `TerminalNameResolver.knownName`.
    static func recognise(command: String) -> String? {
        let lowercased = command.lowercased()
        let executable = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        return all.first { $0.processMatch.matches(command: lowercased, executable: executable) }?.name
    }

    /// The reopen ladder used when the session's own terminal cannot reopen itself. Order is the
    /// long-standing iTerm → Terminal → Warp preference, now derived from rows rather than
    /// restated as a third list of strings.
    static let genericOpeners: [TerminalCapability] = ["iTerm", "Terminal", "Warp"]
        .compactMap { capability(for: $0) }

    /// The session's own terminal first when it can reopen itself, then the generic ladder. This
    /// replaces `Jumper.openerOrder`, whose `defaults.contains` guard silently dropped every
    /// terminal that was not already one of the three generic openers.
    static func openerOrder(preferring terminal: String?) -> [TerminalCapability] {
        guard let preferred = capability(for: terminal), preferred.reopen != .unsupported else {
            return genericOpeners
        }
        return [preferred] + genericOpeners.filter { $0.key != preferred.key }
    }
}
