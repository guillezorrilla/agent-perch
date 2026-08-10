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
    private let cardShortcuts = CardShortcutMonitor()
    private var projectsWatcher: ClaudeProjectsWatcher?
    private var spoolWatcher: SpoolWatcher?
    private var notch: DynamicNotch<NotchContentView, CompactLeadingView, CompactTrailingView>?
    private var notifier: SessionNotifier?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: StatusItemController?
    private var autoCollapseTask: Task<Void, Never>?
    private var displayChangeTask: Task<Void, Never>?
    /// Geometry the current mode was applied for. `didChangeScreenParameters` also fires for
    /// wallpaper, Space and menu-bar changes; re-applying on those would restart the hover
    /// controller under the user's cursor for nothing.
    private var lastAppliedScreen: ScreenInfo?
    /// What we last asked DynamicNotchKit to do. Its own `state` is package-internal, and we
    /// need to know whether a leftover panel is live before ordering it out.
    private var notchIsVisible = false
    /// The screen a `.activeDisplay` reposition is already debounced towards. Makes the hover-tick
    /// watcher edge-triggered: a focus change that persists across many ticks (10/sec) schedules
    /// exactly one reposition instead of restarting the debounce every 100ms and never firing.
    private var pendingActiveScreen: ScreenInfo?

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
                actions: self.actions,
                shortcuts: self.cardShortcuts
            )
        } compactLeading: {
            CompactLeadingView(store: self.store, actions: self.actions)
        } compactTrailing: {
            CompactTrailingView(store: self.store, actions: self.actions)
        }
        notch.transitionConfiguration.skipIntermediateHides = true
        self.notch = notch

        actions.expandAction = { [weak self] in self?.expandOnDemand() }
        actions.hoverExpandAction = { [weak self] in self?.expandOnHover() }
        actions.collapseAction = { [weak self] in self?.collapseNotch() }
        settings.onDisplayModeChange = { [weak self] in self?.applyDisplayMode($0) }
        settings.onScreenChoiceChange = { [weak self] _ in
            guard let self else { return }
            applyDisplayMode(settings.displayMode, forceReposition: true)
        }

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
        cardShortcuts.stop()
    }

    private func selectedScreenPair() -> (screen: NSScreen, info: ScreenInfo)? {
        let mainScreen = NSScreen.main
        let screens = NSScreen.screens.map { screen in
            (screen: screen, info: ScreenInfo(screen, mainScreen: mainScreen))
        }
        guard let selected = ScreenInfo.selected(from: screens.map { $0.info }, choice: settings.screenChoice)
        else { return nil }
        return screens.first { $0.info.id == selected.id }
    }

    private func selectedScreen() -> NSScreen? { selectedScreenPair()?.screen }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        displayChangeTask?.cancel()
        displayChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            defer { discardStrayPanel() }
            // Spurious notifications (wallpaper, Spaces, menu-bar autohide) must not restart
            // the hover controller: that is a collapse and re-expand under the cursor. But
            // DynamicNotchKit rebuilds its panel on `NSScreen.screens.first` on EVERY such
            // notification (DynamicNotch.swift:144-153), regardless of the screen we picked,
            // so a no-op notification can still strand a visible panel on the wrong display.
            let strandedOnWrongScreen = notchIsVisible
                && notch?.windowController?.window?.screen !== selectedScreen()
            guard selectedScreenPair()?.info != lastAppliedScreen || strandedOnWrongScreen else {
                return
            }
            applyDisplayMode(settings.displayMode, forceReposition: true)
        }
    }

    /// DynamicNotchKit rebuilds its NSPanel on every screen-parameter change, including while
    /// it is hidden (DynamicNotch.swift:144-153), and its `hide()` early-returns in the hidden
    /// state — so the rebuilt panel would sit at `.screenSaver` level forever, swallowing
    /// clicks over the notch. The public `windowController` is the only handle we get on it.
    private func discardStrayPanel() {
        guard !notchIsVisible else { return }
        notch?.windowController?.window?.orderOut(nil)
    }

    private func applyDisplayMode(_ mode: DisplayMode, forceReposition: Bool = false) {
        lastAppliedScreen = selectedScreenPair()?.info
        // A mode change outranks a dwell armed under the previous mode, which would otherwise
        // fire later and drive the panel from a mode that no longer applies.
        autoCollapseTask?.cancel()
        guard mode != .hidden else {
            hoverController.stop()
            hideNotch()
            return
        }
        startHoverController()
        // A mode re-apply must be invisible to someone who is already hovering: reconstruct
        // the hover state from where the cursor actually is instead of resetting it, and let
        // the hover controller do the closing when the cursor leaves. It still has to honour
        // `forceReposition` — `expand()` early-returns when already expanded, so without it a
        // panel open under the cursor would stay on the display it was born on.
        if hoverController.isMouseInside(), expandNotch(repositioning: forceReposition) {
            hoverController.adoptExternalExpansion()
            return
        }
        restToBaseState(forceReposition: forceReposition)
    }

    /// Hover drives visibility in BOTH visible modes: `.hoverOnly` rests hidden, `.alwaysShow`
    /// rests compact, and in each case the cursor entering the notch expands and the cursor
    /// leaving the notch∪panel returns to that resting state. One owner, one answer.
    private func startHoverController() {
        hoverController.start(
            notchRect: { [weak self] in
                guard let screen = self?.selectedScreen() else { return .zero }
                return NotchHoverController.notchFrame(on: screen)
            },
            screenFrame: { [weak self] in self?.selectedScreen()?.frame ?? .zero },
            // DynamicNotchKit's own hover truth: SwiftUI `.onHover` over the rendered panel,
            // set only while it is visible. Correct in any coordinate space, on any screen, in
            // both the notch and floating (clamshell) styles — which a re-derived rect was not.
            panelHovered: { [weak self] in self?.notch?.isHovering ?? false },
            onEnter: { [weak self] in self?.expandNotch() ?? false },
            onExit: { [weak self] in self?.restToBaseState() },
            onTick: { [weak self] in self?.checkActiveDisplayFollow() }
        )
    }

    /// `.activeDisplay` follows `NSScreen.main`, which changes silently as keyboard focus moves
    /// between displays — plugging/unplugging a monitor fires `didChangeScreenParametersNotification`,
    /// moving focus to another screen's window does not. The hover poll (10/sec, running whenever
    /// a mode is active) is the only thing already ticking often enough to notice, so this
    /// piggybacks on it rather than adding a second timer. Debounced ~400ms so a cursor merely
    /// passing over another display's window mid-move doesn't thrash the panel.
    private func checkActiveDisplayFollow() {
        guard settings.screenChoice == .activeDisplay, settings.displayMode != .hidden else { return }
        let current = selectedScreenPair()?.info
        guard current != lastAppliedScreen, current != pendingActiveScreen else { return }
        pendingActiveScreen = current
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            defer { self.pendingActiveScreen = nil }
            guard !Task.isCancelled,
                  current == selectedScreenPair()?.info,
                  current != lastAppliedScreen else { return }
            applyDisplayMode(settings.displayMode, forceReposition: true)
            discardStrayPanel()
        }
    }

    /// The mode's resting appearance, with hover state cleared to match. Hover exit, dwell
    /// expiry and mode re-applies all land here — never on a bare `hide()` that would leave
    /// the controller believing the panel is still open.
    private func restToBaseState(forceReposition: Bool = false) {
        hoverController.resetExpanded()
        switch settings.displayMode {
        case .hoverOnly, .hidden:
            hideNotch()
        case .alwaysShow:
            showBaseState(forceReposition: forceReposition)
        }
    }

    /// `.alwaysShow`'s resting appearance: compact beside the physical notch, or fully expanded
    /// on a display without one — DynamicNotchKit's floating style has no compact state and
    /// hides instead (DynamicNotch.swift:226-229).
    private func showBaseState(forceReposition: Bool) {
        guard settings.displayMode == .alwaysShow, let screen = selectedScreen() else { return }
        notchIsVisible = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if forceReposition { await repositionIfNeeded(on: screen) }
            guard settings.displayMode == .alwaysShow else { return }
            if screen.auxiliaryTopLeftArea != nil,
               screen.auxiliaryTopRightArea != nil {
                await notch?.compact(on: screen)
            } else {
                await notch?.expand(on: screen)
            }
        }
    }

    /// `expand()` and `compact()` early-return when the state already matches, so a panel that
    /// is already open never moves to a new display on its own. Hiding first forces the rebuild.
    ///
    /// The hide is deliberately NOT awaited: `hide()` resumes its continuation from a task that
    /// `expand()`/`compact()` cancel (DynamicNotch.swift:180, 236, 306), so awaiting it strands
    /// this function forever if a hover tick expands mid-close — which is exactly what happens
    /// on a display change under the cursor. `_hide` flips the state synchronously, which is
    /// all the rebuild needs; the sleep only lets the close animation get out of the way.
    private func repositionIfNeeded(on screen: NSScreen) async {
        guard notch?.windowController?.window?.screen !== screen else { return }
        Task { @MainActor [weak self] in await self?.notch?.hide() }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// - Returns: whether the panel will actually open. The hover controller rolls its state
    ///   back on `false`, so it retries on the next tick rather than latching a lie.
    @discardableResult
    private func expandNotch(repositioning: Bool = false) -> Bool {
        guard settings.displayMode != .hidden,
              !(settings.displayMode == .hoverOnly && store.sessions.isEmpty),
              let screen = selectedScreen() else { return false }
        notchIsVisible = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if repositioning { await repositionIfNeeded(on: screen) }
            // The mode is read synchronously above but the expand lands a hop later; re-check
            // so a switch to `.hidden` in between can't be overtaken by a stale expand.
            guard settings.displayMode != .hidden else { return }
            await notch?.expand(on: screen)
        }
        return true
    }

    private func hideNotch() {
        notchIsVisible = false
        Task { @MainActor [weak self] in await self?.notch?.hide() }
    }

    /// Expansion requested by a tap or a hover on the compact views, which sit outside the
    /// notch rect. Adopting it hands ownership to the hover controller, so leaving closes it.
    private func expandOnDemand() {
        guard expandNotch() else { return }
        hoverController.adoptExternalExpansion()
    }

    /// Same, but declines while a dismissal is latched. `adoptExternalExpansion()` clears that
    /// latch, so without this guard the compact view reappearing under a stationary cursor
    /// would fire `.onHover(true)` and re-open the panel the user just dismissed.
    private func expandOnHover() {
        guard !hoverController.isSuppressed else { return }
        expandOnDemand()
    }

    /// A close the user asked for: a jump, a permission decision, or the last session ending.
    /// Latch hover shut so the next poll tick doesn't re-open the panel under a cursor that
    /// never left the notch, and drop any pending needs-action dwell.
    private func collapseNotch() {
        autoCollapseTask?.cancel()
        hoverController.suppressUntilExit()
        switch settings.displayMode {
        case .hoverOnly, .hidden:
            hideNotch()
        case .alwaysShow:
            showBaseState(forceReposition: false)
        }
    }

    private func temporarilyExpand() {
        guard settings.displayMode != .hidden else { return }
        autoCollapseTask?.cancel()
        guard expandNotch() else { return }
        hoverController.adoptExternalExpansion()
        guard settings.dwellTime.seconds != nil else { return }
        autoCollapseTask = Task { @MainActor [weak self] in
            repeat {
                // Re-read each pass so changing the setting mid-dwell takes effect, and so
                // switching it to Off leaves the panel up rather than closing on a stale value.
                guard let seconds = self?.settings.dwellTime.seconds else { return }
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                // Hook events arrive continuously while an agent works, so this timer fires
                // constantly. Collapsing on it while the cursor is in the panel is the whole
                // difference between a stable panel and a five-second flicker — wait instead.
                guard hoverController.isMouseInside() else {
                    restToBaseState()
                    return
                }
            } while !Task.isCancelled
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
