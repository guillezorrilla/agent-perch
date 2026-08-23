import XCTest
@testable import AgentPerch

/// WezTerm is the one terminal without an AppleScript dictionary that still reports a real
/// per-pane tty, so these cover the decode of its CLI's real output shape and the tty-before-cwd
/// ranking that keeps a jump off the wrong pane (#4).
final class WezTermFocuserTests: XCTestCase {
    /// Trimmed from real `wezterm cli list --format json` output on a three-pane WezTerm: two
    /// panes share `/private/tmp`, only one of them is the session's. `is_zoomed` and `size` stand
    /// in for the dozen fields we never read, and pane 3 carries no `tty_name` at all.
    private let listing = """
        [
          { "window_id": 0, "tab_id": 0, "pane_id": 0, "workspace": "default",
            "title": "~", "cwd": "file://guillermos-macbook-pro.local/Users/gzorrilla",
            "size": { "rows": 24, "cols": 80 }, "is_zoomed": false,
            "is_active": true, "tty_name": "/dev/ttys005" },
          { "window_id": 0, "tab_id": 1, "pane_id": 1,
            "cwd": "file://guillermos-macbook-pro.local/private/tmp",
            "is_active": true, "tty_name": "/dev/ttys042" },
          { "window_id": 0, "tab_id": 2, "pane_id": 2,
            "cwd": "file://guillermos-macbook-pro.local/private/tmp",
            "is_active": true, "tty_name": "/dev/ttys049" },
          { "window_id": 0, "tab_id": 3, "pane_id": 3,
            "cwd": "file://guillermos-macbook-pro.local/repo",
            "is_active": false }
        ]
        """

    override func tearDown() {
        WezTermFocuser.resetCacheForTesting()
    }

    func testDecodesRealListingIgnoringUnknownFieldsAndAMissingTTY() {
        let panes = WezTermFocuser.parsePanes(listing)

        XCTAssertEqual(panes.count, 4)
        XCTAssertEqual(panes[0].paneId, 0)
        XCTAssertEqual(panes[0].ttyName, "/dev/ttys005")
        XCTAssertEqual(panes[0].cwd, "file://guillermos-macbook-pro.local/Users/gzorrilla")
        // A pane with no controlling terminal must decode, not take the whole array down.
        XCTAssertEqual(panes[3].paneId, 3)
        XCTAssertNil(panes[3].ttyName)
    }

    func testMalformedOutputDecodesToNothingRatherThanThrowing() {
        XCTAssertEqual(WezTermFocuser.parsePanes(""), [])
        XCTAssertEqual(WezTermFocuser.parsePanes("wezterm: not running"), [])
        // `pane_id` is the one field a focus cannot be composed without.
        XCTAssertEqual(WezTermFocuser.parsePanes("""
            [{ "tty_name": "/dev/ttys005" }]
            """), [])
    }

    /// The regression that matters most: pane 1 and pane 2 share a cwd, so a cwd-first ranking
    /// would focus whichever came first in the list. The tty names the session exactly (#23).
    func testTTYWinsOverADifferentPaneWhoseCwdAlsoMatches() {
        let panes = WezTermFocuser.parsePanes(listing)

        XCTAssertEqual(WezTermFocuser.selectPane(from: panes, tty: "ttys049", cwd: "/tmp"), 2)
        XCTAssertEqual(WezTermFocuser.selectPane(from: panes, tty: "ttys042", cwd: "/tmp"), 1)
    }

    func testTTYPrefixIsNormalizedInBothDirections() {
        let panes = WezTermFocuser.parsePanes(listing)

        // WezTerm reports `/dev/ttys042`; `JumpTarget` carries `ttys042`. Either spelling on
        // either side has to reach the same pane.
        XCTAssertEqual(WezTermFocuser.selectPane(from: panes, tty: "ttys042", cwd: nil), 1)
        XCTAssertEqual(WezTermFocuser.selectPane(from: panes, tty: "/dev/ttys042", cwd: nil), 1)

        let bareInListing = WezTermFocuser.parsePanes("""
            [{ "pane_id": 7, "tty_name": "ttys077", "cwd": "file://host/repo" }]
            """)
        XCTAssertEqual(WezTermFocuser.selectPane(from: bareInListing, tty: "/dev/ttys077", cwd: nil), 7)
        XCTAssertEqual(WezTermFocuser.selectPane(from: bareInListing, tty: "ttys077", cwd: nil), 7)
    }

