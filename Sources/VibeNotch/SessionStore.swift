import Combine
import Foundation

struct SessionTransition: Equatable, Sendable {
    let previousStatus: SessionStatus?
    let session: AgentSession
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// How each session's card was answered, keyed by session id. Lives here rather than in the
    /// card's own `@State` because DynamicNotchKit tears the panel down and rebuilds it on every
    /// expand (DynamicNotch.swift:352) — view state would be gone before the user read it.
    @Published private(set) var resolutions: [String: ActionResolution] = [:]
    var onTransition: ((SessionTransition) -> Void)?
    /// Fired when an answered card's confirmation has been on screen for its hold and the card is
    /// dropped — the panel close the answer implied, deferred until the feedback actually landed.
    var onAnswerDismissed: (() -> Void)?

    /// How long "Approved ✓" stays up before the card falls back to the session's normal body.
    nonisolated static let answerHold: TimeInterval = 1.0

    let projectsDirectory: URL
    let codexHome: URL
    private let sources: [AgentSessionSource]
    private let processProvider: () -> [ClaudeProcess]
    private let terminalResolver: TerminalNameResolver
    private var discoveredSessions: [String: DiscoveredSession] = [:]
    private var hookStates: [String: HookState] = [:]
    private var answerHoldTasks: [String: Task<Void, Never>] = [:]

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
            // Shares this same process listing rather than defaulting to its own — one
            // `pgrep`/`lsof` pass per refresh covers both liveness here and jump-rung/terminal
            // pill resolution below, and keeps them looking at a consistent process snapshot.
            CodexSessionSource(codexHome: codexHome, fileManager: fileManager, processProvider: processProvider)
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

        // The agent moved on, so a "couldn't answer" banner about a request that no longer exists
        // is stale. An `.answered` confirmation is left alone by everything EXCEPT a fresh
        // notification: its hold owns it, so the user still sees the feedback when the next tool
        // call lands milliseconds later — but a new notification means something new is waiting,
        // and holding a stale "Approved ✓" over it would swallow that request.
        switch (resolutions[sessionID], event.event) {
        case (.some(.failed), _), (.some(.answered), "Notification"):
            clearResolution(sessionID)
        default:
            break
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

    /// Whether any card on screen is still waiting on the user. The needs-action dwell timer
    /// checks this: a diff takes longer than five seconds to read, and a panel that closes
    /// mid-decision takes the decision away. A failed answer still counts — that card is asking
    /// the user to go do it by hand — while an answered one does not; its own hold owns it.
    var hasUnresolvedPendingAction: Bool {
        sessions.contains { session in
            guard session.pendingAction != nil else { return false }
            switch resolutions[session.sessionId] {
            case .answered: return false
            case .failed, nil: return true
            }
        }
    }

    /// Whether the panel is still the user's turn: a card waiting for an answer, or one showing
    /// the answer it just took. The dwell must not close either out from under them — a
    /// confirmation nobody saw is the same as no confirmation at all.
    var hasCardAwaitingUser: Bool {
        !resolutions.isEmpty || hasUnresolvedPendingAction
    }

    /// The answer went in. Show the confirmation, then drop the card back to the session's normal
    /// body — the pending action is cleared with it, so the card cannot pop straight back up
    /// while we wait for the agent's next hook event.
    func markAnswered(_ sessionID: String, label: String, hold: TimeInterval = answerHold) {
        resolutions[sessionID] = .answered(label)
        answerHoldTasks[sessionID]?.cancel()
        answerHoldTasks[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.dismissAnswered(sessionID)
        }
    }

    /// Nothing was typed anywhere — no terminal we can drive, or Accessibility is not granted.
    /// The card stays until the user dismisses it or the agent moves on, so the request does not
    /// silently vanish having never been answered.
    func markUnanswerable(_ sessionID: String) {
        answerHoldTasks[sessionID]?.cancel()
        answerHoldTasks[sessionID] = nil
        resolutions[sessionID] = .failed
    }

    /// The user acted on a card we couldn't answer for them (jumped to the terminal to do it by
    /// hand) — the banner has served its purpose.
    func clearResolution(_ sessionID: String) {
        answerHoldTasks[sessionID]?.cancel()
        answerHoldTasks[sessionID] = nil
        resolutions[sessionID] = nil
    }

    /// The end of an answered card's life, split out of the hold so it is testable without
    /// waiting a second for it.
    func dismissAnswered(_ sessionID: String) {
        answerHoldTasks[sessionID]?.cancel()
        answerHoldTasks[sessionID] = nil
        guard resolutions.removeValue(forKey: sessionID) != nil else { return }
        if var state = hookStates[sessionID] {
            state.notificationMessage = nil
            state.pendingToolName = nil
            state.pendingToolInput = nil
            hookStates[sessionID] = state
            reconcile(now: Date())
        }
        onAnswerDismissed?()
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
