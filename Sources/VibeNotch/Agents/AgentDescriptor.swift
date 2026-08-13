import Foundation

/// Everything this app knows about one agent, on one row.
///
/// Adding an agent used to mean editing five mapping tables that never referenced each other,
/// spread across `Watchers`, `Models`, `Jump` and `UI`, all keyed on the same `agentName` string.
/// Two of the five failed *silently* when missed:
///
/// - absent from `LiveAgentScan.agentsByExecutableName` and the agent's live processes are simply
///   invisible — no row, no error;
/// - absent from `TTYResolver.isAgentCLI` and it falls through `default: isClaudeCLI`, quietly
///   degrading both jump resolution and retirement, with nothing to notice.
///
/// A row cannot be half-filled without saying so. Everything below is a field, and a field left at
/// its default is a decision on the record rather than an omission somebody has to spot.
struct AgentDescriptor: @unchecked Sendable {
    /// The canonical name, as it appears on `AgentSession.agentName`.
    let name: String

    /// Executable BASENAMES whose live processes are this agent's sessions.
    ///
    /// Claude is deliberately empty: its hooks report a session (and its tty) from inside the
    /// terminal it runs in, which is strictly better evidence than a process listing.
    var executableNames: [String] = []

    /// argv[1] markers for an agent whose launcher is a SCRIPT, where the process table shows an
    /// INTERPRETER as argv[0] and the basename lookup cannot see it at all. Homebrew's `gemini` is
    /// exactly this — `file` calls it "a node script text executable" (#11).
    ///
    /// Matched against argv[1] ONLY, never the whole command line: `claude --mcp-config
    /// …/gemini-cli/…` would otherwise be misread as a Gemini session.
    var scriptMarkers: [String] = []

    /// The glyph beside this agent's usage row.
    var glyph: String = "●"

    /// Whether a process command line is one of this agent's CLI sessions. Defaults to Claude's
    /// rules, which is what every call site assumed before Codex existed.
    var isCLI: @Sendable (String) -> Bool = { TTYResolver.isClaudeCLI(command: $0) }

    /// The GUI IDE this agent's *workspace* rows open in, for agents that have them.
    ///
    /// Antigravity's real `agy` CLI sessions deliberately share `agentName` with its IDE-workspace
    /// rows (one Settings toggle, one pill) and are told apart by the session-id prefix — a CLI
    /// session is NOT a workspace and takes the normal ladder (#29). Cursor has no CLI counterpart
    /// in this app, so every row from its source is a workspace, but the prefix check keeps the
    /// same shape so the two cannot drift (#11).
    var workspaceIDE: JumpPlan.WorkspaceIDE?

    /// Whether a session id belongs to a workspace row rather than a CLI session. Only meaningful
    /// alongside `workspaceIDE`, and required with it — see `AgentRegistryTests`.
    var isWorkspaceSessionId: (@Sendable (String) -> Bool)?
}

/// The one place an agent is described. Adding one is adding a row here.
enum AgentRegistry {
    static let all: [AgentDescriptor] = [
        AgentDescriptor(
            name: "Claude",
            glyph: "✦",
            isCLI: { TTYResolver.isClaudeCLI(command: $0) }
        ),
        AgentDescriptor(
            name: "Codex",
            executableNames: ["codex"],
            glyph: "◆",
            isCLI: { TTYResolver.isCodexCLI(command: $0) }
        ),
        AgentDescriptor(
            name: "Antigravity",
            executableNames: ["agy", "antigravity"],
            glyph: "▲",
            isCLI: { TTYResolver.isAntigravityCLI(command: $0) },
            workspaceIDE: .antigravity,
            isWorkspaceSessionId: { AntigravitySessionSource.isWorkspaceSessionId($0) }
        ),
        AgentDescriptor(
            name: "Gemini",
            executableNames: ["gemini"],
            scriptMarkers: ["/gemini-cli/", "/bin/gemini"],
            glyph: "✧",
            isCLI: { TTYResolver.isGeminiCLI(command: $0) }
        ),
        AgentDescriptor(
            name: "OpenCode",
            executableNames: ["opencode"],
            scriptMarkers: ["/.opencode/bin/"],
            isCLI: { TTYResolver.isOpenCodeCLI(command: $0) }
        ),
        AgentDescriptor(
            name: "Kiro",
            executableNames: ["kiro", "kiro-cli"],
            glyph: "◈",
            isCLI: { TTYResolver.isKiroCLI(command: $0) }
        ),
        AgentDescriptor(
            name: "Cursor",
            workspaceIDE: .cursor,
            isWorkspaceSessionId: { CursorSessionSource.isWorkspaceSessionId($0) }
        ),
    ]

    private static let byName: [String: AgentDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )

    static func descriptor(for agentName: String) -> AgentDescriptor? { byName[agentName] }

    /// Executable basename -> agent name, derived from the rows rather than restated.
    static let agentsByExecutableName: [String: String] = Dictionary(
        uniqueKeysWithValues: all.flatMap { descriptor in
            descriptor.executableNames.map { ($0, descriptor.name) }
        }
    )

    /// Script markers in row order, which is the order they were tried in before.
    static let agentsByScriptMarker: [(marker: String, agentName: String)] = all.flatMap { descriptor in
        descriptor.scriptMarkers.map { (marker: $0, agentName: descriptor.name) }
    }

    /// An unknown agent keeps Claude's rules, exactly as `isAgentCLI`'s `default:` arm did — but
    /// now every agent that HAS a row states its own, so falling back means "not one of ours"
    /// rather than "somebody forgot".
    static func isCLI(agentName: String, command: String) -> Bool {
        guard let descriptor = descriptor(for: agentName) else {
            return TTYResolver.isClaudeCLI(command: command)
        }
        return descriptor.isCLI(command)
    }

    static func workspaceIDE(agentName: String, sessionId: String) -> JumpPlan.WorkspaceIDE? {
        guard let descriptor = descriptor(for: agentName),
              let ide = descriptor.workspaceIDE,
              descriptor.isWorkspaceSessionId?(sessionId) == true else { return nil }
        return ide
    }

    static func glyph(for agentName: String) -> String {
        descriptor(for: agentName)?.glyph ?? "●"
    }
}
