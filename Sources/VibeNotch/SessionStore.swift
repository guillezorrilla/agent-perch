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
    let codexHome: URL
    private let sources: [AgentSessionSource]
    private let processProvider: () -> [ClaudeProcess]
    private let terminalResolver: TerminalNameResolver
    private var discoveredSessions: [String: DiscoveredSession] = [:]
    private var hookStates: [String: HookState] = [:]

    init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        codexHome: URL = CodexSessionSource.defaultCodexHome(),
        sources: [AgentSessionSource]? = nil,
        fileManager: FileManager = .default,
        processProvider: @escaping () -> [ClaudeProcess] = { TTYResolver().processes() },
        terminalResolver: TerminalNameResolver = TerminalNameResolver()
    ) {
        self.projectsDirectory = projectsDirectory
        self.codexHome = codexHome
        self.sources = sources ?? [
            ClaudeSessionSource(projectsDirectory: projectsDirectory, fileManager: fileManager),
            CodexSessionSource(codexHome: codexHome, fileManager: fileManager)
        ]
        self.processProvider = processProvider
        self.terminalResolver = terminalResolver
    }

    func refresh(now: Date = Date()) {
        var discovered: [String: DiscoveredSession] = [:]
        for source in sources {
            for session in source.discover(now: now) {
                discovered[session.sessionId] = session
            }
        }
        discoveredSessions = discovered
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
            currentActivity: nil,
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
            // Harness-generated turns (task notifications etc.) must not clobber the
            // last real user prompt — filter at ingestion.
            state.lastPrompt = SessionTitle.displayablePrompt(event.prompt) ?? state.lastPrompt
            state.notificationMessage = nil
            state.pendingToolName = nil
            state.pendingToolInput = nil
        case "PreToolUse":
            state.status = .working
            state.currentActivity = ActivityLine.describe(
                toolName: event.toolName,
                toolInput: event.toolInput
            )
            state.pendingToolName = event.toolName
            state.pendingToolInput = event.toolInput
            state.notificationMessage = nil
        case "Notification":
            state.status = .needsAction
            state.currentActivity = nil
            state.notificationMessage = event.message
        case "Stop":
            state.status = .done
            state.currentActivity = nil
            state.notificationMessage = nil
            state.pendingToolName = nil
            state.pendingToolInput = nil
        case "SessionEnd":
            state.status = .ended
            state.currentActivity = nil
            state.notificationMessage = nil
            state.pendingToolName = nil
            state.pendingToolInput = nil
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
        let ids = Set(discoveredSessions.keys).union(hookStates.keys)
        let processes = ids.isEmpty ? [] : processProvider()
        sessions = ids.compactMap { sessionID -> AgentSession? in
            let discovered = discoveredSessions[sessionID]
            let agentName = discovered?.agentName ?? "Claude"
            // Hook events are Claude-only — a Codex (or future-agent) session must never pick
            // up hook state, even if some future id collision made the lookup succeed.
            let hook = agentName == "Claude" ? hookStates[sessionID] : nil
            let hookWins = hook.map {
                discovered == nil || Self.isAtLeastAsFresh($0.updatedAt, as: discovered!.lastActivity)
            } ?? false

            if let hook, hook.status == .ended,
               now.timeIntervalSince(hook.updatedAt) >= 30,
               discovered == nil || Self.isAtLeastAsFresh(hook.updatedAt, as: discovered!.lastActivity) {
                return nil
            }

            guard let status = hookWins ? hook?.status : discovered?.status else { return nil }
            let cwd = discovered?.cwd ?? hook?.cwd ?? ""
            let modifiedAt = hookWins ? hook!.updatedAt : discovered!.lastActivity
            let tty = hook?.tty
            let process = processes.first {
                if let tty { return $0.tty == tty || $0.tty == "/dev/\(tty)" }
                return $0.cwd == cwd
            }
            let jumpRung = Jumper.rung(
                for: cwd,
                preferredTTY: tty,
                agentName: agentName,
                processes: processes
            )

            return AgentSession(
                sessionId: sessionID,
                agentName: agentName,
                cwd: cwd,
                modifiedAt: modifiedAt,
                status: status,
                jumpRung: jumpRung,
                title: discovered?.title ?? SessionTitle.resolve(
                    sessionFileURL: discovered?.sessionFileURL,
                    lastPrompt: hook?.lastPrompt,
                    cwd: cwd
                ),
                lastPrompt: hook?.lastPrompt,
                tty: tty,
                terminalName: process.map { terminalResolver.terminalName(for: $0.pid) } ?? nil,
                currentActivity: hookWins ? hook?.currentActivity : nil,
                notificationMessage: hook?.notificationMessage,
                pendingToolName: hook?.pendingToolName,
                pendingToolInput: hook?.pendingToolInput,
                resumeCommand: discovered?.resumeCommand
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

    private struct HookState {
        var cwd: String?
        var updatedAt: Date
        var status: SessionStatus
        var lastPrompt: String?
        var tty: String?
        var currentActivity: String?
        var notificationMessage: String?
        var pendingToolName: String?
        var pendingToolInput: JSONValue?
    }
}
