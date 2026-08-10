import Foundation

struct ClaudeProcess: Equatable, Sendable {
    let pid: Int32
    let command: String
    let cwd: String
    let tty: String?
}

struct TTYResolver {
    // pgrep's `-f` pattern is an extended regex, so "claude|codex" matches either binary's
    // command line in one call; each candidate line is still re-validated below by the
    // agent-specific CLI check (same as today for Claude alone).
    func processes() -> [ClaudeProcess] {
        guard let listing = Self.output("/usr/bin/pgrep", ["-fl", "claude|codex"]) else {
            return []
        }

        return listing.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let pid = Int32(fields[0]),
                  Self.isClaudeCLI(command: String(fields[1])) || Self.isCodexCLI(command: String(fields[1])),
                  let cwd = cwd(for: pid) else { return nil }

            return ClaudeProcess(
                pid: pid,
                command: String(fields[1]),
                cwd: cwd,
                tty: tty(for: pid)
            )
        }
    }

    static func tty(for cwd: String, agentName: String = "Claude", in processes: [ClaudeProcess]) -> String? {
        processes.first {
            isAgentCLI(agentName, command: $0.command)
                && $0.cwd == cwd
                && $0.tty?.isEmpty == false
                && $0.tty != "??"
        }?.tty
    }

    /// Dispatches to the right agent's CLI check by name, defaulting to Claude's rules — the
    /// same default every call site already assumed before Codex existed.
    static func isAgentCLI(_ agentName: String, command: String) -> Bool {
        switch agentName {
        case "Codex": return isCodexCLI(command: command)
        default: return isClaudeCLI(command: command)
        }
    }

    static func isClaudeCLI(command: String) -> Bool {
        let command = command.lowercased()
        guard command.contains("claude"),
              !command.contains("claude.app/"),
              !command.contains("/contents/helpers/"),
              !command.contains("claude helper") else { return false }

        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        return executableName == "claude"
            || executableName == "claude-code"
            || command.contains("/.local/share/claude/versions/")
            || command.contains("/@anthropic-ai/claude-code/")
    }

    // ChatGPT.app embeds its own binary literally named "codex" (used as an internal
    // "app-server", plus separate XPC helper processes) — none of these are an interactive
    // CLI session, so every one of these markers must be rejected the way isClaudeCLI already
    // rejects Claude.app's helpers (#24).
    static func isCodexCLI(command: String) -> Bool {
        let command = command.lowercased()
        guard command.contains("codex"),
              !command.contains("chatgpt.app"),
              !command.contains("codex framework.framework"),
              !command.contains("codex (service)"),
              !command.contains("codex (renderer)"),
              !command.contains("app-server") else { return false }

        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        return executableName == "codex"
    }

    // Fallback when no live claude process matches: any shell sitting at the session's
    // cwd (the user's still-open tab after the agent exited). One lsof call for all shells.
    func shellTTY(at cwd: String) -> String? {
        guard let listing = Self.output(
            "/usr/sbin/lsof",
            ["-a", "-d", "cwd", "-c", "zsh", "-c", "bash", "-c", "fish", "-Fpn"]
        ), let pid = Self.firstPid(withCwd: cwd, inLsofFieldOutput: listing) else { return nil }
        return tty(for: pid)
    }

    static func firstPid(withCwd cwd: String, inLsofFieldOutput listing: String) -> Int32? {
        var currentPid: Int32?
        for line in listing.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                currentPid = Int32(line.dropFirst())
            } else if line.first == "n", String(line.dropFirst()) == cwd {
                if let currentPid { return currentPid }
            }
        }
        return nil
    }

    private func cwd(for pid: Int32) -> String? {
        Self.output("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])?
            .split(whereSeparator: \.isNewline)
            .first { $0.first == "n" }
            .map { String($0.dropFirst()) }
    }

    private func tty(for pid: Int32) -> String? {
        guard let value = Self.output("/bin/ps", ["-o", "tty=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "??" else { return nil }
        return value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
    }

    static func output(_ executable: String, _ arguments: [String]) -> String? {
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

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
