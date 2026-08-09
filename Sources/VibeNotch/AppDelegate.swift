@preconcurrency import AppKit
@preconcurrency import DynamicNotchKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let jumper = Jumper()
    private let actions = NotchActions()
    private let settings = AppSettings()
    private let usageProvider = UsageProvider()
    private let actionInjector = ActionInjector()
    private let hoverController = NotchHoverController()
    private var projectsWatcher: ClaudeProjectsWatcher?
    private var spoolWatcher: SpoolWatcher?
    private var notch: DynamicNotch<NotchContentView, CompactLeadingView, CompactTrailingView>?
    private var notifier: SessionNotifier?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: StatusItemController?
    private var autoCollapseTask: Task<Void, Never>?
    private var displayChangeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        _ = try? HookScript.materialize(in: settings.applicationSupportDirectory)
        store.refresh()

        let notch = DynamicNotch(hoverBehavior: [.increaseShadow], style: .auto) {
            NotchContentView(
                store: self.store,
                usageProvider: self.usageProvider,
                settings: self.settings,
                jumper: self.jumper,
                actionInjector: self.actionInjector,
                actions: self.actions
            )
        } compactLeading: {
            CompactLeadingView(store: self.store, actions: self.actions)
        } compactTrailing: {
            CompactTrailingView(store: self.store, actions: self.actions)
        }
        notch.transitionConfiguration.skipIntermediateHides = true
        self.notch = notch

        actions.expandAction = { [weak self] in self?.expandNotch() }
        actions.collapseAction = { [weak self] in self?.collapseNotch() }
        settings.onDisplayModeChange = { [weak self] in self?.applyDisplayMode($0) }

        notifier = SessionNotifier(
            jumper: jumper,
            sessionProvider: { [weak store] id in
                store?.sessions.first { $0.sessionId == id }
            },
            onNeedsAction: { [weak self] in self?.temporarilyExpand() }
        )
        store.onTransition = { [weak self] transition in
            guard let self else { return }
            notifier?.handle(transition, soundsEnabled: settings.soundsEnabled)
        }

        projectsWatcher = ClaudeProjectsWatcher(directoryURL: store.projectsDirectory) { [weak store] in
            Task { @MainActor in store?.refresh() }
        }
        projectsWatcher?.start()

        let eventsDirectory = settings.applicationSupportDirectory
            .appendingPathComponent("events", isDirectory: true)
        spoolWatcher = SpoolWatcher(directoryURL: eventsDirectory) { [weak store] event in
            Task { @MainActor in store?.handle(event) }
        }
        spoolWatcher?.start()

        let settingsWindow = SettingsWindowController(settings: settings)
        self.settingsWindow = settingsWindow
        statusItem = StatusItemController(settings: settings) { [weak settingsWindow] in
            settingsWindow?.show()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        applyDisplayMode(settings.displayMode)
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoCollapseTask?.cancel()
        displayChangeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        projectsWatcher?.stop()
        spoolWatcher?.stop()
        hoverController.stop()
    }

    private func selectedScreen() -> NSScreen? {
        let mainScreen = NSScreen.main
        let screens = NSScreen.screens.map { screen in
            (screen: screen, info: ScreenInfo(screen, mainScreen: mainScreen))
        }
        guard let selected = ScreenInfo.selected(from: screens.map { $0.info }) else { return nil }
        return screens.first(where: { $0.info.id == selected.id })?.screen
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        displayChangeTask?.cancel()
        displayChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            applyDisplayMode(settings.displayMode, forceReposition: true)
        }
    }

    private func applyDisplayMode(_ mode: DisplayMode, forceReposition: Bool = false) {
        switch mode {
        case .hoverOnly:
            hoverController.start(
                notchRect: { [weak self] in
                    guard let screen = self?.selectedScreen() else { return .zero }
                    return NotchHoverController.notchFrame(on: screen)
                },
                screenFrame: { [weak self] in self?.selectedScreen()?.frame ?? .zero },
                expandedFrame: { [weak self] in self?.notch?.windowController?.window?.frame },
                onEnter: { [weak self] in self?.expandNotch() },
                onExit: { [weak self] in
                    Task { @MainActor [weak self] in await self?.notch?.hide() }
                }
            )
            Task { @MainActor [weak notch] in await notch?.hide() }
        case .alwaysShow:
            hoverController.stop()
            Task { @MainActor [weak self, weak notch] in
                guard let self else { return }
                if forceReposition { await notch?.hide() }
                guard settings.displayMode == .alwaysShow,
                      let screen = selectedScreen() else { return }
                if screen.auxiliaryTopLeftArea != nil,
                   screen.auxiliaryTopRightArea != nil {
                    await notch?.compact(on: screen)
                } else {
                    await notch?.expand(on: screen)
                }
            }
        case .hidden:
            hoverController.stop()
            Task { @MainActor [weak notch] in await notch?.hide() }
        }
    }

    private func expandNotch() {
        guard settings.displayMode != .hidden,
              !(settings.displayMode == .hoverOnly && store.sessions.isEmpty) else { return }
        Task { @MainActor [weak self, weak notch] in
            guard let screen = self?.selectedScreen() else { return }
            await notch?.expand(on: screen)
        }
    }

    private func collapseNotch() {
        switch settings.displayMode {
        case .hoverOnly:
            hoverController.resetExpanded()
            Task { @MainActor [weak notch] in await notch?.hide() }
        case .alwaysShow, .hidden:
            applyDisplayMode(settings.displayMode)
        }
    }

    private func temporarilyExpand() {
        guard settings.displayMode != .hidden else { return }
        autoCollapseTask?.cancel()
        expandNotch()
        guard let seconds = settings.dwellTime.seconds else { return }
        autoCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            applyDisplayMode(settings.displayMode)
        }
    }
}

@main
struct VibeNotchApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
