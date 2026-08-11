import SwiftUI

/// The expanded card's progress panel (#15): how long this turn has been running and what it has
/// cost, over the agent's own checklist when it publishes one.
///
/// The trail of finished tool calls it used to draw between the two is gone (#41) — the call in
/// flight is the card's status line one row above, and the finished ones were never achievements.
///
/// Renders literally nothing when there is nothing to say, which is the normal case for a hookless
/// agent and for a session sitting idle. Every decision about what fits lives in
/// `SessionProgress.checklist`; this only draws it.
struct SessionProgressView: View {
    let progress: SessionProgress

    var body: some View {
        if progress.hasAnythingToShow {
            VStack(alignment: .leading, spacing: 3) {
                header
                ForEach(Array(SessionProgress.checklist(progress).enumerated()), id: \.offset) { _, todo in
                    row(todo)
                }
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var header: some View {
        if progress.turnStartedAt != nil {
            // One second, not the card's usual thirty: the whole point of showing "4m 46s" is
            // that it moves. The ticker exists only while a turn is actually in flight.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                headerText(now: context.date)
            }
        } else {
            headerText(now: Date())
        }
    }

    @ViewBuilder
    private func headerText(now: Date) -> some View {
        if let text = SessionProgress.headerText(progress, now: now) {
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.vibeGray)
                .lineLimit(1)
        }
    }

    private func row(_ todo: ProgressTodo) -> some View {
        let isDone = todo.state == .completed
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(glyph(for: todo.state))
                .foregroundStyle(isDone ? Color.vibeGreen : Color.vibeGray)
                .frame(width: 9, alignment: .leading)
            Text(todo.text)
                .strikethrough(isDone, color: Color.vibeGray.opacity(0.7))
                .foregroundStyle(Color.vibeGray.opacity(isDone ? 0.55 : 1))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func glyph(for state: TodoState) -> String {
        switch state {
        // `.deleted` is filtered out before it ever reaches a row.
        case .pending, .deleted: "□"
        case .inProgress: "■"
        case .completed: "✓"
        }
    }
}
