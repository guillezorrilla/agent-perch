import SwiftUI

struct FeaturedSessionCard: View {
    let session: AgentSession
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 13) {
                InvaderGlyph(color: statusColor)
                    .scaleEffect(2)
                    .frame(width: 26, height: 24)

                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text("You: \(session.lastPrompt ?? "No prompt captured")")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.vibeGray)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    statusLine
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 8) {
                    SessionPills(terminalName: session.terminalName)
                    ElapsedText(since: session.modifiedAt)
                }
            }
            .padding(14)
            .background(Color.vibeCard, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title), \(statusLabel)")
        .accessibilityHint("Jump to terminal")
        .firstMouseAction(onClick)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch session.status {
        case .needsAction:
            Text("Needs input — click to respond")
                .foregroundStyle(Color.vibeAmber)
        case .done, .ended:
            Text("Done — click to jump")
                .foregroundStyle(Color.vibeGreen)
        case .active, .idle, .working:
            if session.status == .working, let activity = session.currentActivity {
                HStack(spacing: 5) {
                    SessionStatusDot(status: .working, size: 7)
                    Text(activity)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(Color.vibeGray)
            } else {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Working…")
                }
                .foregroundStyle(Color.vibeGray)
            }
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .needsAction: .vibeAmber
        case .active, .working: .vibeGreen
        case .idle, .done, .ended: .vibeGray
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .needsAction: "needs input"
        case .done, .ended: "done"
        case .active, .idle, .working: "working"
        }
    }
}

struct CompactSessionRow: View {
    let session: AgentSession
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 9) {
                SessionStatusDot(status: session.status, size: 7)
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                SessionPills(terminalName: session.terminalName)
                ElapsedText(since: session.modifiedAt)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Color.vibeCard.opacity(0.72), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title), open terminal")
        .firstMouseAction(onClick)
    }
}

struct PermissionRequestCard: View {
    let request: PermissionRequest
    let onDecision: (ActionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.vibeAmber)
                    .frame(width: 7, height: 7)
                Text("Permission Request")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.vibeGray)
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("⚠︎")
                    .foregroundStyle(Color.vibeAmber)
                Text(request.toolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.vibeAmber)
                Text(request.target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let diff = request.diff {
                DiffPreviewView(diff: diff)
            } else {
                Text(request.details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.vibePanel, in: RoundedRectangle(cornerRadius: 9))
            }

            ActionButtons(
                negativeTitle: "Deny ⌘N",
                positiveTitle: "Allow ⌘Y",
                onDecision: onDecision
            )
        }
        .padding(14)
        .background(Color.vibeCard, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

struct PlanReviewCard: View {
    let markdown: String
    let onDecision: (ActionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.vibeBlue)
                    .frame(width: 7, height: 7)
                Text("Plan Review")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.vibeGray)
            }

            ScrollView {
                Group {
                    if let renderedMarkdown {
                        Text(renderedMarkdown)
                    } else {
                        Text(markdown)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .padding(11)
            .background(Color.vibePanel, in: RoundedRectangle(cornerRadius: 9))

            ActionButtons(
                negativeTitle: "Reject ⌘N",
                positiveTitle: "Approve ⌘Y",
                onDecision: onDecision
            )
        }
        .padding(14)
        .background(Color.vibeCard, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var renderedMarkdown: AttributedString? {
        try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )
    }
}

struct QuestionPromptCard: View {
    let prompt: QuestionPrompt
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.vibeBlue)
                    .frame(width: 7, height: 7)
                Text("Claude asks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.vibeGray)
            }

            Text(prompt.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(prompt.options.indices, id: \.self) { index in
                        optionButton(at: index)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(14)
        .background(Color.vibeCard, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func optionButton(at index: Int) -> some View {
        let number = index + 1
        let label = prompt.options[index]
        return Button { onSelect(number) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("⌘\(number)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.vibeBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let description = prompt.descriptions[index], !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.vibeGray)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.vibePanel, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        .accessibilityLabel("Option \(number): \(label)")
        .firstMouseAction { onSelect(number) }
    }
}

private struct DiffPreviewView: View {
    let diff: DiffPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                Text("\(line.kind == .removed ? "-" : "+")\(line.text)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(line.kind == .removed ? Color.red : Color.vibeGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (line.kind == .removed ? Color.red : Color.vibeGreen).opacity(0.11)
                    )
            }

            if diff.isTruncated {
                Text("…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.vibeGray)
                    .padding(.horizontal, 8)
            }

            Text("+\(diff.addedCount) -\(diff.removedCount)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.vibeGray)
                .padding(.horizontal, 8)
                .padding(.top, 5)
        }
        .padding(.vertical, 8)
        .background(Color.vibePanel, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct ActionButtons: View {
    let negativeTitle: String
    let positiveTitle: String
    let onDecision: (ActionDecision) -> Void

    var body: some View {
        HStack {
            Spacer()
            // `.firstMouseAction` last, so the catcher covers the whole drawn capsule rather
            // than the bare Button frame the padding sits outside of. `.keyboardShortcut` is
            // kept for when VibeNotch itself is active; CardShortcutMonitor covers the normal
            // case, where the user is typing in their terminal and this panel is never key.
            Button(negativeTitle) { onDecision(.deny) }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(Color.vibeBadge, in: Capsule())
                .firstMouseAction { onDecision(.deny) }

            Button(positiveTitle) { onDecision(.allow) }
                .buttonStyle(.plain)
                .keyboardShortcut("y", modifiers: .command)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(.black)
                .background(.white, in: Capsule())
                .firstMouseAction { onDecision(.allow) }
        }
    }
}

private struct SessionPills: View {
    let terminalName: String?

    var body: some View {
        HStack(spacing: 4) {
            pill("Claude")
            if let terminalName {
                pill(terminalName)
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.72))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.vibeBadge, in: Capsule())
    }
}

private struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(elapsed(since: since, now: context.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.vibeGray)
        }
    }
}

private func elapsed(since: Date, now: Date) -> String {
    let totalMinutes = max(0, Int(now.timeIntervalSince(since)) / 60)
    if totalMinutes < 1 { return "<1m" }
    if totalMinutes < 60 { return "\(totalMinutes)m" }
    return "\(totalMinutes / 60)h\(totalMinutes % 60)m"
}
