import Foundation

/// `kitty @ send-text` — Kitty's own text API, addressed by window id (#42).
///
/// UNVERIFIED. Kitty is not installed on the machine this was written on, so every line here is
/// exercised against fixtures and nothing else; the `kitty @ ls` shape and the `--match id:`
/// spelling are taken from Kitty's remote-control documentation, not from a running Kitty. It also
/// only works at all when the user has turned on `allow_remote_control` in `kitty.conf` — Kitty
/// refuses the socket otherwise, which arrives here as an ordinary failure and leaves the card
/// saying nothing was typed.
///
/// Why a window id and not a tty: Kitty reports each window's foreground process ids and never a
/// tty, so the session's agent pid is the bridge. That pid is available by construction — it is the
/// same pid `TerminalNameResolver` walked to decide this session is in Kitty at all — and matching
/// on it is exact, where matching on cwd would put the answer in whichever window happens to sit in
/// the same repo.
enum KittyRemote {
    /// `kitty @ ls` prints OS windows, each holding tabs, each holding windows. Only the fields a
    /// send needs are declared; `Decodable` ignores the dozens of others for free rather than
    /// failing the whole decode when Kitty adds one.
    struct OSWindow: Decodable, Equatable {
        let tabs: [Tab]
    }

    struct Tab: Decodable, Equatable {
        let windows: [Window]
    }

    struct Window: Decodable, Equatable {
        let id: Int
        /// The pid of the process Kitty launched in this window — the shell, usually.
        let pid: Int32?
        /// The window's foreground process group, where an agent started from that shell shows up.
        let foregroundProcesses: [ForegroundProcess]?

        enum CodingKeys: String, CodingKey {
            case id
            case pid
            case foregroundProcesses = "foreground_processes"
        }

        struct ForegroundProcess: Decodable, Equatable {
            let pid: Int32?
        }
    }

    /// Types `text` into the Kitty window running `agentPID`, or refuses. A nil pid, an unreadable
    /// listing or a pid no window claims all mean the same thing: we do not know which window this
    /// session is, so nothing is typed.
    static func sendText(
        _ text: String,
        agentPID: Int32?,
        list: () -> String? = Self.list,
        send: (Int, String) -> Bool = { Self.send($1, toWindowID: $0) }
    ) -> Bool {
        guard let agentPID, let listing = list(),
              let windowID = windowID(inListing: listing, forPID: agentPID) else { return false }
        return send(windowID, text)
    }

    /// The window whose own process, or one of whose foreground processes, is `pid`.
    static func windowID(inListing json: String, forPID pid: Int32) -> Int? {
        guard let data = json.data(using: .utf8),
              let osWindows = try? JSONDecoder().decode([OSWindow].self, from: data) else { return nil }
        return osWindows
            .flatMap(\.tabs)
            .flatMap(\.windows)
            .first { window in
                window.pid == pid
                    || (window.foregroundProcesses ?? []).contains { $0.pid == pid }
            }?.id
    }

    private static func list() -> String? {
        TTYResolver.output("/usr/bin/env", ["kitty", "@", "ls"])
    }

    /// `--` ends the option list so an answer that starts with a dash can never be read as a flag,
    /// and the raw bytes of `text` go through untouched — Escape included (see `InjectionKey`).
    private static func send(_ text: String, toWindowID windowID: Int) -> Bool {
        TTYResolver.output(
            "/usr/bin/env",
            ["kitty", "@", "send-text", "--match", "id:\(windowID)", "--", text]
        ) != nil
    }
}
