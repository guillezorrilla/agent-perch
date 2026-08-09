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
    let jumper: Jumper
    let actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLAUDE SESSIONS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if store.sessions.isEmpty {
                Text("No agent sessions")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ForEach(store.sessions) { session in
                    SessionCardView(session: session) {
                        if jumper.jump(session) { actions.collapse() }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onHover { hovering in
            if !hovering { actions.collapse() }
        }
    }
}

struct CompactStatusView: View {
    @ObservedObject var store: SessionStore
    let actions: NotchActions

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(store.sessions) { session in
                        SessionStatusDot(status: session.status, size: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture { actions.expand() }
        .onHover { hovering in
            if hovering { actions.expand() }
        }
        .accessibilityLabel("Claude sessions")
        .accessibilityHint("Show session list")
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
        case .active, .working: .green
        case .needsAction: .orange
        case .idle, .done, .ended: .gray
        }
    }
}