    /// The agent has exited, so nothing carries its tty — WezTerm's own pane list still knows
    /// which pane sits at the cwd, which is the answer `shellTTY` would pay an `lsof` to guess.
    func testFallsBackToCwdWhenNoTTYMatches() {
        let panes = WezTermFocuser.parsePanes(listing)

        XCTAssertEqual(WezTermFocuser.selectPane(from: panes, tty: nil, cwd: "/repo"), 3)
        // A tty that names no live pane must not stop the cwd fallback from running.
        XCTAssertEqual(WezTermFocuser.selectPane(from: panes, tty: "ttys999", cwd: "/repo"), 3)
        // `/tmp` and the `/private/tmp` WezTerm reports are the same directory (`CanonicalPath`).
        XCTAssertEqual(WezTermFocuser.selectPane(from: panes, tty: nil, cwd: "/tmp"), 1)
        XCTAssertEqual(WezTermFocuser.selectPane(from: panes, tty: nil, cwd: "/private/tmp"), 1)
    }

    func testReturnsNilWhenNothingMatchesSoTheCallerKeepsItsLadder() {
        let panes = WezTermFocuser.parsePanes(listing)

        XCTAssertNil(WezTermFocuser.selectPane(from: panes, tty: "ttys999", cwd: "/nowhere"))
        XCTAssertNil(WezTermFocuser.selectPane(from: panes, tty: nil, cwd: nil))
        XCTAssertNil(WezTermFocuser.selectPane(from: panes, tty: nil, cwd: ""))
        XCTAssertNil(WezTermFocuser.selectPane(from: [], tty: "ttys005", cwd: "/repo"))
        // `??` is `ps`'s "no controlling terminal" and must never match a pane that also has none.
        XCTAssertNil(WezTermFocuser.selectPane(from: panes, tty: "??", cwd: nil))
    }

    func testFileURLCwdsAreReducedToPlainPaths() {
        // The host is the machine name, not a path component.
        XCTAssertEqual(
            WezTermFocuser.path(fromFileURL: "file://guillermos-macbook-pro.local/private/tmp"),
            "/private/tmp"
        )
        XCTAssertEqual(WezTermFocuser.path(fromFileURL: "file:///Users/me/repo"), "/Users/me/repo")
        // Percent-escapes come back decoded, so a repo with a space still compares equal.
        XCTAssertEqual(WezTermFocuser.path(fromFileURL: "file://host/Users/me/My%20Repo"), "/Users/me/My Repo")
        XCTAssertNil(WezTermFocuser.path(fromFileURL: "not a url at all"))
    }

    func testAttemptFocusStopsBeforeShellingOutWhenWezTermIsNotInstalled() {
        let handled = WezTermFocuser.attemptFocus(
            tty: "ttys042",
            cwd: "/tmp",
            isAvailable: { false },
            listPanes: { XCTFail("must not list panes when WezTerm isn't installed"); return nil },
            activatePane: { _ in XCTFail("must not activate a pane"); return false },
            activateApp: { XCTFail("must not activate WezTerm"); return false }
        )
        XCTAssertFalse(handled)
    }

    /// `activate-pane` switches the pane but does NOT bring WezTerm forward — verified live — so
    /// app activation is part of the jump, not an optional extra (#4).
    func testAttemptFocusActivatesTheMatchedPaneAndThenTheApp() {
        var activatedPane: Int?
        var activatedApp = false
        let handled = WezTermFocuser.attemptFocus(
            tty: "ttys049",
            cwd: "/tmp",
            isAvailable: { true },
            listPanes: { self.listing },
            activatePane: {
                activatedPane = $0
                return true
            },
            activateApp: {
                activatedApp = true
                return true
            }
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(activatedPane, 2)
        XCTAssertTrue(activatedApp)
    }

    func testAttemptFocusReportsAMissWithoutActivatingAnything() {
        var activatedApp = false
        let handled = WezTermFocuser.attemptFocus(
            tty: "ttys999",
            cwd: "/nowhere",
            isAvailable: { true },
            listPanes: { self.listing },
            activatePane: { _ in XCTFail("no pane matched; must not activate one"); return false },
            activateApp: {
                activatedApp = true
                return true
            }
        )

        XCTAssertFalse(handled)
        XCTAssertFalse(activatedApp)
        // WezTerm not running: the CLI returns nothing and the jump falls through untouched.
        XCTAssertFalse(WezTermFocuser.attemptFocus(
            tty: "ttys042",
            cwd: "/tmp",
            isAvailable: { true },
            listPanes: { nil },
            activatePane: { _ in XCTFail("nothing was listed; must not activate a pane"); return false },
            activateApp: { XCTFail("nothing was listed; must not activate WezTerm"); return false }
        ))
    }

    func testAvailabilityIsCachedSoAJumpNeverReprobes() {
        var probes = 0
        let which: (String) -> String? = { _ in
            probes += 1
            return "/opt/homebrew/bin/wezterm"
        }
        XCTAssertTrue(WezTermFocuser.isAvailable(which: which))
        XCTAssertTrue(WezTermFocuser.isAvailable(which: which))
        XCTAssertEqual(probes, 1)
    }
}

/// Ghostty and cmux are focused by cwd because neither exposes a tty at all. These cover the
/// routing and the one behavior that differs between them (#4).
final class CwdFocusJumpTests: XCTestCase {
    private func route(
        terminal: String?,
        cwd: String = "/repo",
        tty: String? = nil,
        focusWezTerm: (String?, String) -> Bool = { _, _ in
            XCTFail("only a wezterm session may reach WezTerm")
            return false
        },
        cmuxAvailable: () -> Bool = { true }
    ) -> JumpPlan.Target? {
        Jumper.routeTerminalJump(
            terminal: terminal,
            cwd: cwd,
            tty: tty,
            focusWezTerm: focusWezTerm,
            cmuxAvailable: cmuxAvailable
        )
    }

