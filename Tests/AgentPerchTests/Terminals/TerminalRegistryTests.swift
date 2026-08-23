import XCTest
@testable import AgentPerch

/// The invariants that used to be spread across six switches keyed on the same string, and so
/// could only be checked by reading all six.
final class TerminalRegistryTests: XCTestCase {
    func testEveryTerminalIsReachableByItsOwnNameAndAliases() {
        for capability in TerminalRegistry.all {
            for key in capability.keys {
                XCTAssertEqual(
                    TerminalRegistry.capability(for: key)?.name,
                    capability.name,
                    "\(key) should resolve to \(capability.name)"
                )
            }
        }
    }

    func testLookupIsCaseInsensitiveBecauseCallersSpellItBothWays() {
        XCTAssertEqual(TerminalRegistry.capability(for: "GHOSTTY")?.name, "Ghostty")
        XCTAssertEqual(TerminalRegistry.capability(for: "Terminal.app")?.name, "Terminal")
        XCTAssertNil(TerminalRegistry.capability(for: "nothing-by-that-name"))
        XCTAssertNil(TerminalRegistry.capability(for: nil))
    }

    func testNoTwoTerminalsClaimTheSameSpelling() {
        var seen: Set<String> = []
        for key in TerminalRegistry.all.flatMap(\.keys) {
            XCTAssertTrue(seen.insert(key).inserted, "\(key) is claimed by two rows")
        }
    }

    /// `JumpPlan.CwdFocusApp` reads its bundle identifier and its miss behavior off the registry
    /// now. If a case ever loses its row those fall back to `""` and `false`, so this is the test
    /// that keeps the fallback unreachable.
    func testEveryCwdFocusAppHasARowWithASurfaceFocus() {
        for app in [JumpPlan.CwdFocusApp.ghostty, .cmux] {
            guard let capability = TerminalRegistry.capability(for: app.rawValue) else {
                return XCTFail("\(app.rawValue) has no row in TerminalRegistry")
            }
            XCTAssertFalse(app.bundleIdentifier.isEmpty)
            XCTAssertEqual(app.bundleIdentifier, capability.bundleIdentifiers.first)
            guard case .cwdSurface = capability.focus else {
                return XCTFail("\(app.rawValue) is focused by cwd, so its row must say so")
            }
        }
    }

    func testCmuxKeepsItsActivateOnMissFloorAndGhosttyDoesNot() {
        XCTAssertTrue(JumpPlan.CwdFocusApp.cmux.activatesOnMiss)
        XCTAssertFalse(
            JumpPlan.CwdFocusApp.ghostty.activatesOnMiss,
            "Ghostty's miss falls through to the ladder — which now has a Ghostty arm"
        )
    }

    /// Recognition moved onto the rows from `TerminalNameResolver`'s if-chain. These are the exact
    /// cases that chain encoded, including the two that depend on its ordering.
    func testProcessRecognitionMatchesTheChainItReplaced() {
        let expected: [(String, String?)] = [
            ("/Applications/iTerm.app/Contents/MacOS/iTerm2", "iTerm"),
            ("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "Terminal"),
            ("/Applications/Warp.app/Contents/MacOS/stable", "Warp"),
            ("/opt/homebrew/bin/tmux: server", "tmux"),
            ("/Applications/Ghostty.app/Contents/MacOS/ghostty", "Ghostty"),
            ("/opt/homebrew/bin/wezterm-gui", "WezTerm"),
            ("/Applications/kitty.app/Contents/MacOS/kitty", "Kitty"),
            ("/Applications/cmux.app/Contents/MacOS/cmux", "cmux"),
            ("/bin/zsh", nil),
            ("/usr/bin/ssh", nil),
        ]
        for (command, name) in expected {
            XCTAssertEqual(TerminalRegistry.recognise(command: command), name, command)
        }
    }

    /// tmux only counts when it is the server process — a plain `tmux` client is not a terminal.
    func testTmuxNeedsBothWordsNotJustItsName() {
        XCTAssertEqual(TerminalRegistry.recognise(command: "/opt/homebrew/bin/tmux: server"), "tmux")
        XCTAssertNil(TerminalRegistry.recognise(command: "/opt/homebrew/bin/tmux attach"))
    }

    /// Every terminal that can be answered by tty must also be reachable by the jump path, and
    /// every terminal answered by cwd must be focusable by cwd. This is the agreement that had no
    /// enforcement at all when the two lived in different directories.
    func testAnswerAndFocusStrategiesAgreeAboutHowATerminalIsAddressed() {
        for capability in TerminalRegistry.all {
            switch capability.answer {
            case .warpTabByCwd:
                XCTAssertEqual(capability.focus, .warpTabIndex, capability.name)
            case .surfaceByCwd:
                guard case .cwdSurface = capability.focus else {
                    return XCTFail("\(capability.name) answers by cwd but is not focused by cwd")
                }
            case .iTermAppleScript, .terminalAppleScript:
                XCTAssertEqual(capability.focus, .appleScriptTTY, capability.name)
            case .wezTermCLI:
                XCTAssertEqual(capability.focus, .wezTermCLI, capability.name)
            case .tmuxCLI, .kittyRemote, .unsupported:
                // Addressed by tty through their own CLI, with no window to focus of their own.
                XCTAssertEqual(capability.focus, .unsupported, capability.name)
            }
        }
    }
}
