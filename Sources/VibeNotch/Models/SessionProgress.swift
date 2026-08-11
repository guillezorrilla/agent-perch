import Foundation

/// One tool call the agent made this turn, in the order it made it (#15). Derived from the same
/// `PreToolUse` hook events that already feed the card's live-activity line — nothing new is
/// parsed or watched for it.
struct ProgressStep: Equatable, Sendable {
    let label: String
    var isComplete: Bool
}

/// A `TodoWrite` entry's three states, spelled the way Claude Code writes them so the raw value
/// is the parse.
enum TodoState: String, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct ProgressTodo: Equatable, Sendable {
    let label: String
    let state: TodoState
}

/// One rendered line of the progress panel. Deriving these as values rather than inside the view
/// is what makes the bounding rule testable without touching SwiftUI (#15).
enum ProgressRow: Equatable, Sendable {
    case todo(ProgressTodo)
    case step(ProgressStep)
    /// Everything the row budget could not fit, todos and steps together.
    case more(Int)
}

/// What the expanded card knows about a session's turn in flight: how long it has been running,
/// what it has cost, the trail of steps behind it, and the agent's own checklist when it
/// publishes one (#15).
///
/// Accumulated incrementally in `SessionStore`'s per-session hook state — every field except
/// `tokens` is folded from the hook event stream one event at a time, so a turn with a thousand
/// tool calls costs the same as one with three. `tokens` is the one thing hooks cannot supply
/// (no hook payload carries a token count) and comes from `TranscriptTokenTally`, which is
/// incremental for the same reason.
struct SessionProgress: Equatable, Sendable {
    /// Steps are kept only as deep as the panel can render them; older ones are counted, not
    /// stored, so `+N more` stays truthful without holding a whole turn's history alive.
    static let retainedSteps = 4
    /// The panel's row budget. A notch panel that grows with the turn eventually covers the
    /// screen — and every extra row here is multiplied by `SessionLayout.maxFullCards`.
    static let maxRows = 4

    /// When the turn in flight started, or `nil` between turns. Drives the elapsed half of the
    /// header, so a finished turn stops counting instead of reporting time the agent isn't using.
    var turnStartedAt: Date?
    /// Oldest to newest, at most `retainedSteps`.
    var steps: [ProgressStep] = []
    /// Steps that fell off the front of `steps`.
    var droppedSteps: Int = 0
    /// Empty unless the agent actually published a checklist — see `hasAnythingToShow`.
    var todos: [ProgressTodo] = []
    /// Cumulative for the session, filled in by `SessionStore` from `TranscriptTokenTally`.
    var tokens: Int = 0

    /// Whether this session has anything at all worth a panel. An empty panel is worse than no
    /// panel — it costs the same vertical space in the notch and says nothing (#15).
    var hasAnythingToShow: Bool {
        turnStartedAt != nil || tokens > 0 || !steps.isEmpty || !todos.isEmpty
    }

    /// Folds one hook event in. Mirrors `SessionStore.handle`'s own switch on `event.event` so
    /// the two can never disagree about what a turn is.
    mutating func apply(_ event: HookEvent) {
        switch event.event {
        case "SessionStart", "UserPromptSubmit":
            turnStartedAt = event.timestamp
            steps = []
            droppedSteps = 0
            // The checklist is dropped with the steps rather than carried across the turn
            // boundary: a plan belonging to a request the user has already moved past would sit
            // there fully ✓ forever. Claude re-publishes the entire list on its next `TodoWrite`
            // (it writes the whole array every time), so a plan that genuinely continues comes
            // straight back on the first tool call of the new turn.
            todos = []
        case "PreToolUse":
            // A tool call with no prompt behind it means VibeNotch started mid-turn. The turn is
            // at least this old, which beats showing no elapsed time at all.
            turnStartedAt = turnStartedAt ?? event.timestamp
            if event.toolName == "TodoWrite" {
                todos = Self.todos(in: event.toolInput)
                // No step row for it: the checklist rendered directly above IS this call's
                // output, and "Updating the plan" would spend one of four rows saying so twice.
                return
            }
            guard let label = ActivityLine.describe(
                toolName: event.toolName,
                toolInput: event.toolInput
            ) ?? event.toolName, !label.isEmpty else { return }
            // The previous step is finished the moment the next one starts — the hooks give us
            // no PostToolUse, and in practice the agent never has two calls in flight at once.
            completeAllSteps()
            steps.append(ProgressStep(label: label, isComplete: false))
            if steps.count > Self.retainedSteps {
                let overflow = steps.count - Self.retainedSteps
                steps.removeFirst(overflow)
                droppedSteps += overflow
            }
        case "Stop", "SessionEnd":
            completeAllSteps()
            turnStartedAt = nil
        default:
            // `Notification` included, deliberately: a permission prompt means the in-flight step
            // is still in flight, waiting on the user. Marking it ✓ would claim it had run.
            break
        }
    }

    private mutating func completeAllSteps() {
        for index in steps.indices where !steps[index].isComplete {
            steps[index].isComplete = true
        }
    }

    /// The panel's lines, bounded (#15). A published checklist comes first and gets first call on
    /// the budget — it says more about where a turn is going than the tool calls do — and the
    /// steps fill whatever is left.
    static func rows(_ progress: SessionProgress, limit: Int = maxRows) -> [ProgressRow] {
        guard limit > 0 else { return [] }
        let todos = window(progress.todos, limit: limit)
        let stepBudget = limit - todos.count
        let steps = stepBudget > 0 ? Array(progress.steps.suffix(stepBudget)) : []

        var rows: [ProgressRow] = todos.map(ProgressRow.todo) + steps.map(ProgressRow.step)
        let total = progress.todos.count + progress.droppedSteps + progress.steps.count
        let shown = todos.count + steps.count
        if total > shown { rows.append(.more(total - shown)) }
        return rows
    }

    /// Anchors a long checklist on the item actually in flight. The first four rows of a
    /// ten-item plan are almost always four ✓ and no news; one row of finished context above the
    /// live one is all the history that earns its place.
    private static func window(_ todos: [ProgressTodo], limit: Int) -> [ProgressTodo] {
        guard todos.count > limit else { return todos }
        let anchor = todos.firstIndex { $0.state == .inProgress } ?? todos.count - 1
        let start = min(max(0, anchor - 1), todos.count - limit)
        return Array(todos[start..<(start + limit)])
    }

    /// Reads a `TodoWrite` call's `todos` array out of a `PreToolUse` payload.
    ///
    /// Note this is fed by the hook stream, not by the transcript: probing every transcript on
    /// this machine found zero `TodoWrite` entries persisted anywhere (#15), so the checklist can
    /// only ever come from the live hook payload — which carries the full `tool_input` and would
    /// light this up the instant an agent publishes one.
    static func todos(in input: JSONValue?) -> [ProgressTodo] {
        guard let value = input?.object?["todos"], case let .array(entries) = value else {
            return []
        }
        return entries.compactMap { entry in
            guard let fields = entry.object else { return nil }
            let state = fields["status"]?.string.flatMap(TodoState.init(rawValue:)) ?? .pending
            // `activeForm` is the present-tense phrasing Claude writes for the item it is on
            // ("Running the tests"); `content` is the imperative one ("Run the tests"). Show
            // whichever fits the state, and fall back either way rather than dropping the row.
            let label = (state == .inProgress ? fields["activeForm"]?.string : nil)
                ?? fields["content"]?.string
                ?? fields["activeForm"]?.string
            guard let label, !label.isEmpty else { return nil }
            return ProgressTodo(label: label, state: state)
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
