import XCTest
@testable import VibeNotch

/// Records what a jump would have run instead of running it. `Jumper` took an `AppleScriptRunner`
/// as a hardwired `private let` until now, which put every script in the jump path — and the whole
/// reopen ladder — out of reach of any test.
final class RecordingAppleScript: AppleScripting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let answer: Bool

    init(answer: Bool = true) { self.answer = answer }

    var sources: [String] { lock.withLock { recorded } }

    func run(_ source: String) -> Bool {
        lock.withLock { recorded.append(source) }
        return answer
    }
}

final class RecordingLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(executable: String, arguments: [String])] = []
    private let answer: Bool

    init(answer: Bool = true) { self.answer = answer }

    var launches: [(executable: String, arguments: [String])] { lock.withLock { recorded } }

    func launch(_ executable: String, _ arguments: [String]) -> Bool {
        lock.withLock { recorded.append((executable, arguments)) }
        return answer
    }
}

final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var urls: [URL] { lock.withLock { recorded } }

    func open(_ url: URL) -> Bool {
        lock.withLock { recorded.append(url) }
        return true
    }
}

@MainActor
final class ReopenLadderTests: XCTestCase {
    private func jumper(
        script: RecordingAppleScript = RecordingAppleScript(),
        launcher: RecordingLauncher = RecordingLauncher(),
        openedURLs: URLRecorder = URLRecorder(),
        installed: Set<String> = ["com.googlecode.iterm2", "com.apple.Terminal",
                                  "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                                  "com.github.wez.wezterm"]
    ) -> Jumper {
        Jumper(
            appleScript: script,
            appURL: { installed.contains($0) ? URL(fileURLWithPath: "/Applications/\($0).app") : nil },
            launch: { launcher.launch($0, $1) },
            openURL: { openedURLs.open($0) }
        )
    }

    private func reopen(_ terminal: String?, with jumper: Jumper, resumeCommand: String? = nil) {
        _ = jumper.perform(
            JumpPlan(target: .newTab, cwd: "/repo", terminal: terminal, resumeCommand: resumeCommand)
        )
    }

    /// The bug this whole seam exists to catch.
    ///
    /// `openerOrder` guarded on a hardcoded `["iterm", "terminal", "warp"]`, so Ghostty — absent
    /// from that list and from `openNewTab`'s switch — fell straight through to iTerm's
    /// `create window`. A user running Ghostty clicked a dead session and got somebody else's
    /// terminal.
    func testGhosttySessionReopensInGhosttyRatherThanITerm() {
        let script = RecordingAppleScript()
        let launcher = RecordingLauncher()
        reopen("ghostty", with: jumper(script: script, launcher: launcher))

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].executable.hasSuffix("Contents/MacOS/ghostty"))
        XCTAssertEqual(launcher.launches[0].arguments, ["+new-window", "--working-directory=/repo"])
        XCTAssertTrue(
            script.sources.isEmpty,
            "Reopening Ghostty must not run iTerm's AppleScript — that was the bug"
        )
    }

    func testGhosttyReopenCarriesTheResumeCommand() {
        let launcher = RecordingLauncher()
        reopen("ghostty", with: jumper(launcher: launcher), resumeCommand: "codex resume abc")

        let arguments = launcher.launches[0].arguments
        XCTAssertEqual(arguments.prefix(2), ["+new-window", "--working-directory=/repo"])
        // `-e` swallows everything after it, so it has to come last.
        XCTAssertEqual(arguments[2], "-e")
        XCTAssertTrue(arguments.last?.contains("codex resume abc") == true)
    }

    func testWezTermReopensThroughItsOwnCLI() {
        let script = RecordingAppleScript()
        let launcher = RecordingLauncher()
        reopen("wezterm", with: jumper(script: script, launcher: launcher))

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].executable.hasSuffix("Contents/MacOS/wezterm"))
        XCTAssertEqual(launcher.launches[0].arguments, ["start", "--cwd", "/repo"])
        XCTAssertTrue(script.sources.isEmpty)
    }

    /// Addressed through `/usr/bin/env wezterm` this reported success and stopped the ladder even
    /// with no WezTerm installed: `env` launches fine and only *then* exits 127, long after
    /// `runDetached` has said the launch was accepted. Nothing opened, and the user got no window
    /// at all rather than a fallback one.
    func testWezTermFallsBackToTheGenericLadderWhenItIsNotInstalled() {
        let script = RecordingAppleScript()
        let launcher = RecordingLauncher()
        reopen("wezterm", with: jumper(script: script, launcher: launcher, installed: ["com.googlecode.iterm2"]))

        XCTAssertTrue(launcher.launches.isEmpty, "nothing should be launched for an absent WezTerm")
        XCTAssertEqual(script.sources.count, 1)
        XCTAssertTrue(script.sources[0].contains("com.googlecode.iterm2"))
    }

    /// The same trap, checked for every terminal that reopens by launching something: a reopen may
    /// only claim the jump when it has actually found the app to launch.
    func testNoReopenClaimsSuccessWithoutAnInstalledApp() {
        for terminal in ["ghostty", "wezterm"] {
            let launcher = RecordingLauncher()
            let jumper = jumper(launcher: launcher, installed: [])
            let handled = jumper.perform(
                JumpPlan(target: .newTab, cwd: "/repo", terminal: terminal, resumeCommand: nil)
            )
            XCTAssertTrue(launcher.launches.isEmpty, "\(terminal) launched something that is not there")
            XCTAssertFalse(handled, "\(terminal) claimed a jump it did not make")
        }
    }

    /// Ghostty not being installed is the one case where landing in iTerm is genuinely right.
    func testGhosttyFallsBackToTheGenericLadderWhenItIsNotInstalled() {
        let script = RecordingAppleScript()
        let launcher = RecordingLauncher()
        reopen("ghostty", with: jumper(script: script, launcher: launcher, installed: ["com.googlecode.iterm2"]))

        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(script.sources.count, 1)
        XCTAssertTrue(script.sources[0].contains("com.googlecode.iterm2"))
    }

    /// A terminal whose row says it has no reopen mechanism at all. Falling back is correct here —
    /// the point is that it is now a recorded decision rather than an omission.
    func testKittyFallsBackToTheGenericLadder() {
        let script = RecordingAppleScript()
        reopen("kitty", with: jumper(script: script))

        XCTAssertEqual(script.sources.count, 1)
        XCTAssertTrue(script.sources[0].contains("com.googlecode.iterm2"))
    }

    func testITermSessionStillReopensInITerm() {
        let script = RecordingAppleScript()
        let launcher = RecordingLauncher()
        reopen("iterm", with: jumper(script: script, launcher: launcher))

        XCTAssertEqual(script.sources.count, 1)
        XCTAssertTrue(script.sources[0].contains("com.googlecode.iterm2"))
        XCTAssertTrue(script.sources[0].contains("/repo"))
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testTerminalAppSessionStillReopensInTerminalApp() {
        let script = RecordingAppleScript()
        reopen("terminal.app", with: jumper(script: script))

        XCTAssertEqual(script.sources.count, 1)
        XCTAssertTrue(script.sources[0].contains("tell application \"Terminal\""))
    }

    /// A failing opener must not stop the ladder — iTerm refusing hands over to Terminal.
    func testAFailingOpenerFallsThroughToTheNextOne() {
        let script = RecordingAppleScript(answer: false)
        let opened = URLRecorder()
        reopen(nil, with: jumper(script: script, openedURLs: opened))

        XCTAssertEqual(script.sources.count, 2, "iTerm then Terminal; Warp is a URL, not a script")
        XCTAssertTrue(script.sources[0].contains("com.googlecode.iterm2"))
        XCTAssertTrue(script.sources[1].contains("tell application \"Terminal\""))
        XCTAssertEqual(opened.urls.map(\.scheme), ["warp"], "and then the ladder reaches Warp")
    }
}
