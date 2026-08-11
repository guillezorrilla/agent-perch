import Foundation

/// Whether a row still has a process behind it — the one signal that cleanly separated the four
/// ghost rows in #46 from the three real sessions sitting beside them.
///
/// Everything else was checked against that live data first and none of it discriminates: the
/// throwaway sessions an agent spawned carry `isSidechain: false` exactly like a top-level one,
/// `CLAUDE_CODE_CHILD_SESSION` is exported into every tool subprocess including the hook script
/// itself, and their transcripts are the same shape a user-started session writes. What told them
/// apart was that nothing was running behind them any more.
enum SessionLiveness: Equatable, Sendable {
    /// A process was resolved for this session on this pass.
    case live
    /// The process table was asked about this session and had nothing to say.
    case absent
    /// Deliberately never asked. An IDE-workspace row (Antigravity, Cursor) is a GUI folder, not
    /// a terminal: `SessionStore.reconcile` refuses to resolve one against the process table at
    /// all, because an unrelated CLI process that merely shares the folder would answer a
    /// different question (#3, #11). Never retired for absence, never collapsed — this app has no
    /// standing to call one dead.
    case unasked

    var isAbsent: Bool { self == .absent }
}

/// Retires the rows nothing is running behind, and collapses the duplicates they pile up (#46).
///
/// Stateful on purpose, because absence only means something once it is SUSTAINED. The store
/// reconciles against `ProcessTableCache.cachedProcesses()`, which hands back an EMPTY listing
/// until the first background scan lands, and any single `pgrep`/`lsof` pass can miss a process
/// that is genuinely there. Retiring a live session is a far worse failure than showing a dead one
/// for another half minute, so one empty answer is never enough on its own.
struct SessionRetirement {
    /// How long the process table must CONTINUOUSLY come up empty for a session before its absence
    /// counts as evidence at all.
    ///
    /// Wall clock rather than a count of passes, deliberately: consecutive reconciles inside
    /// `ProcessTableCache`'s 2s TTL are handed the very same snapshot, so "missed N scans in a row"
    /// can be one stale answer read N times, while thirty seconds spans a dozen real scans and
    /// covers the cold-start window where the cache has nothing at all.
    static let processAbsenceGrace: TimeInterval = 30.0

    /// How long a session with nothing running behind it stays on screen after its last activity.
    ///
    /// Not zero: #10 shows recently-finished sessions ON PURPOSE — the tab you just closed is the
    /// one you most want to jump back to, and a session that finished a minute ago is still worth
    /// resuming. Not the 60 minutes `SessionStatus.at` grants a transcript either: that window
    /// exists to decide whether a FILE is worth reading, and applying it to a session whose process
    /// exited is what put four dead `vn-progress` rows in a panel that had three real sessions in
    /// it (#46). Five minutes is long enough to come back to something you just finished, short
    /// enough that the panel stays a list of what is happening rather than of what happened.
    static let finishedSessionGrace: TimeInterval = 5 * 60.0

    /// The grace an explicit `SessionEnd` gets before its row is dropped — the same half minute
    /// `SessionStore.reconcile` already gives hook state that outranks the transcript, so a session
    /// is seen to finish rather than vanishing mid-glance.
    static let endedGrace: TimeInterval = 30.0

    /// When the process table first came up empty for each session, cleared the moment one is seen
    /// again. Pruned against the rows discovery still produces, NOT against the survivors: a
    /// retired row's transcript stays inside the 60-minute discovery window for a good while
    /// longer, so dropping its record would let the next reconcile re-admit it, start its clock
    /// over and flicker it in and out every `processAbsenceGrace`.
    private var absentSince: [String: Date] = [:]

    /// How long until the earliest pending retirement comes due, or `nil` when nothing is on its
    /// way out. `SessionStore` has no periodic tick — it reconciles on hook events, transcript
    /// writes and process rescans — and the machine whose last session just exited produces none
    /// of those, so the row that should age out is exactly the row nothing is left to age out.
    private(set) var nextRetirementDelay: TimeInterval?

