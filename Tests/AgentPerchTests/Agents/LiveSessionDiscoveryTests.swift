import Foundation
import XCTest
@testable import AgentPerch

/// The process table exactly as it was measured on the machine issue #33 was diagnosed against:
/// five real sessions the user could point at as Warp tabs, plus four processes that merely share
/// an agent's binary name. `ps -axo pid=,tty=,comm=` and `lsof -a -p PID -d cwd -Fn` produced every
/// value below.
///
/// The dividing line is the controlling terminal. Every session the user is actually sitting in
/// has one (`ttys*`); the ChatGPT app-server, the agent-spawned Codex threads and the background
/// `agy` all report `??`.
private enum GroundTruth {
    static let agentPerch = "/Users/gzorrilla/Developer/personal/agent-perch"
    static let cientoApp = "/Users/gzorrilla/Developer/ciento/ciento-app"

    /// The ONE real `agy` session — a Warp tab on ttys002.
    static let agy = ClaudeProcess(
        pid: 46_021,
        command: "/Users/gzorrilla/.local/bin/agy",
        cwd: agentPerch,
        tty: "ttys002"
    )
    /// The real Codex session, alive on ttys025, whose rollout had not been written to in 71
    /// minutes — the one the app dropped entirely.
    static let codex = ClaudeProcess(pid: 81_983, command: "codex", cwd: cientoApp, tty: "ttys025")
    static let claudeOne = ClaudeProcess(pid: 13_109, command: "claude", cwd: agentPerch, tty: "ttys004")
    static let claudeTwo = ClaudeProcess(pid: 99_521, command: "claude", cwd: cientoApp, tty: "ttys018")
    /// ChatGPT.app's embedded `codex` binary run as an internal app-server: right basename, no
    /// terminal, cwd `/`. Three independent reasons to reject it, and the source of the row the
    /// app used to title `/`.
    static let chatGPTAppServer = ClaudeProcess(
        pid: 21_321,
        command: "/Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true "
            + "app-server --analytics-default-enabled",
        cwd: "/",
        tty: nil
    )
    static let agentSpawnedCodexA = ClaudeProcess(pid: 41_545, command: "codex", cwd: cientoApp, tty: nil)
    static let agentSpawnedCodexB = ClaudeProcess(pid: 64_673, command: "codex", cwd: agentPerch, tty: nil)
    /// A background `agy` with no controlling terminal, sitting in the home directory — the source
    /// of the duplicate `/Users/gzorrilla` rows.
    static let backgroundAgy = ClaudeProcess(
        pid: 60_478,
        command: "/Users/gzorrilla/.local/bin/agy",
        cwd: "/Users/gzorrilla",
        tty: nil
    )

    static let processTable = [
        agy, codex, claudeOne, claudeTwo,
        chatGPTAppServer, agentSpawnedCodexA, agentSpawnedCodexB, backgroundAgy
    ]
}

final class LiveAgentScanTests: XCTestCase {
    /// The whole point of #33, in one assertion: the measured process table contains exactly two
    /// hookless sessions, and every `??` row and every bundled binary is excluded.
    func testTheRealProcessTableYieldsExactlyTheTwoHooklessSessions() {
        let sessions = LiveAgentScan.liveSessions(in: GroundTruth.processTable)

        XCTAssertEqual(
            sessions.map { [$0.agentName, $0.cwd, $0.tty] },
            [
                ["Antigravity", GroundTruth.agentPerch, "ttys002"],
                ["Codex", GroundTruth.cientoApp, "ttys025"]
            ]
        )
        XCTAssertEqual(sessions.map(\.pid), [46_021, 81_983])
    }

    /// Claude is deliberately absent from the scan: its hooks report the session and its tty from
    /// inside the terminal, which is better evidence than a process listing and already drives its
    /// own source.
    func testClaudeIsNotDiscoveredByProcessEvenOnARealTerminal() {
        XCTAssertTrue(LiveAgentScan.liveSessions(in: [GroundTruth.claudeOne, GroundTruth.claudeTwo]).isEmpty)
    }

