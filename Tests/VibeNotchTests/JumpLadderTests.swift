import XCTest
@testable import VibeNotch

final class JumpLadderTests: XCTestCase {
    func testMatchingClaudeCLIWithTTYSelectsExactFocus() {
        let processes = [
            ClaudeProcess(
                pid: 9,
                command: "/usr/bin/vim claude-notes.md",
                cwd: "/repo",
                tty: "ttys000"
            ),
            ClaudeProcess(
                pid: 10,
                command: "/Applications/Claude.app/Contents/Helpers/Claude Helper",
                cwd: "/repo",
                tty: "ttys001"
            ),
            ClaudeProcess(
                pid: 11,
                command: "/usr/local/bin/claude",
                cwd: "/other",
                tty: "ttys002"
            ),
            ClaudeProcess(
                pid: 12,
                command: "/Users/me/.local/share/claude/versions/1.0.0",
                cwd: "/repo",
                tty: "ttys003"
            )
        ]

        XCTAssertEqual(
            Jumper.rung(for: "/repo", processes: processes),
            .exactFocus(tty: "ttys003")
        )
    }

    func testNoMatchingTTYSelectsNewTab() {
        let processes = [
            ClaudeProcess(
                pid: 11,
                command: "/usr/local/bin/claude",
                cwd: "/other",
                tty: "ttys002"
            )
        ]

        XCTAssertEqual(
            Jumper.rung(for: "/repo", processes: processes),
            .newTab
        )
    }

    func testHookTTYWinsWithoutAProcessRescanMatch() {
        XCTAssertEqual(
            Jumper.rung(for: "/repo", preferredTTY: "ttys009", processes: []),
            .exactFocus(tty: "ttys009")
        )
    }

    func testOpenerOrderPutsDetectedTerminalFirst() {
        XCTAssertEqual(Jumper.openerOrder(preferring: "warp"), ["warp", "iterm", "terminal"])
        XCTAssertEqual(Jumper.openerOrder(preferring: "terminal.app"), ["terminal", "iterm", "warp"])
        XCTAssertEqual(Jumper.openerOrder(preferring: "iterm2"), ["iterm", "terminal", "warp"])
        // Unknown/unsupported terminal or no detection → stable default order.
        XCTAssertEqual(Jumper.openerOrder(preferring: "ghostty"), ["iterm", "terminal", "warp"])
        XCTAssertEqual(Jumper.openerOrder(preferring: nil), ["iterm", "terminal", "warp"])
    }

    func testExactFocusOnlyForTTYExposingTerminals() {
        XCTAssertTrue(Jumper.canExactFocus(nil))
        XCTAssertTrue(Jumper.canExactFocus("iterm"))
        XCTAssertTrue(Jumper.canExactFocus("terminal"))
        XCTAssertFalse(Jumper.canExactFocus("warp"))
        XCTAssertFalse(Jumper.canExactFocus("ghostty"))
    }

    func testWarpRoutingFocusesBeforeFallbackAndFallsBackOnMissOrFailure() {
        var calls: [String] = []
        XCTAssertTrue(Jumper.routeWarpJump(
            cwd: "/repo",
            locate: {
                calls.append("locate:\($0)")
                return 4
            },
            focus: {
                calls.append("focus:\($0)")
                return true
            },
            fallback: {
                calls.append("fallback")
                return false
            }
        ))
        XCTAssertEqual(calls, ["locate:/repo", "focus:4"])

        calls = []
        XCTAssertTrue(Jumper.routeWarpJump(
            cwd: "/repo",
            locate: { _ in
                calls.append("locate")
                return nil
            },
            focus: { _ in
                calls.append("focus")
                return true
            },
            fallback: {
                calls.append("fallback")
                return true
            }
        ))
        XCTAssertEqual(calls, ["locate", "fallback"])

        calls = []
        XCTAssertTrue(Jumper.routeWarpJump(
            cwd: "/repo",
            locate: { _ in
                calls.append("locate")
                return 4
            },
            focus: { _ in
                calls.append("focus")
                return false
            },
            fallback: {
                calls.append("fallback")
                return true
            }
        ))
        XCTAssertEqual(calls, ["locate", "focus", "fallback"])
    }

    func testNewTabCommandIsShellWrappedForITerm() {
        let command = Jumper.newTabShellCommand(cwd: "/Users/me/My Repo's")
        // Must be a single shell invocation: iTerm execs this without a shell (#10).
        XCTAssertTrue(command.hasPrefix("/bin/zsh -lc '"))
        // The inner command (with the `;`) is inside the quoted argument, never bare.
        XCTAssertTrue(command.contains("cd -- "))
        XCTAssertTrue(command.contains("My Repo"))
        XCTAssertFalse(command.hasSuffix(";"))
    }

    func testShellAtCwdParsedFromLsofFieldOutput() {
        let listing = "p101\nn/Users/me/other\np202\nn/Users/me/project\np303\nn/tmp\n"
        XCTAssertEqual(TTYResolver.firstPid(withCwd: "/Users/me/project", inLsofFieldOutput: listing), 202)
        XCTAssertNil(TTYResolver.firstPid(withCwd: "/nope", inLsofFieldOutput: listing))
    }
}

final class CodexJumpTests: XCTestCase {
    func testIsCodexCLIMatchesOnlyTheCodexExecutable() {
        XCTAssertTrue(TTYResolver.isCodexCLI(command: "/usr/local/bin/codex resume abc-123"))
        XCTAssertTrue(TTYResolver.isCodexCLI(command: "codex"))
        XCTAssertFalse(TTYResolver.isCodexCLI(command: "/usr/bin/vim codex-notes.md"))
        XCTAssertFalse(TTYResolver.isCodexCLI(command: "/usr/local/bin/claude"))
    }

