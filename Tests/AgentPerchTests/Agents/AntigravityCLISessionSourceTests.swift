import Foundation
import XCTest
@testable import AgentPerch

final class AntigravityCLILogTests: XCTestCase {
    func testParsesTheWorkspaceLine() {
        XCTAssertEqual(
            AntigravityCLILog.workspacePath(in: "some banner\nworkspace /Users/me/project\nmore log lines\n"),
            "/Users/me/project"
        )
    }

    func testReturnsNilWhenNoWorkspaceLineExists() {
        XCTAssertNil(AntigravityCLILog.workspacePath(in: "no workspace line here\njust ordinary log lines\n"))
    }

    /// Tolerate absence, don't crash on it.
    func testReturnsNilForEmptyText() {
        XCTAssertNil(AntigravityCLILog.workspacePath(in: ""))
    }

    func testFirstWorkspaceLineWinsWhenMultipleExist() {
        XCTAssertEqual(
            AntigravityCLILog.workspacePath(in: "workspace /first\nworkspace /second\n"),
            "/first"
        )
    }

    func testEmptyWorkspaceValueIsNil() {
        XCTAssertNil(AntigravityCLILog.workspacePath(in: "workspace \nmore log lines\n"))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(AntigravityCLILog.workspacePath(in: "  workspace   /Users/me/project  \n"), "/Users/me/project")
    }

    func testWorkspacePathAtURLReadsFromDisk() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("cli-test.log")
        try Data("workspace /Users/me/project\n".utf8).write(to: url)

