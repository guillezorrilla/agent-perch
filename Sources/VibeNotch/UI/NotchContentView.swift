import SwiftUI

@MainActor
final class NotchActions {
    var expandAction: () -> Void = {}
    var collapseAction: () -> Void = {}

    func expand() { expandAction() }
    func collapse() { collapseAction() }
}

struct NotchContentView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var usageProvider: UsageProvider
    @ObservedObject var settings: AppSettings
    let jumper: Jumper
    let actionInjector: ActionInjector
    let actions: NotchActions

    var body: some View {
        Group {
            if let featuredSession {
                VStack(alignment: .leading, spacing: 10) {
                    if let usage = usageProvider.usage {
                        UsageStripView(usage: usage)
                    }

                    featuredCard(for: featuredSession)

                    ForEach(remainingSessions) { session in
                        CompactSessionRow(session: session) {
                            jump(to: session)
                        }
                    }
                }
                .padding(16)
                .frame(width: CGFloat(settings.panelWidth), alignment: .leading)
                .background(Color.black)
                .onHover { hovering in
                    if !hovering { actions.collapse() }
                }
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

    private var featuredSession: AgentSession? {
        store.sessions.first { $0.status == .needsAction } ?? store.sessions.first
    }

    private var remainingSessions: [AgentSession] {
        guard let featuredSession else { return store.sessions }
        return store.sessions.filter { $0.id != featuredSession.id }
    }

    @ViewBuilder
    private func featuredCard(for session: AgentSession) -> some View {
        if session.status == .needsAction,
           let pending = PendingAction.parse(
               toolName: session.pendingToolName,
               input: session.pendingToolInput
           ) {
            switch pending {
            case let .permission(request):
                PermissionRequestCard(request: request) { decision in
                    respond(decision, to: session)
                }
            case let .plan(markdown):
                PlanReviewCard(markdown: markdown) { decision in
                    respond(decision, to: session)
                }
            }
        } else {
            FeaturedSessionCard(session: session) {
                jump(to: session)
            }
        }
    }

    private func respond(_ decision: ActionDecision, to session: AgentSession) {
        if actionInjector.inject(decision, into: session) {
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
                .onHover { if $0 { actions.expand() } }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(session.title), show Claude sessions")
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
                    .onHover { if $0 { actions.expand() } }
                    .accessibilityLabel("\(store.sessions.count) Claude sessions")
                    .accessibilityHint("Show session list")
            }
        }
    }
}

struct UsageStripView: View {
    let usage: UsageSnapshot

    var body: some View {
        HStack(spacing: 7) {
            Text("✦")
                .foregroundStyle(.white)
            window(label: "5h", value: usage.fiveHour)
            Text("|")
                .foregroundStyle(Color.vibeGray.opacity(0.65))
            window(label: "7d", value: usage.sevenDay)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func window(label: String, value: UsageWindow) -> some View {
        Text(label)
            .foregroundStyle(Color.vibeGray)
        Text("\(Int(value.utilization.rounded()))%")
            .foregroundStyle(color(for: value.level))
        Text(value.resetText())
            .foregroundStyle(Color.vibeGray)
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
