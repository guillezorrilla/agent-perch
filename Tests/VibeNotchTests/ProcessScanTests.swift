import Foundation
import XCTest
@testable import VibeNotch

/// The batched scan's parsers. One `lsof` and one `ps` now answer for every candidate pid at
/// once, so their field output — including the shapes a dying pid leaves behind — is the only
/// thing standing between a click and the right terminal.
final class BatchedProcessListingTests: XCTestCase {
    private let lsofListing = """
        p101
        fcwd
        n/Users/me/other
        p202
        fcwd
        n/Users/me/project
        p303
        fcwd
        n/tmp
        """

    func testLsofFieldOutputBecomesAPidToCwdMap() {
        XCTAssertEqual(
            TTYResolver.cwdsByPID(inLsofFieldOutput: lsofListing),
            [101: "/Users/me/other", 202: "/Users/me/project", 303: "/tmp"]
        )
    }

    /// lsof exits non-zero as soon as one pid in the batch has gone away, and can leave a
    /// half-written record behind: a path with no process line above it, a pid line with nothing
    /// under it, an unparsable pid. None of that may cost the entries around it.
    func testMalformedLsofLinesAreSkippedWithoutLosingTheGoodOnes() {
        let listing = """
            n/orphaned/path
            pnot-a-pid
            n/Users/me/ignored
            p404
            n
            p505
            fcwd
            n/Users/me/kept

            """

        XCTAssertEqual(
            TTYResolver.cwdsByPID(inLsofFieldOutput: listing),
            [505: "/Users/me/kept"]
        )
        XCTAssertTrue(TTYResolver.cwdsByPID(inLsofFieldOutput: "").isEmpty)
    }

    func testFirstEntryWinsForAProcessListedTwice() {
        let listing = "p707\nn/first\nn/second\n"
        XCTAssertEqual(TTYResolver.cwdsByPID(inLsofFieldOutput: listing), [707: "/first"])
    }

    /// Several shells sitting in one directory is the normal case, not an error — the most
    /// recently started one is the tab the user most likely means.
    func testPidsAtACwdComeBackMostRecentlyStartedFirst() {
        let listing = "p101\nn/repo\np909\nn/repo\np404\nn/repo\np202\nn/elsewhere\n"

        XCTAssertEqual(TTYResolver.pids(withCwd: "/repo", inLsofFieldOutput: listing), [909, 404, 101])
        XCTAssertEqual(TTYResolver.pids(withCwd: "/nowhere", inLsofFieldOutput: listing), [])
    }

    func testLsofCwdsAreComparedCanonically() {
        let listing = "p101\nn/private/tmp/some-project\n"

        XCTAssertEqual(TTYResolver.pids(withCwd: "/tmp/some-project/", inLsofFieldOutput: listing), [101])
    }

    func testPSOutputBecomesAPidToTTYMap() {
        let listing = """
                1 ??
            60933 ttys012
            60934 /dev/ttys013

            """

        // A process with no controlling terminal is dropped rather than recorded as "??", and a
        // fully-qualified device is stored the way every caller compares it.
        XCTAssertEqual(
            TTYResolver.ttysByPID(inPSOutput: listing),
            [60933: "ttys012", 60934: "ttys013"]
        )
    }

    func testMalformedPSLinesAreSkipped() {
        let listing = "garbage\n\nnotapid ttys001\n71000\n71001 ttys002 extra-column\n"

        XCTAssertEqual(TTYResolver.ttysByPID(inPSOutput: listing), [71001: "ttys002"])
    }

    /// `etime`'s three shapes, byte-for-byte from `ps -o pid=,tty=,etime=` on the machine issue
    /// #33 was measured on: `MM:SS` under an hour, `HH:MM:SS` under a day, `DD-HH:MM:SS` beyond.
    func testElapsedTimeParsesAllThreePSShapes() {
        XCTAssertEqual(TTYResolver.elapsedSeconds("00:42"), 42)
        XCTAssertEqual(TTYResolver.elapsedSeconds("11:14:33"), 11 * 3_600.0 + 14 * 60.0 + 33)
        XCTAssertEqual(TTYResolver.elapsedSeconds("02-04:31:00"), 2 * 86_400.0 + 4 * 3_600.0 + 31 * 60.0)
    }

