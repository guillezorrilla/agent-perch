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
}
