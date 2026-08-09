import Foundation

enum SessionStatus: Equatable, Sendable {
    case active
    case idle

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

    var id: String { sessionId }

    var folderName: String {
        cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }
}
