import SwiftUI

/// A busy session's full card: glyph, title, "You: …" subtitle, activity/status line, pills,
/// elapsed. Every busy session gets one of these now (up to `SessionLayout.maxFullCards`) —
/// the name predates that and is kept only because it's a one-word answer to "which card".
struct FeaturedSessionCard: View {
    let session: AgentSession
    /// A jump this card started is still resolving. Comes from `SessionStore`, never from view
    /// state: the panel is rebuilt on every expand, and a spinner that vanished on the rebuild
    /// would leave the click looking like it did nothing.
    var isJumping = false
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

                    if let subtitle {
                        Text("You: \(subtitle)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.vibeGray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    statusLine

                    // Below the status line rather than instead of it: the status line is the
                    // headline ("Reading Foo.swift"), this is what the turn has cost and the
                    // trail behind it. It draws nothing when there is nothing to draw, so an idle
                    // or hookless card stays exactly as tall as it was before (#15).
                    SessionProgressView(progress: session.progress)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 8) {
                    if isJumping {
                        ProgressView().controlSize(.small)
                    } else {
                        SessionPills(agentName: session.agentName, terminalName: session.terminalName)
                    }
                    ElapsedText(since: session.modifiedAt)
                }
            }
            .padding(14)
            .background(Color.vibeCard, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .opacity(isJumping ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title), \(isJumping ? "jumping" : statusLabel)")
        .accessibilityHint("Jump to terminal")
        .firstMouseAction(onClick)
    }

    // No placeholder when there is nothing captured yet — an empty "You: " row would take
    // vertical space for no information (#21).
    private var subtitle: String? {
        SessionTitle.subtitle(forPrompt: session.lastPrompt)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch SessionStatusPresentation.of(session) {
        case .needsAction:
            // This is the card a session gets when it needs input but nothing is blocked on an
            // Allow/Deny — an idle "Claude is waiting for your input" notification. Clicking it
            // jumps to the terminal; it never answers anything on the user's behalf.
            Text("Needs input — click to jump")
                .foregroundStyle(Color.vibeAmber)
        case .done:
            Text("Done — click to jump")
                .foregroundStyle(Color.vibeGreen)
        case let .activity(text):
            HStack(spacing: 5) {
                SessionStatusDot(status: .working, size: 7)
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Color.vibeGray)
        case .workingSpinner:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Working…")
            }
            .foregroundStyle(Color.vibeGray)
        case .neutral:
            // A hookless session (Codex, `agy`): `.active` here only means "recently touched and
            // a live process," never a verified in-flight turn — never claim "Working…" for it
            // (#31). The elapsed time already sits in the card's trailing corner.
            SessionStatusDot(status: session.status, size: 7)
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
    /// See `FeaturedSessionCard.isJumping` — same flag, same store-owned reason.
    var isJumping = false
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 9) {
                if isJumping {
                    ProgressView().controlSize(.mini)
                } else {
                    SessionStatusDot(status: session.status, size: 7)
                }
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                SessionPills(agentName: session.agentName, terminalName: session.terminalName)
                ElapsedText(since: session.modifiedAt)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Color.vibeCard.opacity(0.72), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .opacity(isJumping ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title), \(isJumping ? "jumping" : "open terminal")")
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

            // Both fields are empty when the request could not be tied to a recorded tool call —
            // the notification message below is then all we honestly know about it.
            if !request.toolName.isEmpty || !request.target.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("⚠︎")
                        .foregroundStyle(Color.vibeAmber)
                    if !request.toolName.isEmpty {
                        Text(request.toolName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.vibeAmber)
                    }
                    Text(request.target)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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

/// What an answered card turns into: the decision that was made, held on screen long enough to
/// be read, with no buttons left to press twice. Its `resolution` comes from `SessionStore`, not
/// from view state — DynamicNotchKit rebuilds this panel on every expand, so a local flag would
/// be gone before the user saw it.
struct ResolvedActionCard: View {
    let resolution: ActionResolution
    /// Only the failure state is clickable; there is nothing left to do about a successful one.
    let onJump: () -> Void

    var body: some View {
        switch resolution {
        case let .answered(label):
            row(dot: .vibeGreen, text: label)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
        case .failed:
            Button(action: onJump) {
                row(dot: .vibeAmber, text: "Couldn't answer — click to jump")
                    .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Couldn't answer")
            .accessibilityHint("Jump to terminal")
            .firstMouseAction(onJump)
        }
    }

    private func row(dot: Color, text: String) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.vibeCard, in: RoundedRectangle(cornerRadius: 16))
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
    let agentName: String
    let terminalName: String?

    var body: some View {
        HStack(spacing: 4) {
            pill(agentName)
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
