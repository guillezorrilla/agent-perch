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
                        Circle()
                            .fill(session.status == .active ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
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
