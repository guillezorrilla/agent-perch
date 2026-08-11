import AppKit
import ApplicationServices
import Combine

/// What macOS has to consent to before an answer can be typed, and whether it already has (#42).
///
/// Owner's ask, verbatim: *"it should work for all terminals and ask for permission before, and
/// save them, and don't ask the user again — so when the accept/deny or the questions come, the
/// user already gave permissions."* Two rules follow from it and shape everything here:
///
/// 1. **Checking never prompts.** `AXIsProcessTrusted()` and
///    `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: false)` both answer silently.
///    Asking is a separate, explicit button, because the alternative — discovering the grant is
///    missing at the moment a permission card appears — is the failure this section exists to
///    remove, and `AXIsProcessTrustedWithOptions(prompt:)` re-opens its dialog on EVERY ungranted
///    call (#20).
/// 2. **A recorded decision cannot be re-asked.** Once TCC has stored a "Don't Allow", asking
///    again returns the refusal without ever showing a dialog. A denied row therefore says so and
///    sends the user to the right System Settings pane rather than appearing to do nothing.
enum PermissionStatus: Equatable, Sendable {
    case granted
    /// Refused and recorded. Only System Settings can undo this — see the rule above.
    case denied
    /// Never decided, so asking will actually show a dialog.
    case undetermined
    /// Automation only: macOS will neither report nor ask about an app that is not running.
    case targetNotRunning

    /// `AEDeterminePermissionToAutomateTarget`'s four answers. Verified against a real machine:
    /// `noErr` for a terminal already granted, `-1744` (`errAEEventWouldRequireUserConsent`) for
    /// one never asked about, `-600` (`procNotFound`) for one that is not running.
    init(automationStatus: OSStatus) {
        switch automationStatus {
        case noErr: self = .granted
        case OSStatus(errAEEventNotPermitted): self = .denied
        case OSStatus(procNotFound): self = .targetNotRunning
        default: self = .undetermined
        }
    }

    var isGranted: Bool { self == .granted }

    var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Denied — change it in System Settings"
        case .undetermined: "Not asked yet"
        case .targetNotRunning: "Not running — open it to ask"
        }
    }

    /// What the row's button does, or `nil` when there is nothing left to do. A denied grant can
    /// only be changed in System Settings, so offering "Request" there would be a button that
    /// silently does nothing.
    var action: PermissionAction? {
        switch self {
        case .granted: nil
        case .denied: .openSystemSettings
        case .undetermined, .targetNotRunning: .request
        }
    }
}

enum PermissionAction: Equatable, Sendable {
    case request
    case openSystemSettings

    var title: String {
        switch self {
        case .request: "Request"
        case .openSystemSettings: "Open Settings…"
        }
    }
}

/// An app the answer path has to send AppleEvents to, and why.
struct AutomationTarget: Equatable, Sendable, Identifiable {
    let name: String
    let bundleIdentifier: String
    let purpose: String

    var id: String { bundleIdentifier }
}

enum AnswerPermissions {
    /// Only the apps answering actually scripts. Warp is absent on purpose: its tab switch and its
    /// keystroke are both `CGEvent`s, so it needs Accessibility and no AppleEvent at all. WezTerm,
    /// Kitty and tmux are absent for the opposite reason — each has a CLI that takes the text, so
    /// they need neither permission (#42).
    static let automationTargets: [AutomationTarget] = [
        AutomationTarget(
            name: "iTerm2",
            bundleIdentifier: "com.googlecode.iterm2",
            purpose: "Writes the answer straight into the session's own tab."
        ),
        AutomationTarget(
            name: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            purpose: "Selects the session's tab before the keystroke."
        ),
        AutomationTarget(
            name: "System Events",
            bundleIdentifier: "com.apple.systemevents",
            purpose: "Sends the keystroke itself — Terminal.app has no scripting command for it."
        ),
        AutomationTarget(
            name: "Ghostty",
            bundleIdentifier: "com.mitchellh.ghostty",
            purpose: "Focuses the session's surface, which has no other way to be addressed."
        ),
        AutomationTarget(
            name: "cmux",
            bundleIdentifier: "com.cmuxterm.app",
            purpose: "Focuses the session's surface, which has no other way to be addressed."
        )
    ]

