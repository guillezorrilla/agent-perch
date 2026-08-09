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
    @AppStorage("launchAtLogin") private var storedLaunchAtLogin = false
    @AppStorage("soundsEnabled") private var storedSoundsEnabled = true
    @AppStorage("panelWidth") private var storedPanelWidth = 500.0
    @AppStorage("needsActionDwellTime") private var storedDwellTime = NeedsActionDwellTime.fiveSeconds
    @Published private var installedHooks = false

    let applicationSupportDirectory: URL
    let settingsURL: URL
    var onDisplayModeChange: ((DisplayMode) -> Void)?

    var displayMode: DisplayMode {
        get { storedDisplayMode }
        set {
            guard newValue != storedDisplayMode else { return }
            objectWillChange.send()
            storedDisplayMode = newValue
            onDisplayModeChange?(newValue)
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