    // ChatGPT.app embeds its own binary literally named "codex", plus separate XPC helper
    // processes — none of these are an interactive CLI session (#24). Each marker is checked
    // both alongside the full ChatGPT.app path (the realistic shape) and in isolation (so the
    // rejection isn't accidentally riding solely on the "chatgpt.app" substring).
    func testIsCodexCLIRejectsChatGPTAppHelperProcesses() {
        XCTAssertFalse(TTYResolver.isCodexCLI(
            command: "/Applications/ChatGPT.app/Contents/Resources/codex --codex-run-as-apiserver app-server"
        ))
        XCTAssertFalse(TTYResolver.isCodexCLI(
            command: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/A/Codex Framework"
        ))
        XCTAssertFalse(TTYResolver.isCodexCLI(
            command: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/XPCServices/Codex (Service).xpc/Contents/MacOS/Codex (Service)"
        ))
        XCTAssertFalse(TTYResolver.isCodexCLI(
            command: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/XPCServices/Codex (Renderer).xpc/Contents/MacOS/Codex (Renderer)"
        ))
        // Each marker in isolation, without the ChatGPT.app path prefix.
        XCTAssertFalse(TTYResolver.isCodexCLI(command: "codex app-server"))
        XCTAssertFalse(TTYResolver.isCodexCLI(command: "Codex Framework.framework/Versions/A/Codex Framework"))
        XCTAssertFalse(TTYResolver.isCodexCLI(command: "Codex (Service)"))
        XCTAssertFalse(TTYResolver.isCodexCLI(command: "Codex (Renderer)"))
        // A real interactive CLI invocation must still be accepted.
        XCTAssertTrue(TTYResolver.isCodexCLI(command: "/usr/local/bin/codex"))
        XCTAssertTrue(TTYResolver.isCodexCLI(command: "/opt/homebrew/bin/codex resume 019fe8a4-1234"))
    }

    func testGeneralizedAgentCLICheckDispatchesByAgentName() {
        XCTAssertTrue(TTYResolver.isAgentCLI("Codex", command: "/usr/local/bin/codex"))
        XCTAssertFalse(TTYResolver.isAgentCLI("Codex", command: "/usr/local/bin/claude"))
        XCTAssertTrue(TTYResolver.isAgentCLI("Claude", command: "/usr/local/bin/claude"))
        XCTAssertFalse(TTYResolver.isAgentCLI("Claude", command: "/usr/local/bin/codex"))
        // Anything unrecognized defaults to the Claude rules — the same assumption every
        // call site already made before Codex existed.
        XCTAssertTrue(TTYResolver.isAgentCLI("SomeFutureAgent", command: "/usr/local/bin/claude"))
    }

    func testCodexRungPrefersLiveProcessMatchOverNewTab() {
        let processes = [
            ClaudeProcess(pid: 40, command: "/usr/local/bin/codex", cwd: "/repo", tty: "ttys005"),
            ClaudeProcess(pid: 41, command: "/usr/local/bin/claude", cwd: "/repo", tty: "ttys006")
        ]

        XCTAssertEqual(
            Jumper.rung(for: "/repo", agentName: "Codex", processes: processes),
            .exactFocus(tty: "ttys005")
        )
        XCTAssertEqual(
            Jumper.rung(for: "/repo", agentName: "Claude", processes: processes),
            .exactFocus(tty: "ttys006")
        )
    }

    func testCodexRungFallsBackToNewTabWithoutALiveProcess() {
        XCTAssertEqual(
            Jumper.rung(for: "/repo", agentName: "Codex", processes: []),
            .newTab
        )
        // A live Claude process at the same cwd must never satisfy a Codex rung.
        XCTAssertEqual(
            Jumper.rung(for: "/repo", agentName: "Codex", processes: [
                ClaudeProcess(pid: 1, command: "/usr/local/bin/claude", cwd: "/repo", tty: "ttys001")
            ]),
            .newTab
        )
    }

    func testCodexResumeCommandIsShellQuoted() {
        XCTAssertEqual(
            Jumper.codexResumeCommand(sessionId: "019fe8a4-1234"),
            "codex resume '019fe8a4-1234'"
        )
    }

    func testNewTabShellCommandUsesCodexResumeWhenProvided() {
        let resume = Jumper.codexResumeCommand(sessionId: "019fe8a4-1234")
        let command = Jumper.newTabShellCommand(cwd: "/Users/me/My Repo's", resumeCommand: resume)

        XCTAssertTrue(command.hasPrefix("/bin/zsh -lc '"))
        XCTAssertTrue(command.contains("cd -- "))
        XCTAssertTrue(command.contains("My Repo"))
        XCTAssertTrue(command.contains("codex resume"))
        XCTAssertTrue(command.contains("019fe8a4-1234"))
        // Without a resumeCommand, behavior must stay byte-identical to the Claude path.
        XCTAssertFalse(command.contains("exec"))
    }

    func testNewTabShellCommandWithoutResumeCommandStillDropsIntoALoginShell() {
        let command = Jumper.newTabShellCommand(cwd: "/repo")
        XCTAssertTrue(command.contains("exec"))
        XCTAssertTrue(command.contains("SHELL:-/bin/zsh"))
    }
}
