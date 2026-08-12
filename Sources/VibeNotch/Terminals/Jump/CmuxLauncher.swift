import Foundation

/// Whether cmux is here, and the floor under a cmux jump.
///
/// This used to also hunt for a focus subcommand by shelling out to `cmux --help` and grepping the
/// output for a line mentioning "focus" — a guess that could never fire, because cmux ships no
/// binary on PATH at all. cmux does ship an AppleScript dictionary (it is a Ghostty fork, and the
/// parts used here are identical), so real per-surface focus now happens in
/// `Jumper.focusTerminalByCwd` and the guess is gone (#4).
///
/// What remains is the pair that still has to run on `Jumper`'s discovery queue, off the main
/// actor: the install check, which shells out and is cached because installed-or-not cannot change
/// mid-run, and plain activation as the floor when no surface matches.
enum CmuxLauncher {
    private static var cachedAvailability: Bool?

    /// Only for tests — the static cache would otherwise leak between them.
    static func resetCacheForTesting() {
        cachedAvailability = nil
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

    /// Brings cmux to the front without claiming to know which surface the session is in — what a
    /// cmux jump falls back to, and what every cmux jump did before #4.
    static func activate() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "cmux"]
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

    private static func which(_ name: String) -> String? {
        guard let output = TTYResolver.output("/usr/bin/which", [name]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
