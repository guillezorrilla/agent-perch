import AppKit
import ApplicationServices

/// One answer keystroke posted into a terminal that exposes no text API at all — Ghostty and cmux,
/// the two #34 taught jumping about and which nothing could answer until #42.
///
/// The mechanism is Warp's, unchanged since #20: focus the surface, then post the key to that app's
/// pid. What differs is the refusal. `Jumper` may fall back to merely activating cmux when no
/// surface matches, because landing in the right app beats landing nowhere; an answer may not.
/// A digit posted at whatever surface happens to be in front answers a prompt nobody was looking
/// at, which is strictly worse than the card saying nothing was typed — so the caller only gets
/// here once a real surface has been focused.
///
/// Never prompts for Accessibility, on purpose. `AXIsProcessTrustedWithOptions(prompt:)` re-opens
/// the system dialog on every call made without the grant (#20), and a permission card on screen is
/// the worst possible moment to ask. The Settings preflight is where the grant is requested (#42);
/// here a missing grant is simply a refusal.
@MainActor
enum SurfaceKeystroke {
    static func post(_ key: InjectionKey, toBundleIdentifier bundleIdentifier: String) -> Bool {
        guard let keyCode = WarpFocuser.keyCode(forAnswer: key),
              AXIsProcessTrusted(),
              let application = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == bundleIdentifier
              }),
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return false }

        // No `activate` — the surface was focused a moment ago and bringing the app forward again
        // here would race the focus this depends on, the same reason `WarpFocuser.answer` doesn't.
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)
        return true
    }
}
