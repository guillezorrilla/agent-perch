import SwiftUI

/// Settings, split across tabs rather than stacked in one long scroll.
///
/// The single `Form` this replaced had grown to nine sections and 780pt of height: the
/// permission rows that matter when answering breaks were below the fold, under three
/// near-identical per-agent toggles. Tabs are the native macOS answer and they let each area
/// be read on its own.
///
/// The window is a fixed size across every tab on purpose. A `TabView` that resizes to its
/// content makes the window jump each time you switch, which reads as a glitch rather than as
/// a feature.
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

    static let windowSize = CGSize(width: 540, height: 562)

    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettings(settings: settings)
        case .island: IslandSettings(settings: settings)
        case .agents: AgentSettings(settings: settings, usageProviders: usageProviders)
        case .answering: AnsweringSettings(permissions: permissions)
        case .updates: UpdateSettings(settings: settings, updates: updates)
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, island, agents, answering, updates

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .island: "Island"
        case .agents: "Agents"
        case .answering: "Answering"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .island: "macbook.gen2"
        case .agents: "square.stack.3d.up"
        case .answering: "keyboard"
        case .updates: "arrow.down.circle"
        }
    }
}

/// Drawn here rather than left to `TabView`.
///
/// SwiftUI's macOS `TabView` hoists its tab strip into the window's toolbar, so hosted in the
/// plain `NSWindow` this app uses it renders the first tab's content and no tabs at all —
/// verified by dumping the view hierarchy, which contains no tab view of any kind. Adding a
/// toolbar to chase that behaviour would tie the window's appearance to a SwiftUI internal
/// that has already changed across macOS releases. Thirty lines that always draw are cheaper.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 16, weight: .regular))
                            .frame(height: 20)
                        Text(tab.label)
                            .font(.system(size: 11))
                    }
                    .frame(width: 78, height: 48)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == tab ? Color.primary.opacity(0.1) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == tab ? Color.accentColor : Color.primary)
                .help(tab.label)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                Toggle("Play sounds", isOn: Binding(
                    get: { settings.soundsEnabled },
                    set: { settings.soundsEnabled = $0 }
                ))
            } footer: {
                Caption("A sound plays when an agent needs you, and when one finishes.")
            }

            Section("Live status for Claude Code") {
                StatusRow(
                    isOn: settings.hooksInstalled,
                    title: settings.hooksInstalled ? "Hooks installed" : "Hooks not installed",
                    buttonTitle: settings.hooksInstalled ? "Uninstall" : "Install",
                    action: { try? settings.toggleHooks() }
                )
                Caption("Without hooks, cards come from transcript files and lag behind. With them you get "
                    + "live status, the current tool, token counts and the answer shortcuts.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Island

struct IslandSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Show the panel", selection: Binding(
                    get: { settings.displayMode },
                    set: { settings.displayMode = $0 }
                )) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("On which display", selection: Binding(
                    get: { settings.screenChoice },
                    set: { settings.screenChoice = $0 }
                )) {
                    ForEach(ScreenChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                Caption(settings.screenChoice.help)
            }

            Section {
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

                Picker("Hold open for", selection: Binding(
                    get: { settings.dwellTime },
                    set: { settings.dwellTime = $0 }
                )) {
                    ForEach(NeedsActionDwellTime.allCases) { dwell in
                        Text(dwell.label).tag(dwell)
                    }
                }
                .pickerStyle(.segmented)
                Caption("How long the panel stays open after an agent asks for something. It never closes "
                    + "while your cursor is inside it, or while a card is still waiting on an answer.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Agents

struct AgentSettings: View {
    @ObservedObject var settings: AppSettings
    var usageProviders: [String]

    var body: some View {
        Form {
            // Three toggles that used to be three separate sections saying almost the same
            // thing. They are one list because they are one decision: whether to show folders
            // an IDE merely touched alongside sessions an agent is actually running.
            Section("Show more than live sessions") {
                Toggle("Codex sub-agent sessions", isOn: Binding(
                    get: { settings.showSubAgentSessions },
                    set: { settings.showSubAgentSessions = $0 }
                ))
                Toggle("Antigravity workspaces", isOn: Binding(
                    get: { settings.showAntigravityWorkspaces },
                    set: { settings.showAntigravityWorkspaces = $0 }
                ))
                Toggle("Cursor workspaces", isOn: Binding(
                    get: { settings.showCursorWorkspaces },
                    set: { settings.showCursorWorkspaces = $0 }
                ))
                Caption("Workspaces are folders an IDE opened recently — not evidence an agent is running "
                    + "in them, which is why they are off by default. Antigravity CLI sessions are always "
                    + "shown regardless.")
            }

            if !usageProviders.isEmpty {
                Section("Quota shown in the strip") {
                    ForEach(usageProviders, id: \.self) { provider in
                        Toggle(provider, isOn: Binding(
                            get: { settings.showsUsageProvider(provider) },
                            set: { settings.setUsageProvider(provider, shown: $0) }
                        ))
                    }
                    Caption("A provider switched off is not polled at all. Antigravity takes two lines on "
                        + "its own, so switching it off is how you get that panel height back.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Answering

struct AnsweringSettings: View {
    @ObservedObject var permissions: AnswerPermissionsModel

    var body: some View {
        Form {
            // Gathered here, up front, precisely so nothing has to be asked for at the moment a
            // permission card is on screen — see `AnswerPermissions` (#42). Reading a status never
            // prompts; only the buttons do.
            Section {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Types into Warp, Ghostty and cmux — the terminals with no scripting command "
                        + "for text. macOS only reports whether this is on, never whether it was refused.",
                    status: permissions.accessibility,
                    request: { permissions.requestAccessibility() },
                    openSettings: { permissions.open(AnswerPermissions.accessibilityPane) }
                )
            } footer: {
                Caption("Nothing is ever requested while a card is on screen. These are asked for here, "
                    + "in advance, so answering never stalls on a permission dialog.")
            }

            if !permissions.automation.isEmpty {
                Section("Automation") {
                    ForEach(permissions.automation) { row in
                        PermissionRow(
                            title: row.target.name,
                            detail: row.target.purpose,
                            status: row.status,
                            request: { permissions.request(row.target) },
                            openSettings: { permissions.open(AnswerPermissions.automationPane) }
                        )
                    }
                }
            }

            Section {
                Caption("\(AnswerPermissions.permissionlessTerminals.joined(separator: ", ")) need no "
                    + "permission at all — each takes the answer through its own command line.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

struct UpdateSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AgentPerch \(UpdateCheck.currentVersion)")
                        Text(updates.state.label)
                            .font(.caption)
                            .foregroundStyle(updates.state.newVersion == nil ? .secondary : .primary)
                    }
                    Spacer()
                    if let version = updates.state.newVersion {
                        Button("Get \(version)…") { updates.openReleasesPage() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Check now") { updates.checkNow() }
                            .disabled(updates.state == .checking)
                    }
                }

                Toggle("Check automatically", isOn: Binding(
                    get: { settings.checkForUpdates },
                    set: { settings.checkForUpdates = $0 }
                ))
            } footer: {
                Caption("AgentPerch points you at the download; it never replaces itself. Swapping the app "
                    + "bundle out from under macOS revokes the Accessibility and app-data grants, which "
                    + "would leave cards appearing while answers silently stopped landing — so the last "
                    + "step of an update is yours.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared pieces

/// Explanatory text under a control. One shape for all of it, so no section invents its own.
private struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A coloured dot, a label and a button — the shape both the hooks row and every permission
/// row use, because to a reader they are the same thing: something either is set up or is not,
/// and there is one button that changes it.
private struct StatusRow: View {
    let isOn: Bool
    let title: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Button(buttonTitle, action: action)
        }
    }
}

/// The same shape as `StatusRow`, plus the one thing a hooks row never has to say: what to do
/// when macOS will not re-ask. A recorded "Don't Allow" can only be undone in System Settings,
/// so a denied row offers that instead of a Request button that would quietly do nothing.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionStatus
    let request: () -> Void
    let openSettings: () -> Void

    private var dotColor: Color {
        switch status {
        case .granted: .green
        case .denied: .red
        default: Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(dotColor)
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
            Caption(detail)
        }
    }
}
