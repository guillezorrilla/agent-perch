import SwiftUI

struct SessionCardView: View {
    let session: AgentSession
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                SessionStatusDot(status: session.status, size: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    if let lastPrompt = session.lastPrompt {
                        Text(lastPrompt)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                Text(relativeAge)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Image(systemName: session.jumpRung.isExact ? "terminal.fill" : "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(session.jumpRung.isExact ? Color.green : Color.secondary)
                    .help(session.jumpRung.isExact ? "Jump to terminal" : "Open a new terminal tab")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .padding(.vertical, session.lastPrompt == nil ? 0 : 6)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.folderName), \(statusLabel), \(relativeAge)")
        .accessibilityHint(session.jumpRung.isExact ? "Jump to its terminal" : "Open it in a terminal")
    }

    private var relativeAge: String {
        let minutes = max(0, Int(Date().timeIntervalSince(session.modifiedAt))) / 60
        return minutes == 0 ? "<1m" : "\(minutes)m"
    }

    private var statusLabel: String {
        switch session.status {
        case .active: "active"
        case .idle: "idle"
        case .working: "working"
        case .needsAction: "needs action"
        case .done: "done"
        case .ended: "ended"
        }
    }
}
