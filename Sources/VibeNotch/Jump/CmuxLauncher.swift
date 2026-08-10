import Foundation

/// Best-effort focus for a session whose terminal is cmux.
///
/// VibeNotch has no AppleScript dictionary and no documented URL scheme to drive cmux with the
/// way it drives iTerm/Terminal by tty or Warp by its sqlite database, so everything here is read
/// at runtime rather than hard-coded: whether cmux is installed at all, and whether its own
/// `--help` output volunteers a subcommand for focusing a specific workspace. Both are cached —
/// installed-or-not and the CLI's own subcommands don't change mid-run — so a session list that
/// refreshes every few seconds never re-shells-out for either.
///
/// Everything here runs on `Jumper`'s discovery queue, off the main actor: `cmux --help` is a
/// subprocess wait, and the rule since #23 is that nothing which can block gets to run on the
/// click.
enum CmuxLauncher {
    private static var cachedAvailability: Bool?
    private static var cachedFocusSubcommand: String??

    /// Only for tests — the static caches would otherwise leak between them.
    static func resetCacheForTesting() {
        cachedAvailability = nil
        cachedFocusSubcommand = nil
    }

    static func isAvailable(
        which: (String) -> String? = Self.which,
        fileManager: FileManager = .default
    ) -> Bool {
        if let cached = cachedAvailability { return cached }
        let available = which("cmux") != nil || fileManager.fileExists(atPath: "/Applications/cmux.app")
        cachedAvailability = available
        return available
    }

    /// Whether this counted as a completed jump: a real per-workspace focus via cmux's own CLI,
    /// or — lacking one — simply bringing cmux to the front. `false` only when cmux isn't
    /// installed at all, which is the caller's cue to fall back to the pre-cmux ladder
    /// (iTerm/Terminal/Warp, same as any other unrecognized terminal).
    static func attemptFocus(
        cwd: String,
        isAvailable: () -> Bool = { Self.isAvailable() },
        focusSubcommand: () -> String? = Self.focusSubcommand,
        runCmux: (String, String) -> Bool = Self.runCmux,
        activate: () -> Bool = Self.activate
    ) -> Bool {
        guard isAvailable() else { return false }
        if let subcommand = focusSubcommand(), runCmux(subcommand, cwd) {
            return true
        }
        return activate()
    }

    /// Looks for a line in `cmux --help` naming a subcommand whose own description mentions
    /// focusing/activating a window — the closest thing to "a documented CLI subcommand" without
    /// a fixed contract to code against. Trusts only an unambiguous match; anything else means no
    /// subcommand-based focus is attempted, and `attemptFocus` falls back to plain activation.
    static func focusSubcommand() -> String? {
        if let cached = cachedFocusSubcommand { return cached }
        let subcommand = runHelp().flatMap(parseFocusSubcommand)
        cachedFocusSubcommand = subcommand
        return subcommand
    }

    static func parseFocusSubcommand(_ helpText: String) -> String? {
        for line in helpText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowercased = trimmed.lowercased()
            guard lowercased.contains("focus") || lowercased.contains("activate") else { continue }
            guard let name = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init),
                  !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0 == "-" }) else { continue }
            return name
        }
        return nil
    }

    private static func runHelp() -> String? {
        TTYResolver.output("/usr/bin/env", ["cmux", "--help"], keepingPartialOutput: true)
    }

    private static func runCmux(_ subcommand: String, _ cwd: String) -> Bool {
        run("/usr/bin/env", ["cmux", subcommand, cwd])
    }

    private static func activate() -> Bool {
        run("/usr/bin/open", ["-a", "cmux"])
    }

    private static func which(_ name: String) -> String? {
        guard let output = TTYResolver.output("/usr/bin/which", [name]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
