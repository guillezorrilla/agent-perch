@preconcurrency import AppKit
@preconcurrency import UserNotifications

final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let jumper: Jumper
    private let sessionProvider: @MainActor (String) -> AgentSession?
    private let onNeedsAction: @MainActor () -> Void
    private let center: UNUserNotificationCenter?

    init(
        jumper: Jumper,
        sessionProvider: @escaping @MainActor (String) -> AgentSession?,
        onNeedsAction: @escaping @MainActor () -> Void
    ) {
        self.jumper = jumper
        self.sessionProvider = sessionProvider
        self.onNeedsAction = onNeedsAction
        self.center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert]) { _, _ in }
    }

    @MainActor
    func handle(_ transition: SessionTransition, soundsEnabled: Bool) {
        switch transition.session.status {
        case .needsAction:
            if soundsEnabled { NSSound(named: "Funk")?.play() }
            onNeedsAction()

            let content = UNMutableNotificationContent()
            content.title = "\(transition.session.folderName) needs input"
            content.body = transition.session.notificationMessage ?? "Claude Code needs your attention"
            content.userInfo = ["session_id": transition.session.sessionId]
            center?.add(UNNotificationRequest(
                identifier: "vibenotch-\(transition.session.sessionId)-\(transition.session.modifiedAt.timeIntervalSince1970)",
                content: content,
                trigger: nil
            ))
        case .done:
            if soundsEnabled { NSSound(named: "Glass")?.play() }
        default:
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // An app gets exactly one notification-centre delegate, so the update notice (#75) is
        // routed through this one rather than fighting over it.
        if let link = response.notification.request.content.userInfo["open_url"] as? String,
           let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            completionHandler()
            return
        }
        guard let sessionID = response.notification.request.content.userInfo["session_id"] as? String else {
            completionHandler()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            if let session = sessionProvider(sessionID) {
                await jumper.jump(session)
            }
            completionHandler()
        }
    }
}