    func testUnparsableElapsedTimesAreRejectedRatherThanGuessed() {
        XCTAssertNil(TTYResolver.elapsedSeconds(""))
        XCTAssertNil(TTYResolver.elapsedSeconds("42"))
        XCTAssertNil(TTYResolver.elapsedSeconds("ttys002"))
        XCTAssertNil(TTYResolver.elapsedSeconds("1-2-3:04:05"))
        XCTAssertNil(TTYResolver.elapsedSeconds("00:00:00:01"))
    }

    /// The same `ps` run answers two questions, so the start-time parser has to survive the rows
    /// the tty parser drops: a `??` process still reports a perfectly good elapsed time.
    func testPSOutputBecomesAPidToStartTimeMap() {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let listing = """
            46021 ttys002     11:14:33
            81983 ttys025  02-04:31:00
            21321 ??       02-06:15:40
            99999 ttys003
            88888 ttys004  not-an-etime

            """

        XCTAssertEqual(
            TTYResolver.startedAtByPID(inPSOutput: listing, now: now),
            [
                46_021: now.addingTimeInterval(-(11 * 3_600.0 + 14 * 60.0 + 33)),
                81_983: now.addingTimeInterval(-(2 * 86_400.0 + 4 * 3_600.0 + 31 * 60.0)),
                21_321: now.addingTimeInterval(-(2 * 86_400.0 + 6 * 3_600.0 + 15 * 60.0 + 40))
            ]
        )
    }
}

