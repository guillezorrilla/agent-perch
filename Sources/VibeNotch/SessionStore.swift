import Combine
import Foundation

struct SessionTransition: Equatable, Sendable {
    let previousStatus: SessionStatus?
    let session: AgentSession
}

/// Resumes a continuation exactly once, whichever of two racing tasks reaches it first — the
/// injection or the deadline watching it.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// How each session's card was answered, keyed by session id. Lives here rather than in the
    /// card's own `@State` because DynamicNotchKit tears the panel down and rebuilds it on every
    /// expand (DynamicNotch.swift:352) — view state would be gone before the user read it.
    @Published private(set) var resolutions: [String: ActionResolution] = [:]
    /// Sessions whose jump is still in flight. Resolving where a session lives takes a moment
    /// even now that it happens off the main actor, and a card that does nothing for that moment
    /// reads as a click that missed. Lives here for the same reason `resolutions` does: the panel
    /// is torn down and rebuilt on every expand, so view state would not survive it.
    @Published private(set) var jumpingSessions: Set<String> = []
    var onTransition: ((SessionTransition) -> Void)?
    /// Fired when an answered card's confirmation has been on screen for its hold and the card is
    /// dropped — the panel close the answer implied, deferred until the feedback actually landed.
    var onAnswerDismissed: (() -> Void)?

    /// How long "Approved ✓" stays up before the card falls back to the session's normal body.
    nonisolated static let answerHold: TimeInterval = 1.0

    /// How long an injection is given before the card stops waiting on it. Typing an answer means
    /// finding the session's tab first, which for Warp copies a database out of another app's
    /// container; if that ever stalls, the card must still end up somewhere the user can act on
    /// rather than sitting forever on a confirmation that never happened (#32).
    nonisolated static let injectionTimeout: TimeInterval = 5.0

    let projectsDirectory: URL
    let codexHome: URL
    let antigravityHome: URL
    let antigravityCLIHome: URL
    let geminiHome: URL
    let openCodeDatabaseURL: URL
    let kiroHome: URL
    private let sources: [AgentSessionSource]
    private let processProvider: () -> [ClaudeProcess]
    private let terminalResolver: TerminalNameResolver
    private var discoveredSessions: [String: DiscoveredSession] = [:]
    private var hookStates: [String: HookState] = [:]
    private var answerHoldTasks: [String: Task<Void, Never>] = [:]
    /// Sessions whose answer injection is still in flight. Unlike `jumpingSessions` this is not
    /// published: the card takes its resolution the instant the click lands, so nothing on screen
    /// waits on this — it exists only to stop a second answer racing the first.
    private var answeringSessions: Set<String> = []
    /// Pids whose terminal is being resolved in the background right now, so the reconcile that
    /// resolution triggers doesn't ask for the same walk a second time.
    private var resolvingTerminalNamePIDs: Set<Int32> = []

    init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        codexHome: URL = CodexSessionSource.defaultCodexHome(),
        antigravityHome: URL = AntigravitySessionSource.defaultAntigravityHome(),
        antigravityCLIHome: URL = AntigravityCLISessionSource.defaultAntigravityCLIHome(),
        // Injectable for the same reason every home above is: a test that builds the DEFAULT source
        // list must be able to point all of it at its own temporary directories, or the suite ends
        // up reading whatever real agent state happens to be on the machine running it (#11).
        geminiHome: URL = GeminiSessionSource.defaultGeminiHome(),
        openCodeDatabaseURL: URL = OpenCodeSessionSource.defaultDatabaseURL(),
        kiroHome: URL = KiroSessionSource.defaultKiroHome(),
        sources: [AgentSessionSource]? = nil,
        fileManager: FileManager = .default,
        // Non-blocking by default: reconciling happens on the main actor on every hook event, and
        // `ProcessTableCache.processes()` would scan the process table right there when its
        // snapshot has aged out (#32). `cachedProcesses()` answers from what it has and rescans in
        // the background; `ProcessTableCache.onRefresh` is what brings the newer answer back.
        processProvider: @escaping () -> [ClaudeProcess] = { ProcessTableCache.shared.cachedProcesses() },
        terminalResolver: TerminalNameResolver = .shared
    ) {
        self.projectsDirectory = projectsDirectory
        self.codexHome = codexHome
        self.antigravityHome = antigravityHome
        self.antigravityCLIHome = antigravityCLIHome
        self.geminiHome = geminiHome
        self.openCodeDatabaseURL = openCodeDatabaseURL
        self.kiroHome = kiroHome
        self.sources = sources ?? [
            ClaudeSessionSource(projectsDirectory: projectsDirectory, fileManager: fileManager),
            // Shares this same process listing rather than defaulting to its own — one
            // `pgrep`/`lsof` pass per refresh covers both liveness here and jump-rung/terminal
            // pill resolution below, and keeps them looking at a consistent process snapshot —
            // now literally so: the default provider is a shared, briefly-cached snapshot that a
            // click reuses instead of rescanning (#23).
            CodexSessionSource(codexHome: codexHome, fileManager: fileManager, processProvider: processProvider),
            // Antigravity IDE workspaces, not agent turns — see `AntigravitySessionSource`. Gated
            // behind `showAntigravityWorkspaces` (#27) and capped at `.idle` (#29); its own
            // liveness check needs no process table at all any more.
            AntigravitySessionSource(antigravityHome: antigravityHome, fileManager: fileManager),
            // Real `agy` terminal sessions (#29) — unlike the IDE-workspace source above, always
            // on, and shares this same process listing for the same reason Codex's does.
            AntigravityCLISessionSource(
                antigravityCLIHome: antigravityCLIHome,
                fileManager: fileManager,
                processProvider: processProvider
            ),
            // The three agents added by #11. Each one shares this same process listing for the
            // reason Codex's does, and each is written so that a missing directory, an unreadable
            // database or a schema that turns out not to match simply contributes no rows — a new
            // agent must never be able to take the list down with it.
            GeminiSessionSource(
                geminiHome: geminiHome,
                fileManager: fileManager,
                processProvider: processProvider
            ),
            OpenCodeSessionSource(
                databaseURL: openCodeDatabaseURL,
                fileManager: fileManager,
                processProvider: processProvider
            ),
            KiroSessionSource(kiroHome: kiroHome, fileManager: fileManager, processProvider: processProvider)
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
        discoveredSessions = Self.suppressingWorkspacesShadowedByCLISessions(discovered)
        reconcile(now: now)
    }

    /// A CLI session and an IDE-workspace row for the very SAME folder is a duplicate a real user
    /// hit turning on `showAntigravityWorkspaces` for the first time (#29): the CLI row is a real
    /// session, so it wins outright and the workspace row for that path is dropped rather than
    /// shown beside it.
    private static func suppressingWorkspacesShadowedByCLISessions(
        _ discovered: [String: DiscoveredSession]
    ) -> [String: DiscoveredSession] {
        let cliCwds = Set(discovered.values
            .filter { $0.agentName == "Antigravity" && $0.sessionId.hasPrefix(AntigravityCLISessionSource.sessionIdPrefix) }
            .map { CanonicalPath.canonical($0.cwd) })
        guard !cliCwds.isEmpty else { return discovered }
        return discovered.filter { _, session in
            guard session.agentName == "Antigravity",
                  AntigravitySessionSource.isWorkspaceSessionId(session.sessionId) else { return true }
            return !cliCwds.contains(CanonicalPath.canonical(session.cwd))
        }
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

        // Whether this event is a fresh request for the user, which is the only kind of event
        // allowed to cut an answered card's confirmation short below.
        var startsANewRequest = false

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
            // The same hook fires for "Claude needs your permission to use Bash" and for the ~60s
            // "Claude is waiting for your input" nudge. Only the first is a request; treating the
            // second as one is what made every idle session go amber under auto/bypass permission
            // mode, where the agent never asks for anything at all (#25).
            switch NotificationOutcome.of(
                message: event.message,
                currentStatus: state.status,
                pendingToolName: state.pendingToolName,
                pendingToolInput: state.pendingToolInput
            ) {
            case .needsAction:
                state.status = .needsAction
                state.currentActivity = nil
                state.notificationMessage = event.message
                startsANewRequest = true
            case .finished:
                state.status = .done
                state.currentActivity = nil
                state.notificationMessage = nil
            case .ignored:
                return nil
            }
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
        // request: its hold owns it, so the user still sees the feedback when the next tool call
        // lands milliseconds later — but a new request means something new is waiting, and
        // holding a stale "Approved ✓" over it would swallow it. An idle nudge is not a new
        // request and must not cut the confirmation short (#25).
        switch resolutions[sessionID] {
        case .some(.failed):
            clearResolution(sessionID)
        case .some(.answered) where startsANewRequest:
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

    func isAnswering(_ sessionID: String) -> Bool { answeringSessions.contains(sessionID) }

    /// Answers a card: acknowledge the click first, then type.
    ///
    /// The resolution is written BEFORE `inject` runs, so the card reacts to the click on the spot
    /// even though the injection behind it still has to find the session's tab — for Warp, a copy
    /// of a ~30MB database. That work used to happen inline on the main thread, which froze the
    /// whole app for as long as it took (#32).
    ///
    /// The answered card's hold only starts once the keystroke has actually landed: starting it up
    /// front would let a slow injection have its confirmation dismissed out from under it and then
    /// fail, leaving a "Couldn't answer" card for a panel that had already closed.
    ///
    /// A second answer while one is in flight is ignored rather than queued, exactly as a second
    /// jump is: the first is already typing, and two digits into one prompt answer two questions.
    @discardableResult
    func performAnswer(
        _ sessionID: String,
        label: String,
        hold: TimeInterval = answerHold,
        timeout: TimeInterval = injectionTimeout,
        inject: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard answeringSessions.insert(sessionID).inserted else { return false }
        defer { answeringSessions.remove(sessionID) }

        // Any hold left over from a previous answer is cancelled with it, so it cannot expire
        // mid-injection and dismiss the card this one is about to confirm.
        answerHoldTasks[sessionID]?.cancel()
        answerHoldTasks[sessionID] = nil
        resolutions[sessionID] = .answered(label)
        let injected = await Self.firstAnswer(of: inject, within: timeout)

        // Cleared while we were typing — the agent moved on, or the user jumped to do it by hand.
        // Whatever it says now is newer than what this answer has to report.
        guard resolutions[sessionID] != nil else { return injected }
        if injected {
            markAnswered(sessionID, label: label, hold: hold)
        } else {
            markUnanswerable(sessionID)
        }
        return injected
    }

    /// The injection's answer, or `false` once `timeout` passes — whichever comes first.
    ///
    /// The work cannot be cancelled (it is a file copy and a keystroke), so a timeout abandons it
    /// rather than waiting for it. A card must never be left stuck behind a Warp database read
    /// that never returns, which is the difference between a card that gives up and a UI that
    /// hangs (#32).
    private static func firstAnswer(
        of work: @escaping @MainActor () async -> Bool,
        within timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let deadline = Task {
                try? await Task.sleep(for: .seconds(timeout))
                once.resume(false)
            }
            Task { @MainActor in
                once.resume(await work())
                deadline.cancel()
            }
        }
    }

    func isJumping(_ sessionID: String) -> Bool { jumpingSessions.contains(sessionID) }

    /// Runs a jump with its card marked as jumping for exactly as long as it takes, cleared on
    /// success and on failure alike. The lifecycle lives here rather than in the view so that no
    /// path can leave a card spinning forever, and so a panel rebuilt mid-jump still shows it.
    ///
    /// A second click while one is in flight is ignored rather than queued: the first is already
    /// doing the work, and jumping twice would fight over which window ends up in front.
    @discardableResult
    func performJump(
        _ session: AgentSession,
        using jump: @MainActor (AgentSession) async -> Bool
    ) async -> Bool {
        guard jumpingSessions.insert(session.sessionId).inserted else { return false }
        defer { jumpingSessions.remove(session.sessionId) }
        return await jump(session)
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
        // Pids whose terminal nobody has walked the ancestry for yet. Collected here and resolved
        // off the main actor below, because each one costs a pair of `ps` spawns (#32).
        var unresolvedPIDs: Set<Int32> = []
        // What each card is showing right now, so a pid whose walk hasn't happened yet keeps the
        // terminal it already had rather than blanking for a pass.
        let shownTerminalNames = Dictionary(
            sessions.map { ($0.sessionId, $0.terminalName) },
            uniquingKeysWith: { first, _ in first }
        )
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
            // Hooks outrank discovery: Claude reports its tty from inside its own terminal on
            // every event, so it can never go stale. A hookless agent has no hooks to say so and
            // supplies the tty its live process was found on instead (#33).
            let tty = hook?.tty ?? discovered?.tty
            // One answer to "which process is this session", shared by the jump rung and the
            // terminal pill: the session's own tty first, then a process that names the session,
            // and only then anything that merely shares the cwd (#23).
            //
            // An Antigravity IDE-workspace row is a GUI folder, never a terminal — resolving it
            // against the process table risks matching an unrelated Claude/Codex CLI process
            // that merely shares this workspace's cwd, which would wrongly imply a terminal pill
            // and an exact-focus rung neither exists for it (#3). A real `agy` CLI session
            // (same `agentName`, different `sessionId` prefix) is NOT shortcut here — it behaves
            // exactly like Claude/Codex (#29).
            let isAntigravityWorkspace = agentName == "Antigravity"
                && AntigravitySessionSource.isWorkspaceSessionId(sessionID)
            let target = isAntigravityWorkspace ? JumpTarget.unresolved : JumpTarget.resolve(
                agentName: agentName,
                sessionId: sessionID,
                tty: tty,
                cwd: cwd,
                processes: processes
            )
            let jumpRung = Jumper.rung(for: target)

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
                terminalName: target.pid.flatMap { pid in
                    // Cached-only: walking a pid's ancestry spawns `ps` twice per step, and this
                    // runs on the main actor (#32). An unknown pid is walked in the background
                    // right after, and until that lands the card keeps the terminal it was already
                    // showing — the pill must not flicker, and the answer path reads this field to
                    // know how to type into the session at all.
                    guard terminalResolver.isResolved(pid) else {
                        unresolvedPIDs.insert(pid)
                        return shownTerminalNames[sessionID] ?? nil
                    }
                    return terminalResolver.cachedTerminalName(for: pid)
                },
                currentActivity: hookWins ? hook?.currentActivity : nil,
                notificationMessage: hook?.notificationMessage,
                pendingToolName: hook?.pendingToolName,
                pendingToolInput: hook?.pendingToolInput,
                resumeCommand: discovered?.resumeCommand,
                supportsLiveStatus: discovered?.supportsLiveStatus ?? true
            )
        }.sorted {
            if ($0.status == .needsAction) != ($1.status == .needsAction) {
                return $0.status == .needsAction
            }
            return $0.modifiedAt > $1.modifiedAt
        }.prefix(10).map { $0 }

        resolveTerminalNames(for: unresolvedPIDs)
    }

    /// Walks the ancestry of pids the resolver has never seen, off the main actor, then reconciles
    /// once more so their terminal pills appear. Each walk is a pair of `ps` spawns per step, so
    /// the answers are cached for the launch and this runs at most once per pid.
    private func resolveTerminalNames(for pids: Set<Int32>) {
        let pending = pids.subtracting(resolvingTerminalNamePIDs)
        guard !pending.isEmpty else { return }
        resolvingTerminalNamePIDs.formUnion(pending)

        let resolver = terminalResolver
        Task.detached(priority: .userInitiated) {
            resolver.resolve(pending)
            await MainActor.run { [weak self] in
                guard let self else { return }
                resolvingTerminalNamePIDs.subtract(pending)
                reconcile(now: Date())
            }
        }
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
