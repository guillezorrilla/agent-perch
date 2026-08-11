import Foundation
import XCTest
@testable import VibeNotch

final class AntigravityWorkspaceJSONTests: XCTestCase {
    func testDecodesPlainFileURI() {
        XCTAssertEqual(AntigravityWorkspaceJSON.decodeFileURI("file:///Users/me/project"), "/Users/me/project")
    }

    func testDecodesPercentEncodedPath() {
        XCTAssertEqual(
            AntigravityWorkspaceJSON.decodeFileURI("file:///Users/me/My%20Repo"),
            "/Users/me/My Repo"
        )
    }

    func testAcceptsEmptyOrLocalhostHost() {
        XCTAssertEqual(
            AntigravityWorkspaceJSON.decodeFileURI("file://localhost/Users/me/project"),
            "/Users/me/project"
        )
    }

    /// A remote or WSL workspace names a folder nothing on this Mac could open.
    func testRejectsARealRemoteHost() {
        XCTAssertNil(AntigravityWorkspaceJSON.decodeFileURI("file://remote-host/Users/me/project"))
    }

    func testRejectsNonFileSchemes() {
        XCTAssertNil(AntigravityWorkspaceJSON.decodeFileURI("https://example.com/project"))
    }

    func testRejectsAnUnparsableURI() {
        XCTAssertNil(AntigravityWorkspaceJSON.decodeFileURI(""))
    }