    /// The rows that survive this pass, deduplicated and ordered.
    mutating func rank(
        _ rows: [AgentSession],
        processes: [ClaudeProcess],
        endedSessionIDs: Set<String> = [],
        now: Date
    ) -> [AgentSession] {
        let liveness = Self.liveness(of: rows, processes: processes)
        observe(liveness, now: now)

        var surviving: [AgentSession] = []
        var earliestDue: Date?
        for row in rows {
            let state = liveness[row.sessionId] ?? .unasked
            let ended = endedSessionIDs.contains(row.sessionId) || row.status == .ended
            if let due = retirementDate(for: row, liveness: state, ended: ended) {
                guard due > now else { continue }
                earliestDue = min(earliestDue ?? due, due)
            }
            surviving.append(row)
        }
        // Never tighter than half a second: a sweep exists to notice a deadline passing, not to
        // spin the store.
        nextRetirementDelay = earliestDue.map { max(0.5, $0.timeIntervalSince(now)) }

        return Self.ordered(
            Self.collapsingFinishedDuplicates(surviving, liveness: liveness),
            liveness: liveness
        )
    }

    /// When this row is due to be retired, or `nil` if it is not on its way out at all.
    ///
    /// Two ways in, and both need the process to be gone first:
    ///
    /// - An explicit `SessionEnd` plus an absent process is two independent signals agreeing, so
    ///   neither has to be sustained and the row goes after `endedGrace`. This is also the one
    ///   path that retires a session whose TRANSCRIPT is newer than its `SessionEnd` — the case
    ///   `SessionStore.reconcile`'s own ended rule stands down for, on the reasonable theory that
    ///   a newer write is newer truth. A `claude --resume` of that id really would put a process
    ///   back; no process means it was just the transcript's last flush landing after the hook.
    /// - No `SessionEnd` at all — a killed session never sends one — so process absence is the
    ///   only evidence there will ever be. It has to be sustained for `processAbsenceGrace`, and
    ///   the session has to have been quiet for `finishedSessionGrace` on top of that, so a
    ///   session the user just finished still gets its moment on screen (#10).
    private func retirementDate(
        for session: AgentSession,
        liveness: SessionLiveness,
        ended: Bool
    ) -> Date? {
        guard liveness.isAbsent else { return nil }
        if ended { return session.modifiedAt.addingTimeInterval(Self.endedGrace) }
        guard let absentSince = absentSince[session.sessionId] else { return nil }
        return max(
            absentSince.addingTimeInterval(Self.processAbsenceGrace),
            session.modifiedAt.addingTimeInterval(Self.finishedSessionGrace)
        )
    }

    private mutating func observe(_ liveness: [String: SessionLiveness], now: Date) {
        for (sessionID, state) in liveness {
            if state.isAbsent {
                if absentSince[sessionID] == nil { absentSince[sessionID] = now }
            } else {
                absentSince[sessionID] = nil
            }
        }
        absentSince = absentSince.filter { liveness[$0.key] != nil }
    }