        XCTAssertEqual(AntigravityCLILog.workspacePath(at: url), "/Users/me/project")
    }

    func testWorkspacePathAtURLReturnsNilForAMissingFile() {
        XCTAssertNil(AntigravityCLILog.workspacePath(at: URL(fileURLWithPath: "/nonexistent/cli.log")))
    }

    /// The exact line that started this bug (issue #31's predecessor): byte-for-byte from a real
    /// `~/.gemini/antigravity-cli/log/cli-20260810_091658.log`, where `workspace ` sits mid-line
    /// after Go's own logging preamble rather than at the line's start.
    func testParsesTheRealGoStyleLogLineWithTheMarkerMidLine() {
        let realLine = "ERROR: logging before google.Init: I0810 09:16:58.692555       1 manager.go:367] "
            + "Initializing CLI store manager for workspace /Users/gzorrilla/Developer/personal/agent-perch"
        XCTAssertEqual(AntigravityCLILog.workspacePath(in: realLine), "/Users/gzorrilla/Developer/personal/agent-perch")
    }

    /// A run started in the home directory itself — verified on the same machine — must still
    /// parse; the path is exactly `/Users/gzorrilla`, nothing more.
    func testParsesAWorkspaceThatIsTheHomeDirectoryItself() {
        let line = "I0810 09:20:00.000000       1 manager.go:367] Initializing CLI store manager for workspace /Users/gzorrilla"
        XCTAssertEqual(AntigravityCLILog.workspacePath(in: line), "/Users/gzorrilla")
    }

    /// Two verified-real logs carry no `workspace` text anywhere at all — those sessions must be
    /// skipped (`nil`), never crash or default to a wrong path.
    func testLogWithNoWorkspaceTextAnywhereIsNil() {
        let noMarkerLog = """
        ERROR: logging before google.Init: I0810 09:16:58.692555       1 manager.go:200] Starting CLI
        I0810 09:16:58.700000       1 manager.go:210] Loaded config
        I0810 09:16:59.000000       1 manager.go:400] Ready
        """
        XCTAssertNil(AntigravityCLILog.workspacePath(in: noMarkerLog))
    }

    /// A relative path (or nothing at all) after the marker is rejected outright rather than
    /// handed to the caller as a bogus cwd.
    func testRelativePathAfterTheMarkerIsNil() {
        let line = "I0810 09:16:58.692555       1 manager.go:367] Initializing CLI store manager for workspace relative/path"
        XCTAssertNil(AntigravityCLILog.workspacePath(in: line))
    }

    /// Proves the >=64KB bounded read is generous enough: the real marker was observed ~8KB into
    /// a real log, so a fixture that pads well past that offset before the matching line must
    /// still be found by `workspacePath(at:)`, which only ever reads a bounded prefix from disk.
    func testMarkerFoundEightKilobytesIntoALargeLogViaTheBoundedRead() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("cli-padded.log")
        let padding = String(repeating: "I0810 09:16:58.000000       1 manager.go:100] padding line\n", count: 150)
        XCTAssertGreaterThan(padding.utf8.count, 8_000, "the padding itself must clear ~8KB before the real line")
        let content = padding
            + "I0810 09:16:59.000000       1 manager.go:367] Initializing CLI store manager for workspace /Users/me/project\n"
        try Data(content.utf8).write(to: url)

        XCTAssertEqual(AntigravityCLILog.workspacePath(at: url), "/Users/me/project")
    }

    /// The first LINE containing the marker wins — using the real mid-line format, not just the
    /// bare `workspace <path>` shape, so the "first line wins" rule is proven against the shape
    /// that actually appears on disk.
    func testFirstMatchingGoStyleLineWinsWhenMultipleExist() {
        let text = """
        I0810 09:16:58.000000       1 manager.go:367] Initializing CLI store manager for workspace /first
        I0810 09:17:00.000000       1 manager.go:367] Initializing CLI store manager for workspace /second
        """
        XCTAssertEqual(AntigravityCLILog.workspacePath(in: text), "/first")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

final class AntigravityCLIDiscoveryTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testCandidateLogFilesAreBoundedToTheNewestByMtime() throws {
        let logDirectory = try makeTemporaryDirectory()
        for index in 0..<5 {
            let url = logDirectory.appendingPathComponent("cli-\(index).log")
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: fixedNow.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }

        let files = AntigravityCLIDiscovery.candidateLogFiles(logDirectory: logDirectory, fileManager: .default, maxFiles: 2)
        XCTAssertEqual(files.map(\.lastPathComponent), ["cli-4.log", "cli-3.log"])
    }

    func testCandidateLogFilesIgnoreNamesThatDontMatch() throws {
        let logDirectory = try makeTemporaryDirectory()
        try Data().write(to: logDirectory.appendingPathComponent("cli-real.log"))
        try Data().write(to: logDirectory.appendingPathComponent("notes.txt"))
        try Data().write(to: logDirectory.appendingPathComponent("other-cli.log"))

        let files = AntigravityCLIDiscovery.candidateLogFiles(logDirectory: logDirectory, fileManager: .default)
        XCTAssertEqual(files.map(\.lastPathComponent), ["cli-real.log"])
    }

    func testMissingLogDirectoryYieldsNoFiles() {
        XCTAssertTrue(
            AntigravityCLIDiscovery.candidateLogFiles(
                logDirectory: URL(fileURLWithPath: "/nonexistent/log"),
                fileManager: .default
            ).isEmpty
        )
    }

    func testImplicitFilesAreBoundedAndFilteredToPBExtension() throws {
        let directory = try makeTemporaryDirectory()
        try Data().write(to: directory.appendingPathComponent("keep.pb"))
        try Data().write(to: directory.appendingPathComponent("ignore.txt"))

        let files = AntigravityCLIDiscovery.implicitFiles(in: directory, fileManager: .default)
        XCTAssertEqual(files.map(\.id), ["keep"])
    }

    func testClosestImplicitIDPicksTheNearestMtime() {
        let files: [(id: String, modifiedAt: Date)] = [
            (id: "far", modifiedAt: fixedNow.addingTimeInterval(-500)),
            (id: "near", modifiedAt: fixedNow.addingTimeInterval(-2))
        ]
        XCTAssertEqual(AntigravityCLIDiscovery.closestImplicitID(to: fixedNow, in: files), "near")
    }

    func testClosestImplicitIDIsNilWhenThereAreNoCandidates() {
        XCTAssertNil(AntigravityCLIDiscovery.closestImplicitID(to: fixedNow, in: []))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// The visibility rule every hookless agent now shares (#33): a live process is what makes a
/// session exist, a recent transcript write is what makes it look busy, and the two questions are
/// never confused for each other again.
final class HooklessLivenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    /// Issue #31, preserved: a live process alone was once enough for `.active` no matter how
    /// stale the transcript was — exactly the bug where a terminal parked at an idle prompt
    /// (process running, nothing written in almost an hour) showed as "Working…".
    func testLiveProcessWithAWriteOlderThanTheActiveWriteWindowIsIdle() {
        XCTAssertEqual(
            HooklessLiveness.liveStatus(lastWriteAt: now.addingTimeInterval(-5 * 60.0), now: now),
            .idle
        )
    }

    /// The other half of #31: a recent write next to a live process is still `.active` — the rule
    /// narrows what counts as evidence, it doesn't remove `.active` altogether.
    func testLiveProcessWithARecentWriteIsActive() {
        XCTAssertEqual(HooklessLiveness.liveStatus(lastWriteAt: now.addingTimeInterval(-10), now: now), .active)
    }

    /// Issue #33's core rule: transcript age can no longer HIDE a session that has a live process.
    /// The 71-minute-old rollout on this machine's real `ttys025` Codex session is well past every
    /// freshness threshold in the app and must still come back visible, merely `.idle`.
    func testALiveSessionIsNeverHiddenByTranscriptAgeHoweverStale() {
        XCTAssertEqual(
            HooklessLiveness.liveStatus(lastWriteAt: now.addingTimeInterval(-71 * 60.0), now: now),
            .idle
        )
        XCTAssertEqual(
            HooklessLiveness.liveStatus(lastWriteAt: now.addingTimeInterval(-30 * 24 * 60 * 60.0), now: now),
            .idle
        )
    }

    /// No transcript matched at all is an ordinary quiet session, not a reason to hide one.
    func testALiveSessionWithNoTranscriptAtAllIsIdleRatherThanHidden() {
        XCTAssertEqual(HooklessLiveness.liveStatus(lastWriteAt: nil, now: now), .idle)
    }

    func testActiveWriteWindowIsSharedWithCodex() {
        XCTAssertEqual(HooklessLiveness.activeWriteWindow, 90.0)
        XCTAssertEqual(CodexLiveness.activeWriteWindow, HooklessLiveness.activeWriteWindow)
    }
}

final class AntigravityCLISessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testDiscoversTheLiveProcessAndEnrichesItFromItsOwnLog() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 5 * 60.0)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: "/Users/me/project")] }
        ).discover(now: fixedNow)

        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(session.agentName, "Antigravity")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        // A REAL session — unlike the IDE-workspace source, the title is a plain basename, no
        // "workspace" qualifier.
        XCTAssertEqual(session.title, "project")
        // The log supplied `lastActivity`; it is five minutes stale, so #31 caps this at idle.
        XCTAssertEqual(session.lastActivity, fixedNow.addingTimeInterval(-5 * 60.0))
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.resumeCommand, "agy")
        XCTAssertEqual(session.tty, "ttys002")
        XCTAssertNil(session.sessionFileURL)
        // `agy` has no hooks — `.active` can never mean more than "live process + recent write"
        // (issue #31), so `SessionCardView` must never show "Working…" for it.
        XCTAssertFalse(session.supportsLiveStatus)
    }

    /// The heart of #33: logs are a record of writes, not a list of sessions. `agy` writes several
    /// per run and leaves every one behind, so the ONLY thing that may create a row is a live
    /// process — however fresh, however numerous, however well-formed the logs are.
    func testLogsWithNoLiveProcessYieldNoSessionsAtAll() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-a.log", workspace: "/Users/me/project", ageSeconds: 60)
        try makeLog(in: home, name: "cli-b.log", workspace: "/Users/me/other", ageSeconds: 5)

        XCTAssertTrue(
            AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })
                .discover(now: fixedNow).isEmpty
        )
    }

    /// A live process with no log to match it is still a session — the log is enrichment, never
    /// the evidence. Its title falls back to the cwd basename and its date to the process's own
    /// start time.
    func testLiveProcessWithNoMatchingLogIsStillASessionDatedByItsStartTime() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-elsewhere.log", workspace: "/Users/me/other", ageSeconds: 30)
        let started = fixedNow.addingTimeInterval(-3 * 60 * 60.0)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: "/Users/me/project", startedAt: started)] }
        ).discover(now: fixedNow)

        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(session.title, "project")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        XCTAssertEqual(session.lastActivity, started)
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.sessionId, "antigravity-cli:tty:ttys002:/Users/me/project")
    }

    func testLogWithNoWorkspaceLineCannotEnrichAnything() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: nil, ageSeconds: 60, extraLines: ["nothing useful here"])
        try makeImplicit(in: home, uuid: "some-uuid", ageSeconds: 60)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: "/Users/me/project")] }
        ).discover(now: fixedNow)

        // The session still shows (the process proves it), but the unreadable log gave it nothing.
        XCTAssertEqual(discovered.map(\.sessionId), ["antigravity-cli:tty:ttys002:/Users/me/project"])
    }

    func testSessionIdPrefersTheImplicitFileClosestByMtime() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)
        try makeImplicit(in: home, uuid: "far-uuid", ageSeconds: 600)
        try makeImplicit(in: home, uuid: "close-uuid", ageSeconds: 61)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: "/Users/me/project")] }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.sessionId, "antigravity-cli:close-uuid")
    }

    func testSessionIdFallsBackToTheLogFilenameWithoutAnyImplicitFile() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: "/Users/me/project")] }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.sessionId, "antigravity-cli:cli-20260808_160031")
    }

    /// #33: a live session is never hidden by its log's age. The old rule dropped anything past 60
    /// minutes, which is exactly how a terminal the user was sitting in disappeared from the list.
    func testALiveSessionSurvivesALogFarPastTheOldHiddenThreshold() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-stale.log", workspace: "/Users/me/project", ageSeconds: 116 * 60.0)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: "/Users/me/project")] }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.map(\.status), [.idle])
    }

    /// The full #31 regression, still in force: a live process whose log hasn't been written to in
    /// minutes (a terminal parked at an idle prompt) must not read as `.active`.
    func testLiveProcessWithAStaleLogDegradesToIdleAtTheSourceLevel() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 5 * 60.0)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: "/Users/me/project")] }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.status, .idle)
    }

    func testActiveNeedsBothALiveProcessAndARecentLogWrite() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 10)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: "/Users/me/project")] }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.status, .active)
    }

    /// The exact live-machine shape from #33: eight logs, two of them recording a workspace of
    /// literally `/` and four more all naming `/Users/gzorrilla`, next to ONE real `agy` process
    /// at `agent-perch`. The app used to draw four Antigravity rows from this — one titled `/`,
    /// two duplicates of each other. There is one session, so there is one row.
    func testTheEightLogRealWorldShapeYieldsExactlyOneSession() throws {
        let home = try makeTemporaryDirectory()
        let agentPerch = "/Users/gzorrilla/Developer/personal/agent-perch"
        try makeLog(in: home, name: "cli-20260810_0920.log", workspace: "/Users/gzorrilla", ageSeconds: 3 * 60.0)
        try makeLog(in: home, name: "cli-20260810_0918.log", workspace: agentPerch, ageSeconds: 5 * 60.0)
        try makeLog(in: home, name: "cli-20260810_0827.log", workspace: "/", ageSeconds: 56 * 60.0)
        try makeLog(in: home, name: "cli-20260810_0826.log", workspace: "/", ageSeconds: 56.5 * 60.0)
        try makeLog(in: home, name: "cli-20260810_0811.log", workspace: "/Users/gzorrilla", ageSeconds: 72 * 60.0)
        try makeLog(in: home, name: "cli-20260810_0800.log", workspace: "/Users/gzorrilla", ageSeconds: 83 * 60.0)
        try makeLog(in: home, name: "cli-20260810_0743.log", workspace: "/Users/gzorrilla", ageSeconds: 100 * 60.0)
        try makeLog(in: home, name: "cli-20260810_0727.log", workspace: "/Users/gzorrilla", ageSeconds: 116 * 60.0)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: { [liveAgy(cwd: agentPerch)] }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.title, "agent-perch")
        XCTAssertEqual(discovered.first?.cwd, agentPerch)
        XCTAssertEqual(discovered.first?.tty, "ttys002")
        // Enriched by the `agent-perch` log, not by any of the `/Users/gzorrilla` ones.
        XCTAssertEqual(discovered.first?.lastActivity, fixedNow.addingTimeInterval(-5 * 60.0))
        XCTAssertFalse(discovered.contains { $0.cwd == "/" })
    }

    /// Two terminals really can run `agy` in the same folder — the tty is what tells them apart,
    /// and each claims its own log rather than both enriching from the newest one.
    func testTwoTerminalsInOneFolderAreTwoSessionsOnePerTTY() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-newer.log", workspace: "/Users/me/project", ageSeconds: 30)
        try makeLog(in: home, name: "cli-older.log", workspace: "/Users/me/project", ageSeconds: 20 * 60.0)

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: {
                [
                    liveAgy(pid: 100, cwd: "/Users/me/project", tty: "ttys002"),
                    liveAgy(pid: 200, cwd: "/Users/me/project", tty: "ttys009")
                ]
            }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.count, 2)
        XCTAssertEqual(Set(discovered.compactMap(\.tty)), ["ttys002", "ttys009"])
        XCTAssertEqual(Set(discovered.map(\.lastActivity)), [
            fixedNow.addingTimeInterval(-30),
            fixedNow.addingTimeInterval(-20 * 60.0)
        ])
    }

    /// Two processes sharing one terminal and one folder — a wrapper and the binary it exec'd —
    /// are one session, not two.
    func testTwoProcessesOnTheSameTTYAndCwdCollapseToOneSession() throws {
        let home = try makeTemporaryDirectory()

        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: home,
            processProvider: {
                [
                    liveAgy(pid: 100, cwd: "/Users/me/project", tty: "ttys002"),
                    liveAgy(pid: 101, cwd: "/Users/me/project", tty: "ttys002")
                ]
            }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.count, 1)
    }

    func testMissingLogDirectoryStillDiscoversTheLiveSession() throws {
        let discovered = AntigravityCLISessionSource(
            antigravityCLIHome: URL(fileURLWithPath: "/nonexistent/antigravity-cli"),
            processProvider: { [liveAgy(cwd: "/Users/me/project")] }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.map(\.title), ["project"])
    }

    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// The real jump-execution seam: unlike an Antigravity IDE-workspace row, a real `agy` CLI session
