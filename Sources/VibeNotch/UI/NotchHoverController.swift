@preconcurrency import AppKit

struct ScreenInfo: Equatable {
    let id: CGDirectDisplayID
    let frame: NSRect
    let hasNotch: Bool
    let isMain: Bool

    init(id: CGDirectDisplayID, frame: NSRect, hasNotch: Bool, isMain: Bool) {
        self.id = id
        self.frame = frame
        self.hasNotch = hasNotch
        self.isMain = isMain
    }

    init(_ screen: NSScreen, mainScreen: NSScreen?) {
        let displayID = Self.displayID(for: screen)
        id = displayID
        frame = screen.frame
        hasNotch = screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        isMain = mainScreen.map { Self.displayID(for: $0) == displayID } ?? false
    }

    static func selected(from screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first(where: \ScreenInfo.hasNotch) ?? screens.first(where: \ScreenInfo.isMain)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
            ?? CGDirectDisplayID(truncatingIfNeeded: screen.hash)
    }
}

// Poll-based hover with hysteresis, and the SINGLE owner of panel visibility while a display
// mode is active. An NSTrackingArea on the bare notch rect thrashes: expanding the panel
// downward moves the cursor out of the notch rect, firing exit -> collapse -> cursor back in
// notch -> enter, forever. Here the "hot zone" is the notch UNION the visible panel area, and
// collapse only fires after the cursor is truly outside it for `exitGrace`, so moving between
// notch and panel never flickers.
//
// Everything else that wants the panel open or shut goes through this state machine too, so
// there is exactly one answer to "should the panel be visible right now":
//   * the user dismissing it (jump, permission decision) -> `dismiss()`, latched until exit
//   * a needs-action alert opening it -> `adoptExternalExpansion()`, hover takes over on entry
//   * a mode re-apply -> reconstructed from the cursor, never a blind reset
@MainActor
final class NotchHoverController {
    struct State: Equatable {
        var expanded = false
        var outsideSince: TimeInterval?
        /// Set when the panel closed because the user asked it to. Without it the next poll
        /// tick re-opens the panel under a cursor that never left the notch — a dismissal that
        /// undoes itself 100ms later.
        var suppressedUntilExit = false
        /// Set when something other than hover opened the panel (a needs-action alert). The
        /// cursor is usually nowhere near the notch then, so the exit grace would close the
        /// alert 0.35s after it appeared. Hover only takes ownership once the cursor visits.
        var awaitingFirstEntry = false

        /// Forget the expansion without latching — for closes that aren't the user dismissing
        /// the panel (dwell expiry with the cursor away, a mode re-apply).
        mutating func forgetExpansion() {
            expanded = false
            outsideSince = nil
            awaitingFirstEntry = false
        }

        /// The user dismissed the panel: stay shut until the cursor actually leaves.
        mutating func dismiss() {
            forgetExpansion()
            suppressedUntilExit = true
        }

        /// Adopt an expansion hover didn't cause, so the open panel counts as part of the hot
        /// zone and hovering it keeps it open.
        mutating func adoptExternalExpansion() {
            expanded = true
            outsideSince = nil
            suppressedUntilExit = false
            awaitingFirstEntry = true
        }
    }

    enum Effect: Equatable {
        case none
        case expand
        case collapse
    }

    nonisolated static let defaultExitGrace: TimeInterval = 0.20
    private nonisolated static let panelBottomOverreach: CGFloat = 180
    private nonisolated static let minimumPanelHeight: CGFloat = 120

    // Pure state machine — the bug-prone part, unit-tested in isolation.
    nonisolated static func step(
        _ state: inout State,
        mouseInside: Bool,
        now: TimeInterval,
        exitGrace: TimeInterval
    ) -> Effect {
        if mouseInside {
            state.outsideSince = nil
            state.awaitingFirstEntry = false
            guard !state.suppressedUntilExit, !state.expanded else { return .none }
            state.expanded = true
            return .expand
        }
        // Leaving the hot zone clears the dismissal latch: the next deliberate hover may open.
        state.suppressedUntilExit = false
        guard state.expanded, !state.awaitingFirstEntry else { return .none }
        guard let since = state.outsideSince else {
            state.outsideSince = now
            return .none
        }
        guard now - since >= exitGrace else { return .none }
        state.expanded = false
        state.outsideSince = nil
        return .collapse
    }