final class CanonicalPathTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testTrailingSlashesAndRelativeComponentsCollapse() {
        XCTAssertTrue(CanonicalPath.equal("/repo/", "/repo"))
        XCTAssertTrue(CanonicalPath.equal("/repo///", "/repo"))
        XCTAssertTrue(CanonicalPath.equal("/repo/./sub", "/repo/sub"))
        XCTAssertTrue(CanonicalPath.equal("/repo/sub/../sub", "/repo/sub"))
        XCTAssertEqual(CanonicalPath.canonical("/"), "/")
    }

    /// `/private/var` and `/var` are the same directory; `lsof` reports one and a shell reports
    /// the other. This holds whether or not the path still exists.
    func testPrivatePrefixIsNormalizedEvenForPathsThatNoLongerExist() {
        let deleted = "tmp/gone-\(UUID().uuidString)"

        XCTAssertTrue(CanonicalPath.equal("/private/var/folders/x/repo", "/var/folders/x/repo"))
        XCTAssertTrue(CanonicalPath.equal("/private/\(deleted)/", "/\(deleted)"))
        XCTAssertTrue(CanonicalPath.equal("/private/etc/hosts", "/etc/hosts"))
        // A directory that merely starts with the same letters is left alone.
        XCTAssertFalse(CanonicalPath.equal("/private/variables", "/variables"))
    }

    func testSymlinkedDirectoriesCompareEqualToTheirTarget() throws {
        let base = temporaryDirectory()
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertTrue(CanonicalPath.equal(link.path, real.path))
        XCTAssertTrue(CanonicalPath.equal(link.path + "/", real.path))
    }

    func testDifferentDirectoriesStayDifferent() {
        XCTAssertFalse(CanonicalPath.equal("/repo/a", "/repo/b"))
        XCTAssertFalse(CanonicalPath.equal("/repo", "/repo-two"))
        XCTAssertEqual(CanonicalPath.canonical(""), "")
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

/// Which process a session is jumped to. Per-session identity first, cwd only as a last resort —
/// the wrong-tab half of #23.
final class JumpTargetTests: XCTestCase {
    private let claudeInRepo = ClaudeProcess(
        pid: 200,
        command: "/usr/local/bin/claude",
        cwd: "/repo",
        tty: "ttys002"
    )

    func testSessionTTYWinsOverAProcessSharingTheCwd() {
        let target = JumpTarget.resolve(
            agentName: "Claude",
            sessionId: "session-1",
            tty: "ttys009",
            cwd: "/repo",
            processes: [claudeInRepo]
        )

        XCTAssertEqual(target.match, .sessionTTY)
        XCTAssertEqual(target.tty, "ttys009")
        // No live process carries that tty, so there is no pid to walk for a terminal name —
        // but the tty is still exact, and still what we focus.
        XCTAssertNil(target.pid)
    }

    func testSessionTTYPicksUpItsOwnProcessRegardlessOfDevPrefix() {
        let process = ClaudeProcess(pid: 300, command: "/usr/local/bin/claude", cwd: "/other", tty: "/dev/ttys009")

        let target = JumpTarget.resolve(
            agentName: "Claude",
            sessionId: "session-1",
            tty: "/dev/ttys009",
            cwd: "/repo",
            processes: [process]
        )

        XCTAssertEqual(target.tty, "ttys009")
        XCTAssertEqual(target.pid, 300)
    }

    func testPlaceholderTTYIsNotAnIdentity() {
        for tty in ["", "??"] {
            let target = JumpTarget.resolve(
                agentName: "Claude",
                sessionId: "session-1",
                tty: tty,
                cwd: "/repo",
                processes: [claudeInRepo]
            )
            XCTAssertEqual(target.match, .cwd, tty)
            XCTAssertEqual(target.pid, 200, tty)
        }
    }

    func testAProcessNamingTheSessionBeatsOneThatMerelySharesTheCwd() {
        let bare = ClaudeProcess(pid: 10, command: "/usr/local/bin/codex", cwd: "/repo", tty: "ttys001")
        let named = ClaudeProcess(
            pid: 11,
            command: "/usr/local/bin/codex resume 019fe8a4",
            cwd: "/repo",
            tty: "ttys004"
        )

        let target = JumpTarget.resolve(
            agentName: "Codex",
            sessionId: "019fe8a4",
            tty: nil,
            cwd: "/repo",
            processes: [bare, named]
        )

        XCTAssertEqual(target.match, .sessionProcess)
        XCTAssertEqual(target.pid, 11)
        XCTAssertEqual(target.tty, "ttys004")
    }

    func testAProcessResumingAnotherSessionIsNeverACandidate() {
        let other = ClaudeProcess(
            pid: 12,
            command: "/usr/local/bin/codex resume some-other-id",
            cwd: "/repo",
            tty: "ttys007"
        )

        let target = JumpTarget.resolve(
            agentName: "Codex",
            sessionId: "019fe8a4",
            tty: nil,
            cwd: "/repo",
            processes: [other]
        )

        XCTAssertEqual(target.match, .none)
        XCTAssertNil(target.tty)
    }

    func testCwdIsMatchedCanonically() {
        let process = ClaudeProcess(
            pid: 21,
            command: "/usr/local/bin/claude",
            cwd: "/private/var/folders/x/repo",
            tty: "ttys003"
        )

        let target = JumpTarget.resolve(
            agentName: "Claude",
            sessionId: "session-1",
            tty: nil,
            cwd: "/var/folders/x/repo/",
            processes: [process]
        )

        XCTAssertEqual(target.match, .cwd)
        XCTAssertEqual(target.tty, "ttys003")
    }

    /// Two sessions in one repo with no tty between them: still a guess, but the same guess every
    /// time, and one that says so.
    func testAmbiguousCwdPicksTheMostRecentlyStartedAndRecordsTheAlternatives() {
        let processes = [
            ClaudeProcess(pid: 400, command: "/usr/local/bin/claude", cwd: "/repo", tty: "ttys001"),
            ClaudeProcess(pid: 900, command: "/usr/local/bin/claude", cwd: "/repo", tty: "ttys005"),
            ClaudeProcess(pid: 700, command: "/usr/local/bin/claude", cwd: "/repo", tty: "ttys003")
        ]

        let target = JumpTarget.resolve(
            agentName: "Claude",
            sessionId: "session-1",
            tty: nil,
            cwd: "/repo",
            processes: processes
        )

        XCTAssertEqual(target.match, .ambiguousCwd)
        XCTAssertTrue(target.isAmbiguous)
        XCTAssertEqual(target.pid, 900)
        XCTAssertEqual(target.candidates, [400, 700, 900])
        // Order in, order out: the same listing shuffled must still choose 900.
        XCTAssertEqual(
            JumpTarget.resolve(
                agentName: "Claude",
                sessionId: "session-1",
                tty: nil,
                cwd: "/repo",
                processes: processes.reversed()
            ).pid,
            900
        )
    }

    /// A terminal we can actually land in beats a newer process we cannot.
    func testACandidateWithATTYOutranksANewerOneWithout() {
        let processes = [
            ClaudeProcess(pid: 100, command: "/usr/local/bin/claude", cwd: "/repo", tty: "ttys001"),
            ClaudeProcess(pid: 999, command: "/usr/local/bin/claude", cwd: "/repo", tty: nil)
        ]

        let target = JumpTarget.resolve(
            agentName: "Claude",
            sessionId: "session-1",
            tty: nil,
            cwd: "/repo",
            processes: processes
        )

        XCTAssertEqual(target.pid, 100)
        XCTAssertEqual(target.tty, "ttys001")
    }

    func testOnlyTheSessionsOwnAgentCounts() {
        let target = JumpTarget.resolve(
            agentName: "Codex",
            sessionId: "session-1",
            tty: nil,
            cwd: "/repo",
            processes: [claudeInRepo]
        )

        XCTAssertEqual(target.match, .none)
        XCTAssertEqual(Jumper.rung(for: target), .newTab)
    }

    func testASingleCwdMatchIsNotReportedAsAmbiguous() {
        let target = JumpTarget.resolve(
            agentName: "Claude",
            sessionId: "session-1",
            tty: nil,
            cwd: "/repo",
            processes: [claudeInRepo]
        )

        XCTAssertEqual(target.match, .cwd)
        XCTAssertFalse(target.isAmbiguous)
        XCTAssertEqual(target.candidates, [])
        XCTAssertEqual(Jumper.rung(for: target), .exactFocus(tty: "ttys002"))
    }
}

/// The snapshot a refresh and a click share, so a click does not pay for a scan the store
/// finished milliseconds ago.
final class ProcessTableCacheTests: XCTestCase {
    func testASecondReadInsideTheWindowReusesTheSnapshot() {
        let scanner = RecordingScanner(now: Date(timeIntervalSince1970: 1_000))
        let cache = ProcessTableCache(ttl: 2, now: { scanner.now }, scan: { scanner.scan() })

        XCTAssertEqual(cache.processes().first?.pid, 1)
        scanner.now = Date(timeIntervalSince1970: 1_001.9)
        XCTAssertEqual(cache.processes().first?.pid, 1)

        XCTAssertEqual(scanner.scans, 1)
    }

    func testTheWindowExpiresAndTheNextReadRescans() {
        let scanner = RecordingScanner(now: Date(timeIntervalSince1970: 1_000))
        let cache = ProcessTableCache(ttl: 2, now: { scanner.now }, scan: { scanner.scan() })

        _ = cache.processes()
        scanner.now = Date(timeIntervalSince1970: 1_002)
        _ = cache.processes()

        XCTAssertEqual(scanner.scans, 2)
        // And the fresh answer is the one handed back, not the stale one.
        XCTAssertEqual(cache.processes().first?.command, "/usr/local/bin/claude 2")
        XCTAssertEqual(scanner.scans, 2)
    }

    /// Lock-protected because the store reads this on the main actor while `Jumper` reads it on
    /// its discovery queue.
    private final class RecordingScanner: @unchecked Sendable {
        private let lock = NSLock()
        private var currentDate: Date
        private var scanCount = 0

        init(now: Date) { currentDate = now }

        var now: Date {
            get { lock.withLock { currentDate } }
            set { lock.withLock { currentDate = newValue } }
        }

        var scans: Int { lock.withLock { scanCount } }

        func scan() -> [ClaudeProcess] {
            lock.withLock {
                scanCount += 1
                return [ClaudeProcess(
                    pid: 1,
                    command: "/usr/local/bin/claude \(scanCount)",
                    cwd: "/repo",
                    tty: "ttys001"
                )]
            }
        }
    }
}

/// The store's half of per-session identity: the hook tty is the session's own, it is re-read on
/// every hook event, and it decides which process the card's terminal and jump rung come from.
final class SessionIdentityTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    func testTheSessionsOwnTTYOutranksAnotherProcessAtTheSameCwd() throws {
        let store = makeStore(processes: [
            // Another Claude session in the same repo, started later — it would win any
            // cwd-based match, and it is not this session.
            ClaudeProcess(pid: 900, command: "/usr/local/bin/claude", cwd: "/tmp/repo", tty: "ttys055"),
            ClaudeProcess(pid: 100, command: "/usr/local/bin/claude", cwd: "/tmp/repo", tty: "ttys001")
        ])

        try send(to: store, "SessionStart", tty: "ttys001", timestamp: 100)

        XCTAssertEqual(store.sessions.first?.tty, "ttys001")
        XCTAssertEqual(store.sessions.first?.jumpRung, .exactFocus(tty: "ttys001"))
    }

    /// A session resumed in another terminal reports a new tty; the old one points at a tab that
    /// is not it any more.
    @MainActor
    func testTheHookTTYIsRefreshedOnEveryEvent() throws {
        let store = makeStore(processes: [])

        try send(to: store, "SessionStart", tty: "ttys001", timestamp: 100)
        XCTAssertEqual(store.sessions.first?.jumpRung, .exactFocus(tty: "ttys001"))

        try send(to: store, "UserPromptSubmit", tty: "/dev/ttys077", timestamp: 101)

        XCTAssertEqual(store.sessions.first?.tty, "ttys077")
        XCTAssertEqual(store.sessions.first?.jumpRung, .exactFocus(tty: "ttys077"))
    }

    /// The hook has no tty to report (`??`) — the cwd is all that is left, and it still has to
    /// find the session's own agent rather than the vim session next to it.
    @MainActor
    func testWithoutATTYTheAgentProcessAtTheCwdIsUsed() throws {
        let store = makeStore(processes: [
            ClaudeProcess(pid: 10, command: "/usr/bin/vim claude-notes.md", cwd: "/tmp/repo", tty: "ttys009"),
            ClaudeProcess(pid: 11, command: "/usr/local/bin/claude", cwd: "/private/tmp/repo", tty: "ttys004")
        ])

        try send(to: store, "SessionStart", tty: "??", timestamp: 100)

        XCTAssertNil(store.sessions.first?.tty)
        XCTAssertEqual(store.sessions.first?.jumpRung, .exactFocus(tty: "ttys004"))
    }

    @MainActor
    private func makeStore(processes: [ClaudeProcess]) -> SessionStore {
        SessionStore(
            projectsDirectory: temporaryDirectory(),
            codexHome: temporaryDirectory(),
            antigravityHome: temporaryDirectory(),
            antigravityCLIHome: temporaryDirectory(),
            processProvider: { processes }
        )
    }

    @MainActor
    private func send(
        to store: SessionStore,
        _ name: String,
        tty: String,
        timestamp: Int
    ) throws {
        let event = try HookEvent.parse(Data("""
        {"event":"\(name)","tty":"\(tty)","ts":\(timestamp),"payload":{"session_id":"session-1","cwd":"/tmp/repo"}}
        """.utf8))
        store.handle(event, now: event.timestamp)
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

/// The click's immediate acknowledgement: the card says it is going somewhere, and stops saying
/// it whichever way the jump ends.
final class JumpingStateTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    func testTheCardIsMarkedJumpingForTheDurationAndClearedOnSuccess() async {
        let store = makeStore()
        let session = makeSession()
        var markedDuringJump = false

        let jumped = await store.performJump(session) { session in
            markedDuringJump = store.isJumping(session.sessionId)
            return true
        }

        XCTAssertTrue(jumped)
        XCTAssertTrue(markedDuringJump)
        XCTAssertFalse(store.isJumping(session.sessionId))
        XCTAssertTrue(store.jumpingSessions.isEmpty)
    }

    /// A jump that finds nothing must not leave the card spinning forever.
    @MainActor
    func testTheMarkIsClearedWhenTheJumpFails() async {
        let store = makeStore()
        let session = makeSession()

        let jumped = await store.performJump(session) { _ in false }

        XCTAssertFalse(jumped)
        XCTAssertFalse(store.isJumping(session.sessionId))
    }

    @MainActor
    func testASecondClickWhileAJumpIsInFlightIsIgnored() async {
        let store = makeStore()
        let session = makeSession()
        var attempts = 0

        _ = await store.performJump(session) { session in
            attempts += 1
            let reentrant = await store.performJump(session) { _ in
                attempts += 1
                return true
            }
            XCTAssertFalse(reentrant)
            return true
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(store.isJumping(session.sessionId))
    }

    @MainActor
    private func makeStore() -> SessionStore {
        SessionStore(
            projectsDirectory: temporaryDirectory(),
            codexHome: temporaryDirectory(),
            antigravityHome: temporaryDirectory(),
            antigravityCLIHome: temporaryDirectory(),
            processProvider: { [] }
        )
    }

    private func makeSession() -> AgentSession {
        AgentSession(
            sessionId: "session-1",
            agentName: "Claude",
            cwd: "/repo",
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            status: .working,
            jumpRung: .newTab,
            title: "repo",
            lastPrompt: nil,
            tty: nil,
            terminalName: nil,
            currentActivity: nil,
            notificationMessage: nil,
            pendingToolName: nil,
            pendingToolInput: nil,
            resumeCommand: nil
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
