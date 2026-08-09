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
}
