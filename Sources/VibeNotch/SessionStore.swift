import Combine
import Foundation

struct SessionTransition: Equatable, Sendable {
    let previousStatus: SessionStatus?
    let session: AgentSession
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    var onTransition: ((SessionTransition) -> Void)?

    let projectsDirectory: URL
    private let fileManager: FileManager
    private let processProvider: () -> [ClaudeProcess]
    private let terminalResolver: TerminalNameResolver
    private var fileSessions: [String: FileSession] = [:]
    private var hookStates: [String: HookState] = [:]

    init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        fileManager: FileManager = .default,
        processProvider: @escaping () -> [ClaudeProcess] = { TTYResolver().processes() },
        terminalResolver: TerminalNameResolver = TerminalNameResolver()
    ) {
        self.projectsDirectory = projectsDirectory
        self.fileManager = fileManager
        self.processProvider = processProvider
        self.terminalResolver = terminalResolver
    }

    func refresh(now: Date = Date()) {
        var discovered: [String: FileSession] = [:]
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let projectDirectories = (try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        for projectDirectory in projectDirectories {
            guard (try? projectDirectory.resourceValues(forKeys: keys).isDirectory) == true else {
                continue
            }

            let cwd = ClaudeProjectPathDecoder.decode(
                projectDirectory.lastPathComponent,
                exists: fileManager.fileExists(atPath:)
            )
            let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
            let files = (try? fileManager.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: Array(fileKeys),
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: fileKeys),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      let status = SessionStatus.at(modifiedAt: modifiedAt, now: now) else {
                    continue
                }
                let id = file.deletingPathExtension().lastPathComponent
                if discovered[id]?.modifiedAt ?? .distantPast < modifiedAt {
                    discovered[id] = FileSession(
                        cwd: cwd,
                        modifiedAt: modifiedAt,
                        status: status,
                        fileURL: file
                    )
                }
            }
        }

        fileSessions = discovered
        reconcile(now: now)
    }

    @discardableResult
    func handle(_ event: HookEvent, now: Date = Date()) -> SessionTransition? {
        guard let sessionID = event.sessionID,
              hookStates[sessionID]?.updatedAt ?? .distantPast <= event.timestamp else {
            return nil
        }

        let previousStatus = sessions.first { $0.sessionId == sessionID }?.status
        var state = hookStates[sessionID] ?? HookState(
            cwd: event.cwd,
            updatedAt: event.timestamp,
            status: .working,
            lastPrompt: nil,
            tty: nil,
            notificationMessage: nil,
            pendingToolName: nil,
            pendingToolInput: nil
        )
        state.updatedAt = event.timestamp
        state.cwd = event.cwd ?? state.cwd
        if !event.tty.isEmpty, event.tty != "??" {
            state.tty = event.tty.hasPrefix("/dev/") ? String(event.tty.dropFirst(5)) : event.tty
        }

        switch event.event {
        case "SessionStart":
            state.status = .working
        case "UserPromptSubmit":
            state.status = .working
            state.lastPrompt = event.prompt ?? state.lastPrompt
            state.notificationMessage = nil
        case "PreToolUse":
            state.status = .working
            state.pendingToolName = event.toolName ?? state.pendingToolName
            state.pendingToolInput = event.toolInput ?? state.pendingToolInput
            state.notificationMessage = nil
        case "Notification":
            state.status = .needsAction
            state.notificationMessage = event.message
        case "Stop":
            state.status = .done
            state.notificationMessage = nil
        case "SessionEnd":
            state.status = .ended
            state.notificationMessage = nil
        default:
            return nil
        }

        hookStates[sessionID] = state
        reconcile(now: now)
        guard let session = sessions.first(where: { $0.sessionId == sessionID }),
              session.status != previousStatus else { return nil }

        let transition = SessionTransition(previousStatus: previousStatus, session: session)
        onTransition?(transition)
        if state.status == .ended {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.removeEndedSessions()
            }
        }
        return transition
    }

    func removeEndedSessions(now: Date = Date()) {
        reconcile(now: now)
    }

    private func reconcile(now: Date) {
        let ids = Set(fileSessions.keys).union(hookStates.keys)
        let processes = ids.isEmpty ? [] : processProvider()
        sessions = ids.compactMap { sessionID -> AgentSession? in
            let file = fileSessions[sessionID]
            let hook = hookStates[sessionID]
            let hookWins = hook.map {
                file == nil || Self.isAtLeastAsFresh($0.updatedAt, as: file!.modifiedAt)
            } ?? false

            if let hook, hook.status == .ended,
               now.timeIntervalSince(hook.updatedAt) >= 30,
               file == nil || Self.isAtLeastAsFresh(hook.updatedAt, as: file!.modifiedAt) {
                return nil
            }

            guard let status = hookWins ? hook?.status : file?.status else { return nil }
            let cwd = file?.cwd ?? hook?.cwd ?? ""
            let modifiedAt = hookWins ? hook!.updatedAt : file!.modifiedAt
            let tty = hook?.tty
            let process = processes.first {
                if let tty { return $0.tty == tty || $0.tty == "/dev/\(tty)" }
                return $0.cwd == cwd
            }
            let jumpRung = Jumper.rung(
                for: cwd,
                preferredTTY: tty,
                processes: processes
            )

            return AgentSession(
                sessionId: sessionID,
                cwd: cwd,
                modifiedAt: modifiedAt,
                status: status,
                jumpRung: jumpRung,
                title: SessionTitle.resolve(
                    sessionFileURL: file?.fileURL,
                    lastPrompt: hook?.lastPrompt,
                    cwd: cwd
                ),
                lastPrompt: hook?.lastPrompt,
                tty: tty,
                terminalName: process.map { terminalResolver.terminalName(for: $0.pid) } ?? nil,
                notificationMessage: hook?.notificationMessage,
                pendingToolName: hook?.pendingToolName,
                pendingToolInput: hook?.pendingToolInput
            )
        }.sorted {
            if ($0.status == .needsAction) != ($1.status == .needsAction) {
                return $0.status == .needsAction
            }
            return $0.modifiedAt > $1.modifiedAt
        }.prefix(10).map { $0 }
    }

    private static func isAtLeastAsFresh(_ hookDate: Date, as fileDate: Date) -> Bool {
        floor(hookDate.timeIntervalSince1970) >= floor(fileDate.timeIntervalSince1970)
    }

    private struct FileSession {
        let cwd: String
        let modifiedAt: Date
        let status: SessionStatus
        let fileURL: URL
    }

    private struct HookState {
        var cwd: String?
        var updatedAt: Date
        var status: SessionStatus
        var lastPrompt: String?
        var tty: String?
        var notificationMessage: String?
        var pendingToolName: String?
        var pendingToolInput: JSONValue?
    }
}
