import XCTest
@testable import AgentPerch

/// The invariants that used to be spread across five mapping tables in four directories, none
/// referencing another, two of which failed silently when an agent was missing from them.
final class AgentRegistryTests: XCTestCase {
    func testNoTwoAgentsShareAName() {
        var seen: Set<String> = []
        for descriptor in AgentRegistry.all {
            XCTAssertTrue(seen.insert(descriptor.name).inserted, "\(descriptor.name) has two rows")
        }
    }

    func testEveryExecutableNameBelongsToExactlyOneAgent() {
        var owners: [String: String] = [:]
        for descriptor in AgentRegistry.all {
            for executable in descriptor.executableNames {
                XCTAssertNil(owners[executable], "\(executable) is claimed by two agents")
                owners[executable] = descriptor.name
            }
        }
        XCTAssertEqual(owners, AgentRegistry.agentsByExecutableName)
    }

    /// The derived table has to keep saying exactly what the hand-written one said.
    func testTheExecutableTableIsUnchanged() {
        XCTAssertEqual(AgentRegistry.agentsByExecutableName, [
            "codex": "Codex",
            "agy": "Antigravity",
            "antigravity": "Antigravity",
            "gemini": "Gemini",
            "opencode": "OpenCode",
            "kiro": "Kiro",
            "kiro-cli": "Kiro",
        ])
        XCTAssertEqual(LiveAgentScan.agentsByExecutableName, AgentRegistry.agentsByExecutableName)
    }

    /// Order is load-bearing — these are tried in sequence against argv[1].
    func testTheScriptMarkerTableKeepsItsOrder() {
        XCTAssertEqual(
            AgentRegistry.agentsByScriptMarker.map(\.marker),
            ["/gemini-cli/", "/bin/gemini", "/.opencode/bin/"]
        )
        XCTAssertEqual(
            AgentRegistry.agentsByScriptMarker.map(\.agentName),
            ["Gemini", "Gemini", "OpenCode"]
        )
    }

    /// Claude is absent from process discovery on purpose: its hooks report a session and its tty
    /// from inside the terminal, which beats a process listing.
    func testClaudeIsNotDiscoveredByProcessListing() {
        XCTAssertTrue(AgentRegistry.descriptor(for: "Claude")?.executableNames.isEmpty == true)
        XCTAssertFalse(AgentRegistry.agentsByExecutableName.values.contains("Claude"))
    }

    /// The paired fields: a workspace IDE is meaningless without the prefix check that tells a
    /// workspace row from a CLI session, and vice versa. Two half-filled rows would put an
    /// Antigravity CLI session on the workspace path, which #29 exists to prevent.
    func testWorkspaceIDEAndItsSessionIdCheckAreAlwaysBothPresent() {
        for descriptor in AgentRegistry.all {
            XCTAssertEqual(
                descriptor.workspaceIDE == nil,
                descriptor.isWorkspaceSessionId == nil,
                "\(descriptor.name) fills one of the workspace fields and not the other"
            )
        }
    }

    func testWorkspaceRowsAreStillToldApartFromCLISessions() {
        // An Antigravity workspace row versus its real `agy` CLI session (#29).
        XCTAssertEqual(
            AgentSession.workspaceIDE(agentName: "Antigravity", sessionId: "antigravity:/repo"),
            .antigravity
        )
        XCTAssertNil(
            AgentSession.workspaceIDE(agentName: "Antigravity", sessionId: "antigravity-cli:ttys001:/repo")
        )
        XCTAssertNil(AgentSession.workspaceIDE(agentName: "Codex", sessionId: "codex:abc"))
        XCTAssertNil(AgentSession.workspaceIDE(agentName: "Claude", sessionId: "abc"))
    }

    /// Every agent found by process listing must state its own CLI rule. Missing an arm used to
    /// fall through `default: isClaudeCLI`, which silently degraded jump resolution and retirement
    /// — the failure this test exists to make loud.
    func testEveryProcessDiscoveredAgentRecognisesItsOwnExecutable() {
        for descriptor in AgentRegistry.all where !descriptor.executableNames.isEmpty {
            for executable in descriptor.executableNames {
                XCTAssertTrue(
                    AgentRegistry.isCLI(agentName: descriptor.name, command: "/opt/homebrew/bin/\(executable)"),
                    "\(descriptor.name) does not recognise its own executable \(executable)"
                )
            }
        }
    }

    /// An agent nobody has a row for keeps Claude's rules, exactly as the old `default:` arm did.
    func testAnUnknownAgentStillFallsBackToClaudesRules() {
        XCTAssertEqual(
            AgentRegistry.isCLI(agentName: "SomethingNew", command: "/usr/local/bin/claude"),
            TTYResolver.isClaudeCLI(command: "/usr/local/bin/claude")
        )
        XCTAssertEqual(
            TTYResolver.isAgentCLI("SomethingNew", command: "/bin/zsh"),
            TTYResolver.isClaudeCLI(command: "/bin/zsh")
        )
    }

    /// Each agent's own rule still routes to the check it always did.
    func testAgentCLIChecksStillRouteToTheirOwnRules() {
        let commands = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/gemini",
            "/bin/zsh",
            "node /opt/homebrew/lib/gemini-cli/bin/gemini",
        ]
        for command in commands {
            XCTAssertEqual(TTYResolver.isAgentCLI("Codex", command: command),
                           TTYResolver.isCodexCLI(command: command), command)
            XCTAssertEqual(TTYResolver.isAgentCLI("Gemini", command: command),
                           TTYResolver.isGeminiCLI(command: command), command)
            XCTAssertEqual(TTYResolver.isAgentCLI("Kiro", command: command),
                           TTYResolver.isKiroCLI(command: command), command)
            XCTAssertEqual(TTYResolver.isAgentCLI("OpenCode", command: command),
                           TTYResolver.isOpenCodeCLI(command: command), command)
            XCTAssertEqual(TTYResolver.isAgentCLI("Antigravity", command: command),
                           TTYResolver.isAntigravityCLI(command: command), command)
        }
    }

    func testUsageGlyphsAreUnchanged() {
        XCTAssertEqual(AgentRegistry.glyph(for: "Claude"), "✦")
        XCTAssertEqual(AgentRegistry.glyph(for: "Codex"), "◆")
        XCTAssertEqual(AgentRegistry.glyph(for: "Antigravity"), "▲")
        XCTAssertEqual(AgentRegistry.glyph(for: "Gemini"), "✧")
        XCTAssertEqual(AgentRegistry.glyph(for: "Kiro"), "◈")
        XCTAssertEqual(AgentRegistry.glyph(for: "OpenCode"), "●")
        XCTAssertEqual(AgentRegistry.glyph(for: "Nobody"), "●")
    }
}