    nonisolated static func hotZone(
        notchRect: NSRect,
        panelRect: NSRect?,
        screenFrame: NSRect,
        expanded: Bool
    ) -> NSRect {
        guard !screenFrame.isEmpty, !notchRect.isEmpty else { return .zero }
        let notchRect = notchRect.intersection(screenFrame)
        guard !notchRect.isEmpty,
              expanded,
              let panelRect,
              !panelRect.isEmpty,
              panelRect.intersects(screenFrame) else { return notchRect }
        return notchRect.union(panelRect.intersection(screenFrame))
    }

    nonisolated static func visiblePanelRect(
        screenFrame: NSRect,
        panelWidth: CGFloat,
        dnkFrame: NSRect?,
        notchRect: NSRect
    ) -> NSRect? {
        let notchRect = notchRect.intersection(screenFrame)
        guard !screenFrame.isEmpty,
              !notchRect.isEmpty,
              let dnkFrame,
              !dnkFrame.isEmpty,
              dnkFrame.intersects(screenFrame) else { return nil }
        let width = min(max(panelWidth, 0), screenFrame.width)
        guard width > 0 else { return nil }
        let height = max(dnkFrame.height - panelBottomOverreach, minimumPanelHeight)
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - notchRect.height - height,
            width: width,
            height: height
        ).intersection(screenFrame)
    }

    nonisolated static func isInside(
        cursor: NSPoint,
        notchRect: NSRect,
        panelFrame: NSRect?,
        panelWidth: CGFloat,
        screenFrame: NSRect,
        expanded: Bool
    ) -> Bool {
        // A cursor inside the physical notch is pinned to the screen's top edge and
        // reports y == maxY — which half-open NSRect.contains EXCLUDES. Nudge it in,
        // or hovering the notch itself reads as "outside" and flickers.
        var cursor = cursor
        if cursor.y >= screenFrame.maxY, cursor.y <= screenFrame.maxY + 1 {
            cursor.y = screenFrame.maxY - 0.5
        }
        guard screenFrame.contains(cursor) else { return false }
        return hotZone(
            notchRect: notchRect,
            panelRect: visiblePanelRect(
                screenFrame: screenFrame,
                panelWidth: panelWidth,
                dnkFrame: panelFrame,
                notchRect: notchRect
            ),
            screenFrame: screenFrame,
            expanded: expanded
        ).contains(cursor)
    }

    private var timer: Timer?
    private var state = State()
    private var cachedPanelFrame: NSRect?
    private let exitGrace: TimeInterval
    private let pollInterval: TimeInterval

    private var notchRect: () -> NSRect = { .zero }
    private var screenFrame: () -> NSRect = { .zero }
    private var panelWidth: () -> CGFloat = { 0 }
    private var expandedFrame: () -> NSRect? = { nil }
    private var onEnter: () -> Bool = { false }
    private var onExit: () -> Void = {}

    init(
        exitGrace: TimeInterval = NotchHoverController.defaultExitGrace,
        pollInterval: TimeInterval = 0.1
    ) {
        self.exitGrace = exitGrace
        self.pollInterval = pollInterval
    }

    /// Re-arms the poll with fresh geometry. Deliberately does NOT reset hover state: a mode
    /// re-apply (display change, settings change, dwell expiry) can land while the user is
    /// hovering, and forgetting `expanded` there makes the next tick fire a second expand —
    /// the collapse/re-expand the user sees as a flicker.
    func start(
        notchRect: @escaping () -> NSRect,
        screenFrame: @escaping () -> NSRect,
        panelWidth: @escaping () -> CGFloat,
        expandedFrame: @escaping () -> NSRect?,
        onEnter: @escaping () -> Bool,
        onExit: @escaping () -> Void
    ) {
        timer?.invalidate()
        timer = nil
        self.notchRect = notchRect
        self.screenFrame = screenFrame
        self.panelWidth = panelWidth
        self.expandedFrame = expandedFrame
        self.onEnter = onEnter
        self.onExit = onExit
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        state = State()
        cachedPanelFrame = nil
    }

    // Called when the panel closes for a reason other than hover, so the next hover starts
    // from a clean slate instead of thinking it's still expanded.
    func resetExpanded() {
        state.forgetExpansion()
        cachedPanelFrame = nil
    }

    // Called when the USER closed the panel (jump, permission decision, last session gone).
    func suppressUntilExit() {
        state.dismiss()
        cachedPanelFrame = nil
    }

    // Called when something other than hover opened the panel (needs-action alert, tap on the
    // compact view, a mode re-apply under the cursor).
    func adoptExternalExpansion() {
        state.adoptExternalExpansion()
        cachedPanelFrame = expandedFrame()
    }

    /// Whether a user dismissal is still latched — i.e. the cursor has not left since. Hover
    /// triggers outside this controller check it so they don't undo the dismissal.
    var isSuppressed: Bool { state.suppressedUntilExit }

    /// Whether the cursor is over the notch or the open panel right now. Callers use this to
    /// avoid yanking the panel out from under it on a timer or a mode re-apply.
    func isMouseInside() -> Bool {
        refreshPanelFrame()
        return Self.isInside(
            cursor: NSEvent.mouseLocation,
            notchRect: notchRect(),
            panelFrame: state.expanded ? cachedPanelFrame : nil,
            panelWidth: panelWidth(),
            screenFrame: screenFrame(),
            expanded: state.expanded
        )
    }

    /// DynamicNotchKit tears its NSPanel down and rebuilds it on every screen-parameter change
    /// (DynamicNotch.swift:144-153), so `window?.frame` is briefly nil while the panel is on
    /// screen. Without this cache the hot zone would collapse to the bare notch mid-hover and
    /// the exit grace would close the panel under the cursor.
    private func refreshPanelFrame() {
        guard state.expanded else {
            cachedPanelFrame = nil
            return
        }
        if let frame = expandedFrame(), !frame.isEmpty {
            cachedPanelFrame = frame
        }
    }

    private func tick() {
        let inside = isMouseInside()
        switch Self.step(&state, mouseInside: inside, now: Date().timeIntervalSinceReferenceDate, exitGrace: exitGrace) {
        case .expand:
            // The delegate can refuse (nothing to show yet). Roll the state back so the next
            // tick tries again instead of pretending the panel is open.
            if !onEnter() { state.expanded = false }
        case .collapse:
            cachedPanelFrame = nil
            onExit()
        case .none:
            break
        }
    }

    // Notch geometry, with a centered-strip fallback for displays without a physical notch.
    static func notchFrame(on screen: NSScreen) -> NSRect {
        notchFrame(
            screenFrame: screen.frame,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            safeAreaTop: screen.safeAreaInsets.top
        )
    }

    /// A hot zone that changes size under a stationary cursor is a flicker source in its own
    /// right, so the height never comes from the menu bar alone: with "automatically hide and
    /// show the menu bar" on, `safeAreaInsets.top` and the menu bar height both drop toward 0
    /// exactly when the cursor approaches the top edge, which would shrink the notch out from
    /// under it. The auxiliary areas beside the notch are physical and keep their height.
    nonisolated static func notchFrame(
        screenFrame: NSRect,
        menuBarHeight: CGFloat,
        auxiliaryTopLeft: NSRect?,
        auxiliaryTopRight: NSRect?,
        safeAreaTop: CGFloat
    ) -> NSRect {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight else {
            let width: CGFloat = 300
            let height = max(menuBarHeight, fallbackStripHeight)
            return NSRect(
                x: screenFrame.midX - width / 2,
                y: screenFrame.maxY - height,
                width: width,
                height: height
            )
        }
        let width = screenFrame.width - left.width - right.width
        let height = max(safeAreaTop, left.height, right.height, fallbackStripHeight)
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: max(width, 1),
            height: height
        )
    }

    /// Standard macOS menu bar height — the floor for the hoverable strip.
    private nonisolated static let fallbackStripHeight: CGFloat = 24
}
