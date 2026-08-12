import Foundation

/// Exact focus for a session whose terminal is WezTerm (#4).
///
/// Alone among the terminals VibeNotch drives without an AppleScript dictionary, WezTerm's CLI
/// reports a real per-pane `tty_name` — the same currency `JumpTarget.tty` already carries — so a
/// WezTerm jump is tty-exact the way iTerm/Terminal are, not the cwd guess Ghostty and cmux are
/// limited to.
///
/// Everything here runs on `Jumper`'s discovery queue, off the main actor: every call shells out
/// to `wezterm cli` and waits for it, and the rule since #23 is that nothing which can block gets
/// to run on the click. `wezterm cli` reaches the GUI through its mux socket and blocks until it
/// can — which never happens when WezTerm isn't running — so every call is deadline-bounded here
/// rather than using `TTYResolver.output`, which waits forever by design.
enum WezTermFocuser {
    /// Comfortably above an observed mux round trip (~50ms) and low enough that a WezTerm which
    /// has stopped answering costs one slow jump instead of wedging the serial discovery queue.
    private static let commandTimeout: TimeInterval = 2.0

    private static var cachedAvailability: Bool?

    /// One pane as `wezterm cli list --format json` reports it.
    ///
    /// Only the three fields a jump needs are declared. WezTerm prints a dozen more (sizes, cursor
    /// position, window/tab titles) and adds to them between releases; `Decodable` ignores unknown
    /// keys for free rather than failing the whole decode over a field we never read.
    struct Pane: Decodable, Equatable {
        let paneId: Int
        /// A full `/dev/ttysNNN` path — note the prefix, which `JumpTarget` strips from its own.
        /// Absent for a pane with no controlling terminal, which must not take the list down.
        let ttyName: String?
        /// A `file://<host>/<path>` URL, not a bare path: the host is the machine name.
        let cwd: String?

        enum CodingKeys: String, CodingKey {
            case paneId = "pane_id"
            case ttyName = "tty_name"
            case cwd
        }
    }

    /// Only for tests — the static cache would otherwise leak between them.
    static func resetCacheForTesting() {
        cachedAvailability = nil
    }

    static func isAvailable(
        which: (String) -> String? = Self.which,
        fileManager: FileManager = .default
    ) -> Bool {
        if let cached = cachedAvailability { return cached }
        let available = which("wezterm") != nil
            || fileManager.fileExists(atPath: "/Applications/WezTerm.app")
        cachedAvailability = available
        return available
    }

    /// Whether a pane belonging to this session was found and brought to the front. `false` —
    /// WezTerm not installed, not running, or holding no pane that matches — leaves the caller on
    /// the ladder it would have taken anyway.
    static func attemptFocus(
        tty: String?,
        cwd: String,
        isAvailable: () -> Bool = { Self.isAvailable() },
        listPanes: () -> String? = Self.listPanes,
        activatePane: (Int) -> Bool = Self.activatePane,
        activateApp: () -> Bool = Self.activateApp
    ) -> Bool {
        guard isAvailable(),
              let listing = listPanes(),
              let paneId = selectPane(from: parsePanes(listing), tty: tty, cwd: cwd),
              activatePane(paneId) else { return false }
        // `activate-pane` switches the pane inside WezTerm but does NOT bring WezTerm forward —
        // verified against a running WezTerm while another app held focus, where the pane changed
        // and the frontmost app did not (#4). Without this the jump lands correctly behind
        // whatever window the user was already looking at, which reads as nothing happening.
        // Reported as the result the same way `CmuxLauncher` reports its own activation.
        return activateApp()
    }