    func testGhosttySessionRoutesToACwdFocus() {
        XCTAssertEqual(
            route(terminal: "ghostty"),
            .focusTerminalByCwd(app: .ghostty, cwd: "/repo")
        )
    }

    func testCmuxSessionRoutesToACwdFocusWhenInstalled() {
        XCTAssertEqual(
            route(terminal: "cmux"),
            .focusTerminalByCwd(app: .cmux, cwd: "/repo")
        )
        // Not installed at all still falls through to the pre-cmux ladder (#3).
        XCTAssertNil(route(terminal: "cmux", cmuxAvailable: { false }))
    }

    /// WezTerm has already been focused off the main actor by the time this returns, so the plan
    /// only has to report success — the same shape the cmux branch had before #4.
    func testWezTermSessionFocusesOffTheMainActorAndReportsAlreadyFocused() {
        var askedWith: (tty: String?, cwd: String)?
        let target = route(
            terminal: "wezterm",
            cwd: "/repo",
            tty: "ttys042",
            focusWezTerm: { tty, cwd in
                askedWith = (tty, cwd)
                return true
            }
        )

        XCTAssertEqual(target, .alreadyFocused)
        XCTAssertEqual(askedWith?.tty, "ttys042")
        XCTAssertEqual(askedWith?.cwd, "/repo")
    }

    func testWezTermMissFallsThroughRatherThanDeadEnding() {
        XCTAssertNil(route(terminal: "wezterm", focusWezTerm: { _, _ in false }))
    }

    /// The terminals that already worked must keep reaching the tty ladder untouched.
    func testUnroutedTerminalsAreLeftToTheExistingLadder() {
        for terminal in ["iterm", "terminal", "warp", "kitty", "tmux", nil] {
            XCTAssertNil(route(terminal: terminal), "\(terminal ?? "nil") must not be rerouted")
        }
    }

    /// cmux keeps the floor it had before #4 — a miss surfaces cmux itself rather than opening an
    /// iTerm window beside it. Ghostty never had that floor, so its miss stays a miss.
    func testOnlyCmuxTreatsAMissAsHandled() {
        XCTAssertTrue(JumpPlan.CwdFocusApp.cmux.activatesOnMiss)
        XCTAssertFalse(JumpPlan.CwdFocusApp.ghostty.activatesOnMiss)
    }

    func testEachAppCarriesTheBundleIdentifierTheScriptGuardsOn() {
        XCTAssertEqual(JumpPlan.CwdFocusApp.ghostty.bundleIdentifier, "com.mitchellh.ghostty")
        XCTAssertEqual(JumpPlan.CwdFocusApp.cmux.bundleIdentifier, "com.cmuxterm.app")
    }

    /// `CanonicalPath` cannot run inside an AppleScript string comparison, so the spellings it
    /// would have collapsed are passed into the script instead. `/private` aliasing is the one
    /// that actually bites: a surface reports `/private/tmp` where a hook reports `/tmp`.
    func testCwdSpellingsCoverPrivateAliasingAndTheOriginalSpelling() {
        XCTAssertEqual(Jumper.cwdSpellings("/tmp"), ["/tmp", "/private/tmp"])
        XCTAssertEqual(Jumper.cwdSpellings("/private/tmp"), ["/tmp", "/private/tmp", "/private/tmp"])
        // An ordinary path has exactly one spelling — no speculative variants.
        XCTAssertEqual(Jumper.cwdSpellings("/Users/me/repo"), ["/Users/me/repo"])
        // A trailing slash is collapsed, and the raw spelling is kept so a surface reporting it
        // unresolved still matches.
        XCTAssertEqual(Jumper.cwdSpellings("/Users/me/repo/"), ["/Users/me/repo", "/Users/me/repo/"])
        // `/vardir` merely starts with the same letters as `/var` and must not be aliased.
        XCTAssertEqual(Jumper.cwdSpellings("/vardir"), ["/vardir"])
    }
}
