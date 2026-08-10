import AppKit

/// A keystroke that answers the card currently on screen.
enum CardShortcut: Equatable, Sendable {
    case allow
    case deny
    case option(Int)

    /// ⌘Y allow, ⌘N deny, ⌘1…⌘9 pick option N.
    ///
    /// Command must be the ONLY modifier: this monitor watches every keystroke the user makes
    /// anywhere, so ⌘⇧N, ⌥⌘Y and friends have to stay with the app they were typed into.
    static func map(characters: String?, modifiers: NSEvent.ModifierFlags) -> CardShortcut? {
        guard modifiers.intersection(.deviceIndependentFlagsMask) == .command,
              let characters, characters.count == 1 else { return nil }
        switch characters.lowercased() {
        case "y": return .allow
        case "n": return .deny
        default:
            guard let digit = Int(characters), (1...9).contains(digit) else { return nil }
            return .option(digit)
        }
    }
}

/// Keyboard answers for the card on screen, watched wherever the user is typing.
///
/// SwiftUI `.keyboardShortcut` cannot reach us here: it is dispatched to the key window of the
/// ACTIVE app, and VibeNotch is an `.accessory` app whose panel is never made key while the user
/// works in their terminal — verified with the panel on screen: `NSApp.isActive == false`,
/// `NSApp.keyWindow == nil`. The global monitor sees the keystroke wherever focus actually is;
/// the local one covers the case where VibeNotch itself happens to be active, and consumes the
/// event so it does not also beep.
///
/// Both monitors live ONLY while a card is on screen. A global key monitor that outlives the
/// card it belongs to is a keylogger nobody asked for, so `start` is paired with `stop` on the
/// card's own appearance and disappearance.
@MainActor
final class CardShortcutMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    func start(_ handler: @escaping (CardShortcut) -> Void) {
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard let shortcut = CardShortcut.map(
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            ) else { return }
            MainActor.assumeIsolated { handler(shortcut) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let shortcut = CardShortcut.map(
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            ) else { return event }
            MainActor.assumeIsolated { handler(shortcut) }
            return nil
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
