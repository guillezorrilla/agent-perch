import AppKit
import ApplicationServices

struct WarpFocuser {
    private static let keyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let escapeKeyCode: CGKeyCode = 53
    private static let bundleIdentifiers = ["dev.warp.Warp-Stable", "dev.warp.Warp"]

    static func keyCode(forTabIndex index: Int) -> CGKeyCode? {
        guard keyCodes.indices.contains(index - 1) else { return nil }
        return keyCodes[index - 1]
    }

    /// The keystroke that answers Claude's prompt in the focused Warp tab: the digit of the
    /// numbered choice it printed, or Escape to reject. Same digit key codes as tab switching —
    /// only the Command flag differs at post time.
    static func keyCode(forAnswer key: InjectionKey) -> CGKeyCode? {
        switch key {
        case .escape:
            return escapeKeyCode
        case let .text(text):
            guard let digit = Int(text), text.count == 1 else { return nil }
            return keyCode(forTabIndex: digit)
        }
    }

    /// `AXIsProcessTrustedWithOptions(prompt:)` re-opens the Accessibility prompt on EVERY call
    /// made without the grant — and that is one call per session click (#20). Ask at most once
    /// per launch; after that a silent check is enough and the caller falls back to a jump.
    @MainActor private static var hasPromptedForAccessibility = false

    @MainActor
    private static func isTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard !hasPromptedForAccessibility else { return false }
        hasPromptedForAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    func focus(tabIndex: Int) -> Bool {
        guard let keyCode = Self.keyCode(forTabIndex: tabIndex), Self.isTrusted() else {
            return false
        }
        return post(keyCode: keyCode, flags: .maskCommand, activating: true)
    }

    /// Types the answer into whichever Warp tab is focused right now. Call it only after
    /// `focus(tabIndex:)` has landed — this deliberately does NOT activate Warp again, so it
    /// cannot race the tab switch it depends on.
    @MainActor
    func answer(_ key: InjectionKey) -> Bool {
        guard let keyCode = Self.keyCode(forAnswer: key), AXIsProcessTrusted() else {
            return false
        }
        return post(keyCode: keyCode, flags: [], activating: false)
    }

    @MainActor
    private func post(keyCode: CGKeyCode, flags: CGEventFlags, activating: Bool) -> Bool {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            guard let identifier = $0.bundleIdentifier else { return false }
            return Self.bundleIdentifiers.contains(identifier)
        }) else { return false }

        if activating, !application.activate(options: [.activateAllWindows]) { return false }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return false }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)
        return true
    }
}
