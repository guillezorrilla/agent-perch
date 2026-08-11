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
    /// Whether an `.active`/`.working` status from this source is backed by VERIFIED in-flight
    /// activity, not merely "a live process happens to sit at this cwd". Claude's hooks report
    /// real working/needs-action/done transitions, so it stays `true`. Codex and the `agy` CLI
    /// have no hooks — their liveness is a live process plus a recently-touched transcript, which
    /// tells you the process hasn't exited, never that a turn is actually in flight (a TUI parked
    /// at an idle prompt stays alive indefinitely). `SessionCardView` uses this to withhold the
    /// "Working…" treatment from sessions that can't honestly back it up (issue #31). Defaults to
    /// `true` so the handful of sources/fixtures that never need to say otherwise don't have to.
    /// `var` rather than `let` only so the synthesized memberwise init can give it that default
    /// while still letting Codex/`agy` override it — this struct is never mutated after init.
    var supportsLiveStatus: Bool = true
}