    func testProcessesWithNoControllingTerminalAreExcluded() {
        XCTAssertTrue(
            LiveAgentScan.liveSessions(in: [
                GroundTruth.agentSpawnedCodexA,
                GroundTruth.agentSpawnedCodexB,
                GroundTruth.backgroundAgy
            ]).isEmpty
        )
    }

    /// The `??` filter must live here rather than only in `TTYResolver`: an injected listing has
    /// never been through that filter.
    func testPlaceholderAndNonSessionTerminalsAreRejected() {
        XCTAssertNil(LiveAgentScan.sessionTTY("??"))
        XCTAssertNil(LiveAgentScan.sessionTTY(""))
        XCTAssertNil(LiveAgentScan.sessionTTY(nil))
        XCTAssertNil(LiveAgentScan.sessionTTY("console"))
        XCTAssertEqual(LiveAgentScan.sessionTTY("ttys025"), "ttys025")
        XCTAssertEqual(LiveAgentScan.sessionTTY("/dev/ttys025"), "ttys025")
    }

    /// Binaries whose basename really is an agent's, rejected by PATH — the only check that can
    /// tell ChatGPT.app's `codex` from Homebrew's. Each is given a real terminal here so that the
    /// path rejection is the only thing left doing the work.
    func testBundledBinariesAreRejectedByPathEvenOnARealTerminal() {
        let impostors = [
            "/Applications/ChatGPT.app/Contents/Resources/codex app-server",
            "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/151/Helpers/codex",
            "/Applications/Antigravity IDE.app/Contents/MacOS/antigravity",
            "/Applications/Antigravity.app/Contents/MacOS/agy",
            "/opt/homebrew/bin/codex app-server",
            // Found on the same machine while proving this fix: a bundle path containing a SPACE,
            // so splitting on whitespace hands the basename check the bare word `Codex`. Only the
            // path rejection stops it.
            "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"
        ]
        for command in impostors {
            XCTAssertNil(LiveAgentScan.agentName(forCommand: command), command)
            XCTAssertTrue(
                LiveAgentScan.liveSessions(in: [
                    ClaudeProcess(pid: 1, command: command, cwd: "/Users/me/project", tty: "ttys002")
                ]).isEmpty,
                command
            )
        }
    }

    /// Basename, not substring: `codex-code-mode-host` really does run on the same tty as the
    /// Codex session it serves (pid 84101 on this machine), and it is not a session.
    func testOnlyAnExactExecutableBasenameCounts() {
        XCTAssertNil(LiveAgentScan.agentName(forCommand: "/Users/me/.codex/bin/codex-code-mode-host"))
        XCTAssertNil(LiveAgentScan.agentName(forCommand: "/usr/local/bin/codexbar"))
        XCTAssertEqual(LiveAgentScan.agentName(forCommand: "/opt/homebrew/bin/codex"), "Codex")
        XCTAssertEqual(LiveAgentScan.agentName(forCommand: "/Users/me/.local/bin/agy resume"), "Antigravity")
        XCTAssertEqual(LiveAgentScan.agentName(forCommand: "antigravity"), "Antigravity")
    }

    /// A process reporting the filesystem root has no meaningful working directory — never a
    /// folder anybody works in, and the exact shape behind the row the app titled `/`.
    func testAProcessAtTheFilesystemRootIsNeverASession() {
        XCTAssertTrue(
            LiveAgentScan.liveSessions(in: [
                ClaudeProcess(pid: 1, command: "/Users/me/.local/bin/agy", cwd: "/", tty: "ttys002")
            ]).isEmpty
        )
    }

    /// One terminal, one folder, two processes (a wrapper and the binary it exec'd) is one
    /// session. The lowest pid wins, so the row is stable between refreshes.
    func testProcessesSharingAgentCwdAndTTYCollapseToOneSessionKeepingTheLowestPID() {
        let sessions = LiveAgentScan.liveSessions(in: [
            ClaudeProcess(pid: 900, command: "codex", cwd: "/Users/me/project", tty: "ttys002"),
            ClaudeProcess(pid: 100, command: "/opt/homebrew/bin/codex", cwd: "/Users/me/project/", tty: "/dev/ttys002")
        ])
        XCTAssertEqual(sessions.map(\.pid), [100])
    }

