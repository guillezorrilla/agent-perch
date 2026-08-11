import Foundation

enum SessionStatus: Equatable, Sendable {
    case active
    case idle
    case working
    case needsAction
    case done
    case ended

    static func at(modifiedAt: Date, now: Date = Date()) -> SessionStatus? {
        let age = now.timeIntervalSince(modifiedAt)
        if age < 5 * 60 { return .active }
        if age < 60 * 60 { return .idle }
        return nil
    }
}

struct AgentSession: Identifiable, Equatable, Sendable {
    let sessionId: String
    let agentName: String
    let cwd: String
    let modifiedAt: Date
    let status: SessionStatus
    let jumpRung: JumpRung
    let title: String
    let lastPrompt: String?
    let tty: String?
    let terminalName: String?
    var currentActivity: String?
    let notificationMessage: String?
    let pendingToolName: String?
    let pendingToolInput: JSONValue?
    /// How to reopen this session when no live process/tty is found for it. `nil` means a
    /// plain shell at `cwd` is enough (Claude); Codex supplies `codex resume <id>`.
    let resumeCommand: String?
    /// See `DiscoveredSession.supportsLiveStatus` — carried through unchanged by
    /// `SessionStore.reconcile` (issue #31). Defaults to `true` (Claude's own behavior) so the
    /// existing fixtures that build an `AgentSession` directly don't need to know this exists.
    /// `var` rather than `let` only so the synthesized memberwise init can give it that default
    /// while still letting callers override it — this struct is never mutated after init.
    var supportsLiveStatus: Bool = true
    /// Elapsed turn, cumulative tokens, steps and checklist for the expanded card (#15).
    /// Accumulated in `SessionStore` from the hook stream, never re-derived here. Defaults to an
    /// empty `SessionProgress` — which renders nothing at all — for the same reason
    /// `supportsLiveStatus` has a default: existing fixtures shouldn't have to know it exists.
    var progress = SessionProgress()

    var id: String { sessionId }

    /// The permission/plan/question card this session should show, or `nil` when nothing is
    /// actually blocked on the user — see `PendingAction.resolve`.
    var pendingAction: PendingAction? {
        PendingAction.resolve(
            status: status,
            notificationMessage: notificationMessage,
            toolName: pendingToolName,
            toolInput: pendingToolInput
        )
    }

    var folderName: String {
        cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }
}
