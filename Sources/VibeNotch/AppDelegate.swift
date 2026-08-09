@preconcurrency import AppKit
@preconcurrency import DynamicNotchKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let jumper = Jumper()
    private let actions = NotchActions()
    private var watcher: ClaudeProjectsWatcher?
    private var notch: DynamicNotch<NotchContentView, CompactStatusView, EmptyView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        store.refresh()

        let notch = DynamicNotch(hoverBehavior: [.keepVisible, .increaseShadow]) {
            NotchContentView(store: self.store, jumper: self.jumper, actions: self.actions)
        } compactLeading: {
            CompactStatusView(store: self.store, actions: self.actions)
        } compactTrailing: {
            EmptyView()
        }
        self.notch = notch

        actions.expandAction = { [weak notch] in
            Task { @MainActor in await notch?.expand() }
        }
        actions.collapseAction = { [weak notch] in
            let screen = NSScreen.screens[0]
            guard screen.auxiliaryTopLeftArea != nil,
                  screen.auxiliaryTopRightArea != nil else { return }
            Task { @MainActor in await notch?.compact(on: screen) }
        }

        watcher = ClaudeProjectsWatcher(directoryURL: store.projectsDirectory) { [weak store] in
            Task { @MainActor in store?.refresh() }
        }
        watcher?.start()

        let screen = NSScreen.screens[0]
        let hasNotch = screen.auxiliaryTopLeftArea != nil
            && screen.auxiliaryTopRightArea != nil
        Task { @MainActor in
            if hasNotch {
                await notch.compact(on: screen)
            } else {
                await notch.expand(on: screen)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
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
