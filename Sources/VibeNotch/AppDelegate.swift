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
    private let trackingWindow = NotchTrackingWindow()
    private var projectsWatcher: ClaudeProjectsWatcher?
    private var spoolWatcher: SpoolWatcher?
    private var notch: DynamicNotch<NotchContentView, CompactLeadingView, CompactTrailingView>?
    private var notifier: SessionNotifier?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: StatusItemController?
    private var autoCollapseTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        _ = try? HookScript.materialize(in: settings.applicationSupportDirectory)
        store.refresh()

        let screenHasNotch = NSScreen.screens.first.map {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        } ?? true
        let style: DynamicNotchStyle = screenHasNotch
            ? .notch(topCornerRadius: 15, bottomCornerRadius: 24)
            : .floating(cornerRadius: 24)
        let notch = DynamicNotch(hoverBehavior: [.increaseShadow], style: style) {
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

        applyDisplayMode(settings.displayMode)
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoCollapseTask?.cancel()
        projectsWatcher?.stop()
        spoolWatcher?.stop()
        trackingWindow.hide()
    }

    private func applyDisplayMode(_ mode: DisplayMode) {
        guard let screen = NSScreen.screens.first else { return }
        switch mode {
        case .hoverOnly:
            trackingWindow.show(
                on: screen,
                onEnter: { [weak self] in self?.expandNotch() },
                onExit: { [weak self] in self?.hideAfterTrackingExit() }
            )
            Task { @MainActor [weak notch] in await notch?.hide() }
        case .alwaysShow:
            trackingWindow.hide()
            Task { @MainActor [weak notch] in
                if screen.auxiliaryTopLeftArea != nil,
                   screen.auxiliaryTopRightArea != nil {
                    await notch?.compact(on: screen)
                } else {
                    await notch?.expand(on: screen)
                }
            }
        case .hidden:
            trackingWindow.hide()
            Task { @MainActor [weak notch] in await notch?.hide() }
        }
    }

    private func expandNotch() {
        guard settings.displayMode != .hidden,
              !(settings.displayMode == .hoverOnly && store.sessions.isEmpty),
              let screen = NSScreen.screens.first else { return }
        Task { @MainActor [weak notch] in await notch?.expand(on: screen) }
    }

    private func collapseNotch() {
        applyDisplayMode(settings.displayMode)
    }

    private func hideAfterTrackingExit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, settings.displayMode == .hoverOnly else { return }
            if let frame = notch?.windowController?.window?.frame,
               frame.contains(NSEvent.mouseLocation) {
                return
            }
            Task { @MainActor [weak notch] in await notch?.hide() }
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
