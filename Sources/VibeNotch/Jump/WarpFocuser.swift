import AppKit
import ApplicationServices

struct WarpFocuser {
    private static let keyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func keyCode(forTabIndex index: Int) -> CGKeyCode? {
        guard keyCodes.indices.contains(index - 1) else { return nil }
        return keyCodes[index - 1]
    }

    @MainActor
    func focus(tabIndex: Int) -> Bool {
        guard let keyCode = Self.keyCode(forTabIndex: tabIndex) else { return false }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        let bundleIdentifiers = ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            guard let identifier = $0.bundleIdentifier else { return false }
            return bundleIdentifiers.contains(identifier)
        }), application.activate(options: [.activateAllWindows]),
              let keyDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: keyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: keyCode,
                keyDown: false
              ) else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)
        return true
    }
}
