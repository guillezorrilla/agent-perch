import Foundation

/// A checklist entry's states, spelled the way Claude Code writes them so the raw value is the
/// parse. `deleted` is a status the agent can genuinely set (`TaskUpdate`); the item keeps its slot
/// so the ones after it still line up by position, and the panel simply never draws it (#41).
enum TodoState: String, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case deleted
}

struct ProgressTodo: Equatable, Sendable {
    /// The imperative phrasing the agent wrote: "Write the model".
    let label: String
    /// The present-tense phrasing it wrote alongside it ("Writing the model"), which exists for
    /// exactly one moment: while this is the item in flight.
    var activeLabel: String?
    var state: TodoState

    var text: String { (state == .inProgress ? activeLabel : nil) ?? label }
}

/// What the expanded card knows about a session's turn in flight: how long it has been running,
/// what it has cost, and the agent's own checklist when it publishes one (#15).
///
/// The trail of finished tool calls #15 also drew here is gone (#41). A finished `ls` is not an
/// accomplishment, and rendering it with a ✓ borrowed the visual language of a checklist for
/// something that was not one; the one call actually in flight is already the card's status line,
/// one row above this panel. What is left is the two things the card cannot say anywhere else.
///
/// Accumulated incrementally in `SessionStore`'s per-session hook state — every field except
/// `tokens` is folded from the hook event stream one event at a time. `tokens` is the one thing
/// hooks cannot supply (no hook payload carries a token count) and comes from
/// `TranscriptTokenTally`, which is incremental for the same reason.
struct SessionProgress: Equatable, Sendable {
    /// The panel's row budget. A notch panel that grows with the turn eventually covers the
    /// screen — and every extra row here is multiplied by `SessionLayout.maxFullCards`.
    static let maxRows = 4
    /// Stored items are capped well above the row budget: the panel windows onto the item in
    /// flight, so a ten-item plan has to be kept whole, but a session must not accumulate forever.
    static let retainedTodos = 32

    /// When the turn in flight started, or `nil` between turns. Drives the elapsed half of the
    /// header, so a finished turn stops counting instead of reporting time the agent isn't using.
    var turnStartedAt: Date?
    /// Empty unless the agent actually published a checklist — see `hasAnythingToShow`.
    var todos: [ProgressTodo] = []
    /// Cumulative for the session, filled in by `SessionStore` from `TranscriptTokenTally`.
    var tokens: Int = 0

    /// Whether this session has anything at all worth a panel. An empty panel is worse than no
    /// panel — it costs the same vertical space in the notch and says nothing (#15).
    var hasAnythingToShow: Bool {
        turnStartedAt != nil || tokens > 0 || todos.contains { $0.state != .deleted }
    }

    /// Folds one hook event in. Mirrors `SessionStore.handle`'s own switch on `event.event` so
    /// the two can never disagree about what a turn is.
    mutating func apply(_ event: HookEvent) {
        switch event.event {
        case "SessionStart", "UserPromptSubmit":
            turnStartedAt = event.timestamp
            // Only a finished checklist is dropped at the turn boundary: one left fully ✓ belongs
            // to a request the user has already moved past. A plan with work still in it is
            // carried across, because `TaskCreate`/`TaskUpdate` publish one item at a time and
            // never re-send the list — clearing here would lose a multi-turn plan for good (#41).
            if !todos.contains(where: { $0.state == .pending || $0.state == .inProgress }) {
                todos = []
            }
        case "PreToolUse":
            // A tool call with no prompt behind it means VibeNotch started mid-turn. The turn is
            // at least this old, which beats showing no elapsed time at all.
            turnStartedAt = turnStartedAt ?? event.timestamp
            applyChecklist(event)
        case "Stop", "SessionEnd":
            turnStartedAt = nil
        default:
            // `Notification` included: a permission prompt is the turn waiting on the user, not
            // the turn ending.
            break
        }
    }

