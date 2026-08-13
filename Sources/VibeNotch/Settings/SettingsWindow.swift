@preconcurrency import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Owned by the window controller, not by this view: the window is built once and reused, so
    /// re-reading the statuses has to happen on every `show()` — a grant changed in System Settings
    /// while this was closed must not still read as missing (#42).
    @ObservedObject var permissions: AnswerPermissionsModel
    /// Owned by the app delegate, which also runs its daily loop — this view only reads the
    /// state and offers the two buttons (#75).
    @ObservedObject var updates: UpdateChecker
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

            Section("Updates") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Version \(UpdateCheck.currentVersion)")
                        Text(updates.state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let version = updates.state.newVersion {
                            Button("Download \(version)…") { updates.openReleasesPage() }
                        } else {
                            Button("Check now") { updates.checkNow() }
                                .disabled(updates.state == .checking)
                        }
                    }
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { settings.checkForUpdates },
                        set: { settings.checkForUpdates = $0 }
                    ))
                    Text("VibeNotch points you at the download; it never replaces itself. Swapping the app bundle out from under macOS revokes the Accessibility and app-data grants, which would leave cards appearing while answers silently stopped landing — so the last step of an update is yours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            // Gathered here, up front, precisely so nothing has to be asked for at the moment a
            // permission card is on screen — see `AnswerPermissions` (#42). Reading a status never
            // prompts; only the buttons do.
            Section("Answering") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Types into Warp, Ghostty and cmux, the terminals with no scripting command for text. "
                        + "macOS only reports whether this is on — never whether it was refused.",
                    status: permissions.accessibility,
                    request: { permissions.requestAccessibility() },
                    openSettings: { permissions.open(AnswerPermissions.accessibilityPane) }
                )

                ForEach(permissions.automation) { row in
                    permissionRow(
                        title: "Automation · \(row.target.name)",
                        detail: row.target.purpose,
                        status: row.status,
                        request: { permissions.request(row.target) },
                        openSettings: { permissions.open(AnswerPermissions.automationPane) }
                    )
                }

                Text("\(AnswerPermissions.permissionlessTerminals.joined(separator: ", ")) need no permission — "
                    + "each takes the answer through its own command line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        // Taller than it was: the Usage section adds a row per provider (#39), Answering adds
        // one per permission target (#42), and Updates adds a fixed two (#75). The grouped Form
        // still scrolls, so this only decides how much is visible without scrolling.
        .frame(width: 500, height: 780)
    }

    /// The same circle/label/button shape as the "Claude hooks" row above, with the status text
    /// carrying the one thing that row never has to say: what to do when macOS will not re-ask.
    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        status: PermissionStatus,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(status.isGranted ? Color.green : (status == .denied ? Color.red : Color.gray))
                    .frame(width: 8, height: 8)
                Text(title)
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let action = status.action {
                    Button(action.title) {
                        switch action {
                        case .request: request()
                        case .openSystemSettings: openSettings()
                        }
                    }
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private let permissions = AnswerPermissionsModel()
    private let updates: UpdateChecker
    private let usageProviders: [String]
    private var window: NSWindow?

    init(settings: AppSettings, updates: UpdateChecker, usageProviders: [String] = []) {
        self.settings = settings
        self.updates = updates
        self.usageProviders = usageProviders
    }

    func show() {
        settings.refreshHooksInstalled()
        // Silent — every status here is read with the no-prompt API, which is what makes it safe
        // to do on every open rather than at the moment an answer is needed (#42).
        permissions.refresh()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 780),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "VibeNotch Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView(
                    settings: settings,
                    permissions: permissions,
                    updates: updates,
                    usageProviders: usageProviders
                )
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

        // The app icon's mark — a ring around a filled centre — rather than generic sparkles.
        // An SF Symbol instead of a bundled asset because it is already a template image, so
        // macOS inverts it for a light or dark menu bar without a second copy of the artwork,
        // and it stays sharp on any display. `circle.inset.filled` is the closest match to the
        // icon at 18pt; the alternatives put too small a dot in the middle to read.
        statusItem.button?.image = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "VibeNotch")
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
