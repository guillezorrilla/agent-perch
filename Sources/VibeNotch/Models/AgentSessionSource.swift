import Foundation

/// A source of agent sessions discovered from disk (or wherever an agent records its own
/// state) — the seam that lets `SessionStore` aggregate Claude, Codex, and future agents
/// without knowing anything about how each one stores its sessions.
protocol AgentSessionSource {
    var agentName: String { get }
    func discover(now: Date) -> [DiscoveredSession]
}

/// One session as reported by an `AgentSessionSource`, before `SessionStore` merges in any
/// hook state (Claude-only) and computes the jump rung.
struct DiscoveredSession: Equatable, Sendable {
    let sessionId: String
    let agentName: String
    let cwd: String
    /// Pre-resolved title for sources with nothing left for `SessionStore` to improve on
    /// (Codex: `thread_name`/cwd basename). `nil` tells `SessionStore` to fall back to
    /// `SessionTitle.resolve`, which also considers hook-provided prompts and transcript
    /// metadata — Claude-only inputs a source has no access to.
    let title: String?
    let lastActivity: Date
    let status: SessionStatus
    /// How to reopen this session when no live process is found for it. `nil` means "just
    /// open a shell at `cwd`" (Claude); Codex supplies `codex resume <id>`.
    let resumeCommand: String?
    /// Claude-only: the session transcript, so `SessionTitle.resolve` can look for
    /// `custom-title`/`agent-name`/`summary` metadata that only exists in that format.
    let sessionFileURL: URL?
}
