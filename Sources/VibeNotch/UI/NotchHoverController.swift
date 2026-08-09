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

// Poll-based hover with hysteresis. An NSTrackingArea on the bare notch rect thrashes:
// expanding the panel downward moves the cursor out of the notch rect, firing exit ->
// collapse -> cursor back in notch -> enter, forever. Here the "hot zone" is the notch
// UNION the expanded panel, and collapse only fires after the cursor is truly outside it
// for `exitGrace`, so moving between notch and panel never flickers.
@MainActor
final class NotchHoverController {
    struct State: Equatable {
        var expanded = false
        var outsideSince: TimeInterval?
    }

    enum Effect: Equatable {
        case none
        case expand
        case collapse
    }

    // Pure state machine — the bug-prone part, unit-tested in isolation.
    nonisolated static func step(
        _ state: inout State,
        mouseInside: Bool,
        now: TimeInterval,
        exitGrace: TimeInterval
    ) -> Effect {
        if mouseInside {
            state.outsideSince = nil
            guard !state.expanded else { return .none }
            state.expanded = true
            return .expand
        }
        guard state.expanded else { return .none }
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
        panelFrame: NSRect?,
        screenFrame: NSRect,
        expanded: Bool
    ) -> NSRect {
        guard !screenFrame.isEmpty, !notchRect.isEmpty else { return .zero }
        let notchRect = notchRect.intersection(screenFrame)
        guard !notchRect.isEmpty,
              expanded,
              let panelFrame,
              !panelFrame.isEmpty,
              panelFrame.intersects(screenFrame) else { return notchRect }
        return notchRect.union(panelFrame.intersection(screenFrame))
    }

    nonisolated static func isInside(
        cursor: NSPoint,
        notchRect: NSRect,
        panelFrame: NSRect?,
        screenFrame: NSRect,
        expanded: Bool
    ) -> Bool {
        guard screenFrame.contains(cursor) else { return false }
        return hotZone(
            notchRect: notchRect,
            panelFrame: panelFrame,
            screenFrame: screenFrame,
            expanded: expanded
        ).contains(cursor)
    }

    private var timer: Timer?
    private var state = State()
    private let exitGrace: TimeInterval
    private let pollInterval: TimeInterval

    private var notchRect: () -> NSRect = { .zero }
    private var screenFrame: () -> NSRect = { .zero }
    private var expandedFrame: () -> NSRect? = { nil }
    private var onEnter: () -> Void = {}
    private var onExit: () -> Void = {}

    init(exitGrace: TimeInterval = 0.35, pollInterval: TimeInterval = 0.1) {
        self.exitGrace = exitGrace
        self.pollInterval = pollInterval
    }

    func start(
        notchRect: @escaping () -> NSRect,
        screenFrame: @escaping () -> NSRect,
        expandedFrame: @escaping () -> NSRect?,
        onEnter: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) {
        stop()
        self.notchRect = notchRect
        self.screenFrame = screenFrame
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
    }

    // Called when the panel collapses for a reason other than hover (click/jump), so the
    // next hover starts from a clean slate instead of thinking it's still expanded.
    func resetExpanded() {
        state.expanded = false
        state.outsideSince = nil
    }

    private func tick() {
        let inside = Self.isInside(
            cursor: NSEvent.mouseLocation,
            notchRect: notchRect(),
            panelFrame: state.expanded ? expandedFrame() : nil,
            screenFrame: screenFrame(),
            expanded: state.expanded
        )
        switch Self.step(&state, mouseInside: inside, now: Date().timeIntervalSinceReferenceDate, exitGrace: exitGrace) {
        case .expand: onEnter()
        case .collapse: onExit()
        case .none: break
        }
    }

    // Notch geometry, with a centered-strip fallback for displays without a physical notch.
    static func notchFrame(on screen: NSScreen) -> NSRect {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            let width: CGFloat = 300
            let height = screen.frame.maxY - screen.visibleFrame.maxY
            return NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: max(height, 1)
            )
        }
        let width = screen.frame.width - left.width - right.width
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: width,
            height: screen.safeAreaInsets.top
        )
    }
}
