import Combine
import Foundation
import ServiceManagement
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case hoverOnly
    case alwaysShow
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hoverOnly: "Hover only"
        case .alwaysShow: "Always show"
        case .hidden: "Hidden"
        }
    }
}

/// Which display the panel should render on. `.activeDisplay` tracks `NSScreen.main` — AppKit's
/// name for the screen holding the window with keyboard focus — so it follows the user between
/// displays; the other two policies are stable regardless of focus. See `ScreenInfo.selected`
/// for the actual selection logic and its fallbacks.
enum ScreenChoice: String, CaseIterable, Identifiable {
    case activeDisplay
    case notchDisplay
    case primaryDisplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activeDisplay: "Active display"
        case .notchDisplay: "Notch display"
        case .primaryDisplay: "Primary display"
        }
    }

    var help: String {
        switch self {
        case .activeDisplay: "Follows your focused window between displays."
        case .notchDisplay: "Always the MacBook's built-in display, when connected."
        case .primaryDisplay: "Always the display with the menu bar."
        }
    }
}

enum NeedsActionDwellTime: Int, CaseIterable, Identifiable {
    case off = 0
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10

    var id: Int { rawValue }
    var seconds: Int? { self == .off ? nil : rawValue }

    var label: String {
        self == .off ? "Off" : "\(rawValue)s"
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("displayMode") private var storedDisplayMode: DisplayMode = .hoverOnly
    @AppStorage("screenChoice") private var storedScreenChoice: ScreenChoice = .activeDisplay
    @AppStorage("launchAtLogin") private var storedLaunchAtLogin = false
    @AppStorage("soundsEnabled") private var storedSoundsEnabled = true
    @AppStorage("panelWidth") private var storedPanelWidth = 500.0
    @AppStorage("needsActionDwellTime") private var storedDwellTime = NeedsActionDwellTime.fiveSeconds
    // Keyed identically to what `CodexSessionSource`'s default `showSubAgentSessions` closure
    // reads directly from `UserDefaults.standard` — @AppStorage is backed by that same store,
    // so no plumbing is needed to get this toggle from Settings down to session discovery.
    @AppStorage("showSubAgentSessions") private var storedShowSubAgentSessions = false
    // Same trick, same store, for `AntigravitySessionSource`. Off by default: an Antigravity
    // workspace directory's mtime is not evidence of agent activity, so leaving this on surfaced
    // idle workspaces beside real agent sessions (#27).
    @AppStorage("showAntigravityWorkspaces") private var storedShowAntigravityWorkspaces = false
    // One key holding the whole hidden set, not a Bool per provider — see `UsageVisibility` for
    // why it is stored hidden-rather-than-shown, and why the same key is read directly by
    // `UsageProvider` (#39).
    @AppStorage(UsageVisibility.hiddenKey) private var storedHiddenUsageProviders = ""
    @Published private var installedHooks = false

    let applicationSupportDirectory: URL
    let settingsURL: URL
    var onDisplayModeChange: ((DisplayMode) -> Void)?
    var onScreenChoiceChange: ((ScreenChoice) -> Void)?
    /// The strip is already on screen while Settings is open, and it publishes on its own clock;
    /// this is what makes a toggle land immediately rather than up to two minutes later (#39).
    var onUsageVisibilityChange: (() -> Void)?

    var displayMode: DisplayMode {
        get { storedDisplayMode }
        set {
            guard newValue != storedDisplayMode else { return }
            objectWillChange.send()
            storedDisplayMode = newValue
            onDisplayModeChange?(newValue)
        }
    }

    var screenChoice: ScreenChoice {
        get { storedScreenChoice }
        set {
            guard newValue != storedScreenChoice else { return }
            objectWillChange.send()
            storedScreenChoice = newValue
            onScreenChoiceChange?(newValue)
        }
    }

    var launchAtLogin: Bool {
        get { storedLaunchAtLogin }
        set {
            guard newValue != storedLaunchAtLogin else { return }
            objectWillChange.send()
            storedLaunchAtLogin = newValue
            if newValue {
                if SMAppService.mainApp.status == .notRegistered {
                    try? SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    var soundsEnabled: Bool {
        get { storedSoundsEnabled }
        set {
            guard newValue != storedSoundsEnabled else { return }
            objectWillChange.send()
            storedSoundsEnabled = newValue
        }
    }

    var panelWidth: Double {
        get { min(800, max(440, storedPanelWidth)) }
        set {
            let value = min(800, max(440, newValue))
            guard value != storedPanelWidth else { return }
            objectWillChange.send()
            storedPanelWidth = value
        }
    }

    var dwellTime: NeedsActionDwellTime {
        get { storedDwellTime }
        set {
            guard newValue != storedDwellTime else { return }
            objectWillChange.send()
            storedDwellTime = newValue
        }
    }

    var showSubAgentSessions: Bool {
        get { storedShowSubAgentSessions }
        set {
            guard newValue != storedShowSubAgentSessions else { return }
            objectWillChange.send()
            storedShowSubAgentSessions = newValue
        }
    }

    var showAntigravityWorkspaces: Bool {
        get { storedShowAntigravityWorkspaces }
        set {
            guard newValue != storedShowAntigravityWorkspaces else { return }
            objectWillChange.send()
            storedShowAntigravityWorkspaces = newValue
        }
    }

    /// Providers whose usage row the user has switched off. Membership, not a per-provider flag,
    /// so Settings can render a toggle per registered provider without knowing any of their names
    /// at compile time (#39).
    var hiddenUsageProviders: Set<String> {
        get { UsageVisibility.decode(storedHiddenUsageProviders) }
        set {
            let encoded = UsageVisibility.encode(newValue)
            guard encoded != storedHiddenUsageProviders else { return }
            objectWillChange.send()
            storedHiddenUsageProviders = encoded
            onUsageVisibilityChange?()
        }
    }

    /// Absence means shown: a provider nobody has ever toggled — including one added in a later
    /// version — is visible.
    func showsUsageProvider(_ provider: String) -> Bool {
        !hiddenUsageProviders.contains(provider)
    }

    func setUsageProvider(_ provider: String, shown: Bool) {
        var hidden = hiddenUsageProviders
        if shown { hidden.remove(provider) } else { hidden.insert(provider) }
        hiddenUsageProviders = hidden
    }

    var hooksInstalled: Bool { installedHooks }

    init(
        applicationSupportDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeNotch", isDirectory: true),
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.settingsURL = settingsURL
    }

    func refreshHooksInstalled() {
        installedHooks = HookInstaller(settingsURL: settingsURL).hasInstalledHooks(
            binURL: HookScript.url(in: applicationSupportDirectory)
        )
    }

    func toggleHooks() throws {
        let installer = HookInstaller(settingsURL: settingsURL)
        if installer.hasInstalledHooks(binURL: HookScript.url(in: applicationSupportDirectory)) {
            try installer.uninstall()
        } else {
            try installer.install(binURL: HookScript.url(in: applicationSupportDirectory))
        }
        refreshHooksInstalled()
    }
}