/// DOES let the normal ladder resolve it — a live process yields a tty rung, none falls back to
/// the `agy` resume command (#29).
final class AntigravityCLIJumpRoutingTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    @MainActor
    func testLiveAgyProcessYieldsATTYFocusRung() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)
        let liveProcess = liveAgy(cwd: "/Users/me/project", tty: "ttys009")

        let store = SessionStore(
            sources: [AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [liveProcess] })],
            processProvider: { [liveProcess] }
        )
        store.refresh(now: fixedNow)

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.agentName, "Antigravity")
        // The tty now comes from discovery rather than from hooks `agy` doesn't have (#33), so it
        // identifies THIS session instead of leaving the ladder to guess by cwd.
        XCTAssertEqual(session.tty, "ttys009")
        XCTAssertEqual(session.jumpRung, .exactFocus(tty: "ttys009"))
        XCTAssertEqual(session.resumeCommand, "agy")
    }

    /// Two `agy` terminals in one folder used to be indistinguishable — the ladder could only pick
    /// an agent process at the shared cwd and hope. Each row now carries the tty it was discovered
    /// on, so each focuses its own tab.
    @MainActor
    func testTwoAgySessionsInOneFolderEachFocusTheirOwnTab() throws {
        let home = try makeTemporaryDirectory()
        let processes = [
            liveAgy(pid: 100, cwd: "/Users/me/project", tty: "ttys002"),
            liveAgy(pid: 200, cwd: "/Users/me/project", tty: "ttys009")
        ]

        let store = SessionStore(
            sources: [AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { processes })],
            processProvider: { processes }
        )
        store.refresh(now: fixedNow)

        XCTAssertEqual(
            store.sessions.map(\.jumpRung).sorted { String(describing: $0) < String(describing: $1) },
            [.exactFocus(tty: "ttys002"), .exactFocus(tty: "ttys009")]
        )
    }

    /// A dead `agy` run leaves its logs behind; nothing about that is a session to jump to.
    @MainActor
    func testLogsLeftBehindByAFinishedRunProduceNoRowAtAll() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)

        let store = SessionStore(
            sources: [AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })],
            processProvider: { [] }
        )
        store.refresh(now: fixedNow)

        XCTAssertTrue(store.sessions.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// The exact live-user scenario (#29): one real `agy` CLI session plus several unrelated IDE
/// workspaces, one of which happens to be open on the SAME folder as the CLI session. Turning on
/// `showAntigravityWorkspaces` must yield exactly one row for that shared folder (the CLI
/// session) plus idle workspace rows for the others — never a duplicate.
final class AntigravityCLIWorkspaceDeduplicationTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    @MainActor
    func testCLISessionSuppressesTheWorkspaceRowForTheSamePathAndLeavesTheOthersAsIdleRows() throws {
        let cliHome = try makeTemporaryDirectory()
        try makeLog(in: cliHome, name: "cli-20260808_160031.log", workspace: "/Users/me/agent-perch", ageSeconds: 60)

        let ideHome = try makeTemporaryDirectory()
        try makeWorkspace(in: ideHome, hash: "same-folder", folderPath: "/Users/me/agent-perch", ageSeconds: 180)
        try makeWorkspace(in: ideHome, hash: "other-a", folderPath: "/Users/me/other-a", ageSeconds: 360)
        try makeWorkspace(in: ideHome, hash: "other-b", folderPath: "/Users/me/other-b", ageSeconds: 780)

        let liveProcess = liveAgy(cwd: "/Users/me/agent-perch")
        let store = SessionStore(
            sources: [
                AntigravitySessionSource(antigravityHome: ideHome, agyAvailableProvider: { false }, showWorkspaces: { true }),
                AntigravityCLISessionSource(antigravityCLIHome: cliHome, processProvider: { [liveProcess] })
            ],
            processProvider: { [liveProcess] }
        )
        store.refresh(now: fixedNow)

        let byCwd = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.cwd, $0) })
        XCTAssertEqual(store.sessions.count, 3, "the workspace row sharing the CLI session's folder must be dropped, not duplicated")
        XCTAssertEqual(byCwd["/Users/me/agent-perch"]?.sessionId, "antigravity-cli:cli-20260808_160031")
        XCTAssertEqual(byCwd["/Users/me/agent-perch"]?.title, "agent-perch")
        XCTAssertTrue(byCwd["/Users/me/other-a"]?.title.hasSuffix("— workspace") ?? false)
        XCTAssertTrue(byCwd["/Users/me/other-b"]?.title.hasSuffix("— workspace") ?? false)
    }

    /// With the setting OFF, only the CLI row shows at all — no workspace rows, duplicate or
    /// otherwise, since `AntigravitySessionSource` contributes nothing while opted out (#27).
    @MainActor
    func testWithWorkspacesOptedOutOnlyTheCLISessionShows() throws {
        let cliHome = try makeTemporaryDirectory()
        try makeLog(in: cliHome, name: "cli-20260808_160031.log", workspace: "/Users/me/agent-perch", ageSeconds: 60)

        let ideHome = try makeTemporaryDirectory()
        try makeWorkspace(in: ideHome, hash: "same-folder", folderPath: "/Users/me/agent-perch", ageSeconds: 180)
        try makeWorkspace(in: ideHome, hash: "other-a", folderPath: "/Users/me/other-a", ageSeconds: 360)

        let liveProcess = liveAgy(cwd: "/Users/me/agent-perch")
        let store = SessionStore(
            sources: [
                AntigravitySessionSource(antigravityHome: ideHome, agyAvailableProvider: { false }, showWorkspaces: { false }),
                AntigravityCLISessionSource(antigravityCLIHome: cliHome, processProvider: { [liveProcess] })
            ],
            processProvider: { [liveProcess] }
        )
        store.refresh(now: fixedNow)

        XCTAssertEqual(store.sessions.map(\.sessionId), ["antigravity-cli:cli-20260808_160031"])
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

// MARK: - Shared fixtures

/// Every fixture below is built against this fixed instant — kept as one private constant so
/// `ageSeconds` always means the same thing regardless of which test class's fixture called it.
private let fixtureNow = Date(timeIntervalSince1970: 1_786_000_000)

/// A live `agy` process the way the real one looks on this machine: `/Users/…/.local/bin/agy`
/// with a real controlling terminal. The tty is what makes it a session rather than an
/// agent-spawned or background process (#33), so it is never optional here.
private func liveAgy(
    pid: Int32 = 46_021,
    cwd: String,
    tty: String = "ttys002",
    startedAt: Date? = nil
) -> ClaudeProcess {
    ClaudeProcess(
        pid: pid,
        command: "/Users/me/.local/bin/agy",
        cwd: cwd,
        tty: tty,
        startedAt: startedAt ?? fixtureNow.addingTimeInterval(-60 * 60.0)
    )
}

/// A `cli-*.log`, with an optional `workspace <path>` line, at a given mtime age.
@discardableResult
private func makeLog(
    in antigravityCLIHome: URL,
    name: String,
    workspace: String?,
    ageSeconds: TimeInterval,
    extraLines: [String] = []
) throws -> URL {
    let logDirectory = antigravityCLIHome.appendingPathComponent("log", isDirectory: true)
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let url = logDirectory.appendingPathComponent(name)

    var lines = extraLines
    if let workspace { lines.append("workspace \(workspace)") }
    try Data(lines.joined(separator: "\n").utf8).write(to: url)

    try FileManager.default.setAttributes(
        [.modificationDate: fixtureNow.addingTimeInterval(-ageSeconds)],
        ofItemAtPath: url.path
    )
    return url
}

/// An `implicit/<uuid>.pb` at a given mtime age.
private func makeImplicit(in antigravityCLIHome: URL, uuid: String, ageSeconds: TimeInterval) throws {
    let implicitDirectory = antigravityCLIHome.appendingPathComponent("implicit", isDirectory: true)
    try FileManager.default.createDirectory(at: implicitDirectory, withIntermediateDirectories: true)
    let url = implicitDirectory.appendingPathComponent("\(uuid).pb")
    try Data().write(to: url)

    try FileManager.default.setAttributes(
        [.modificationDate: fixtureNow.addingTimeInterval(-ageSeconds)],
        ofItemAtPath: url.path
    )
}