    /// Types `text` into the pane holding `tty` — `wezterm cli send-text`, WezTerm's own text API
    /// (#42). Lives here rather than in `ActionInjector` because the tty→pane lookup it needs is
    /// the one `attemptFocus` already owns, and two copies of that would be two things to keep
    /// right.
    ///
    /// Nothing is focused and nothing is guessed: `--pane-id` addresses the pane directly, so an
    /// answer cannot land in whatever surface was in front. `cwd` is deliberately NOT offered to
    /// `selectPane` the way focus does — for a jump, landing in a sibling pane in the same repo is
    /// a wrong window the user can see and fix; for an answer it silently approves someone else's
    /// prompt. A tty matching no pane refuses.
    ///
    /// `--no-paste` is load-bearing. Without it `send-text` wraps the bytes in a bracketed paste
    /// for any pane that has enabled one — verified live against a pane in bracketed-paste mode,
    /// where the same `1` arrived as `^[[200~1^[[201~` without the flag and as a bare `1` with it —
    /// and a TUI permission prompt reads a paste as text for its composer, not as the keypress
    /// that picks an option.
    static func sendText(
        _ text: String,
        tty: String?,
        isAvailable: () -> Bool = { Self.isAvailable() },
        listPanes: () -> String? = Self.listPanes,
        send: (Int, String) -> Bool = { Self.send($1, toPaneID: $0) }
    ) -> Bool {
        guard isAvailable(),
              let listing = listPanes(),
              let paneId = selectPane(from: parsePanes(listing), tty: tty, cwd: nil) else { return false }
        return send(paneId, text)
    }

    static func parsePanes(_ json: String) -> [Pane] {
        guard let data = json.data(using: .utf8),
              let panes = try? JSONDecoder().decode([Pane].self, from: data) else { return [] }
        return panes
    }

    /// The pane to focus: tty first, cwd only as a fallback.
    ///
    /// That order is the whole point. Two agents in one repo — or one agent and the shell the user
    /// left open beside it — share a cwd, and matching on it first is exactly what sends a jump to
    /// the wrong tab; cwd is the last resort, never the first (#23). The cwd arm still earns its
    /// place: it covers the session whose agent has exited, where WezTerm's own pane list answers
    /// the question `TTYResolver.shellTTY` would otherwise pay an `lsof` to guess at.
    static func selectPane(from panes: [Pane], tty: String?, cwd: String?) -> Int? {
        if let tty = normalizedTTY(tty),
           let exact = panes.first(where: { normalizedTTY($0.ttyName) == tty }) {
            return exact.paneId
        }
        guard let cwd, !cwd.isEmpty else { return nil }
        return panes.first { pane in
            guard let path = pane.cwd.flatMap(path(fromFileURL:)) else { return false }
            return CanonicalPath.equal(path, cwd)
        }?.paneId
    }

    /// `file://<host>/<path>` — `URL.path` drops the host for us and decodes percent-escapes, so a
    /// repo with a space in its name still compares equal to the path a hook reported.
    static func path(fromFileURL urlString: String) -> String? {
        guard let url = URL(string: urlString), url.isFileURL, !url.path.isEmpty else { return nil }
        return url.path
    }

    /// WezTerm reports `/dev/ttys042`, `JumpTarget` carries `ttys042`; either side may arrive in
    /// either spelling, so both are stripped to the same one before comparing.
    private static func normalizedTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "??" else { return nil }
        return tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    private static func listPanes() -> String? {
        output("/usr/bin/env", ["wezterm", "cli", "list", "--format", "json"])
    }

    /// `--` ends the option list, so an answer starting with a dash can never be read as a flag.
    private static func send(_ text: String, toPaneID paneId: Int) -> Bool {
        output(
            "/usr/bin/env",
            ["wezterm", "cli", "send-text", "--pane-id", String(paneId), "--no-paste", "--", text]
        ) != nil
    }

    private static func activatePane(_ paneId: Int) -> Bool {
        output("/usr/bin/env", ["wezterm", "cli", "activate-pane", "--pane-id", String(paneId)]) != nil
    }

    private static func activateApp() -> Bool {
        output("/usr/bin/open", ["-a", "WezTerm"]) != nil
    }

    /// `which` cannot hang on a socket, so it uses the shared unbounded helper like
    /// `CmuxLauncher` does.
    private static func which(_ name: String) -> String? {
        guard let output = TTYResolver.output("/usr/bin/which", [name]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `TTYResolver.output` waits for the child forever, which is right for `ps` and `lsof` and
    /// wrong here: `wezterm cli` blocks until it can reach the GUI's mux socket, and with WezTerm
    /// not running that socket never appears. The discovery queue is serial, so one call blocked
    /// there stalls every jump queued behind it (#4).
    ///
    /// A watchdog rather than a second reader thread: SIGTERM closes the child's write end, which
    /// releases the blocking read, and the non-zero exit that follows is already rejected below.
    /// Cancelling on the fast path means a healthy call pays nothing but the timer it never fires.
    private static func output(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + commandTimeout,
            execute: watchdog
        )
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
