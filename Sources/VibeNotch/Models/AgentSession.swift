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

    var id: String { sessionId }

    var folderName: String {
        cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }
}