    func testDecodesTheFolderKeyOutOfWorkspaceJSON() {
        XCTAssertEqual(
            AntigravityWorkspaceJSON.decodeFolderPath(from: Data(#"{"folder":"file:///Users/me/project"}"#.utf8)),
            "/Users/me/project"
        )
    }

    func testMissingFolderKeyIsNil() {
        XCTAssertNil(AntigravityWorkspaceJSON.decodeFolderPath(from: Data(#"{"other":"value"}"#.utf8)))
    }

    func testCorruptJSONIsNil() {
        XCTAssertNil(AntigravityWorkspaceJSON.decodeFolderPath(from: Data("not json at all".utf8)))
    }

    func testEmptyDataIsNil() {
        XCTAssertNil(AntigravityWorkspaceJSON.decodeFolderPath(from: Data()))
    }
}

final class AntigravityGlobalStorageTests: XCTestCase {
    func testRecencyRankOrdersByArrayIndex() {
        let json = #"""
        {"backupWorkspaces":{"folders":[
            {"folderUri":"file:///Users/me/newest"},
            {"folderUri":"file:///Users/me/older"}
        ]}}
        """#
        let rank = AntigravityGlobalStorage.recencyRank(Data(json.utf8))
        XCTAssertEqual(rank["/Users/me/newest"], 0)
        XCTAssertEqual(rank["/Users/me/older"], 1)
    }

    func testMalformedFolderEntriesAreSkippedWithoutLosingGoodOnes() {
        let json = #"""
        {"backupWorkspaces":{"folders":[
            {"folderUri":"not-a-file-uri"},
            {"noFolderUriHere":true},
            {"folderUri":"file:///Users/me/kept"}
        ]}}
        """#
        // Entries with no `folderUri` at all are dropped before indices are assigned, so this
        // ends up at index 1 (following the one entry that HAS a `folderUri`, even though it
        // isn't a usable `file://` one) rather than its position of 2 in the original JSON —
        // what matters is that it is still found, and still the only entry present.
        XCTAssertEqual(AntigravityGlobalStorage.recencyRank(Data(json.utf8)), ["/Users/me/kept": 1])
    }

    func testMissingBackupWorkspacesIsEmpty() {
        XCTAssertEqual(AntigravityGlobalStorage.recencyRank(Data(#"{"other":1}"#.utf8)), [:])
    }

    func testCorruptDataIsEmpty() {
        XCTAssertEqual(AntigravityGlobalStorage.recencyRank(Data("not json".utf8)), [:])
    }

    func testMissingFileIsTolerated() {
        XCTAssertEqual(
            AntigravityGlobalStorage.recencyRank(contentsAt: URL(fileURLWithPath: "/nonexistent/storage.json")),
            [:]
        )
    }
}

final class AntigravityRecencyTests: XCTestCase {
    private let older = Date(timeIntervalSince1970: 100)
    private let newer = Date(timeIntervalSince1970: 200)

    func testBothRankedComparesByRankRegardlessOfMtime() {
        // /a is OLDER by mtime but ranked more recent by storage.json — the rank wins.
        XCTAssertTrue(AntigravityRecency.isOrderedBefore(
            cwd: "/a", lastActivity: older,
            otherCwd: "/b", otherLastActivity: newer,
            recencyRank: ["/a": 0, "/b": 1]
        ))
    }

    func testOnlyOneRankedWinsOverAnUnrankedOne() {
        XCTAssertTrue(AntigravityRecency.isOrderedBefore(
            cwd: "/a", lastActivity: older,
            otherCwd: "/b", otherLastActivity: newer,
            recencyRank: ["/a": 5]
        ))
        XCTAssertFalse(AntigravityRecency.isOrderedBefore(
            cwd: "/a", lastActivity: newer,
            otherCwd: "/b", otherLastActivity: older,
            recencyRank: ["/b": 5]
        ))
    }

    func testNeitherRankedFallsBackToLastActivity() {
        XCTAssertTrue(AntigravityRecency.isOrderedBefore(
            cwd: "/a", lastActivity: newer,
            otherCwd: "/b", otherLastActivity: older,
            recencyRank: [:]
        ))
        XCTAssertFalse(AntigravityRecency.isOrderedBefore(
            cwd: "/a", lastActivity: older,
            otherCwd: "/b", otherLastActivity: newer,
            recencyRank: [:]
        ))
    }
}

/// A workspace row is capped at `.idle` — it may never read `.active`, however fresh its mtime
/// (#29). `SessionStatus`'s usual `< 60 minutes` freshness window still gates `.idle` vs. hidden.
final class AntigravityLivenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testFreshMtimeIsIdleNeverActive() {
        // Zero elapsed time is the most suspicious case for accidentally promoting to `.active` —
        // it must still cap at `.idle`.
        XCTAssertEqual(AntigravityLiveness.status(modifiedAt: now, now: now), .idle)
    }

    func testStillIdleASecondAfterBeingTouched() {
        XCTAssertEqual(
            AntigravityLiveness.status(modifiedAt: now.addingTimeInterval(-1), now: now),
            .idle
        )
    }

    func testHiddenPastTheFreshnessThreshold() {
        XCTAssertNil(AntigravityLiveness.status(modifiedAt: now.addingTimeInterval(-3_600), now: now))
    }

    func testIdleJustInsideTheFreshnessThreshold() {
        XCTAssertEqual(
            AntigravityLiveness.status(modifiedAt: now.addingTimeInterval(-3_599), now: now),
            .idle
        )
    }
}

/// `pgrep Antigravity` never matched the IDE's own main process — that process is
/// `/Applications/Antigravity IDE.app/Contents/MacOS/Electron`, whose NAME is `Electron` — so
/// detection now matches the executable path's bundle instead (#27).
final class AntigravityProcessCheckTests: XCTestCase {
    func testMatchesTheMainElectronProcessInsideTheAntigravityBundle() {
        XCTAssertTrue(AntigravityProcessCheck.isAntigravityExecutable(
            "/Applications/Antigravity IDE.app/Contents/MacOS/Electron"
        ))
    }

    func testMatchesHelperProcessesAndTheOtherBundleName() {
        XCTAssertTrue(AntigravityProcessCheck.isAntigravityExecutable(
            "/Applications/Antigravity IDE.app/Contents/Frameworks/Antigravity IDE Helper.app/Contents/MacOS/Antigravity IDE Helper"
        ))
        XCTAssertTrue(AntigravityProcessCheck.isAntigravityExecutable(
            "/Applications/Antigravity.app/Contents/MacOS/Electron"
        ))
    }

    func testRejectsAnUnrelatedElectronProcess() {
        XCTAssertFalse(AntigravityProcessCheck.isAntigravityExecutable(
            "/Applications/Claude.app/Contents/MacOS/Electron"
        ))
        XCTAssertFalse(AntigravityProcessCheck.isAntigravityExecutable(
            "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Electron"
        ))
        XCTAssertFalse(AntigravityProcessCheck.isAntigravityExecutable("Electron"))
    }

    /// A bundle whose name merely ENDS with the one we want is a different app.
    func testRejectsABundleThatOnlySuffixMatches() {
        XCTAssertFalse(AntigravityProcessCheck.isAntigravityExecutable(
            "/Applications/Not Antigravity.app/Contents/MacOS/Electron"
        ))
    }

    func testScansAWholeProcessListingForTheBundle() {
        let listing = """
        /usr/libexec/secinitd
        /Applications/Claude.app/Contents/MacOS/Electron
        /Applications/Antigravity IDE.app/Contents/MacOS/Electron
        """
        XCTAssertTrue(AntigravityProcessCheck.isRunningByExecutablePath { listing })
    }

    func testAListingWithoutTheBundleIsNotRunning() {
        let listing = """
        /usr/libexec/secinitd
        /Applications/Claude.app/Contents/MacOS/Electron
        """
        XCTAssertFalse(AntigravityProcessCheck.isRunningByExecutablePath { listing })
    }

    func testAFailedProcessListingIsNotRunning() {
        XCTAssertFalse(AntigravityProcessCheck.isRunningByExecutablePath { nil })
    }
}

final class AntigravitySessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testDiscoversWorkspaceFromWorkspaceJSON() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc123", folderPath: "/Users/me/project", ageSeconds: 60)

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(session.agentName, "Antigravity")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        // Every title carries the "— workspace" qualifier (#29): a compact row (the only shape
        // one of these is ever allowed to take) has no secondary text line to say so instead.
        XCTAssertEqual(session.title, "project — workspace")
        XCTAssertEqual(session.sessionId, "antigravity:abc123")
        XCTAssertNil(session.sessionFileURL)
    }

    func testSkipsMalformedOrMissingWorkspaceJSON() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "good", folderPath: "/Users/me/kept", ageSeconds: 60)

        let corruptDirectory = home
            .appendingPathComponent("User/workspaceStorage/corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: corruptDirectory.appendingPathComponent("workspace.json"))

        // No workspace.json at all in this one.
        let missingDirectory = home
            .appendingPathComponent("User/workspaceStorage/missing", isDirectory: true)
        try FileManager.default.createDirectory(at: missingDirectory, withIntermediateDirectories: true)

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.map(\.cwd), ["/Users/me/kept"])
    }

    func testTitleIsTheFolderBasenamePlusAWorkspaceQualifierWithWordBoundaryTruncation() throws {
        let home = try makeTemporaryDirectory()
        let longName = Array(repeating: "word", count: 20).joined(separator: "-")
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/\(longName)", ageSeconds: 60)

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        let title = try XCTUnwrap(discovered.first?.title)
        XCTAssertTrue(title.hasSuffix("— workspace"))
        XCTAssertLessThan(title.count, longName.count + " — workspace".count)
        XCTAssertLessThanOrEqual(title.count, 60)
    }

    func testResumeCommandPresentOnlyWhenAgyIsAvailable() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 60)

        let withAgy = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { true },
            showWorkspaces: { true }
        ).discover(now: fixedNow)
        XCTAssertEqual(withAgy.first?.resumeCommand, "agy '/Users/me/project'")

        let withoutAgy = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)
        XCTAssertNil(withoutAgy.first?.resumeCommand)
    }

    func testAFreshWorkspaceIsIdleNeverActive() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 30)

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.first?.status, .idle)
    }

    /// A workspace row must never present as active work — not even the single most-recently
    /// touched one — regardless of how fresh it is (#29, follow-up to #27: capped in the source,
    /// not merely hidden by the view).
    func testNoWorkspaceIsEverActiveRegardlessOfRecency() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "recent", folderPath: "/Users/me/recent", ageSeconds: 30)
        try makeWorkspace(in: home, hash: "older", folderPath: "/Users/me/older", ageSeconds: 600)

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.count, 2)
        XCTAssertTrue(discovered.allSatisfy { $0.status == .idle })
    }

    func testHiddenThresholdDropsAStaleWorkspaceWithoutALiveProcess() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 61 * 60.0)

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        XCTAssertTrue(discovered.isEmpty)
    }

    func testRecencyOrderingFromStorageJSONIsAppliedOverIdenticalMtimes() throws {
        let home = try makeTemporaryDirectory()
        // Both workspaces share the same mtime — mtime alone cannot order them.
        try makeWorkspace(in: home, hash: "a", folderPath: "/Users/me/a", ageSeconds: 60)
        try makeWorkspace(in: home, hash: "b", folderPath: "/Users/me/b", ageSeconds: 60)

        let globalStorageDirectory = home.appendingPathComponent("User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorageDirectory, withIntermediateDirectories: true)
        let json = #"""
        {"backupWorkspaces":{"folders":[
            {"folderUri":"file:///Users/me/b"},
            {"folderUri":"file:///Users/me/a"}
        ]}}
        """#
        try Data(json.utf8).write(to: globalStorageDirectory.appendingPathComponent("storage.json"))

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.map(\.cwd), ["/Users/me/b", "/Users/me/a"])
    }

    func testMissingStorageJSONIsTolerated() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 60)
        // No globalStorage/storage.json at all.

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.map(\.cwd), ["/Users/me/project"])
    }

    func testMissingWorkspaceStorageDirectoryYieldsNoSessions() {
        XCTAssertTrue(
            AntigravitySessionSource(
                antigravityHome: URL(fileURLWithPath: "/nonexistent/Antigravity IDE"),
                agyAvailableProvider: { true },
                showWorkspaces: { true }
            ).discover(now: fixedNow).isEmpty
        )
    }

    // MARK: - Opt-in gate (#27)

    /// A workspace directory's mtime is not evidence of agent activity, so nothing at all is
    /// contributed until the user opts in — not even an idle row.
    func testContributesNothingWhenTheSettingIsOff() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 30)

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { XCTFail("must not probe for agy when opted out"); return true },
            showWorkspaces: { false }
        ).discover(now: fixedNow)

        XCTAssertTrue(discovered.isEmpty)
    }

    /// Opted out, the directory listing itself must not happen — the gate is ahead of all disk
    /// work, not a filter after it.
    func testOptedOutNeverEnumeratesTheWorkspaceStorageDirectory() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "abc", folderPath: "/Users/me/project", ageSeconds: 30)

        final class CountingFileManager: FileManager, @unchecked Sendable {
            var listings = 0
            override func contentsOfDirectory(
                at url: URL,
                includingPropertiesForKeys keys: [URLResourceKey]?,
                options mask: FileManager.DirectoryEnumerationOptions = []
            ) throws -> [URL] {
                listings += 1
                return try super.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys, options: mask
                )
            }
        }

        let fileManager = CountingFileManager()
        _ = AntigravitySessionSource(
            antigravityHome: home,
            fileManager: fileManager,
            agyAvailableProvider: { false },
            showWorkspaces: { false }
        ).discover(now: fixedNow)

        XCTAssertEqual(fileManager.listings, 0)
    }

    /// Opted IN: rows may show, but none of them may EVER claim to be active — regardless of how
    /// many there are or how fresh (#29).
    func testOptedInNeverMarksAnythingActive() throws {
        let home = try makeTemporaryDirectory()
        try makeWorkspace(in: home, hash: "a", folderPath: "/Users/me/a", ageSeconds: 30)
        try makeWorkspace(in: home, hash: "b", folderPath: "/Users/me/b", ageSeconds: 90)
        try makeWorkspace(in: home, hash: "c", folderPath: "/Users/me/c", ageSeconds: 120)

        let discovered = AntigravitySessionSource(
            antigravityHome: home,
            agyAvailableProvider: { false },
            showWorkspaces: { true }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.count, 3)
        XCTAssertTrue(discovered.allSatisfy { $0.status == .idle })
    }

    // MARK: - Fixtures

    private func makeWorkspace(
        in antigravityHome: URL,
        hash: String,
        folderPath: String,
        ageSeconds: TimeInterval
    ) throws {
        let directory = antigravityHome
            .appendingPathComponent("User/workspaceStorage", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let workspaceJSON = directory.appendingPathComponent("workspace.json")
        try Data(#"{"folder":"file://\#(folderPath)"}"#.utf8).write(to: workspaceJSON)
        let contentFile = directory.appendingPathComponent("state.vscdb")
        try Data().write(to: contentFile)

        // The directory and every file just written into it need an explicit mtime — otherwise
        // each carries the real wall-clock time it was created, which (being "now", not
        // `fixedNow`) would always outrank whatever age this fixture asked for.
        let mtime = fixedNow.addingTimeInterval(-ageSeconds)
        for url in [directory, workspaceJSON, contentFile] {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// The real jump-execution seam: `Jumper.resolvePlan` must never resolve an Antigravity session
/// against the process table at all, since a Claude/Codex CLI process that merely shares its
/// workspace's cwd would otherwise be mistaken for it (#3). `SessionStore.reconcile` is where
/// that guard lives — this exercises it the same way `SessionIdentityTests` exercises the
/// Claude/Codex jump rung, with a fake source standing in for real disk state.
final class AntigravityJumpRoutingTests: XCTestCase {
    private struct FakeSource: AgentSessionSource {
        let agentName: String
        let sessions: [DiscoveredSession]
        func discover(now: Date) -> [DiscoveredSession] { sessions }
    }

    @MainActor
    func testAntigravitySessionNeverSelectsATTYFocusRungEvenWhenATerminalProcessSharesItsCwd() throws {
        let discovered = DiscoveredSession(
            sessionId: "antigravity:abc",
            agentName: "Antigravity",
            cwd: "/repo",
            title: "repo",
            lastActivity: Date(timeIntervalSince1970: 1_000),
            status: .idle,
            resumeCommand: nil,
            sessionFileURL: nil
        )
        // A live Claude CLI process at the very same cwd — the ordinary case a cwd-based match
        // would otherwise seize on.
        let claudeAtSameCwd = ClaudeProcess(pid: 42, command: "/usr/local/bin/claude", cwd: "/repo", tty: "ttys009")

        let store = SessionStore(
            sources: [FakeSource(agentName: "Antigravity", sessions: [discovered])],
            processProvider: { [claudeAtSameCwd] }
        )
        store.refresh(now: Date(timeIntervalSince1970: 1_060))

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.agentName, "Antigravity")
        XCTAssertEqual(session.jumpRung, .newTab)
        XCTAssertNil(session.terminalName, "an Antigravity row must never imply terminal semantics")
        XCTAssertNil(session.tty)
    }
}

final class AntigravityLaunchCommandTests: XCTestCase {
    func testUsesAgyWhenAvailable() {
        let plan = Jumper.antigravityLaunchCommand(path: "/repo", agyAvailable: true)
        XCTAssertEqual(plan.executable, "/usr/bin/env")
        XCTAssertEqual(plan.arguments, ["agy", "/repo"])
    }

    func testFallsBackToOpenWhenAgyIsUnavailable() {
        let plan = Jumper.antigravityLaunchCommand(path: "/repo", agyAvailable: false)
        XCTAssertEqual(plan.executable, "/usr/bin/open")
        XCTAssertEqual(plan.arguments, ["-a", "Antigravity IDE", "/repo"])
    }
}

final class CmuxLauncherTests: XCTestCase {
    override func tearDown() {
        CmuxLauncher.resetCacheForTesting()
    }

    func testParseFocusSubcommandFindsAFocusKeyword() {
        let help = """
            Usage: cmux [command]

            Commands:
              focus <path>   Focus the window for a workspace
              list           List open workspaces
            """
        XCTAssertEqual(CmuxLauncher.parseFocusSubcommand(help), "focus")
    }

    func testParseFocusSubcommandFindsAnActivateKeyword() {
        XCTAssertEqual(
            CmuxLauncher.parseFocusSubcommand("activate <path>  Activate cmux on a given workspace\n"),
            "activate"
        )
    }

    func testParseFocusSubcommandReturnsNilWhenNothingMatches() {
        let help = "Usage: cmux [command]\n\nCommands:\n  list   List open workspaces\n"
        XCTAssertNil(CmuxLauncher.parseFocusSubcommand(help))
    }

    func testAttemptFocusReturnsFalseAndNeverProbesWhenCmuxIsNotAvailable() {
        let handled = CmuxLauncher.attemptFocus(
            cwd: "/repo",
            isAvailable: { false },
            focusSubcommand: { XCTFail("must not probe for a subcommand when cmux isn't installed"); return nil },
            runCmux: { _, _ in XCTFail("must not run cmux when it isn't installed"); return false },
            activate: { XCTFail("must not activate cmux when it isn't installed"); return false }
        )
        XCTAssertFalse(handled)
    }

    func testAttemptFocusUsesTheSubcommandWhenItSucceeds() {
        var ranWith: (subcommand: String, cwd: String)?
        let handled = CmuxLauncher.attemptFocus(
            cwd: "/repo",
            isAvailable: { true },
            focusSubcommand: { "focus" },
            runCmux: { subcommand, cwd in
                ranWith = (subcommand, cwd)
                return true
            },
            activate: { XCTFail("must not fall back to activation once the subcommand succeeds"); return false }
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(ranWith?.subcommand, "focus")
        XCTAssertEqual(ranWith?.cwd, "/repo")
    }

    func testAttemptFocusFallsBackToActivationWhenNoSubcommandExists() {
        var activated = false
        let handled = CmuxLauncher.attemptFocus(
            cwd: "/repo",
            isAvailable: { true },
            focusSubcommand: { nil },
            runCmux: { _, _ in XCTFail("no subcommand was found; must not attempt to run one"); return false },
            activate: {
                activated = true
                return true
            }
        )
        XCTAssertTrue(handled)
        XCTAssertTrue(activated)
    }

    func testAttemptFocusFallsBackToActivationWhenTheSubcommandFails() {
        var activated = false
        let handled = CmuxLauncher.attemptFocus(
            cwd: "/repo",
            isAvailable: { true },
            focusSubcommand: { "focus" },
            runCmux: { _, _ in false },
            activate: {
                activated = true
                return true
            }
        )
        XCTAssertTrue(handled)
        XCTAssertTrue(activated)
    }
}