    /// Terminals that need no permission at all, named in the UI so their absence from the rows
    /// above reads as "nothing to do" rather than "not supported".
    static let permissionlessTerminals = ["WezTerm", "Kitty", "tmux"]

    /// Only what is actually on this machine: a row for an app the user does not have is a
    /// permission they can never grant and a status that can never change.
    static func installedAutomationTargets(
        isInstalled: (String) -> Bool = Self.isInstalled
    ) -> [AutomationTarget] {
        automationTargets.filter { isInstalled($0.bundleIdentifier) }
    }

    static func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Silent by construction — `askUserIfNeeded: false` is what makes this safe to call every
    /// time the Settings window opens.
    static func automationStatus(forBundleIdentifier bundleIdentifier: String) -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return PermissionStatus(
            automationStatus: AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                false
            )
        )
    }

    /// Blocks until the user answers the dialog, so never call it on the main actor.
    static func requestAutomation(forBundleIdentifier bundleIdentifier: String) -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return PermissionStatus(
            automationStatus: AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                typeWildCard,
                typeWildCard,
                true
            )
        )
    }

    /// Accessibility has only two observable states, and that is a real limit worth stating: macOS
    /// reports whether the grant is ON, never whether the user once said no, so a refusal is
    /// indistinguishable here from never having been asked. Hence `.undetermined` rather than
    /// `.denied`, and hence the System Settings link beside the request either way.
    @MainActor
    static func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .undetermined
    }

    /// The one place in the app allowed to open this dialog. Everything on the answer path checks
    /// `AXIsProcessTrusted()` silently and refuses instead (#42).
    @MainActor
    @discardableResult
    static func requestAccessibility() -> PermissionStatus {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .granted : .undetermined
    }

    static let accessibilityPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    static let automationPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )
}

/// The Settings section's state. Statuses are re-read whenever the window opens, never cached
/// across it: the user may have changed one in System Settings while it was closed.
@MainActor
final class AnswerPermissionsModel: ObservableObject {
    struct AutomationRow: Identifiable, Equatable {
        let target: AutomationTarget
        let status: PermissionStatus

        var id: String { target.id }
    }

    @Published private(set) var accessibility: PermissionStatus = .undetermined
    @Published private(set) var automation: [AutomationRow] = []

    private let installedTargets: () -> [AutomationTarget]
    private let statusForTarget: (String) -> PermissionStatus
    private let accessibilityStatus: @MainActor () -> PermissionStatus

    init(
        installedTargets: @escaping () -> [AutomationTarget] = { AnswerPermissions.installedAutomationTargets() },
        statusForTarget: @escaping (String) -> PermissionStatus = AnswerPermissions.automationStatus(forBundleIdentifier:),
        accessibilityStatus: @escaping @MainActor () -> PermissionStatus = { AnswerPermissions.accessibilityStatus() }
    ) {
        self.installedTargets = installedTargets
        self.statusForTarget = statusForTarget
        self.accessibilityStatus = accessibilityStatus
    }

    func refresh() {
        accessibility = accessibilityStatus()
        automation = installedTargets().map {
            AutomationRow(target: $0, status: statusForTarget($0.bundleIdentifier))
        }
    }

    /// Asking about a target that is not running returns `procNotFound` without a dialog, so the
    /// app is launched first — the user pressed a button that says "Request", and a request that
    /// quietly does nothing is exactly the behavior #42 is about.
    func request(_ target: AutomationTarget) {
        Task {
            if statusForTarget(target.bundleIdentifier) == .targetNotRunning {
                await Self.launch(target.bundleIdentifier)
            }
            let status = await Task.detached {
                AnswerPermissions.requestAutomation(forBundleIdentifier: target.bundleIdentifier)
            }.value
            automation = automation.map {
                $0.target == target ? AutomationRow(target: target, status: status) : $0
            }
        }
    }

    func requestAccessibility() {
        accessibility = AnswerPermissions.requestAccessibility()
    }

    func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func launch(_ bundleIdentifier: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // Behind the Settings window: this is a permission errand, not a request to switch apps.
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
