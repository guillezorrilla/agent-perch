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
                // The invader marches only while a turn is genuinely in flight, so movement on
                // screen means live activity and nothing else (#53). Full cards are the only
                // place this is passed: a compact row has no glyph, and the notch's own compact
                // glyph is what shows while the panel is CLOSED, which must never animate.
                InvaderGlyph(color: statusColor, isWorking: presentation.isWorking)
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

                    // Below the status line rather than instead of it, and it never repeats it:
                    // the status line above is the one thing in flight, this is what the turn has
                    // cost and the goals the agent published (#41). It draws nothing when there is
                    // nothing to draw, so an idle or hookless card stays exactly as tall as it was
                    // before (#15).
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

    /// Asked once for the card: it decides both what the status line says and whether the glyph
    /// is allowed to move, so the two can never disagree (#52, #53).
    private var presentation: SessionStatusPresentation {
        SessionStatusPresentation.of(session)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch presentation {
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
            // Nothing verified is in flight. Either a hookless session (Codex, `agy`), whose
            // `.active` only means "recently touched and a live process" (#31), or a hook-backed
            // one sitting between turns, whose `.active`/`.idle` only means "transcript recently
            // written" (#52). Neither can honestly claim "Working…"; the elapsed time already
            // sits in the card's trailing corner.
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

    /// VoiceOver hears exactly what the card draws, by the same rule (#52) — an idle session
    /// announced as "working" was the same false claim in a channel nobody was looking at.
    private var statusLabel: String {
        switch presentation {
        case .needsAction: "needs input"
        case .done: "done"
        case .activity, .workingSpinner: "working"
        case .neutral: session.status == .active ? "active" : "idle"
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
    let onSelect: (Int) -> Void
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

            VStack(spacing: 6) {
                ForEach(Array(PendingAction.permissionAffirmatives(forTool: request.toolName).enumerated()), id: \.offset) { index, option in
                    affirmativeButton(number: index + 1, option: option)
                }
            }

            DenyButton(title: "Deny ⌘N") { onDecision(.deny) }
        }
        .padding(14)
        .background(Color.vibeCard, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func affirmativeButton(
        number: Int,
        option: (label: String, description: String)
    ) -> some View {
        Button { onSelect(number) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("⌘\(number)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.vibeAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    Text(option.description)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.vibeGray)
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
        .accessibilityLabel("Option \(number): \(option.label)")
        .firstMouseAction { onSelect(number) }
    }
}

/// Deny on its own, because it is the one answer that is NOT a digit: it sends Escape, which
/// cancels a prompt of any shape (see `PermissionRequestCard.affirmatives`).
private struct DenyButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.vibePanel, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityLabel(title)
        .firstMouseAction(action)
    }
}

struct PlanReviewCard: View {
    let markdown: String
    let onSelect: (Int) -> Void

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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(PlanMarkdown.blocks(markdown).enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .padding(11)
            .background(Color.vibePanel, in: RoundedRectangle(cornerRadius: 9))

            VStack(spacing: 6) {
                ForEach(PendingAction.planOptions.indices, id: \.self) { index in
                    optionButton(at: index)
                }
            }
        }
        .padding(14)
        .background(Color.vibeCard, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func blockView(_ block: PlanMarkdown.Block) -> some View {
        switch block {
        case let .heading(text):
            Text(Self.rendered(text))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 6)
        case let .paragraph(text):
            Text(Self.rendered(text))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        case let .listItem(marker, text):
            // The marker hangs in its own column, so a wrapped step's second line lines up with
            // its first instead of under the number.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.vibeBlue)
                Text(Self.rendered(text))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .spacer:
            Spacer(minLength: 5)
        }
    }

    private func optionButton(at index: Int) -> some View {
        let number = index + 1
        let option = PendingAction.planOptions[index]
        return Button { onSelect(number) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("⌘\(number)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.vibeBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    Text(option.description)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.vibeGray)
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
        .accessibilityLabel("Option \(number): \(option.label)")
        .firstMouseAction { onSelect(number) }
    }

    /// Inline styling only — bold, italic, `code` — for ONE block at a time.
    ///
    /// `.full` is what produced the blob: it parses blocks correctly but stores them as
    /// presentation intents, and a single SwiftUI `Text` ignores those entirely, so every heading
    /// and list item ran together into one paragraph ("…a small Python CLIContextHypothetical…").
    /// Splitting first and parsing inline-only keeps the author's own line breaks, which are the
    /// structure that was being thrown away.
    private static func rendered(_ line: String) -> AttributedString {
        (try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(line)
    }
}

/// Splits plan markdown into renderable BLOCKS. Pure and separate from the view so the part that
/// can actually be wrong is testable without a running SwiftUI stack.
///
/// Rendering one `Text` per source line (the first cut at #62) fixed the run-on blob but left the
/// author's hard wrapping frozen into the card: a sentence wrapped at 80 columns in the terminal
/// broke in the same place at half the width, mid-clause, with a ragged edge nobody wrote. A
/// paragraph is consecutive non-blank lines, so joining them back and letting SwiftUI wrap at the
/// card's own width is what makes it read like prose (#66).
enum PlanMarkdown {
    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        /// Kept apart from `paragraph` so a wrapped step never merges into its neighbour, and so
        /// the marker can be hung in the margin instead of swimming inside the text.
        case listItem(marker: String, text: String)
        /// A run of blank lines — one gap, however many there were.
        case spacer
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var listItem: (marker: String, text: [String])?

        func flush() {
            if let open = listItem {
                blocks.append(.listItem(marker: open.marker, text: open.text.joined(separator: " ")))
                listItem = nil
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                if blocks.last != .spacer, !blocks.isEmpty { blocks.append(.spacer) }
                continue
            }
            if let heading = heading(in: trimmed) {
                flush()
                blocks.append(.heading(heading))
                continue
            }
            if let (marker, text) = listMarker(in: trimmed) {
                flush()
                listItem = (marker, [text])
                continue
            }
            // A continuation line belongs to whichever block is still open, so a wrapped step
            // stays part of that step rather than becoming a stray paragraph under it.
            if listItem != nil {
                listItem?.text.append(trimmed)
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        // A trailing gap would just pad the bottom of the scroll view.
        if blocks.last == .spacer { blocks.removeLast() }
        return blocks
    }

    /// ATX headings only. A `#` with no text after it is NOT one — in a plan that is far more
    /// likely to be a shell comment or a Python line than a title — and neither is more than six.
    private static func heading(in trimmed: String) -> String? {
        let hashes = trimmed.prefix { $0 == "#" }
        let rest = trimmed.dropFirst(hashes.count)
        guard !hashes.isEmpty, hashes.count <= 6, rest.first == " " else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// `1.` / `2)` / `-` / `*` / `+`, each followed by a space. The marker is returned separately
    /// so the view can align it, and so "3." never gets re-flowed into the previous sentence.
    private static func listMarker(in trimmed: String) -> (String, String)? {
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            return (String(first), String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return (String(digits) + String(punctuation), String(afterDigits.dropFirst(2)))
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
