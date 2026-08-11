import XCTest
@testable import VibeNotch

final class ActionInjectorTests: XCTestCase {
    func testITermMapsAllowToOneAndDenyToEscape() {
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "iTerm", tty: "ttys001", decision: .allow),
            .iTerm(tty: "ttys001", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "iTerm2", tty: "ttys001", decision: .deny),
            .iTerm(tty: "ttys001", key: .escape)
        )
    }

    func testTmuxMapsAllowToOneAndDenyToEscape() {
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "tmux", tty: "/dev/ttys002", decision: .allow),
            .tmux(tty: "ttys002", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "tmux", tty: "ttys002", decision: .deny),
            .tmux(tty: "ttys002", key: .escape)
        )
    }

    func testTerminalMapsAllowToOneAndDenyToEscape() {
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "Terminal", tty: "ttys003", decision: .allow),
            .terminal(tty: "ttys003", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "Terminal.app", tty: "ttys003", decision: .deny),
            .terminal(tty: "ttys003", key: .escape)
        )
    }

    func testUnknownTerminalOrMissingTTYRequiresManualResponse() {
        XCTAssertNil(ActionInjector.plan(terminalName: "Warp", tty: "ttys004", decision: .allow))
        XCTAssertNil(ActionInjector.plan(terminalName: "iTerm", tty: nil, decision: .allow))
    }

    func testWarpMapsAllowToOneAndDenyToEscapeUsingCwd() {
        XCTAssertEqual(
            ActionInjector.plan(
                terminalName: "Warp", tty: nil, cwd: "/repo", decision: .allow
            ),
            .warp(cwd: "/repo", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(
                terminalName: "warp", tty: nil, cwd: "/repo", decision: .deny
            ),
            .warp(cwd: "/repo", key: .escape)
        )
    }

    func testWarpMapsOptionDigitsToThatDigit() {
        for number in 1...9 {
            XCTAssertEqual(
                ActionInjector.plan(
                    terminalName: "Warp", tty: nil, cwd: "/repo", digit: String(number)
                ),
                .warp(cwd: "/repo", key: .text(String(number)))
            )
        }
    }

    // Warp exposes no per-tab tty, so the tty must never decide the plan for it.
    func testWarpIgnoresTTYAndRequiresCwd() {
        XCTAssertEqual(
            ActionInjector.plan(
                terminalName: "Warp", tty: "ttys004", cwd: "/repo", decision: .allow
            ),
            .warp(cwd: "/repo", key: .text("1"))
        )
        XCTAssertNil(
            ActionInjector.plan(terminalName: "Warp", tty: "ttys004", cwd: "", decision: .allow)
        )
        XCTAssertNil(
            ActionInjector.plan(terminalName: "Warp", tty: "ttys004", cwd: nil, decision: .allow)
        )
    }

    // A cwd is available for every session, so it must not divert the tty-based terminals.
    func testCwdDoesNotDivertTTYBasedTerminals() {
        XCTAssertEqual(
            ActionInjector.plan(
                terminalName: "iTerm", tty: "ttys001", cwd: "/repo", decision: .allow
            ),
            .iTerm(tty: "ttys001", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(
                terminalName: "WezTerm", tty: "ttys001", cwd: "/repo", decision: .allow
            ),
            .wezTerm(tty: "ttys001", key: .text("1"))
        )
        // …and the reverse for Ghostty, which has no per-surface tty at all: it is addressed by
        // cwd whether or not a tty happens to be known (#42). It used to have no answer route.
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "Ghostty", tty: "ttys001", cwd: "/repo", decision: .allow),
            .surface(app: .ghostty, cwd: "/repo", key: .text("1"))
        )
    }

    // A session whose tty never reached us — Claude Code spawns its hooks detached from the
    // controlling terminal, so the hook reports `??` and it is dropped — was jumpable and
    // unanswerable (#48). Jump's own fallback is the tty of a shell still sitting at the cwd, and
    // the plan a recovered tty produces must be indistinguishable from a reported one's.
    func testARecoveredTTYProducesTheSamePlanAsAReportedOne() {
        for terminal in ["iTerm", "iTerm2"] {
            XCTAssertEqual(
                ActionInjector.plan(
                    for: session(tty: nil, cwd: "/repo", terminalName: terminal),
                    key: .text("1"),
                    recoverTTY: { _ in "ttys027" }
                ),
                ActionInjector.plan(terminalName: terminal, tty: "ttys027", cwd: "/repo", decision: .allow)
            )
        }
        XCTAssertEqual(
            ActionInjector.plan(
                for: session(tty: nil, cwd: "/repo", terminalName: nil),
                key: .escape,
                recoverTTY: { _ in "ttys027" }
            ),
            ActionInjector.plan(terminalName: nil, tty: "ttys027", cwd: "/repo", decision: .deny)
        )
    }

    // The tty-addressed terminals that are NOT `Jumper.canExactFocus`: a tty recovered from a cwd
    // would name a sibling pane or window, so neither is offered one and both keep refusing (#42).
    func testWezTermAndKittyAreNeverGivenACwdRecoveredTTY() {
        var recoveries = 0

        for terminal in ["WezTerm", "Kitty"] {
            XCTAssertNil(
                ActionInjector.plan(
                    for: session(tty: nil, cwd: "/repo", terminalName: terminal),
                    key: .text("1"),
                    recoverTTY: { _ in recoveries += 1; return "ttys027" }
                )
            )
        }
        XCTAssertEqual(recoveries, 0)
    }

    private func session(tty: String?, cwd: String, terminalName: String?) -> AgentSession {
        AgentSession(
            sessionId: "session-1",
            agentName: "Claude",
            cwd: cwd,
            modifiedAt: Date(),
            status: .needsAction,
            jumpRung: .newTab,
            title: "",
            lastPrompt: nil,
            tty: tty,
            terminalName: terminalName,
            currentActivity: nil,
            notificationMessage: nil,
            pendingToolName: nil,
            pendingToolInput: nil,
            resumeCommand: nil
        )
    }

    func testSupportedTerminalsMapOptionDigitsToTextKeystrokes() {
        for number in 1...9 {
            let digit = String(number)
            XCTAssertEqual(
                ActionInjector.plan(terminalName: "iTerm", tty: "ttys001", digit: digit),
                .iTerm(tty: "ttys001", key: .text(digit))
            )
            XCTAssertEqual(
                ActionInjector.plan(terminalName: "tmux", tty: "/dev/ttys002", digit: digit),
                .tmux(tty: "ttys002", key: .text(digit))
            )
            XCTAssertEqual(
                ActionInjector.plan(terminalName: "Terminal", tty: "ttys003", digit: digit),
                .terminal(tty: "ttys003", key: .text(digit))
            )
        }
    }
}
