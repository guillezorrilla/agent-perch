import SwiftUI

struct SessionCardView: View {
    let session: AgentSession
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                Circle()
                    .fill(session.status == .active ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)

                Text(session.folderName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .lineLimit(1)

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
            .frame(height: 40)
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
        session.status == .active ? "active" : "idle"
    }
}