    /// Which rows still have a process behind them — answered for the whole list at once, because
    /// one process can only be one session.
    ///
    /// It runs the same resolution the jump rung and the terminal pill already do (#23) and ranks
    /// its answers the same way. A row matched by its own hook-reported tty, or by a command line
    /// naming it, has identified a specific process and CLAIMS it. Only then do the rows with
    /// nothing but a cwd to go on get their turn, newest first, and each may only take a process
    /// no stronger match has already claimed.
    ///
    /// That last rule is what separates four dead `vn-progress` rows from the one live session
    /// sharing their folder: a bare cwd match is honest evidence that *an* agent is running there
    /// and no evidence at all that THIS session is, and one `claude` at a path cannot be four of
    /// them (#46). Where two processes really do sit at one cwd, two rows really do claim them —
    /// so a repo with two live sessions and no ttys between them still lists both (#23).
    static func liveness(of rows: [AgentSession], processes: [ClaudeProcess]) -> [String: SessionLiveness] {
        var liveness: [String: SessionLiveness] = [:]
        var claimed: Set<Int32> = []
        var byCwdAlone: [(session: AgentSession, candidates: [Int32])] = []

        for row in rows {
            guard !row.isIDEWorkspace else {
                liveness[row.sessionId] = .unasked
                continue
            }
            let target = JumpTarget.resolve(session: row, processes: processes)
            // A hook-reported tty with nothing running on it is the cleanest death there is: the
            // session told us which terminal it was in, and that terminal holds no agent now.
            guard let pid = target.pid else {
                liveness[row.sessionId] = .absent
                continue
            }
            switch target.match {
            case .sessionTTY, .sessionProcess:
                liveness[row.sessionId] = .live
                claimed.insert(pid)
            case .cwd, .ambiguousCwd, .none:
                // The pid the jump would pick first, then the rest of the processes at this cwd.
                byCwdAlone.append((row, [pid] + target.candidates))
            }
        }

        // Newest first, so the row most likely to BE the live session is the one that gets it;
        // the session id only breaks ties, to keep the answer stable across reconciles.
        for entry in byCwdAlone.sorted(by: {
            ($0.session.modifiedAt, $0.session.sessionId) > ($1.session.modifiedAt, $1.session.sessionId)
        }) {
            guard let unclaimed = entry.candidates.first(where: { !claimed.contains($0) }) else {
                liveness[entry.session.sessionId] = .absent
                continue
            }
            claimed.insert(unclaimed)
            liveness[entry.session.sessionId] = .live
        }
        return liveness
    }

    /// Four rows titled `vn-progress`, identical in title and cwd and differing only by minutes,
    /// collapsed to the newest — without touching the case #23 exists for.
    ///
    /// Only rows with no process behind them are candidates. Two LIVE sessions in one repo are
    /// genuinely two things: each has its own tty, each jumps to its own tab, and merging them
    /// would send the user to the wrong terminal. Two DEAD ones are not: same title, same folder,
    /// no tty between them, and neither jumps anywhere but a fresh shell at the same path, so the
    /// second row buys the user nothing and costs a slot. Keyed by `(agent, canonical cwd)` so a
    /// Claude row and a Codex row for one repo still stand apart.
    static func collapsingFinishedDuplicates(
        _ rows: [AgentSession],
        liveness: [String: SessionLiveness]
    ) -> [AgentSession] {
        var kept: Set<String> = []
        return rows.sorted { $0.modifiedAt > $1.modifiedAt }.filter { row in
            guard liveness[row.sessionId]?.isAbsent == true else { return true }
            return kept.insert("\(row.agentName)\u{0}\(CanonicalPath.canonical(row.cwd))").inserted
        }
    }

    /// Live first, then whatever is waiting on the user, then most recent.
    ///
    /// Liveness is the FIRST key and outranks even needs-action (#46): a dead session's pending
    /// permission prompt is stale by construction — the process that asked for it has exited, so
    /// nobody is on the other end of an answer — and it must never push a running session down the
    /// list. `.unasked` sorts with `.live` rather than against it: an IDE-workspace row was never
    /// resolved against the process table, and demoting it would be asserting something this app
    /// deliberately never checked.
    static func ordered(
        _ rows: [AgentSession],
        liveness: [String: SessionLiveness]
    ) -> [AgentSession] {
        rows.sorted { left, right in
            let leftAbsent = liveness[left.sessionId]?.isAbsent == true
            let rightAbsent = liveness[right.sessionId]?.isAbsent == true
            if leftAbsent != rightAbsent { return rightAbsent }
            if (left.status == .needsAction) != (right.status == .needsAction) {
                return left.status == .needsAction
            }
            return left.modifiedAt > right.modifiedAt
        }
    }
}
