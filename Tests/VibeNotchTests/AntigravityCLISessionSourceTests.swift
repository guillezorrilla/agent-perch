import Foundation
import XCTest
@testable import VibeNotch

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

/// Mirrors `CodexLivenessTests`: `agy` has no hooks either, so only a live matching process may
/// promote past `.idle`.
final class AntigravityCLILivenessTests: XCTestCase {
    func testLiveAgyProcessAtCwdIsLive() {
        let processes = [ClaudeProcess(pid: 1, command: "/usr/local/bin/agy", cwd: "/repo", tty: nil)]
        XCTAssertTrue(AntigravityCLILiveness.hasLiveProcess(cwd: "/repo", processes: processes))
    }

    func testNoProcessAtCwdIsNotLive() {
        XCTAssertFalse(AntigravityCLILiveness.hasLiveProcess(cwd: "/repo", processes: []))
        let elsewhere = [ClaudeProcess(pid: 1, command: "/usr/local/bin/agy", cwd: "/other", tty: nil)]
        XCTAssertFalse(AntigravityCLILiveness.hasLiveProcess(cwd: "/repo", processes: elsewhere))
    }

    func testAClaudeProcessAtTheSameCwdDoesNotCountAsLive() {
        let processes = [ClaudeProcess(pid: 1, command: "/usr/local/bin/claude", cwd: "/repo", tty: nil)]
        XCTAssertFalse(AntigravityCLILiveness.hasLiveProcess(cwd: "/repo", processes: processes))
    }

    func testStatusIsActiveWithALiveProcessRegardlessOfStaleMtime() {
        let now = Date(timeIntervalSince1970: 10_000)
        let processes = [ClaudeProcess(pid: 1, command: "/usr/local/bin/agy", cwd: "/repo", tty: nil)]
        XCTAssertEqual(
            AntigravityCLILiveness.status(
                cwd: "/repo", modifiedAt: now.addingTimeInterval(-10_000), now: now, processes: processes
            ),
            .active
        )
    }

    func testStatusDegradesToIdleWithoutALiveProcessEvenWhenFresh() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(
            AntigravityCLILiveness.status(cwd: "/repo", modifiedAt: now, now: now, processes: []),
            .idle
        )
    }

    func testStatusIsHiddenPastTheThresholdWithoutALiveProcess() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(
            AntigravityCLILiveness.status(cwd: "/repo", modifiedAt: now.addingTimeInterval(-3_600), now: now, processes: [])
        )
    }
}

