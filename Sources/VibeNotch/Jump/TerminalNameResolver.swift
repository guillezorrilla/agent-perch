import Foundation

struct AncestorProcess: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let command: String
}

final class TerminalNameResolver {
    typealias ProcessLookup = (Int32) -> AncestorProcess?

    private enum CachedName {
        case found(String)
        case missing
    }

    private let process: ProcessLookup
    private var cache: [Int32: CachedName] = [:]

    init(process: @escaping ProcessLookup = TerminalNameResolver.systemProcess) {
        self.process = process
    }

    func terminalName(for pid: Int32) -> String? {
        if let cached = cache[pid] {
            if case let .found(name) = cached { return name }
            return nil
        }

        var currentPID = pid
        var visited: Set<Int32> = []
        while currentPID > 1, visited.insert(currentPID).inserted,
              let current = process(currentPID) {
            if let name = Self.knownName(for: current.command) {
                cache[pid] = .found(name)
                return name
            }
            currentPID = current.parentPID
        }

        cache[pid] = .missing
        return nil
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
        return nil
    }

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
