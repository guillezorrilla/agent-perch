import Foundation

struct ClaudeProcess: Equatable, Sendable {
    let pid: Int32
    let command: String
    let cwd: String
    let tty: String?
}

struct TTYResolver {
    private struct Candidate {
        let pid: Int32
        let command: String
    }

    /// The whole process table, in three subprocess calls regardless of how many agents are
    /// running.
    ///
    /// It used to cost `1 + 2N`: a `pgrep`, then an `lsof` and a `ps` for EVERY matching pid —
    /// around a tenth of a second each once process-spawn overhead is counted — all of it on the
    /// main thread behind a click (#23). `lsof` and `ps` both take a comma-separated pid list, so
    /// one call each now answers for every candidate.
    ///
    /// pgrep's `-f` pattern is an extended regex, so "claude|codex" matches either binary's
    /// command line in one call; each candidate line is still re-validated by the agent-specific
    /// CLI check.
    func processes() -> [ClaudeProcess] {
        guard let listing = Self.output("/usr/bin/pgrep", ["-fl", "claude|codex"]) else {
            return []
        }

        let candidates = listing.split(whereSeparator: \.isNewline).compactMap { line -> Candidate? in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }
            let command = String(fields[1])
            guard Self.isClaudeCLI(command: command) || Self.isCodexCLI(command: command) else {
                return nil
            }
            return Candidate(pid: pid, command: command)
        }
        guard !candidates.isEmpty else { return [] }

        let pids = candidates.map { String($0.pid) }.joined(separator: ",")
        let cwds = Self.cwdsByPID(
            inLsofFieldOutput: Self.output(
                "/usr/sbin/lsof",
                ["-a", "-d", "cwd", "-p", pids, "-Fpn"],
                keepingPartialOutput: true
            ) ?? ""
        )
        let ttys = Self.ttysByPID(inPSOutput: Self.output(
            "/bin/ps",
            ["-o", "pid=,tty=", "-p", pids],
            keepingPartialOutput: true
        ) ?? "")

        return candidates.compactMap { candidate in
            guard let cwd = cwds[candidate.pid] else { return nil }
            return ClaudeProcess(
                pid: candidate.pid,
                command: candidate.command,
                cwd: cwd,
                tty: ttys[candidate.pid]
            )
        }
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

    // Fallback when no live agent process matches: any shell sitting at the session's cwd (the
    // user's still-open tab after the agent exited). One lsof call for all shells — and the
    // single slowest call a jump makes, so it is only reached off the main actor, and only for a
    // terminal that can actually be focused by tty.
    func shellTTY(at cwd: String) -> String? {
        guard let listing = Self.output(
            "/usr/sbin/lsof",
            ["-a", "-d", "cwd", "-c", "zsh", "-c", "bash", "-c", "fish", "-Fpn"],
            keepingPartialOutput: true
        ), let pid = Self.pids(withCwd: cwd, inLsofFieldOutput: listing).first else { return nil }
        return tty(for: pid)
    }

    /// Every pid whose cwd is `cwd`, most recently started (highest pid) first — the same
    /// deterministic recency rule `JumpTarget` uses when several candidates tie.
    static func pids(withCwd cwd: String, inLsofFieldOutput listing: String) -> [Int32] {
        let target = CanonicalPath.canonical(cwd)
        var pids: [Int32] = []
        scanLsofCwds(listing) { pid, candidate in
            if CanonicalPath.canonical(candidate) == target { pids.append(pid) }
            return true
        }
        return pids.sorted(by: >)
    }

    /// pid -> cwd for a whole batch of pids, from one `lsof -Fpn` run.
    ///
    /// Field output is a flat stream: a `p<pid>` line opens a process, and the `n<path>` line
    /// that follows belongs to it. Anything else (lsof still emits `f` lines, and a dead pid
    /// contributes nothing at all) is skipped, so a malformed or truncated listing costs the
    /// entries it mangled and nothing more.
    static func cwdsByPID(inLsofFieldOutput listing: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        scanLsofCwds(listing) { pid, cwd in
            if result[pid] == nil { result[pid] = cwd }
            return true
        }
        return result
    }

    /// pid -> tty from one `ps -o pid=,tty=` run. `??` means no controlling terminal, which is
    /// no better than no answer, so it is dropped here rather than re-checked by every caller.
    static func ttysByPID(inPSOutput listing: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let pid = Int32(fields[0]) else { continue }
            let tty = String(fields[1])
            guard tty != "??" else { continue }
            result[pid] = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        }
        return result
    }

    /// Walks `lsof -Fpn` output, handing each (pid, cwd) pair to `visit`; `visit` returns whether
    /// to keep going, so a search can stop at its first hit without a second parser existing.
    private static func scanLsofCwds(_ listing: String, _ visit: (Int32, String) -> Bool) {
        var currentPid: Int32?
        for line in listing.split(whereSeparator: \.isNewline) {
            switch line.first {
            case "p":
                currentPid = Int32(line.dropFirst())
            case "n":
                let path = String(line.dropFirst())
                guard let pid = currentPid, !path.isEmpty else { continue }
                guard visit(pid, path) else { return }
            default:
                continue
            }
        }
    }

    private func tty(for pid: Int32) -> String? {
        Self.ttysByPID(
            inPSOutput: Self.output("/bin/ps", ["-o", "pid=,tty=", "-p", String(pid)]) ?? ""
        )[pid]
    }

    /// - Parameter keepingPartialOutput: whether output is worth having even when the tool exits
    ///   non-zero. Both batched tools do that as soon as ONE pid in the list has gone away or is
    ///   unreadable — while still printing perfectly good answers for all the others — so the
    ///   batch callers must not throw the whole listing away over it.
    static func output(
        _ executable: String,
        _ arguments: [String],
        keepingPartialOutput: Bool = false
    ) -> String? {
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
        guard keepingPartialOutput || process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
