@preconcurrency import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Handed in from `UsageProvider.registeredProviders` rather than listed here, so a sixth
    /// `UsageSource` gets its toggle without touching this file (#39).
    var usageProviders: [String] = []

    var body: some View {
        Form {
            Section("Island") {
                Picker("Display", selection: Binding(
                    get: { settings.displayMode },
                    set: { settings.displayMode = $0 }
                )) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show on", selection: Binding(
                        get: { settings.screenChoice },
                        set: { settings.screenChoice = $0 }
                    )) {
                        ForEach(ScreenChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.screenChoice.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Panel width")
                    Slider(
                        value: Binding(
                            get: { settings.panelWidth },
                            set: { settings.panelWidth = $0 }
                        ),
                        in: 440...800,
                        step: 20
                    )
                    Text("\(Int(settings.panelWidth)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Picker("Needs-action dwell", selection: Binding(
                    get: { settings.dwellTime },
                    set: { settings.dwellTime = $0 }
                )) {
                    ForEach(NeedsActionDwellTime.allCases) { dwell in
                        Text(dwell.label).tag(dwell)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Empty only in a preview or a test rig; an empty `Section` would still draw its box.
            if !usageProviders.isEmpty {
                Section("Usage") {
                    // One toggle per row rather than the VStack the single-toggle sections below
                    // use: five of them in a stack would leave the switches ragged instead of
                    // aligned down the Form's own right edge.
                    ForEach(usageProviders, id: \.self) { provider in
                        Toggle(provider, isOn: Binding(
                            get: { settings.showsUsageProvider(provider) },
                            set: { settings.setUsageProvider(provider, shown: $0) }
                        ))
                    }
                    Text("Which providers get a row in the usage strip above the session list. Antigravity takes two lines on its own — switching rows off is how you get that panel height back. A provider you switch off is not polled at all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                Toggle("Sounds", isOn: Binding(
                    get: { settings.soundsEnabled },
                    set: { settings.soundsEnabled = $0 }
                ))
            }

            Section("Codex") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show sub-agent sessions", isOn: Binding(
                        get: { settings.showSubAgentSessions },
                        set: { settings.showSubAgentSessions = $0 }
                    ))
                    Text("Also show Codex sessions spawned by another agent or IDE, or by Codex itself — not just the ones you started yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Antigravity") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Antigravity workspaces", isOn: Binding(
                        get: { settings.showAntigravityWorkspaces },
                        set: { settings.showAntigravityWorkspaces = $0 }
                    ))
                    Text("Shows recently-opened Antigravity IDE workspaces — not agent sessions, since Antigravity keeps no per-agent state on disk. Off by default. Antigravity CLI (agy) sessions are always shown, regardless of this setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cursor") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Cursor workspaces", isOn: Binding(
                        get: { settings.showCursorWorkspaces },
                        set: { settings.showCursorWorkspaces = $0 }
                    ))
                    Text("Shows recently-opened Cursor workspaces — not agent sessions, since Cursor keeps its chat state in a format this app doesn't read. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Claude hooks") {
                HStack {
                    Circle()
                        .fill(settings.hooksInstalled ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(settings.hooksInstalled ? "Claude hooks installed" : "Claude hooks not installed")
                    Spacer()
                    Button(settings.hooksInstalled ? "Uninstall" : "Install") {
                        try? settings.toggleHooks()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        // Taller than it was: the Usage section adds a row per provider. The grouped Form still
        // scrolls, so this only decides how much is visible without scrolling (#39).
        .frame(width: 500, height: 680)
    }
}

@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private let usageProviders: [String]
    private var window: NSWindow?

    init(settings: AppSettings, usageProviders: [String] = []) {
        self.settings = settings
        self.usageProviders = usageProviders
    }

    func show() {
        settings.refreshHooksInstalled()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "VibeNotch Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView(settings: settings, usageProviders: usageProviders)
            )
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hooksItem = NSMenuItem()

    init(settings: AppSettings, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.openSettings = openSettings
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "VibeNotch")
        statusItem.button?.toolTip = "VibeNotch"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Settings…", action: #selector(showSettings), keyEquivalent: ",")
            .target = self
        hooksItem.action = #selector(toggleHooks)
        hooksItem.target = self
        menu.addItem(hooksItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
            .target = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        settings.refreshHooksInstalled()
        hooksItem.title = settings.hooksInstalled
            ? "Uninstall Claude hooks"
            : "Install Claude hooks"
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func toggleHooks() {
        try? settings.toggleHooks()
        hooksItem.title = settings.hooksInstalled
            ? "Uninstall Claude hooks"
            : "Install Claude hooks"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
