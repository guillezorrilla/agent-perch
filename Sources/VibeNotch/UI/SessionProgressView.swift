import SwiftUI

/// The expanded card's progress panel (#15): how long this turn has been running and what it has
/// cost, over the trail of steps behind it — with the agent's own checklist above them when it
/// publishes one.
///
/// Renders literally nothing when there is nothing to say, which is the normal case for a
/// hookless agent and for a session sitting idle. Every decision about what fits lives in
/// `SessionProgress.rows`; this only draws it.
struct SessionProgressView: View {
    let progress: SessionProgress

    var body: some View {
        if progress.hasAnythingToShow {
            VStack(alignment: .leading, spacing: 3) {
                header
                ForEach(Array(SessionProgress.rows(progress).enumerated()), id: \.offset) { _, row in
                    line(for: row)
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

    @ViewBuilder
    private func line(for row: ProgressRow) -> some View {
        switch row {
        case let .todo(todo):
            entry(glyph: glyph(for: todo.state), text: todo.label, isDone: todo.state == .completed)
        case let .step(step):
            entry(glyph: step.isComplete ? "✓" : "■", text: step.label, isDone: step.isComplete)
        case let .more(count):
            // No glyph — the overflow is a count, not a step anyone can act on.
            entry(glyph: " ", text: "+\(count) more", isDone: false)
        }
    }

    private func entry(glyph: String, text: String, isDone: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(glyph)
                .foregroundStyle(isDone ? Color.vibeGreen : Color.vibeGray)
                .frame(width: 9, alignment: .leading)
            Text(text)
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
        case .pending: "□"
        case .inProgress: "■"
        case .completed: "✓"
        }
    }
}