    /// Folds the agent's own checklist calls in — and nothing else. No tool call ever becomes a
    /// checklist row: the ✓/■/□ marks are reserved for goals the agent published as goals (#41).
    ///
    /// Two shapes, because Claude Code has had two. `TodoWrite` rewrites the whole list on every
    /// call. `TaskCreate`/`TaskUpdate` — which is what Claude Code 2.1.227 actually ships, with no
    /// `TodoWrite` tool at all, verified by driving a real plan through a real `PreToolUse` hook
    /// (#41) — publish it one item at a time.
    private mutating func applyChecklist(_ event: HookEvent) {
        let input = event.toolInput?.object
        switch event.toolName {
        case "TodoWrite":
            todos = Self.todos(in: event.toolInput)
        case "TaskCreate":
            guard todos.count < Self.retainedTodos,
                  let label = input?["subject"]?.string ?? input?["description"]?.string,
                  !label.isEmpty else { return }
            todos.append(ProgressTodo(
                label: label,
                activeLabel: input?["activeForm"]?.string,
                state: .pending
            ))
        case "TaskUpdate":
            // Ids are read as positions: `TaskCreate`'s payload carries no id (the agent only
            // learns it from the tool result, which a `PreToolUse` hook never sees) and Claude
            // Code numbers tasks 1, 2, 3… in the order those events arrive. An id past the end —
            // VibeNotch attached mid-session and never saw the create — is dropped, not guessed.
            guard let index = input?["taskId"]?.string.flatMap(Int.init).map({ $0 - 1 }),
                  todos.indices.contains(index),
                  let state = input?["status"]?.string.flatMap(TodoState.init(rawValue:)) else {
                return
            }
            todos[index].state = state
        default:
            break
        }
    }

    /// The panel's rows (#41): the checklist items that still exist, bounded, anchored on the one
    /// in flight. The first four rows of a ten-item plan are almost always four ✓ and no news; one
    /// row of finished context above the live one is all the history that earns its place.
    static func checklist(_ progress: SessionProgress, limit: Int = maxRows) -> [ProgressTodo] {
        guard limit > 0 else { return [] }
        let todos = progress.todos.filter { $0.state != .deleted }
        guard todos.count > limit else { return todos }
        let anchor = todos.firstIndex { $0.state == .inProgress } ?? todos.count - 1
        let start = min(max(0, anchor - 1), todos.count - limit)
        return Array(todos[start..<(start + limit)])
    }

    /// Reads a `TodoWrite` call's `todos` array out of a `PreToolUse` payload.
    static func todos(in input: JSONValue?) -> [ProgressTodo] {
        guard let value = input?.object?["todos"], case let .array(entries) = value else {
            return []
        }
        return entries.prefix(retainedTodos).compactMap { entry in
            guard let fields = entry.object else { return nil }
            let activeForm = fields["activeForm"]?.string
            // Fall back either way rather than dropping a row the agent meant to show.
            guard let label = fields["content"]?.string ?? activeForm, !label.isEmpty else {
                return nil
            }
            return ProgressTodo(
                label: label,
                activeLabel: activeForm,
                // An unknown status is still a real item — show it rather than dropping it.
                state: fields["status"]?.string.flatMap(TodoState.init(rawValue:)) ?? .pending
            )
        }
    }

    /// `48s`, `4m 46s`, `1h 04m` — seconds matter while a turn is short and stop mattering once
    /// it isn't.
    static func elapsedText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(pad(total % 60))s" }
        return "\(total / 3600)h \(pad((total % 3600) / 60))m"
    }

    /// `812`, `12.1k`, `1.7M` — this sits in a corner of a notch panel, so it gets three or four
    /// characters and no more.
    static func tokenText(_ tokens: Int) -> String {
        let tokens = max(0, tokens)
        if tokens < 1_000 { return "\(tokens)" }
        if tokens < 1_000_000 { return String(format: "%.1fk", Double(tokens) / 1_000.0) }
        return String(format: "%.1fM", Double(tokens) / 1_000_000.0)
    }

    /// `4m 46s · 12.1k tokens`, or whichever half exists. `nil` when neither does, so the card
    /// never renders a blank header line.
    static func headerText(_ progress: SessionProgress, now: Date) -> String? {
        var parts: [String] = []
        if let startedAt = progress.turnStartedAt {
            parts.append(elapsedText(now.timeIntervalSince(startedAt)))
        }
        if progress.tokens > 0 {
            parts.append("\(tokenText(progress.tokens)) tokens")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
