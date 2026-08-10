import AppKit
import SwiftUI

@MainActor
final class NotchActions {
    var expandAction: () -> Void = {}
    var hoverExpandAction: () -> Void = {}
    var collapseAction: () -> Void = {}

    func expand() { expandAction() }
    /// Separate from `expand()` because a hover is not a decision: the compact view can
    /// reappear under a cursor that never moved and fire `.onHover(true)` on its own, which
    /// must not re-open a panel the user just dismissed.
    func hoverExpand() { hoverExpandAction() }
    func collapse() { collapseAction() }
}

struct NotchContentView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var usageProvider: UsageProvider
    @ObservedObject var settings: AppSettings
    let jumper: Jumper
    let actionInjector: ActionInjector
    let actions: NotchActions
    let shortcuts: CardShortcutMonitor

    var body: some View {
        Group {
            if !store.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    UsageStripView(providers: usageProvider.providers) {
                        Task { await usageProvider.forceRefresh() }
                    }

                    ForEach(layout.fullCards) { session in
                        fullCard(for: session)
                    }

                    ForEach(layout.compactRows) { session in
                        CompactSessionRow(session: session) {
                            jump(to: session)
                        }
                    }
                }
                .padding(16)
                .frame(width: CGFloat(settings.panelWidth), alignment: .leading)
                .background(Color.black)
                // No `.onHover { if !hovering { collapse() } }` here, ever. This view is inset
                // below the notch (DynamicNotchKit insets the expanded content by the notch
                // height), so hovering the notch itself reads as "not hovering the content" —
                // it collapsed the panel the hover poll had just opened, ~10 times a second.
                // NotchHoverController owns closing; it tracks notch ∪ panel, not this rect.
                .task {
                    usageProvider.showCached()
                    while !Task.isCancelled {
                        await usageProvider.refresh()
                        do {
                            try await Task.sleep(for: .seconds(120))
                        } catch {
                            return
                        }
                    }
                }
            } else if settings.displayMode == .alwaysShow {
                Text("No agent sessions")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.vibeGray)
                    .frame(width: CGFloat(settings.panelWidth))
                    .frame(minHeight: 52)
                    .background(Color.black)
            }
        }
        .onChange(of: store.sessions.count) { _, count in
            if count == 0, settings.displayMode == .hoverOnly {
                actions.collapse()
            }
        }
    }

    private var layout: SessionLayout.Split {
        SessionLayout.split(sessions: store.sessions)
    }

    /// The topmost full card currently showing a pending-action card. Only this one owns the
    /// global `CardShortcutMonitor` — if more than one session somehow needs an answer at
    /// once, every one of them still renders its permission/plan/question card (a full card
    /// never shows both that and its normal body), but ⌘Y/⌘N/⌘1…9 answer whichever renders
    /// on top; the rest stay reachable by clicking or jumping to the terminal.
    private var topmostPendingCard: (session: AgentSession, pending: PendingAction)? {
        for session in layout.fullCards {
            guard session.status == .needsAction,
                  let pending = PendingAction.parse(
                      toolName: session.pendingToolName,
                      input: session.pendingToolInput
                  ) else { continue }
            return (session, pending)
        }
        return nil
    }

    @ViewBuilder
    private func fullCard(for session: AgentSession) -> some View {
        if session.status == .needsAction,
           let pending = PendingAction.parse(
               toolName: session.pendingToolName,
               input: session.pendingToolInput
           ) {
            if session.id == topmostPendingCard?.session.id {
                // The monitor's lifetime is the card's: SwiftUI tears this branch down when
                // the panel collapses or the session stops needing an answer, so the global
                // key monitor can never outlive the card it belongs to.
                pendingCard(pending, for: session)
                    .onAppear { shortcuts.start(handleShortcut) }
                    .onDisappear { shortcuts.stop() }
            } else {
                pendingCard(pending, for: session)
            }
        } else {
            FeaturedSessionCard(session: session) {
                jump(to: session)
            }
        }
    }

    @ViewBuilder
    private func pendingCard(_ pending: PendingAction, for session: AgentSession) -> some View {
        switch pending {
        case let .permission(request):
            PermissionRequestCard(request: request) { decision in
                respond(decision, to: session)
            }
        case let .plan(markdown):
            PlanReviewCard(markdown: markdown) { decision in
                respond(decision, to: session)
            }
        case let .question(prompt):
            QuestionPromptCard(prompt: prompt) { option in
                respond(option, to: prompt, in: session)
            }
        }
    }

    /// Re-derives the card at keystroke time rather than capturing it: the monitor outlives
    /// individual renders, and a stale capture would answer a request the agent has already
    /// moved past. It also means "no card on screen" simply finds nothing to answer.
    private func handleShortcut(_ shortcut: CardShortcut) {
        guard let (session, pending) = topmostPendingCard else { return }

        switch (pending, shortcut) {
        case let (.question(prompt), .option(number)):
            respond(number, to: prompt, in: session)
        case (.question, _):
            // A question has numbered answers only — allow/deny would be a guess.
            return
        case (_, .allow):
            respond(.allow, to: session)
        case (_, .deny):
            respond(.deny, to: session)
        case let (_, .option(number)):
            respond(option: number, in: session)
        }
    }

    private func respond(_ decision: ActionDecision, to session: AgentSession) {
        if actionInjector.inject(decision, into: session) {
            actions.collapse()
        } else {
            jump(to: session)
        }
    }

    private func respond(_ option: Int, to prompt: QuestionPrompt, in session: AgentSession) {
        guard !prompt.multiSelect, prompt.options.indices.contains(option - 1) else {
            jump(to: session)
            return
        }
        respond(option: option, in: session)
    }

    private func respond(option: Int, in session: AgentSession) {
        if actionInjector.inject(String(option), into: session) {
            actions.collapse()
        } else {
            jump(to: session)
        }
    }

    private func jump(to session: AgentSession) {
        if jumper.jump(session) { actions.collapse() }
    }
}