    func testTheSameFolderOnTwoTerminalsIsTwoSessions() {
        let sessions = LiveAgentScan.liveSessions(in: [
            ClaudeProcess(pid: 100, command: "codex", cwd: "/Users/me/project", tty: "ttys002"),
            ClaudeProcess(pid: 200, command: "codex", cwd: "/Users/me/project", tty: "ttys009")
        ])
        XCTAssertEqual(sessions.map(\.tty), ["ttys002", "ttys009"])
    }

    func testCwdIsCanonicalisedSoTranscriptsCanBeMatchedAgainstIt() {
        let sessions = LiveAgentScan.liveSessions(in: [
            ClaudeProcess(pid: 1, command: "codex", cwd: "/private/tmp/project/", tty: "ttys002")
        ])
        XCTAssertEqual(sessions.first?.cwd, "/tmp/project")
    }
}

/// Codex's half of #33: a live session is discovered from the process table and merely ENRICHED by
/// its rollout, so rollout age can no longer decide whether it exists.
final class CodexLiveSessionDiscoveryTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    /// The exact regression: the real ttys025 Codex session's rollout was 71 minutes old — past
    /// the 60-minute hidden threshold — so the app showed no Codex row at all. It must come back,
    /// and it must read `.idle`, since a 71-minute-old write is no evidence of a turn in flight.
    func testALiveSessionWithASeventyOneMinuteOldRolloutIsVisibleAndIdle() throws {
        let codexHome = try makeCodexHome(rollouts: [
            Rollout(id: "ciento-session", cwd: GroundTruth.cientoApp, ageSeconds: 71 * 60.0)
        ])

        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { GroundTruth.processTable },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)

        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(discovered.count, 1, "the ?? Codex processes must not add rows of their own")
        XCTAssertEqual(session.sessionId, "ciento-session")
        XCTAssertEqual(session.cwd, GroundTruth.cientoApp)
        XCTAssertEqual(session.title, "ciento-app")
        XCTAssertEqual(session.tty, "ttys025")
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.lastActivity, fixedNow.addingTimeInterval(-71 * 60.0))
        XCTAssertEqual(session.resumeCommand, Jumper.codexResumeCommand(sessionId: "ciento-session"))
    }

    /// A live session mid-turn is `.active` — and still renders neutrally, because a hookless
    /// agent can never honestly claim "Working…" (#31).
    func testALiveSessionWithATenSecondOldWriteIsActiveButStillRendersNeutrally() throws {
        let codexHome = try makeCodexHome(rollouts: [
            Rollout(id: "busy", cwd: GroundTruth.cientoApp, ageSeconds: 10)
        ])

        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { GroundTruth.processTable },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)

        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(session.status, .active)
        XCTAssertFalse(session.supportsLiveStatus)
        XCTAssertEqual(SessionStatusPresentation.of(agentSession(from: session)), .neutral)
    }

    /// The other side of the rule, untouched: with NO live process a rollout is recently-finished
    /// work — visible for an hour on its own freshness, then gone.
    func testWithoutALiveProcessTheFreshnessPathStillDecidesVisibility() throws {
        let fresh = try makeCodexHome(rollouts: [
            Rollout(id: "fresh", cwd: "/Users/me/project", ageSeconds: 4 * 60.0)
        ])
        let stale = try makeCodexHome(rollouts: [
            Rollout(id: "stale", cwd: "/Users/me/project", ageSeconds: 2 * 60 * 60.0)
        ])

        let visible = CodexSessionSource(codexHome: fresh, processProvider: { [] }, showSubAgentSessions: { false })
            .discover(now: fixedNow)
        XCTAssertEqual(visible.map(\.sessionId), ["fresh"])
        XCTAssertEqual(visible.first?.status, .idle)
        XCTAssertNil(visible.first?.tty, "nothing was discovered on a terminal, so nothing may claim one")

        let hidden = CodexSessionSource(codexHome: stale, processProvider: { [] }, showSubAgentSessions: { false })
            .discover(now: fixedNow)
        XCTAssertTrue(hidden.isEmpty)
    }

    /// A live session with no rollout at all is still a session: titled by its cwd, dated by when
    /// its process started, and reopenable with a bare `codex` since there is no id to resume.
    func testALiveSessionWithNoRolloutIsStillDiscovered() throws {
        let codexHome = try makeCodexHome(rollouts: [])
        let started = fixedNow.addingTimeInterval(-2 * 24 * 60 * 60.0)
        let process = ClaudeProcess(
            pid: 81_983,
            command: "codex",
            cwd: GroundTruth.cientoApp,
            tty: "ttys025",
            startedAt: started
        )

        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [process] },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)

        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(session.sessionId, "codex-live:ttys025:\(GroundTruth.cientoApp)")
        XCTAssertEqual(session.title, "ciento-app")
        XCTAssertEqual(session.lastActivity, started)
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.resumeCommand, "codex")
    }

    /// A rollout may enrich exactly one session. Two live sessions in one folder take the two
    /// newest rollouts there rather than both claiming the same one.
    func testEachLiveSessionClaimsItsOwnRollout() throws {
        let codexHome = try makeCodexHome(rollouts: [
            Rollout(id: "newer", cwd: "/Users/me/project", ageSeconds: 60),
            Rollout(id: "older", cwd: "/Users/me/project", ageSeconds: 30 * 60.0)
        ])
        let processes = [
            ClaudeProcess(pid: 100, command: "codex", cwd: "/Users/me/project", tty: "ttys002"),
            ClaudeProcess(pid: 200, command: "codex", cwd: "/Users/me/project", tty: "ttys009")
        ]

        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { processes },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)

        XCTAssertEqual(Set(discovered.map(\.sessionId)), ["newer", "older"])
    }

    /// A `codex resume <id>` launch names the rollout it is replaying; a newer rollout at the same
    /// cwd belonging to somebody else must not be stolen for it.
    func testAResumeCommandLineMatchesTheRolloutItNames() throws {
        let codexHome = try makeCodexHome(rollouts: [
            Rollout(id: "someone-elses", cwd: "/Users/me/project", ageSeconds: 60),
            Rollout(id: "mine", cwd: "/Users/me/project", ageSeconds: 30 * 60.0)
        ])
        let process = ClaudeProcess(
            pid: 100,
            command: "/opt/homebrew/bin/codex resume mine",
            cwd: "/Users/me/project",
            tty: "ttys002"
        )

        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { [process] },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)

        XCTAssertEqual(discovered.first?.sessionId, "mine")
        XCTAssertEqual(discovered.first?.tty, "ttys002")
    }

    /// A claimed rollout may never also appear as a finished-work row: one session, one card.
    func testAClaimedRolloutIsNeverEmittedTwice() throws {
        let codexHome = try makeCodexHome(rollouts: [
            Rollout(id: "live", cwd: GroundTruth.cientoApp, ageSeconds: 30)
        ])

        let discovered = CodexSessionSource(
            codexHome: codexHome,
            processProvider: { GroundTruth.processTable },
            showSubAgentSessions: { false }
        ).discover(now: fixedNow)
        XCTAssertEqual(discovered.map(\.sessionId), ["live"])
    }

    // MARK: - Fixtures

    private struct Rollout {
        let id: String
        let cwd: String
        var ageSeconds: TimeInterval = 60
    }

    private func makeCodexHome(rollouts: [Rollout]) throws -> URL {
        let codexHome = try makeTemporaryDirectory()
        let dayDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(CodexRolloutDiscovery.dayDirectoryPath(for: fixedNow), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        for rollout in rollouts {
            let modifiedAt = fixedNow.addingTimeInterval(-rollout.ageSeconds)
            let url = dayDirectory.appendingPathComponent("rollout-\(rollout.id).jsonl")
            let line = #"{"type":"session_meta","payload":{"session_id":"\#(rollout.id)","#
                + #""cwd":"\#(rollout.cwd)","originator":"codex-tui","source":"cli"}}"#
            try Data(line.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        return codexHome
    }

    /// The `AgentSession` `SessionStore` would build from this `DiscoveredSession`, for the
    /// presentation assertion — only the fields `SessionStatusPresentation` reads matter.
    private func agentSession(from discovered: DiscoveredSession) -> AgentSession {
        AgentSession(
            sessionId: discovered.sessionId,
            agentName: discovered.agentName,
            cwd: discovered.cwd,
            modifiedAt: discovered.lastActivity,
            status: discovered.status,
            jumpRung: .newTab,
            title: discovered.title ?? "",
            lastPrompt: nil,
            tty: discovered.tty,
            terminalName: nil,
            currentActivity: nil,
            notificationMessage: nil,
            pendingToolName: nil,
            pendingToolInput: nil,
            resumeCommand: discovered.resumeCommand,
            supportsLiveStatus: discovered.supportsLiveStatus
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// The whole list, assembled the way the app assembles it, against the measured process table and
/// fixture transcript trees shaped like the real ones — the end-to-end shape of what the user saw
/// wrong in #33.
final class GroundTruthSessionListTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    @MainActor
    func testTheMeasuredMachineProducesExactlyTwoHooklessRows() throws {
        let codexHome = try makeTemporaryDirectory()
        let dayDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(CodexRolloutDiscovery.dayDirectoryPath(for: fixedNow), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        let rollout = dayDirectory.appendingPathComponent("rollout-ciento.jsonl")
        try Data((#"{"type":"session_meta","payload":{"session_id":"ciento-session","#
            + #""cwd":"\#(GroundTruth.cientoApp)","originator":"codex-tui","source":"cli"}}"#).utf8)
            .write(to: rollout)
        // 71 minutes old: past every freshness threshold in the app, and still a live session.
        try FileManager.default.setAttributes(
            [.modificationDate: fixedNow.addingTimeInterval(-71 * 60.0)],
            ofItemAtPath: rollout.path
        )

        // The eight logs `agy` actually left behind, including the two recording `/` and the four
        // naming the home directory.
        let agyHome = try makeTemporaryDirectory()
        let logDirectory = agyHome.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logs: [(name: String, workspace: String, ageMinutes: Double)] = [
            ("cli-0920.log", "/Users/gzorrilla", 3),
            ("cli-0918.log", GroundTruth.agentPerch, 5),
            ("cli-0827.log", "/", 56),
            ("cli-0826.log", "/", 56.5),
            ("cli-0811.log", "/Users/gzorrilla", 72),
            ("cli-0800.log", "/Users/gzorrilla", 83),
            ("cli-0743.log", "/Users/gzorrilla", 100),
            ("cli-0727.log", "/Users/gzorrilla", 116)
        ]
        for log in logs {
            let url = logDirectory.appendingPathComponent(log.name)
            try Data("I0810 09:16:58 1 manager.go:367] CLI store manager for workspace \(log.workspace)\n".utf8)
                .write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: fixedNow.addingTimeInterval(-log.ageMinutes * 60.0)],
                ofItemAtPath: url.path
            )
        }

        let store = SessionStore(
            sources: [
                CodexSessionSource(
                    codexHome: codexHome,
                    processProvider: { GroundTruth.processTable },
                    showSubAgentSessions: { false }
                ),
                AntigravityCLISessionSource(
                    antigravityCLIHome: agyHome,
                    processProvider: { GroundTruth.processTable }
                )
            ],
            processProvider: { GroundTruth.processTable },
            terminalResolver: TerminalNameResolver(process: { _ in nil })
        )
        store.refresh(now: fixedNow)

        XCTAssertEqual(
            store.sessions.map { [$0.agentName, $0.title, $0.cwd, $0.tty ?? "-"] },
            [
                ["Antigravity", "agent-perch", GroundTruth.agentPerch, "ttys002"],
                ["Codex", "ciento-app", GroundTruth.cientoApp, "ttys025"]
            ],
            "one row per real session — no `/` row, no duplicate home-directory rows, and the "
                + "Codex session present despite its 71-minute-old rollout"
        )
        XCTAssertEqual(store.sessions.map(\.status), [.idle, .idle])
        XCTAssertEqual(
            store.sessions.map(\.jumpRung),
            [.exactFocus(tty: "ttys002"), .exactFocus(tty: "ttys025")]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
