import Foundation
import XCTest
@testable import AgentPerch

/// Fixtures live in the test's OWN temporary directory: the real `~/.gemini` is never read from
/// and never written to by this suite (#11).
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

/// Header lines are byte-for-byte the shape of the real ones read off this machine (#11), with
/// personal paths redacted to `/Users/me/...`.
final class GeminiChatHeaderTests: XCTestCase {
    func testParsesTheRealHeaderShape() {
        let line = #"""
        {"sessionId":"3c90ee3d-470e-4a30-8db7-282f0e65f93d","projectHash":"ddb0e09ea68fd887833fa91386c0919381d08970ed4af2f725f03b6ed70aff8c","startTime":"2026-06-07T23:59:13.730Z","lastUpdated":"2026-06-07T23:59:13.730Z","kind":"main"}
        """#
        let header = GeminiChatHeader.parseLine(Data(line.utf8))

        XCTAssertEqual(header?.sessionId, "3c90ee3d-470e-4a30-8db7-282f0e65f93d")
        XCTAssertEqual(header?.kind, "main")
        XCTAssertEqual(header?.isUserStarted, true)
        XCTAssertEqual(header?.directories, [])
    }

    /// The real sub-agent header, which is the only kind observed carrying `directories`.
    func testParsesTheSubagentHeaderAndItsDirectories() {
        let line = #"""
        {"sessionId":"ef485107-7736-4308-b69b-f465f7f47044","projectHash":"ddb0e09e","startTime":"2026-06-07T23:22:49.859Z","lastUpdated":"2026-06-07T23:22:49.859Z","kind":"subagent","directories":["/Users/me/project"]}
        """#
        let header = GeminiChatHeader.parseLine(Data(line.utf8))

        XCTAssertEqual(header?.kind, "subagent")
        XCTAssertEqual(header?.isUserStarted, false)
        XCTAssertEqual(header?.directories, ["/Users/me/project"])
    }

    /// Default-deny (#24): an unrecognized or missing `kind` is not evidence of a user session.
    func testUnknownOrMissingKindIsNotUserStarted() {
        XCTAssertEqual(
            GeminiChatHeader.parseLine(Data(#"{"sessionId":"a","kind":"something-new"}"#.utf8))?.isUserStarted,
            false
        )
        XCTAssertEqual(
            GeminiChatHeader.parseLine(Data(#"{"sessionId":"a"}"#.utf8))?.isUserStarted,
            false
        )
    }

    func testRelativeDirectoriesAreDiscarded() {
        let header = GeminiChatHeader.parseLine(
            Data(#"{"sessionId":"a","kind":"main","directories":["relative/path",42,"/Users/me/ok"]}"#.utf8)
        )
        XCTAssertEqual(header?.directories, ["/Users/me/ok"])
    }

    func testRejectsMalformedOrIdlessLines() {
        XCTAssertNil(GeminiChatHeader.parseLine(Data("{not json at all".utf8)))
        XCTAssertNil(GeminiChatHeader.parseLine(Data()))
        XCTAssertNil(GeminiChatHeader.parseLine(Data(#"{"kind":"main"}"#.utf8)))
        XCTAssertNil(GeminiChatHeader.parseLine(Data(#"{"sessionId":"","kind":"main"}"#.utf8)))
    }

    func testReturnsNilForAMissingFile() {
        XCTAssertNil(GeminiChatHeader.firstLine(at: URL(fileURLWithPath: "/nonexistent/session-x.jsonl")))
    }

    func testReadsOnlyTheFirstLine() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("session-a.jsonl")
        let content = [
            #"{"sessionId":"real","kind":"main"}"#,
            #"{"sessionId":"decoy","kind":"main"}"#
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: url)

        XCTAssertEqual(GeminiChatHeader.firstLine(at: url)?.sessionId, "real")
    }
}

final class GeminiProjectRootTests: XCTestCase {
    func testReadsAndTrimsTheAbsolutePath() throws {
        let directory = try makeTemporaryDirectory()
        try Data("/Users/me/project\n".utf8)
            .write(to: directory.appendingPathComponent(GeminiProjectRoot.markerFileName))

        XCTAssertEqual(GeminiProjectRoot.read(projectDirectory: directory), "/Users/me/project")
    }

    /// The hash-named `~/.gemini/tmp/<64-hex>` directories on this machine have no `.project_root`
    /// at all, and the hash is `sha256(<path>)` — one-way. There is no honest answer here, and
    /// inventing one is what would produce a bogus jump.
    func testMissingMarkerHasNoAnswer() throws {
        XCTAssertNil(GeminiProjectRoot.read(projectDirectory: try makeTemporaryDirectory()))
    }

    func testRelativeOrEmptyMarkerHasNoAnswer() throws {
        for contents in ["", "   \n", "relative/path"] {
            let directory = try makeTemporaryDirectory()
            try Data(contents.utf8)
                .write(to: directory.appendingPathComponent(GeminiProjectRoot.markerFileName))
            XCTAssertNil(GeminiProjectRoot.read(projectDirectory: directory), "for \(contents.debugDescription)")
        }
    }
}

final class GeminiTranscriptTests: XCTestCase {
    /// The real file layout: a header, then one `$set` batch holding Gemini's own
    /// `<session_context>` preamble, then bare message records. The first thing the USER typed is
    /// the third of those, and it is what must win.
    func testFindsTheFirstRealUserPromptPastGeminisOwnPreamble() {
        let lines = [
            #"{"sessionId":"a","kind":"main"}"#,
            #"{"$set":{"messages":[{"id":"1","type":"user","content":[{"text":"<session_context>\nThis is the Gemini CLI. …"}]}],"lastUpdated":"x"}}"#,
            #"{"id":"2","type":"gemini","content":[{"text":"thinking"}]}"#,
            #"{"id":"3","type":"user","content":[{"text":"I have mcp but in claude, how can I have them in gemini as well"}]}"#
        ]
        XCTAssertEqual(
            GeminiTranscript.firstUserPrompt(in: Data(lines.joined(separator: "\n").utf8)),
            "I have mcp but in claude, how can I have them in gemini as well"
        )
    }

    /// Observed verbatim on a real chat whose ONLY user-shaped text was this mode-switch notice —
    /// it would have become the session's title.
    func testSkipsGeminisOwnModeSwitchNotices() {
        let lines = [
            #"{"id":"1","type":"user","content":[{"text":"User has manually exited Plan Mode. Switching to Default mode (edits will require confirmation)."}]}"#,
            #"{"id":"2","type":"user","content":[{"text":"actually fix the parser"}]}"#
        ]
        XCTAssertEqual(
            GeminiTranscript.firstUserPrompt(in: Data(lines.joined(separator: "\n").utf8)),
            "actually fix the parser"
        )
    }

    func testEmptyAndNonUserMessagesAreSkipped() {
        let lines = [
            #"{"id":"1","type":"user","content":[{"text":"   "}]}"#,
            #"{"id":"2","type":"gemini","content":[{"text":"not the user"}]}"#,
            #"{"id":"3","type":"user","content":"a plain string body"}"#
        ]
        XCTAssertEqual(
            GeminiTranscript.firstUserPrompt(in: Data(lines.joined(separator: "\n").utf8)),
            "a plain string body"
        )
    }

    /// The bounded read can slice a line in half; a truncated line must be skipped exactly like a
    /// malformed one, never crash and never stop the scan.
    func testTruncatedAndMalformedLinesAreSkippedWithoutLosingLaterOnes() {
        let lines = [
            "not json at all",
            #"{"id":"1","type":"user","content":[{"text":"cut off here"#,
            #"{"id":"2","type":"user","content":[{"text":"survivor"}]}"#
        ]
        XCTAssertEqual(
            GeminiTranscript.firstUserPrompt(in: Data(lines.joined(separator: "\n").utf8)),
            "survivor"
        )
    }

    func testAChatWithNoUserPromptAtAllHasNone() {
        XCTAssertNil(GeminiTranscript.firstUserPrompt(in: Data(#"{"sessionId":"a","kind":"main"}"#.utf8)))
        XCTAssertNil(GeminiTranscript.firstUserPrompt(in: Data()))
        XCTAssertNil(GeminiTranscript.firstUserPrompt(at: URL(fileURLWithPath: "/nonexistent/session-x.jsonl")))
    }
}

final class GeminiChatDiscoveryTests: XCTestCase {
    func testFindsSessionFilesAcrossProjectDirectoriesNewestFirst() throws {
        let tmpRoot = try makeTemporaryDirectory()
        let older = try writeChat(tmpRoot: tmpRoot, projectKey: "project-a", name: "session-a.jsonl", age: 600)
        let newer = try writeChat(tmpRoot: tmpRoot, projectKey: "project-b", name: "session-b.jsonl", age: 60)

        let files = GeminiChatDiscovery.candidateFiles(tmpRoot: tmpRoot, fileManager: .default)
        // Compared by name, not by URL: `contentsOfDirectory` resolves `/var` to `/private/var`,
        // so the URLs it returns are never `==` to the ones the fixture wrote through.
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, [newer.lastPathComponent, older.lastPathComponent])
        XCTAssertEqual(
            files.map { $0.projectDirectory.lastPathComponent },
            ["project-b", "project-a"]
        )
    }

    /// Sub-agent chats live one level deeper (`chats/<parent-id>/<id>.jsonl`) and carry no
    /// `session-` prefix, so a non-recursive listing never even opens them.
    func testNestedSubagentChatsAndForeignFilesAreNeverListed() throws {
        let tmpRoot = try makeTemporaryDirectory()
        let real = try writeChat(tmpRoot: tmpRoot, projectKey: "project-a", name: "session-a.jsonl", age: 60)
        let chats = tmpRoot.appendingPathComponent("project-a/chats", isDirectory: true)
        try Data().write(to: chats.appendingPathComponent("logs.json"))
        try Data().write(to: chats.appendingPathComponent("session-a.txt"))
        let nested = chats.appendingPathComponent("8f28e924-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("ef485107-child.jsonl"))

        let files = GeminiChatDiscovery.candidateFiles(tmpRoot: tmpRoot, fileManager: .default)
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, [real.lastPathComponent])
    }

    /// `~/.gemini/tmp` really does hold non-project directories (a `bin/` sits there on this
    /// machine); one without a `chats/` subdirectory must contribute nothing, not throw.
    func testProjectDirectoriesWithoutAChatsSubdirectoryAreHarmless() throws {
        let tmpRoot = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: tmpRoot.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(GeminiChatDiscovery.candidateFiles(tmpRoot: tmpRoot, fileManager: .default).isEmpty)
    }

    func testMissingTmpRootYieldsNoFiles() {
        XCTAssertTrue(
            GeminiChatDiscovery.candidateFiles(
                tmpRoot: URL(fileURLWithPath: "/nonexistent/.gemini/tmp"),
                fileManager: .default
            ).isEmpty
        )
    }

    func testCapsAtMaxFilesNewestFirst() throws {
        let tmpRoot = try makeTemporaryDirectory()
        for index in 0..<5 {
            _ = try writeChat(
                tmpRoot: tmpRoot,
                projectKey: "project-a",
                name: "session-\(index).jsonl",
                age: TimeInterval(5 - index) * 60
            )
        }
        let files = GeminiChatDiscovery.candidateFiles(tmpRoot: tmpRoot, fileManager: .default, maxFiles: 2)
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["session-4.jsonl", "session-3.jsonl"])
    }

    @discardableResult
    private func writeChat(tmpRoot: URL, projectKey: String, name: String, age: TimeInterval) throws -> URL {
        let chats = tmpRoot.appendingPathComponent("\(projectKey)/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let url = chats.appendingPathComponent(name)
        try Data(#"{"sessionId":"\#(name)","kind":"main"}"#.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
        return url
    }
}

final class GeminiLivenessTests: XCTestCase {
    func testAFinishedChatIsIdleForAnHourThenHidden() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(GeminiLiveness.finishedStatus(modifiedAt: now, now: now), .idle)
        XCTAssertEqual(
            GeminiLiveness.finishedStatus(modifiedAt: now.addingTimeInterval(-59 * 60.0), now: now),
            .idle
        )
        XCTAssertNil(
            GeminiLiveness.finishedStatus(modifiedAt: now.addingTimeInterval(-61 * 60.0), now: now)
        )
    }
}

final class GeminiCLIRecognitionTests: XCTestCase {
    /// Homebrew's `gemini` is a node script, so a live session shows the INTERPRETER as argv[0] —
    /// a basename check alone would miss every real session.
    func testRecognizesTheHomebrewNodeScriptLaunch() {
        let command = "/opt/homebrew/opt/node/bin/node /opt/homebrew/Cellar/gemini-cli/0.45.2/libexec/bin/gemini"
        XCTAssertTrue(TTYResolver.isGeminiCLI(command: command))
        XCTAssertEqual(LiveAgentScan.agentName(forCommand: command), "Gemini")
    }

    func testRecognizesAPlainBinaryLaunch() {
        XCTAssertTrue(TTYResolver.isGeminiCLI(command: "/opt/homebrew/bin/gemini"))
        XCTAssertEqual(LiveAgentScan.agentName(forCommand: "/opt/homebrew/bin/gemini"), "Gemini")
        XCTAssertTrue(TTYResolver.isAgentCLI("Gemini", command: "/opt/homebrew/bin/gemini"))
    }

    /// Antigravity's own CLI stores its state under `~/.gemini` too, so the word alone proves
    /// nothing — it must stay an Antigravity session, never a Gemini one.
    func testAntigravityCLIIsNotGemini() {
        let command = "/opt/homebrew/bin/agy --workspace /Users/me/project"
        XCTAssertFalse(TTYResolver.isGeminiCLI(command: command))
        XCTAssertEqual(LiveAgentScan.agentName(forCommand: command), "Antigravity")
    }

    func testUnrelatedCommandsAreNotGemini() {
        XCTAssertFalse(TTYResolver.isGeminiCLI(command: "/bin/zsh"))
        XCTAssertFalse(TTYResolver.isGeminiCLI(command: "/Applications/Some.app/Contents/MacOS/gemini"))
    }

    /// An install path appearing as somebody else's ARGUMENT is not a Gemini session. Claude is
    /// deliberately absent from `LiveAgentScan.agentsByExecutableName`, so without the argv[0]/argv[1]
    /// restriction this would fall straight through to the marker list and invent a Gemini row.
    func testAnInstallPathInAnotherAgentsArgumentIsNotASession() {
        let command = "/opt/homebrew/bin/claude --mcp-config /opt/homebrew/Cellar/gemini-cli/0.45.2/mcp.json"
        XCTAssertFalse(TTYResolver.isGeminiCLI(command: command))
        XCTAssertNil(LiveAgentScan.agentName(forCommand: command))
    }

    /// The same trap in the other direction: an argument that merely ends in an agent's name.
    func testAnArgumentEndingInAnAgentNameIsNotASession() {
        XCTAssertNil(LiveAgentScan.agentName(forCommand: "/opt/homebrew/bin/claude /Users/me/agy"))
    }
}

final class GeminiSessionSourceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    func testDiscoversAUserStartedChatWithItsCwdTitleAndTimestamp() throws {
        let home = try makeFixture(chats: [
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "abc-123", prompt: "fix the flaky test")
        ])

        let discovered = makeSource(home: home).discover(now: fixedNow)
        let session = try XCTUnwrap(discovered.first)

        XCTAssertEqual(session.sessionId, "abc-123")
        XCTAssertEqual(session.agentName, "Gemini")
        XCTAssertEqual(session.cwd, "/Users/me/project")
        XCTAssertEqual(session.title, "fix the flaky test")
        XCTAssertEqual(session.lastActivity, fixedNow.addingTimeInterval(-60))
        XCTAssertEqual(session.status, .idle, "no live process was supplied, so this must never be active")
        XCTAssertNil(session.sessionFileURL)
        // Gemini has no hooks, so `SessionCardView` must never show "Working…" for it (#31).
        XCTAssertFalse(session.supportsLiveStatus)
    }

    /// `gemini --resume` takes `"latest"` or an INDEX, never a session id — so the only honest
    /// reopen is a bare relaunch at the right cwd.
    func testResumeCommandIsABareRelaunchNotAnIdResume() throws {
        let home = try makeFixture(chats: [
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "abc-123")
        ])
        let discovered = makeSource(home: home).discover(now: fixedNow)
        XCTAssertEqual(discovered.first?.resumeCommand, "/usr/bin/env-gemini")
    }

    func testSubagentChatsAreHiddenByDefaultAndRevealedByTheToggle() throws {
        let home = try makeFixture(chats: [
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "main-1", kind: "main"),
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "sub-1", kind: "subagent"),
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "future-1", kind: "something-new")
        ])

        XCTAssertEqual(
            makeSource(home: home, showSubAgentSessions: false).discover(now: fixedNow).map(\.sessionId),
            ["main-1"]
        )
        XCTAssertEqual(
            Set(makeSource(home: home, showSubAgentSessions: true).discover(now: fixedNow).map(\.sessionId)),
            ["main-1", "sub-1", "future-1"]
        )
    }

    /// The hash-named `~/.gemini/tmp/<64-hex>` case: no `.project_root`, and the directory name is
    /// a one-way `sha256(<path>)`. The session is dropped rather than shown with a guessed cwd.
    func testAChatWhoseCwdCannotBeResolvedIsDroppedEntirely() throws {
        let home = try makeFixture(chats: [
            Chat(
                projectKey: "05d95252d74b2f6f14f527074be487821fd85e05c3488855b7204c2365af2dc5",
                projectRoot: nil,
                id: "unresolvable"
            ),
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "resolvable")
        ])

        XCTAssertEqual(makeSource(home: home).discover(now: fixedNow).map(\.sessionId), ["resolvable"])
    }

    /// The header's own `directories` is the second honest source of a cwd, and the only one a
    /// hash-named project directory can offer.
    func testHeaderDirectoriesResolveTheCwdWhenProjectRootIsMissing() throws {
        let home = try makeFixture(chats: [
            Chat(projectKey: "abcdef", projectRoot: nil, id: "from-header", directories: ["/Users/me/from-header"])
        ])

        let discovered = makeSource(home: home).discover(now: fixedNow)
        XCTAssertEqual(discovered.map(\.cwd), ["/Users/me/from-header"])
    }

    func testStaleChatsAreHiddenPastTheVisibilityWindow() throws {
        let home = try makeFixture(chats: [
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "stale", ageSeconds: 61 * 60.0)
        ])
        XCTAssertTrue(makeSource(home: home).discover(now: fixedNow).isEmpty)
    }

    /// The single most important property: one broken file cannot cost the source its other rows,
    /// and cannot throw.
    func testMalformedEmptyAndTruncatedChatsAreSkippedWithoutLosingGoodOnes() throws {
        let home = try makeFixture(chats: [
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "good")
        ])
        let chats = home.appendingPathComponent("tmp/project/chats", isDirectory: true)
        try Data("not valid json at all".utf8).write(to: chats.appendingPathComponent("session-broken.jsonl"))
        try Data().write(to: chats.appendingPathComponent("session-empty.jsonl"))
        try Data(#"{"sessionId":"cut","kind":"ma"#.utf8)
            .write(to: chats.appendingPathComponent("session-truncated.jsonl"))

        XCTAssertEqual(makeSource(home: home).discover(now: fixedNow).map(\.sessionId), ["good"])
    }

    func testMissingGeminiHomeYieldsNoSessions() {
        XCTAssertTrue(
            makeSource(home: URL(fileURLWithPath: "/nonexistent/.gemini")).discover(now: fixedNow).isEmpty
        )
    }

    /// A live `gemini` process claims the chat at its own cwd, so the session shows once — with a
    /// tty for the jump ladder — rather than twice.
    func testALiveProcessClaimsItsChatRatherThanDuplicatingIt() throws {
        let home = try makeFixture(chats: [
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "abc-123", ageSeconds: 10)
        ])
        let process = ClaudeProcess(
            pid: 1,
            command: "/opt/homebrew/opt/node/bin/node /opt/homebrew/Cellar/gemini-cli/0.45.2/libexec/bin/gemini",
            cwd: "/Users/me/project",
            tty: "ttys004"
        )

        let discovered = makeSource(home: home, processes: [process]).discover(now: fixedNow)
        XCTAssertEqual(discovered.map(\.sessionId), ["abc-123"])
        XCTAssertEqual(discovered.first?.tty, "ttys004")
        XCTAssertEqual(discovered.first?.status, .active, "a live process plus a 10s-old write is active")
    }

    /// #31, at the source level: a live process next to a stale chat is NOT evidence of a turn in
    /// flight — a TUI parked at an idle prompt looks exactly like this.
    func testALiveProcessWithAStaleChatDegradesToIdle() throws {
        let home = try makeFixture(chats: [
            Chat(projectKey: "project", projectRoot: "/Users/me/project", id: "abc-123", ageSeconds: 5 * 60.0)
        ])
        let process = ClaudeProcess(pid: 1, command: "/opt/homebrew/bin/gemini", cwd: "/Users/me/project", tty: "ttys004")

        XCTAssertEqual(makeSource(home: home, processes: [process]).discover(now: fixedNow).first?.status, .idle)
    }

    /// #33's rule, applied here: a live session is never hidden for lack of a chat file, and dates
    /// itself by when its process started.
    func testALiveProcessWithNoChatAtAllStillShows() throws {
        let home = try makeFixture(chats: [])
        let startedAt = fixedNow.addingTimeInterval(-3 * 60 * 60.0)
        let process = ClaudeProcess(
            pid: 1,
            command: "/opt/homebrew/bin/gemini",
            cwd: "/Users/me/elsewhere",
            tty: "ttys009",
            startedAt: startedAt
        )

        let discovered = makeSource(home: home, processes: [process]).discover(now: fixedNow)
        XCTAssertEqual(discovered.count, 1)
        XCTAssertTrue(discovered[0].sessionId.hasPrefix(GeminiSessionSource.liveSessionIdPrefix))
        XCTAssertEqual(discovered[0].cwd, "/Users/me/elsewhere")
        XCTAssertEqual(discovered[0].title, "elsewhere")
        XCTAssertEqual(discovered[0].lastActivity, startedAt)
        XCTAssertEqual(discovered[0].status, .idle)
    }

    // MARK: - Fixtures

    private struct Chat {
        let projectKey: String
        /// `nil` writes NO `.project_root`, reproducing the hash-named directories on this machine.
        let projectRoot: String?
        let id: String
        var kind = "main"
        var directories: [String] = []
        var prompt: String?
        var ageSeconds: TimeInterval = 60
    }

    private func makeSource(
        home: URL,
        processes: [ClaudeProcess] = [],
        showSubAgentSessions: Bool = false
    ) -> GeminiSessionSource {
        GeminiSessionSource(
            geminiHome: home,
            processProvider: { processes },
            showSubAgentSessions: { showSubAgentSessions },
            // Pinned rather than resolved, so the suite never depends on what is installed on the
            // machine running it.
            resumeCommand: "/usr/bin/env-gemini"
        )
    }

    /// Builds a `~/.gemini` fixture by hand — plain JSON text, exactly what a real chat file's
    /// first lines look like — inside the test's own temporary directory. The real `~/.gemini` is
    /// never read or written by this suite.
    private func makeFixture(chats: [Chat]) throws -> URL {
        let home = try makeTemporaryDirectory()
        for chat in chats {
            let projectDirectory = home.appendingPathComponent("tmp/\(chat.projectKey)", isDirectory: true)
            let chatsDirectory = projectDirectory.appendingPathComponent("chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
            if let projectRoot = chat.projectRoot {
                try Data("\(projectRoot)\n".utf8)
                    .write(to: projectDirectory.appendingPathComponent(GeminiProjectRoot.markerFileName))
            }

            let directories = chat.directories.isEmpty
                ? ""
                : #","directories":[\#(chat.directories.map { "\"\($0)\"" }.joined(separator: ","))]"#
            var lines = [
                #"{"sessionId":"\#(chat.id)","projectHash":"deadbeef","startTime":"2026-06-07T23:59:13.730Z","lastUpdated":"2026-06-07T23:59:13.730Z","kind":"\#(chat.kind)"\#(directories)}"#,
                // Gemini's own preamble always comes first and must never be mistaken for a title.
                #"{"$set":{"messages":[{"id":"1","type":"user","content":[{"text":"<session_context>\nThis is the Gemini CLI. …"}]}]}}"#
            ]
            if let prompt = chat.prompt {
                lines.append(#"{"id":"2","type":"user","content":[{"text":"\#(prompt)"}]}"#)
            }

            let url = chatsDirectory.appendingPathComponent("session-2026-06-07T23-59-\(chat.id).jsonl")
            try Data(lines.joined(separator: "\n").utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: fixedNow.addingTimeInterval(-chat.ageSeconds)],
                ofItemAtPath: url.path
            )
        }
        return home
    }
}
