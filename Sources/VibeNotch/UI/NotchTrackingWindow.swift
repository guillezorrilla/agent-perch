@preconcurrency import AppKit

@MainActor
final class NotchTrackingWindow {
    private var window: NSPanel?

    func show(on screen: NSScreen, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        hide()
        let panel = NSPanel(
            contentRect: notchFrame(on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = NotchTrackingView(onEnter: onEnter, onExit: onExit)
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    private func notchFrame(on screen: NSScreen) -> NSRect {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            let width: CGFloat = 300
            let height = screen.frame.maxY - screen.visibleFrame.maxY
            return NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
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

private final class NotchTrackingView: NSView {
    private let onEnter: () -> Void
    private let onExit: () -> Void
    private var area: NSTrackingArea?

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        self.area = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter()
    }

    override func mouseExited(with event: NSEvent) {
        onExit()
    }
}