final class AntigravityCLISessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testDiscoversASessionFromALogWithAWorkspaceLine() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)

        let discovered = AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })
            .discover(now: fixedNow)

        let session = try XCTUnwrap(discovered.first)
        XCTAssertEqual(session.agentName, "Antigravity")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        // A REAL session — unlike the IDE-workspace source, the title is a plain basename, no
        // "workspace" qualifier.
        XCTAssertEqual(session.title, "project")
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.resumeCommand, "agy")
        XCTAssertNil(session.sessionFileURL)
    }

    func testLogWithNoWorkspaceLineIsSkippedEntirely() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: nil, ageSeconds: 60, extraLines: ["nothing useful here"])

        let discovered = AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })
            .discover(now: fixedNow)
        XCTAssertTrue(discovered.isEmpty)
    }

    func testSessionIdPrefersTheImplicitFileClosestByMtime() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)
        try makeImplicit(in: home, uuid: "far-uuid", ageSeconds: 600)
        try makeImplicit(in: home, uuid: "close-uuid", ageSeconds: 61)

        let discovered = AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })
            .discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.sessionId, "antigravity-cli:close-uuid")
    }

    func testSessionIdFallsBackToTheLogFilenameWithoutAnyImplicitFile() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)

        let discovered = AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })
            .discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.sessionId, "antigravity-cli:cli-20260808_160031")
    }

    func testHiddenThresholdDropsAStaleSessionWithoutALiveProcess() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-stale.log", workspace: "/Users/me/project", ageSeconds: 61 * 60.0)

        let discovered = AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })
            .discover(now: fixedNow)
        XCTAssertTrue(discovered.isEmpty)
    }

    func testActiveRequiresALiveMatchingProcess() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)
        let liveProcess = ClaudeProcess(pid: 1, command: "/usr/local/bin/agy", cwd: "/Users/me/project", tty: nil)

        let withProcess = AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [liveProcess] })
            .discover(now: fixedNow)
        XCTAssertEqual(withProcess.first?.status, .active)

        let withoutProcess = AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })
            .discover(now: fixedNow)
        XCTAssertEqual(withoutProcess.first?.status, .idle)
    }

    func testMissingLogDirectoryYieldsNoSessions() {
        XCTAssertTrue(
            AntigravityCLISessionSource(
                antigravityCLIHome: URL(fileURLWithPath: "/nonexistent/antigravity-cli"),
                processProvider: { [] }
            ).discover(now: fixedNow).isEmpty
        )
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
        let liveProcess = ClaudeProcess(pid: 1, command: "/usr/local/bin/agy", cwd: "/Users/me/project", tty: "ttys009")

        let store = SessionStore(
            sources: [AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [liveProcess] })],
            processProvider: { [liveProcess] }
        )
        store.refresh(now: fixedNow)

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.agentName, "Antigravity")
        // Like Codex, `agy` has no hooks — `AgentSession.tty` stays nil (it's hook-derived only)
        // even though the jump rung itself resolves the live process's tty for exact focus.
        XCTAssertEqual(session.jumpRung, .exactFocus(tty: "ttys009"))
    }

    @MainActor
    func testNoLiveProcessFallsBackToNewTabWithTheAgyResumeCommand() throws {
        let home = try makeTemporaryDirectory()
        try makeLog(in: home, name: "cli-20260808_160031.log", workspace: "/Users/me/project", ageSeconds: 60)

        let store = SessionStore(
            sources: [AntigravityCLISessionSource(antigravityCLIHome: home, processProvider: { [] })],
            processProvider: { [] }
        )
        store.refresh(now: fixedNow)

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.jumpRung, .newTab)
        XCTAssertEqual(session.resumeCommand, "agy")
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
        try makeLog(in: cliHome, name: "cli-20260808_160031.log", workspace: "/Users/me/vibe-notch", ageSeconds: 60)

        let ideHome = try makeTemporaryDirectory()
        try makeWorkspace(in: ideHome, hash: "same-folder", folderPath: "/Users/me/vibe-notch", ageSeconds: 180)
        try makeWorkspace(in: ideHome, hash: "other-a", folderPath: "/Users/me/other-a", ageSeconds: 360)
        try makeWorkspace(in: ideHome, hash: "other-b", folderPath: "/Users/me/other-b", ageSeconds: 780)

        let store = SessionStore(
            sources: [
                AntigravitySessionSource(antigravityHome: ideHome, agyAvailableProvider: { false }, showWorkspaces: { true }),
                AntigravityCLISessionSource(antigravityCLIHome: cliHome, processProvider: { [] })
            ],
            processProvider: { [] }
        )
        store.refresh(now: fixedNow)

        let byCwd = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.cwd, $0) })
        XCTAssertEqual(store.sessions.count, 3, "the workspace row sharing the CLI session's folder must be dropped, not duplicated")
        XCTAssertEqual(byCwd["/Users/me/vibe-notch"]?.sessionId, "antigravity-cli:cli-20260808_160031")
        XCTAssertEqual(byCwd["/Users/me/vibe-notch"]?.title, "vibe-notch")
        XCTAssertTrue(byCwd["/Users/me/other-a"]?.title.hasSuffix("— workspace") ?? false)
        XCTAssertTrue(byCwd["/Users/me/other-b"]?.title.hasSuffix("— workspace") ?? false)
    }

    /// With the setting OFF, only the CLI row shows at all — no workspace rows, duplicate or
    /// otherwise, since `AntigravitySessionSource` contributes nothing while opted out (#27).
    @MainActor
    func testWithWorkspacesOptedOutOnlyTheCLISessionShows() throws {
        let cliHome = try makeTemporaryDirectory()
        try makeLog(in: cliHome, name: "cli-20260808_160031.log", workspace: "/Users/me/vibe-notch", ageSeconds: 60)

        let ideHome = try makeTemporaryDirectory()
        try makeWorkspace(in: ideHome, hash: "same-folder", folderPath: "/Users/me/vibe-notch", ageSeconds: 180)
        try makeWorkspace(in: ideHome, hash: "other-a", folderPath: "/Users/me/other-a", ageSeconds: 360)

        let store = SessionStore(
            sources: [
                AntigravitySessionSource(antigravityHome: ideHome, agyAvailableProvider: { false }, showWorkspaces: { false }),
                AntigravityCLISessionSource(antigravityCLIHome: cliHome, processProvider: { [] })
            ],
            processProvider: { [] }
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
