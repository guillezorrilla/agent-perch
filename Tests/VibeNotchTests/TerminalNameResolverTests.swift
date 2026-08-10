import XCTest
@testable import VibeNotch

final class TerminalNameResolverTests: XCTestCase {
    func testMapsKnownTerminalAncestorsUsingInjectedProcessTable() {
        let cases = [
            ("/Applications/iTerm.app/Contents/MacOS/iTerm2", "iTerm"),
            ("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Apple_Terminal", "Terminal"),
            ("/Applications/Warp.app/Contents/MacOS/WarpTerminal", "Warp"),
            ("/Applications/Warp.app/Contents/MacOS/stable", "Warp"),
            ("tmux: server", "tmux"),
            ("/Applications/Ghostty.app/Contents/MacOS/ghostty", "Ghostty"),
            ("/Applications/WezTerm.app/Contents/MacOS/wezterm", "WezTerm"),
            ("/Applications/kitty.app/Contents/MacOS/kitty", "Kitty"),
            ("/Applications/cmux.app/Contents/MacOS/cmux", "cmux"),
            ("cmux", "cmux")
        ]

        for (command, expected) in cases {
            let table: [Int32: AncestorProcess] = [
                30: AncestorProcess(pid: 30, parentPID: 20, command: "claude"),
                20: AncestorProcess(pid: 20, parentPID: 10, command: "/bin/zsh"),
                10: AncestorProcess(pid: 10, parentPID: 1, command: command)
            ]
            let resolver = TerminalNameResolver { table[$0] }
            XCTAssertEqual(resolver.terminalName(for: 30), expected, command)
        }
    }

    func testCachesResolutionPerClaudePID() {
        let table: [Int32: AncestorProcess] = [
            30: AncestorProcess(pid: 30, parentPID: 20, command: "claude"),
            20: AncestorProcess(pid: 20, parentPID: 1, command: "ghostty")
        ]
        var lookups = 0
        let resolver = TerminalNameResolver {
            lookups += 1
            return table[$0]
        }

        XCTAssertEqual(resolver.terminalName(for: 30), "Ghostty")
        let firstLookupCount = lookups
        XCTAssertEqual(resolver.terminalName(for: 30), "Ghostty")
        XCTAssertEqual(lookups, firstLookupCount)
    }

    func testUnknownAncestorReturnsNil() {
        let table: [Int32: AncestorProcess] = [
            30: AncestorProcess(pid: 30, parentPID: 20, command: "claude"),
            20: AncestorProcess(pid: 20, parentPID: 1, command: "/bin/zsh")
        ]
        XCTAssertNil(TerminalNameResolver { table[$0] }.terminalName(for: 30))
    }
}
