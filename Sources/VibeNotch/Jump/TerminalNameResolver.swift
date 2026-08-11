import Foundation

struct AncestorProcess: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let command: String
}

/// Which terminal a pid is running inside, by walking its ancestry.
///
/// Every step of that walk costs two `ps` spawns, so the answer for a pid is cached for the rest of
/// the launch — including "no terminal", which is just as expensive to work out a second time.
///
/// `@unchecked Sendable` over a locked cache: `SessionStore` reads it while reconciling on the main
/// actor and `Jumper` fills it on the discovery queue, and the whole point of `shared` is that the
/// lookups one of them paid for are already there for the other. Reading it must never spawn
/// anything on the main actor — see `cachedTerminalName(for:)` (#32).
final class TerminalNameResolver: @unchecked Sendable {
    static let shared = TerminalNameResolver()

    /// `@Sendable` is load-bearing, not decoration: the lookup is run on the discovery queue by
    /// `Jumper` and on a detached task by `SessionStore.resolveTerminalNames` (#32), never on the
    /// main actor. Without it a lookup written inside a `@MainActor` context — which is where every
    /// test and every call site in the app builds one — is inferred main-actor-isolated, and the
    /// compiler quietly wraps it in a thunk that traps (`dispatch_assert_queue`) the moment this
    /// type honours its own contract and calls it off the main thread. Spelling it `@Sendable`
    /// turns that runtime trap into a compile error at the point of injection.
    typealias ProcessLookup = @Sendable (Int32) -> AncestorProcess?

    private enum CachedName {
        case found(String)
        case missing
    }

    private let process: ProcessLookup
    private let lock = NSLock()
    private var cache: [Int32: CachedName] = [:]

    init(process: @escaping ProcessLookup = TerminalNameResolver.systemProcess) {
        self.process = process
    }

    func terminalName(for pid: Int32) -> String? {
        if let cached = cachedName(for: pid) {
            if case let .found(name) = cached { return name }
            return nil
        }

        var currentPID = pid
        var visited: Set<Int32> = []
        while currentPID > 1, visited.insert(currentPID).inserted,
              let current = process(currentPID) {
            if let name = Self.knownName(for: current.command) {
                store(.found(name), for: pid)
                return name
            }
            currentPID = current.parentPID
        }

        store(.missing, for: pid)
        return nil
    }

    /// The answer we already have, without ever spawning `ps` to get one — what the main actor is
    /// allowed to ask. `isResolved` tells "not looked up yet" apart from "looked up, no terminal",
    /// so a caller knows whether resolving it in the background is still worth scheduling.
    func cachedTerminalName(for pid: Int32) -> String? {
        guard case let .found(name) = cachedName(for: pid) else { return nil }
        return name
    }

    func isResolved(_ pid: Int32) -> Bool { cachedName(for: pid) != nil }

    /// Resolves `pids` and caches the answers. Off the main actor, always: this is the `ps` work
    /// `cachedTerminalName(for:)` refuses to do.
    func resolve(_ pids: some Sequence<Int32>) {
        for pid in pids { _ = terminalName(for: pid) }
    }

    private func cachedName(for pid: Int32) -> CachedName? {
        lock.withLock { cache[pid] }
    }

    private func store(_ name: CachedName, for pid: Int32) {
        lock.withLock { cache[pid] = name }
    }

    private static func knownName(for command: String) -> String? {
        let lowercased = command.lowercased()
        let executable = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        if lowercased.contains("iterm2") { return "iTerm" }
        if lowercased.contains("apple_terminal") || executable == "terminal" { return "Terminal" }
        if lowercased.contains("warpterminal") || lowercased.contains("warp.app/") { return "Warp" }
        if lowercased.contains("tmux") && lowercased.contains("server") { return "tmux" }
        if lowercased.contains("ghostty") { return "Ghostty" }
        if lowercased.contains("wezterm") { return "WezTerm" }
        if executable == "kitty" || lowercased.contains("kitty.app/") { return "Kitty" }
        if executable == "cmux" || lowercased.contains("cmux.app/") { return "cmux" }
        return nil
    }

    @Sendable
    private static func systemProcess(pid: Int32) -> AncestorProcess? {
        guard let parent = TTYResolver.output(
            "/bin/ps",
            ["-o", "ppid=", "-p", String(pid)]
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parentPID = Int32(parent),
              let command = TTYResolver.output(
                "/bin/ps",
                ["-o", "comm=", "-p", String(pid)]
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return nil }
        return AncestorProcess(pid: pid, parentPID: parentPID, command: command)
    }
}
