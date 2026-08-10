import AppKit
import SwiftUI

/// Delivers the FIRST click to a control in the notch panel.
///
/// DynamicNotchKit's panel is `[.borderless, .nonactivatingPanel]` and is only ever
/// `orderFrontRegardless()`-ed (DynamicNotch.swift:388, 400), never made key, while VibeNotch
/// runs as an `.accessory` app behind the user's terminal. AppKit therefore routes clicks
/// through the "first mouse" path, and the view it asks is the `NSHostingView` itself — SwiftUI
/// renders the whole card into that single NSView — which answers `false`. The click is spent
/// making the window key and never reaches the Button (#19), and because DynamicNotchKit tears
/// the panel down and rebuilds it on every expand (DynamicNotch.swift:352), the next open starts
/// non-key again: every first click is swallowed.
///
/// A real NSView subview wins the hit test and may answer `true`, so the click lands on the
/// first press without keying the panel and without activating VibeNotch — activating would pull
/// focus off the terminal the answer is about to be typed into.
private final class FirstMouseView: NSView {
    var action: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Swallowed so the press cannot fall through to the panel behind. The action fires on
    /// mouse-up inside the control, so dragging off before releasing cancels it like a Button.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
}

private struct FirstMouseClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> FirstMouseView {
        let view = FirstMouseView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: FirstMouseView, context: Context) {
        nsView.action = action
    }
}

extension View {
    /// Makes a notch-panel control act on its first click. Apply it LAST, so the catcher covers
    /// the padded, drawn extent of the control rather than the bare `Button` frame.
    ///
    /// The underlying `Button` keeps the same action: the catcher consumes the mouse, while the
    /// Button still carries the accessibility action for VoiceOver. Only one of the two can fire
    /// for any given interaction, so the action never runs twice.
    func firstMouseAction(_ action: @escaping () -> Void) -> some View {
        overlay(FirstMouseClickCatcher(action: action))
    }
}
