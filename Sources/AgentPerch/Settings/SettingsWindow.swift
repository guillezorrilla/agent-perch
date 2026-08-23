@preconcurrency import AppKit
import SwiftUI

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
            // One size for every tab, taken from the view rather than restated here — a window
            // that resizes as you switch tabs reads as a glitch.
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: SettingsView.windowSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AgentPerch Settings"
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

        // Two speech bubbles: several agents, each with something to say to you. That is what
        // the app is for, so it is what the menu bar shows.
        //
        // An SF Symbol rather than a bundled asset because it is already a template image, so
        // macOS inverts it for a light or dark menu bar without a second copy of the artwork,
        // and it stays sharp on any display.
        //
        // Two glyphs were rejected here for reasons that are not obvious until you render them
        // at 18pt: `circle.inset.filled` echoes the app icon's ring but reads as a record
        // button, and the notch silhouette itself — the obvious choice — collapses into a
        // briefcase, because a notch cutout needs more pixels than a menu bar has.
        statusItem.button?.image = NSImage(
            systemSymbolName: "bubble.left.and.bubble.right.fill",
            accessibilityDescription: "AgentPerch"
        )
        statusItem.button?.toolTip = "AgentPerch"

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
