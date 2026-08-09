@preconcurrency import AppKit

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

    private var timer: Timer?
    private var state = State()
    private let exitGrace: TimeInterval
    private let pollInterval: TimeInterval

    private var notchRect: () -> NSRect = { .zero }
    private var expandedFrame: () -> NSRect? = { nil }
    private var onEnter: () -> Void = {}
    private var onExit: () -> Void = {}

    init(exitGrace: TimeInterval = 0.35, pollInterval: TimeInterval = 0.1) {
        self.exitGrace = exitGrace
        self.pollInterval = pollInterval
    }

    func start(
        notchRect: @escaping () -> NSRect,
        expandedFrame: @escaping () -> NSRect?,
        onEnter: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) {
        stop()
        self.notchRect = notchRect
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
        let region: NSRect
        if state.expanded, let frame = expandedFrame() {
            region = notchRect().union(frame)
        } else {
            region = notchRect()
        }
        let inside = region.contains(NSEvent.mouseLocation)
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