struct CompactLeadingView: View {
    @ObservedObject var store: SessionStore
    let actions: NotchActions

    var body: some View {
        Group {
            if let session = featuredSession {
                HStack(spacing: 7) {
                    InvaderGlyph(color: aggregateColor)
                    Text(session.title)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.vibeGray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 170, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { actions.expand() }
                .onHover { if $0 { actions.hoverExpand() } }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(session.title), show agent sessions")
            }
        }
    }

    private var featuredSession: AgentSession? {
        store.sessions.first { $0.status == .needsAction } ?? store.sessions.first
    }

    private var aggregateColor: Color {
        if store.sessions.contains(where: { $0.status == .needsAction }) { return .vibeAmber }
        if store.sessions.contains(where: { $0.status == .working || $0.status == .active }) {
            return .vibeGreen
        }
        return .vibeGray
    }
}

struct CompactTrailingView: View {
    @ObservedObject var store: SessionStore
    let actions: NotchActions

    var body: some View {
        Group {
            if !store.sessions.isEmpty {
                Text("\(store.sessions.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.vibeBadge, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { actions.expand() }
                    .onHover { if $0 { actions.hoverExpand() } }
                    .accessibilityLabel("\(store.sessions.count) agent sessions")
                    .accessibilityHint("Show session list")
            }
        }
    }
}

struct UsageStripView: View {
    let providers: [ProviderUsage]
    var onRefresh: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if providers.isEmpty {
                // No snapshot yet (never fetched / no credentials / rate-limited) — still offer a refresh.
                Text("usage unavailable")
                    .foregroundStyle(Color.vibeGray)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(providers, id: \.provider) { provider in
                        providerRow(provider)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Color.vibeGray)
            }
            .buttonStyle(.plain)
            .help("Refresh usage")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func providerRow(_ usage: ProviderUsage) -> some View {
        HStack(spacing: 7) {
            Text(glyph(for: usage.provider))
                .foregroundStyle(.white)
            Text(usage.provider)
                .foregroundStyle(Color.vibeGray)
                .frame(minWidth: 44, alignment: .leading)
            ForEach(Array(usage.windows.enumerated()), id: \.offset) { index, window in
                if index > 0 {
                    Text("|")
                        .foregroundStyle(Color.vibeGray.opacity(0.65))
                }
                windowView(window)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func windowView(_ window: UsageWindow) -> some View {
        Text(window.label)
            .foregroundStyle(Color.vibeGray)
        Text("\(Int(window.utilization.rounded()))%")
            .foregroundStyle(color(for: window.level))
        Text(window.resetText())
            .foregroundStyle(Color.vibeGray)
    }

    private func glyph(for provider: String) -> String {
        switch provider {
        case "Claude": "✦"
        case "Codex": "◆"
        default: "●"
        }
    }

    private func color(for level: UsageLevel) -> Color {
        switch level {
        case .low: .vibeGreen
        case .medium: .orange
        case .high: .red
        }
    }
}

struct SessionStatusDot: View {
    let status: SessionStatus
    let size: CGFloat
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(status == .needsAction && pulse ? 0.35 : 1)
            .animation(
                status == .needsAction
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = status == .needsAction }
            .onChange(of: status) { _, newStatus in pulse = newStatus == .needsAction }
    }

    private var color: Color {
        switch status {
        case .active, .working: .vibeGreen
        case .needsAction: .vibeAmber
        case .idle, .done, .ended: .vibeGray
        }
    }
}
