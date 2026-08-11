import XCTest
@testable import VibeNotch

/// The answer half of a card click, which used to run whole on the main thread: locating the
/// session's Warp tab copies a ~30MB database out of another app's container, and the UI was
/// frozen for every millisecond of it (#32). The store now acknowledges the click first, runs the
/// injection behind it, and gives that injection a deadline.
///
/// Everything here drives an injected fake — no real terminal, database or keychain is touched.
final class AnswerPathTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The whole point of the fix: the card says what happened to it while the typing is still
    /// going on, not after.
    @MainActor
    func testTheCardTakesItsResolutionBeforeTheInjectionFinishes() async {
        let store = makeStore()
        var resolutionDuringInjection: ActionResolution?

        let answered = await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            resolutionDuringInjection = store.resolutions["session-1"]
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }

        XCTAssertTrue(answered)
        XCTAssertEqual(
            resolutionDuringInjection,
            .answered("Approved ✓"),
            "the click must be acknowledged before the injection starts, not after it lands"
        )
        XCTAssertEqual(store.resolutions["session-1"], .answered("Approved ✓"))
        XCTAssertFalse(store.isAnswering("session-1"))
    }

    /// Nothing was typed anywhere — the card has to stop claiming otherwise.
    @MainActor
    func testAnInjectionThatFailsTurnsTheCardIntoTheFailureState() async {
        let store = makeStore()

        let answered = await store.performAnswer("session-1", label: "Approved ✓") { false }

        XCTAssertFalse(answered)
        XCTAssertEqual(store.resolutions["session-1"], .failed)
        XCTAssertFalse(store.isAnswering("session-1"))
    }

    /// A Warp database read that never returns must cost the answer, never the UI.
    @MainActor
    func testAnInjectionThatOutlastsItsDeadlineFallsBackToTheFailureState() async {
        let store = makeStore()
        let start = Date()

        let answered = await store.performAnswer(
            "session-1",
            label: "Approved ✓",
            timeout: 0.05
        ) {
            try? await Task.sleep(for: .milliseconds(500))
            return true
        }

        XCTAssertFalse(answered)
        XCTAssertEqual(store.resolutions["session-1"], .failed)
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.4,
            "the deadline must abandon the injection rather than wait for it"
        )
        XCTAssertFalse(store.isAnswering("session-1"))
    }

    /// Two digits into one prompt answer two questions — the second click is dropped, exactly as
    /// a second jump is.
    @MainActor
    func testASecondAnswerWhileOneIsInFlightIsIgnored() async {
        let store = makeStore()
        var attempts = 0

        let answered = await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            attempts += 1
            let reentrant = await store.performAnswer("session-1", label: "Denied ✕", hold: 0.05) {
                attempts += 1
                return true
            }
            XCTAssertFalse(reentrant)
            return true
        }

        XCTAssertTrue(answered)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(store.resolutions["session-1"], .answered("Approved ✓"))
        XCTAssertFalse(store.isAnswering("session-1"))
    }

    /// A different session answered at the same moment is a different card, and must go through.
    @MainActor
    func testAnAnswerForAnotherSessionIsNotBlockedByOneInFlight() async {
        let store = makeStore()

        let answered = await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            await store.performAnswer("session-2", label: "Denied ✕", hold: 0.05) { true }
        }

        XCTAssertTrue(answered)
        XCTAssertEqual(store.resolutions["session-2"], .answered("Denied ✕"))
    }

    /// The agent moved on (or the user jumped) while we were typing: whatever the card says now is
    /// newer than what this answer has to report, so the answer must not overwrite it.
    @MainActor
    func testAnAnswerClearedWhileInFlightIsNotResurrected() async {
        let store = makeStore()

        let answered = await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            store.clearResolution("session-1")
            return true
        }

        XCTAssertTrue(answered)
        XCTAssertNil(store.resolutions["session-1"])
    }

    /// The answered card's hold starts when the keystroke lands, not when the click does — a slow
    /// injection must not have its own confirmation dismissed out from under it.
    @MainActor
    func testTheConfirmationHoldStartsAfterTheInjectionLands() async {
        let store = makeStore()
        var dismissals = 0
        store.onAnswerDismissed = { dismissals += 1 }

        await store.performAnswer("session-1", label: "Approved ✓", hold: 0.05) {
            try? await Task.sleep(for: .milliseconds(80))
            return true
        }

        XCTAssertEqual(store.resolutions["session-1"], .answered("Approved ✓"))
        XCTAssertEqual(dismissals, 0, "the hold cannot have expired before the answer was typed")

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.resolutions["session-1"])
        XCTAssertEqual(dismissals, 1)
    }

    /// A key Warp has no code for is rejected before the group container is ever touched — which
    /// is also what keeps this test off the user's real Warp database.
    func testAWarpAnswerWithNoKeystrokeIsRejectedBeforeAnyDatabaseRead() async {
        let injected = await ActionInjector().inject(.warp(cwd: "/repo", key: .text("0")))
        XCTAssertFalse(injected)
    }

    // MARK: - The #42 regression: an unnamed terminal could be jumped to and never answered

    /// Driven against a real permission prompt: the owner pressed Approve on a live iTerm session
    /// whose terminal name had not resolved, the card flipped to "Couldn't answer — click to jump",
    /// and clicking that same card jumped straight into the session. `Jumper.canExactFocus` allows
    /// a nil terminal and falls back to the tty; `plan` used to make it fatal, so no AppleEvent was
    /// ever sent. The two must now agree.
    func testANilTerminalNameWithAKnownTTYStillProducesAPlan() {
        XCTAssertEqual(
            ActionInjector.plan(terminalName: nil, tty: "ttys001", cwd: "/repo", decision: .allow),
            .ttyLadder(tty: "ttys001", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(terminalName: nil, tty: "/dev/ttys001", cwd: "/repo", decision: .deny),
            .ttyLadder(tty: "ttys001", key: .escape)
        )
    }

    /// ⌘1-9 goes through the very same gate (#14), so the fallback has to reach it too — the
    /// question cards failed for exactly the reason allow/deny did.
    func testTheDigitPathGetsTheSameFallbackAsAllowAndDeny() {
        for number in 1...9 {
            XCTAssertEqual(
                ActionInjector.plan(terminalName: nil, tty: "ttys001", digit: String(number)),
                .ttyLadder(tty: "ttys001", key: .text(String(number)))
            )
        }
        // Still not a real option, terminal or no terminal.
        XCTAssertNil(ActionInjector.plan(terminalName: nil, tty: "ttys001", digit: "0"))
    }

    /// Every terminal jumping learned about in #34 now has an answer route, and each one is the
    /// mechanism that terminal actually offers — a native text API where one exists, focus-then-key
    /// only where none does.
    func testEveryInstallableTerminalMapsToItsOwnDelivery() {
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "WezTerm", tty: "/dev/ttys042", cwd: "/repo", decision: .allow),
            .wezTerm(tty: "ttys042", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "Kitty", tty: "ttys043", cwd: "/repo", decision: .deny),
            .kitty(tty: "ttys043", key: .escape)
        )
        // No tty at all: both of these are addressed by cwd, so a tty must neither be required
        // nor allowed to divert them.
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "Ghostty", tty: "ttys044", cwd: "/repo", decision: .allow),
            .surface(app: .ghostty, cwd: "/repo", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "cmux", tty: nil, cwd: "/repo", digit: "3"),
            .surface(app: .cmux, cwd: "/repo", key: .text("3"))
        )
    }

    /// The refusals, which matter more than the deliveries: typing into the wrong terminal answers
    /// a prompt nobody was looking at, and that is worse than typing nothing at all.
    func testWhatCannotBeAimedAtIsRefusedRatherThanGuessed() {
        // A NAMED terminal nothing here can drive: the tty is no help, because we would be
        // guessing which app owns it.
        XCTAssertNil(ActionInjector.plan(terminalName: "Hyper", tty: "ttys001", cwd: "/repo", decision: .allow))
        // Unnamed AND no tty — nothing identifies a surface, only a cwd every sibling shares.
        XCTAssertNil(ActionInjector.plan(terminalName: nil, tty: nil, cwd: "/repo", decision: .allow))
        XCTAssertNil(ActionInjector.plan(terminalName: nil, tty: "", cwd: "/repo", digit: "1"))
        // The cwd-addressed terminals without a cwd.
        XCTAssertNil(ActionInjector.plan(terminalName: "Ghostty", tty: "ttys001", cwd: nil, decision: .allow))
        XCTAssertNil(ActionInjector.plan(terminalName: "cmux", tty: "ttys001", cwd: "", decision: .allow))
    }

    /// Warp is the one route that already worked, and the delay in it exists because the digit
    /// once raced the tab switch and answered the wrong session. Pinned, so no new route can drift
    /// it while being generalised.
    func testWarpsExistingPlanIsUnchanged() {
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "Warp", tty: "ttys004", cwd: "/repo", decision: .allow),
            .warp(cwd: "/repo", key: .text("1"))
        )
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "warp", tty: nil, cwd: "/repo", decision: .deny),
            .warp(cwd: "/repo", key: .escape)
        )
        XCTAssertEqual(
            ActionInjector.plan(terminalName: "Warp", tty: nil, cwd: "/repo", digit: "7"),
            .warp(cwd: "/repo", key: .text("7"))
        )
        XCTAssertNil(ActionInjector.plan(terminalName: "Warp", tty: "ttys004", cwd: nil, decision: .allow))
    }

    /// What a TUI prompt actually reads: one raw byte for Escape, not the two characters `\e`.
    func testEscapeIsSentAsOneRawByteToTheCLITerminals() {
        XCTAssertEqual(InjectionKey.escape.characters, "\u{1B}")
        XCTAssertEqual(InjectionKey.text("2").characters, "2")
    }

    // MARK: - WezTerm, addressed by pane id

    /// Trimmed from real `wezterm cli list --format json`: panes 1 and 2 share a cwd, and pane 3
    /// has no controlling terminal at all.
    private static let wezTermListing = """
        [
          { "pane_id": 1, "cwd": "file://host/private/tmp", "tty_name": "/dev/ttys042" },
          { "pane_id": 2, "cwd": "file://host/private/tmp", "tty_name": "/dev/ttys049" },
          { "pane_id": 3, "cwd": "file://host/repo" }
        ]
        """

    func testWezTermTypesIntoThePaneHoldingTheSessionsTTY() {
        var sent: [(pane: Int, text: String)] = []

        let delivered = WezTermFocuser.sendText(
            InjectionKey.escape.characters,
            tty: "ttys049",
            isAvailable: { true },
            listPanes: { Self.wezTermListing },
            send: { sent.append((pane: $0, text: $1)); return true }
        )

        XCTAssertTrue(delivered)
        XCTAssertEqual(sent.map(\.pane), [2])
        XCTAssertEqual(sent.map(\.text), ["\u{1B}"])
    }

    /// A jump may fall back to the pane sitting at the same cwd — landing in a sibling tab is a
    /// wrong window the user can see. An answer may not: it would approve someone else's prompt.
    func testWezTermRefusesRatherThanFallingBackToACwdMatch() {
        var sends = 0

        let delivered = WezTermFocuser.sendText(
            "1",
            tty: "ttys999",
            isAvailable: { true },
            listPanes: { Self.wezTermListing },
            send: { _, _ in sends += 1; return true }
        )

        XCTAssertFalse(delivered)
        XCTAssertEqual(sends, 0, "no pane owns that tty, and cwd must never stand in for one")
    }

    func testWezTermNeverShellsOutWhenItIsNotInstalled() {
        var listings = 0

        let delivered = WezTermFocuser.sendText(
            "1",
            tty: "ttys042",
            isAvailable: { false },
            listPanes: { listings += 1; return Self.wezTermListing },
            send: { _, _ in true }
        )

        XCTAssertFalse(delivered)
        XCTAssertEqual(listings, 0)
    }

    // MARK: - Kitty, addressed by window id (fixtures only — Kitty is not installed here)

    private static let kittyListing = """
        [
          { "id": 1, "tabs": [
            { "windows": [
              { "id": 10, "pid": 900, "foreground_processes": [{ "pid": 901 }] },
              { "id": 11, "pid": 910, "foreground_processes": [{ "pid": 911 }, { "pid": 912 }] }
            ] }
          ] },
          { "id": 2, "tabs": [ { "windows": [ { "id": 20, "pid": 920 } ] } ] }
        ]
        """

    func testKittyFindsTheWindowRunningTheSessionsAgent() {
        // The agent is a foreground process of the window, not the window's own child.
        XCTAssertEqual(KittyRemote.windowID(inListing: Self.kittyListing, forPID: 912), 11)
        // …and the shell case, where it is.
        XCTAssertEqual(KittyRemote.windowID(inListing: Self.kittyListing, forPID: 920), 20)
        XCTAssertNil(KittyRemote.windowID(inListing: Self.kittyListing, forPID: 999))
        // Remote control switched off prints an error, not JSON — a miss, never a crash.
        XCTAssertNil(KittyRemote.windowID(inListing: "kitty: remote control is disabled", forPID: 900))
    }

    func testKittySendsToThatWindowAndRefusesWithoutAPID() {
        var sent: [(window: Int, text: String)] = []

        XCTAssertTrue(KittyRemote.sendText(
            "1",
            agentPID: 901,
            list: { Self.kittyListing },
            send: { sent.append((window: $0, text: $1)); return true }
        ))
        XCTAssertEqual(sent.map(\.window), [10])

        // No pid means no way to tell that window from any other — refuse.
        XCTAssertFalse(KittyRemote.sendText(
            "1",
            agentPID: nil,
            list: { Self.kittyListing },
            send: { sent.append((window: $0, text: $1)); return true }
        ))
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: - The terminal name that never resolved

    /// The second half of #42. A session whose pid the process table missed for one pass used to
    /// have its terminal recomputed as nil and nothing scheduled to put it back, which is what
    /// left a permanently unanswerable card. The name now survives the gap, so the reconcile that
    /// follows the next process scan can resolve it.
    func testAnUnresolvedTerminalNameSurvivesUntilAPassCanResolveIt() {
        var walked: [Int32] = []

        // No pid this pass: keep what the card is already showing rather than blanking it.
        XCTAssertEqual(
            SessionStore.terminalName(
                forPID: nil,
                shown: "iTerm",
                isResolved: { _ in false },
                cachedName: { _ in nil },
                scheduleWalk: { walked.append($0) }
            ),
            "iTerm"
        )
        XCTAssertEqual(walked, [], "there is no pid to walk — the gap is covered by keeping the name")

        // A pid nobody has walked yet: schedule it, and hold the old name until it lands.
        XCTAssertEqual(
            SessionStore.terminalName(
                forPID: 42,
                shown: "iTerm",
                isResolved: { _ in false },
                cachedName: { _ in nil },
                scheduleWalk: { walked.append($0) }
            ),
            "iTerm"
        )
        XCTAssertEqual(walked, [42])

        // Walked: its answer is the truth, including when that answer is "no terminal".
        XCTAssertEqual(
            SessionStore.terminalName(
                forPID: 42,
                shown: "iTerm",
                isResolved: { _ in true },
                cachedName: { _ in "WezTerm" },
                scheduleWalk: { walked.append($0) }
            ),
            "WezTerm"
        )
        XCTAssertNil(
            SessionStore.terminalName(
                forPID: 42,
                shown: "iTerm",
                isResolved: { _ in true },
                cachedName: { _ in nil },
                scheduleWalk: { walked.append($0) }
            )
        )
        XCTAssertEqual(walked, [42], "a pid already resolved is never walked twice")
    }

    /// A card that never had a terminal and has no pid yet is still answerable through the tty
    /// ladder — the two halves of the fix meeting.
    func testASessionWithNoTerminalNameAtAllIsStillAnswerableByTTY() {
        let terminalName = SessionStore.terminalName(
            forPID: nil,
            shown: nil,
            isResolved: { _ in false },
            cachedName: { _ in nil },
            scheduleWalk: { _ in }
        )

        XCTAssertNil(terminalName)
        XCTAssertEqual(
            ActionInjector.plan(terminalName: terminalName, tty: "ttys001", cwd: "/repo", decision: .allow),
            .ttyLadder(tty: "ttys001", key: .text("1"))
        )
    }

    // MARK: - Permissions preflight

    /// Checking must be able to say all four things without ever showing a dialog.
    func testAutomationStatusesMapToWhatTheUserCanActuallyDo() {
        XCTAssertEqual(PermissionStatus(automationStatus: noErr), .granted)
        XCTAssertEqual(PermissionStatus(automationStatus: OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(PermissionStatus(automationStatus: OSStatus(procNotFound)), .targetNotRunning)
        XCTAssertEqual(
            PermissionStatus(automationStatus: OSStatus(errAEEventWouldRequireUserConsent)),
            .undetermined
        )

        // macOS cannot re-prompt once a refusal is recorded, so a denied row must send the user to
        // System Settings rather than offer a button that silently does nothing.
        XCTAssertEqual(PermissionStatus.denied.action, .openSystemSettings)
        XCTAssertEqual(PermissionStatus.undetermined.action, .request)
        XCTAssertEqual(PermissionStatus.targetNotRunning.action, .request)
        XCTAssertNil(PermissionStatus.granted.action)
    }

    /// A row for an app the user does not have is a permission they can never grant.
    func testOnlyInstalledTerminalsAreOfferedAPermissionRow() {
        let installed: Set<String> = ["com.googlecode.iterm2", "com.apple.systemevents"]

        XCTAssertEqual(
            AnswerPermissions.installedAutomationTargets(isInstalled: { installed.contains($0) })
                .map(\.name),
            ["iTerm2", "System Events"]
        )
        // Warp, WezTerm, Kitty and tmux are absent by design: the first needs Accessibility and no
        // AppleEvent, the rest take the answer through their own CLI.
        XCTAssertFalse(AnswerPermissions.automationTargets.contains { $0.name.lowercased().contains("warp") })
        XCTAssertEqual(AnswerPermissions.permissionlessTerminals, ["WezTerm", "Kitty", "tmux"])
    }

    @MainActor
    private func makeStore() -> SessionStore {
        SessionStore(
            projectsDirectory: temporaryDirectory(),
            codexHome: temporaryDirectory(),
            antigravityHome: temporaryDirectory(),
            antigravityCLIHome: temporaryDirectory(),
            geminiHome: temporaryDirectory(),
            openCodeDatabaseURL: temporaryDirectory().appendingPathComponent("opencode.db"),
            kiroHome: temporaryDirectory(),
            cursorHome: temporaryDirectory(),
            processProvider: { [] }
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
