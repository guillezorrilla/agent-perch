import Foundation
import XCTest
@testable import AgentPerch

/// Fixtures live in the test's OWN temporary directory — the real `~/.kiro` is never read from and
/// never written to by this suite (#11).
fileprivate extension XCTestCase {
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

final class KiroSessionRecordTests: XCTestCase {
    func testParsesTheDocumentedShape() {
        let json = #"""
        {"sessionId":"abc-123","workingDirectory":"/Users/me/project","title":"Fix the flaky test"}
        """#
        let record = KiroSessionRecord.parse(Data(json.utf8), fallbackSessionId: "from-filename")

        XCTAssertEqual(record?.sessionId, "abc-123")
        XCTAssertEqual(record?.workingDirectory, "/Users/me/project")
        XCTAssertEqual(record?.title, "Fix the flaky test")
        XCTAssertNil(record?.parentSessionId)
    }

    /// In the documented layout the id IS the filename, so a record that does not repeat it inside
    /// is perfectly ordinary rather than broken.
    func testFallsBackToTheFilenameForTheId() {
        let record = KiroSessionRecord.parse(
            Data(#"{"workingDirectory":"/Users/me/project"}"#.utf8),
            fallbackSessionId: "from-filename"
        )
        XCTAssertEqual(record?.sessionId, "from-filename")
        XCTAssertNil(record?.title)
    }

    func testCarriesParentSessionIdSoSubAgentSessionsCanBeFiltered() {
        let record = KiroSessionRecord.parse(
            Data(#"{"workingDirectory":"/Users/me/project","parentSessionId":"parent-1"}"#.utf8),
            fallbackSessionId: "x"
        )
        XCTAssertEqual(record?.parentSessionId, "parent-1")
    }

    /// The one field this cannot do without: no absolute `workingDirectory` means no jump, so the
    /// record is dropped rather than shown with a guessed path.
    func testRecordsWithoutAnAbsoluteWorkingDirectoryAreRejected() {
        XCTAssertNil(KiroSessionRecord.parse(Data(#"{"title":"no cwd"}"#.utf8), fallbackSessionId: "x"))
        XCTAssertNil(
            KiroSessionRecord.parse(Data(#"{"workingDirectory":"relative/path"}"#.utf8), fallbackSessionId: "x")
        )
    }

    func testMalformedTruncatedAndMissingFilesAreRejected() throws {
        XCTAssertNil(KiroSessionRecord.parse(Data("{not json at all".utf8), fallbackSessionId: "x"))
        XCTAssertNil(KiroSessionRecord.parse(Data(), fallbackSessionId: "x"))
        XCTAssertNil(
            KiroSessionRecord.parse(Data(#"{"workingDirectory":"/Users/me/proj"#.utf8), fallbackSessionId: "x")
        )
        XCTAssertNil(KiroSessionRecord.read(at: URL(fileURLWithPath: "/nonexistent/abc.json")))
    }
}

final class KiroSessionDiscoveryTests: XCTestCase {
    func testPairsEachRecordWithItsTranscriptAndLockNewestFirst() throws {
        let directory = try makeTemporaryDirectory()
        try write(id: "older", in: directory, age: 600, transcript: true, locked: false)
        try write(id: "newer", in: directory, age: 60, transcript: true, locked: true)

        let candidates = KiroSessionDiscovery.candidates(sessionsDirectory: directory, fileManager: .default)
        XCTAssertEqual(candidates.map { $0.metadataURL.lastPathComponent }, ["newer.json", "older.json"])
        XCTAssertEqual(candidates.map(\.isLocked), [true, false])
        XCTAssertEqual(candidates.compactMap { $0.transcriptURL?.lastPathComponent }, ["newer.jsonl", "older.jsonl"])
    }

    /// The `.jsonl` is appended throughout the session while the `.json` is written once at the
    /// start, so the newer of the two is the honest `lastActivity`.
    func testLastActivityComesFromWhicheverOfTheTwoFilesIsNewer() throws {
        let directory = try makeTemporaryDirectory()
        try write(id: "abc", in: directory, age: 600, transcript: true, locked: false, transcriptAge: 30)

        let candidate = try XCTUnwrap(
            KiroSessionDiscovery.candidates(sessionsDirectory: directory, fileManager: .default).first
        )
        XCTAssertEqual(
            candidate.modifiedAt.timeIntervalSince1970,
            Date().addingTimeInterval(-30).timeIntervalSince1970,
            accuracy: 5
        )
    }

    func testARecordWithNeitherTranscriptNorLockIsStillACandidate() throws {
        let directory = try makeTemporaryDirectory()
        try write(id: "bare", in: directory, age: 60, transcript: false, locked: false)

        let candidate = try XCTUnwrap(
            KiroSessionDiscovery.candidates(sessionsDirectory: directory, fileManager: .default).first
        )
        XCTAssertNil(candidate.transcriptURL)
        XCTAssertFalse(candidate.isLocked)
    }

    /// `~/.kiro/sessions/cli` does not exist on this machine at all — the case that actually
    /// happens today.
    func testAMissingSessionsDirectoryYieldsNoCandidates() {
        XCTAssertTrue(
            KiroSessionDiscovery.candidates(
                sessionsDirectory: URL(fileURLWithPath: "/nonexistent/.kiro/sessions/cli"),
                fileManager: .default
            ).isEmpty
        )
    }

    func testCapsAtMaxFilesNewestFirst() throws {
        let directory = try makeTemporaryDirectory()
        for index in 0..<5 {
            try write(id: "s\(index)", in: directory, age: TimeInterval(5 - index) * 60, transcript: false, locked: false)
        }
        let candidates = KiroSessionDiscovery.candidates(
            sessionsDirectory: directory,
            fileManager: .default,
            maxFiles: 2
        )
        XCTAssertEqual(candidates.map { $0.metadataURL.lastPathComponent }, ["s4.json", "s3.json"])
    }

    private func write(
        id: String,
        in directory: URL,
        age: TimeInterval,
        transcript: Bool,
        locked: Bool,
        transcriptAge: TimeInterval? = nil
    ) throws {
        let metadata = directory.appendingPathComponent("\(id).json")
        try Data(#"{"workingDirectory":"/Users/me/project"}"#.utf8).write(to: metadata)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: metadata.path
        )
        if transcript {
            let url = directory.appendingPathComponent("\(id).jsonl")
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-(transcriptAge ?? age))],
                ofItemAtPath: url.path
            )
        }
        if locked {
            try Data().write(to: directory.appendingPathComponent("\(id).lock"))
        }
    }
}

final class KiroLivenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    /// A held lock means the session is running, so age can never hide it (#33).
    func testALockedSessionIsNeverHiddenHoweverOldItsTranscriptIs() {
        XCTAssertEqual(
            KiroSessionSource.status(isLocked: true, modifiedAt: now.addingTimeInterval(-5 * 60 * 60.0), now: now),
            .idle
        )
    }

    /// But a lock alone can never say "Working…" either: one left behind by a crashed process
    /// would otherwise pin a dead session there forever (#31).
    func testALockAloneCannotProduceActiveWithoutARecentWrite() {
        XCTAssertEqual(
            KiroSessionSource.status(isLocked: true, modifiedAt: now.addingTimeInterval(-5 * 60.0), now: now),
            .idle
        )
        XCTAssertEqual(
            KiroSessionSource.status(isLocked: true, modifiedAt: now.addingTimeInterval(-10), now: now),
            .active
        )
    }

    func testAnUnlockedSessionIsIdleForAnHourThenHidden() {
        XCTAssertEqual(KiroSessionSource.status(isLocked: false, modifiedAt: now, now: now), .idle)
        XCTAssertNil(
            KiroSessionSource.status(isLocked: false, modifiedAt: now.addingTimeInterval(-61 * 60.0), now: now)
        )
    }
}

final class KiroCLIRecognitionTests: XCTestCase {
    func testRecognizesTheInstalledCLI() {
        XCTAssertTrue(TTYResolver.isKiroCLI(command: "/Users/me/.local/bin/kiro-cli chat"))
        XCTAssertTrue(TTYResolver.isAgentCLI("Kiro", command: "/Users/me/.local/bin/kiro-cli"))
        XCTAssertEqual(LiveAgentScan.agentName(forCommand: "/Users/me/.local/bin/kiro-cli"), "Kiro")
    }

    /// The desktop helper's bundle path contains a SPACE, so splitting the command line on
    /// whitespace hands the basename check the word `kiro` — the `.app/contents/` rejection is the
    /// only thing standing between that and a bogus session row.
    func testTheDesktopBundleHelperIsNotASession() {
        let command = "/Applications/Kiro CLI.app/Contents/MacOS/kiro_cli_desktop --ignore-immediate-update"
        XCTAssertFalse(TTYResolver.isKiroCLI(command: command))
        XCTAssertNil(LiveAgentScan.agentName(forCommand: command))
    }

    /// Kiro wraps its terminal panes in shells named `zsh (kiro-cli-term)` — a shell, not a
    /// session, and there really are seven of them running on this machine.
    func testKiroTerminalShellsAreNotSessions() {
        XCTAssertFalse(TTYResolver.isKiroCLI(command: "zsh (kiro-cli-term)"))
        XCTAssertNil(LiveAgentScan.agentName(forCommand: "zsh (kiro-cli-term)"))
    }
}

final class KiroSessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testDiscoversAUserStartedSessionWithItsCwdTitleAndResumeCommand() throws {
        let home = try makeFixture(sessions: [
            Session(id: "abc-123", title: "Fix the flaky test", ageSeconds: 60)
        ])

        let discovered = makeSource(home: home).discover(now: fixedNow)
        let session = try XCTUnwrap(discovered.first)

        XCTAssertEqual(session.sessionId, "abc-123")
        XCTAssertEqual(session.agentName, "Kiro")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        XCTAssertEqual(session.title, "Fix the flaky test")
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.resumeCommand, "/usr/bin/env-kiro --resume 'abc-123'")
        XCTAssertFalse(session.supportsLiveStatus)
    }

    func testTitleFallsBackToTheCwdBasenameWhenThereIsNone() throws {
        let home = try makeFixture(sessions: [Session(id: "abc-123", title: nil, ageSeconds: 60)])
        XCTAssertEqual(makeSource(home: home).discover(now: fixedNow).first?.title, "project")
    }

    /// #24's rule: only sessions the user started show by default.
    func testSubAgentSessionsAreHiddenByDefaultAndRevealedByTheToggle() throws {
        let home = try makeFixture(sessions: [
            Session(id: "mine", title: "Mine", ageSeconds: 60),
            Session(id: "spawned", title: "Spawned", ageSeconds: 60, parentSessionId: "mine")
        ])

        XCTAssertEqual(makeSource(home: home).discover(now: fixedNow).map(\.sessionId), ["mine"])
        XCTAssertEqual(
            Set(makeSource(home: home, showSubAgentSessions: true).discover(now: fixedNow).map(\.sessionId)),
            ["mine", "spawned"]
        )
    }

    /// A `.lock` is the liveness signal the documented layout offers, and it is better than the
    /// mtime heuristics Codex has to settle for: an old-but-running session still shows.
    func testALockedSessionSurvivesTheVisibilityWindow() throws {
        let home = try makeFixture(sessions: [
            Session(id: "long-running", title: "Still going", ageSeconds: 5 * 60 * 60.0, isLocked: true)
        ])
        XCTAssertEqual(makeSource(home: home).discover(now: fixedNow).map(\.sessionId), ["long-running"])
    }

    func testAnUnlockedStaleSessionIsHidden() throws {
        let home = try makeFixture(sessions: [Session(id: "stale", title: "Old", ageSeconds: 61 * 60.0)])
        XCTAssertTrue(makeSource(home: home).discover(now: fixedNow).isEmpty)
    }

    /// The property that matters most: `~/.kiro/sessions` does not exist here, so this is the case
    /// that actually happens today, and it must be silent rather than fatal.
    func testAMissingSessionsDirectoryYieldsNoSessions() {
        XCTAssertTrue(
            makeSource(home: URL(fileURLWithPath: "/nonexistent/.kiro")).discover(now: fixedNow).isEmpty
        )
    }

    func testMalformedAndCwdlessRecordsAreSkippedWithoutLosingGoodOnes() throws {
        let home = try makeFixture(sessions: [Session(id: "good", title: "Good", ageSeconds: 60)])
        let directory = home.appendingPathComponent("sessions/cli", isDirectory: true)
        try Data("{not valid json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        try Data().write(to: directory.appendingPathComponent("empty.json"))
        try Data(#"{"title":"no working directory"}"#.utf8)
            .write(to: directory.appendingPathComponent("cwdless.json"))

        XCTAssertEqual(makeSource(home: home).discover(now: fixedNow).map(\.sessionId), ["good"])
    }

    func testALiveProcessClaimsItsRecordRatherThanDuplicatingIt() throws {
        let home = try makeFixture(sessions: [Session(id: "abc-123", title: "Live", ageSeconds: 10)])
        let process = ClaudeProcess(
            pid: 1,
            command: "/Users/me/.local/bin/kiro-cli",
            cwd: "/Users/me/project",
            tty: "ttys004"
        )

        let discovered = makeSource(home: home, processes: [process]).discover(now: fixedNow)
        XCTAssertEqual(discovered.map(\.sessionId), ["abc-123"])
        XCTAssertEqual(discovered.first?.tty, "ttys004")
        XCTAssertEqual(discovered.first?.status, .active)
    }

    // MARK: - Fixtures

    private struct Session {
        let id: String
        let title: String?
        var ageSeconds: TimeInterval
        var parentSessionId: String?
        var isLocked = false
    }

    private func makeSource(
        home: URL,
        processes: [ClaudeProcess] = [],
        showSubAgentSessions: Bool = false
    ) -> KiroSessionSource {
        KiroSessionSource(
            kiroHome: home,
            processProvider: { processes },
            showSubAgentSessions: { showSubAgentSessions },
            // Pinned rather than resolved, so the suite never depends on what is installed on the
            // machine running it.
            binaryPath: "/usr/bin/env-kiro"
        )
    }

    private func makeFixture(sessions: [Session]) throws -> URL {
        let home = try makeTemporaryDirectory()
        let directory = home.appendingPathComponent("sessions/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for session in sessions {
            var fields = [#""sessionId":"\#(session.id)""#, #""workingDirectory":"/Users/me/project""#]
            if let title = session.title { fields.append(#""title":"\#(title)""#) }
            if let parent = session.parentSessionId { fields.append(#""parentSessionId":"\#(parent)""#) }

            let metadata = directory.appendingPathComponent("\(session.id).json")
            try Data("{\(fields.joined(separator: ","))}".utf8).write(to: metadata)
            let transcript = directory.appendingPathComponent("\(session.id).jsonl")
            try Data().write(to: transcript)
            if session.isLocked {
                try Data().write(to: directory.appendingPathComponent("\(session.id).lock"))
            }
            for url in [metadata, transcript] {
                try FileManager.default.setAttributes(
                    [.modificationDate: fixedNow.addingTimeInterval(-session.ageSeconds)],
                    ofItemAtPath: url.path
                )
            }
        }
        return home
    }
}
