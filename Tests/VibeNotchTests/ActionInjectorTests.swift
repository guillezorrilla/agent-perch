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
}
