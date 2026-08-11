import Foundation

struct ClaudeProcess: Equatable, Sendable {
    let pid: Int32
    let command: String
    let cwd: String
    let tty: String?
    /// When the process was launched, derived from the same batched `ps` run that reports its tty
    /// (see `startedAtByPID`). The only honest `lastActivity` a live session with no transcript to
    /// match has (#33). `var` with a default only so the synthesized memberwise init keeps working
    /// for the many call sites that have no reason to care; never mutated after init.
    var startedAt: Date? = nil
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
    /// pgrep's `-f` pattern is an extended regex, so "claude|codex|agy|antigravity" matches any
    /// of those binaries' command lines in one call; each candidate line is still re-validated by
    /// the agent-specific CLI check.
    func processes() -> [ClaudeProcess] {
        guard let listing = Self.output(
            "/usr/bin/pgrep",
            ["-fl", "claude|codex|agy|antigravity|gemini|opencode|kiro"]
        ) else {
            return []
        }

        let candidates = listing.split(whereSeparator: \.isNewline).compactMap { line -> Candidate? in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }
            let command = String(fields[1])
            guard Self.isClaudeCLI(command: command)
                || Self.isCodexCLI(command: command)
                || Self.isAntigravityCLI(command: command)
                || Self.isGeminiCLI(command: command)
                || Self.isOpenCodeCLI(command: command)
                || Self.isKiroCLI(command: command) else {
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
        // One `ps` run, two answers: the tty every jump keys off, and the start time a live
        // session with no transcript to match dates itself by (#33) — an extra output column
        // costs nothing next to a second subprocess spawn.
        let psOutput = Self.output(
            "/bin/ps",
            ["-o", "pid=,tty=,etime=", "-p", pids],
            keepingPartialOutput: true
        ) ?? ""
        let ttys = Self.ttysByPID(inPSOutput: psOutput)
        let startTimes = Self.startedAtByPID(inPSOutput: psOutput, now: Date())

        return candidates.compactMap { candidate in
            guard let cwd = cwds[candidate.pid] else { return nil }
            return ClaudeProcess(
                pid: candidate.pid,
                command: candidate.command,
                cwd: cwd,
                tty: ttys[candidate.pid],
                startedAt: startTimes[candidate.pid]
            )
        }
    }

    /// Dispatches to the right agent's CLI check by name, defaulting to Claude's rules — the
    /// same default every call site already assumed before Codex existed.
    static func isAgentCLI(_ agentName: String, command: String) -> Bool {
        switch agentName {
        case "Codex": return isCodexCLI(command: command)
        case "Antigravity": return isAntigravityCLI(command: command)
        case "Gemini": return isGeminiCLI(command: command)
        case "OpenCode": return isOpenCodeCLI(command: command)
        case "Kiro": return isKiroCLI(command: command)
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

    // `agy` — Antigravity's own terminal CLI (#29) — is a real interactive session, unlike the
    // Electron IDE app `AntigravityProcessCheck` already rejects by BUNDLE PATH. Excluded here
    // the same way: a command line running out of either bundle is the IDE's own process, never
    // this CLI, even though both happen to share the word "antigravity".
    static func isAntigravityCLI(command: String) -> Bool {
        let command = command.lowercased()
        guard command.contains("agy") || command.contains("antigravity"),
              !command.contains("antigravity ide.app/"),
              !command.contains("antigravity.app/") else { return false }

        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        return executableName == "agy" || executableName == "antigravity"
    }

    // Homebrew installs `gemini` as a NODE SCRIPT with a shebang, so the process table shows the
    // interpreter as argv[0] and the script as argv[1] — verified here (#11): `file` calls
    // `/opt/homebrew/Cellar/gemini-cli/<v>/libexec/bin/gemini` "a node script text executable".
    // A basename check alone would therefore miss every real session, so the install path is
    // matched too. `~/.gemini/antigravity-cli/…` shares the word "gemini" and belongs to a
    // different agent entirely, hence the explicit rejection.
    static func isGeminiCLI(command: String) -> Bool {
        let command = command.lowercased()
        guard command.contains("gemini"),
              !command.contains(".app/contents/"),
              !command.contains("antigravity") else { return false }

        let launcher = launcherTokens(command)
        if URL(fileURLWithPath: launcher.first ?? "").lastPathComponent == "gemini" { return true }
        // The shebang case: argv[0] is the interpreter, argv[1] the gemini script itself. Only that
        // second token counts — an install path appearing anywhere ELSE on the command line is some
        // other agent's ARGUMENT, not evidence of a Gemini session.
        guard let script = launcher.dropFirst().first else { return false }
        return URL(fileURLWithPath: script).lastPathComponent == "gemini" || script.contains("/gemini-cli/")
    }

    /// argv[0] and argv[1] — the only two places a launcher can be, since a shebang script puts the
    /// interpreter first and the script second. Command lines containing a path with a SPACE are
    /// mangled by this split, which is exactly why every caller rejects application bundles before
    /// asking.
    private static func launcherTokens(_ command: String) -> [String] {
        command.split(maxSplits: 2, whereSeparator: \.isWhitespace).prefix(2).map(String.init)
    }

    // `opencode` ships as a single compiled binary to `~/.opencode/bin/opencode` and is not on
    // PATH, so the install directory is accepted alongside the plain basename.
    static func isOpenCodeCLI(command: String) -> Bool {
        let command = command.lowercased()
        guard command.contains("opencode"), !command.contains(".app/contents/") else { return false }

        return launcherTokens(command).contains {
            URL(fileURLWithPath: $0).lastPathComponent == "opencode" || $0.contains("/.opencode/bin/")
        }
    }

    // The `.app/contents/` rejection is doing real work here, not boilerplate: Kiro's desktop
    // helper lives at `/Applications/Kiro CLI.app/Contents/MacOS/kiro_cli_desktop`, and because
    // that path contains a SPACE, splitting the command line on whitespace hands the basename
    // check the word `kiro` and it would otherwise match (the same trap `LiveAgentScan`
    // documents for `Codex Computer Use.app`).
    static func isKiroCLI(command: String) -> Bool {
        let command = command.lowercased()
        guard command.contains("kiro"), !command.contains(".app/contents/") else { return false }

        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        return executableName == "kiro" || executableName == "kiro-cli"
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

    /// pid -> start date, from the `etime` column of the same `ps -o pid=,tty=,etime=` run.
    ///
    /// Elapsed time rather than `lstart`: `etime`'s `[[DD-]HH:]MM:SS` is a fixed, locale- and
    /// timezone-independent shape, where `lstart` prints a localized date string this would have
    /// to parse back. A line whose elapsed field is missing or unparsable simply contributes
    /// nothing, exactly like a missing tty does.
    static func startedAtByPID(inPSOutput listing: String, now: Date) -> [Int32: Date] {
        var result: [Int32: Date] = [:]
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int32(fields[0]),
                  let elapsed = elapsedSeconds(String(fields[2])) else { continue }
            result[pid] = now.addingTimeInterval(-elapsed)
        }
        return result
    }

    /// `MM:SS`, `HH:MM:SS` or `DD-HH:MM:SS` — the three shapes `ps`'s `etime` prints — as seconds.
    static func elapsedSeconds(_ etime: String) -> TimeInterval? {
        let halves = etime.split(separator: "-", maxSplits: 1)
        guard let clock = halves.last, halves.count <= 2 else { return nil }
        var days: TimeInterval = 0
        if halves.count == 2 {
            guard let parsed = TimeInterval(halves[0]) else { return nil }
            days = parsed
        }
        let units = clock.split(separator: ":").map { TimeInterval($0) }
        guard units.count == 2 || units.count == 3, !units.contains(where: { $0 == nil }) else { return nil }
        let values = units.compactMap { $0 }
        let hours = values.count == 3 ? values[0] : 0
        return ((days * 24.0 + hours) * 60.0 + values[values.count - 2]) * 60.0 + values[values.count - 1]
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
