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
    let cwd: String
    let modifiedAt: Date
    let status: SessionStatus
    let jumpRung: JumpRung
    let title: String
    let lastPrompt: String?
    let tty: String?
    let terminalName: String?
    let notificationMessage: String?
    let pendingToolName: String?
    let pendingToolInput: JSONValue?

    var id: String { sessionId }

    var folderName: String {
        cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }
}
