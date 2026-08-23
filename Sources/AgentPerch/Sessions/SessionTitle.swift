import Foundation

enum SessionTitle {
    struct LocatedValue {
        let value: String
        let position: UInt64
    }

    static func preferredName(customTitle: LocatedValue?, agentName: LocatedValue?) -> String? {
        guard let customTitle else { return agentName?.value }
        guard let agentName else { return customTitle.value }
        return customTitle.position >= agentName.position ? customTitle.value : agentName.value
    }

    private struct Metadata {
        var customTitle: LocatedValue?
        var agentName: LocatedValue?
        var summary: LocatedValue?
    }

    static func resolve(
        sessionFileURL: URL?,
        lastPrompt: String?,
        cwd: String
    ) -> String {
        if let sessionFileURL, let metadata = metadata(in: sessionFileURL) {
            if let name = preferredName(
                customTitle: metadata.customTitle,
                agentName: metadata.agentName
            ) {
                return name
            }
            if let summary = metadata.summary?.value {
                return summary
            }
        }
        if let prompt = displayablePrompt(lastPrompt) {
            return truncate(prompt, max: 40)
        }
        return cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }

    /// Codex has no transcript metadata or hook-provided prompt to fall back on — just the
    /// session index's `thread_name` (once stripped of any machine-generated wrapper, and only
    /// when what's left looks like a real title, not a stored path) and the cwd basename.
    static func resolveCodex(threadName: String?, cwd: String) -> String {
        if let threadName {
            let cleaned = stripMachineGeneratedPrefix(from: threadName)
            if isUsableThreadName(cleaned) {
                return truncate(cleaned, max: 60)
            }
        }
        return cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }

    /// An agent-spawned Codex thread's name is often stamped with a machine-generated wrapper
    /// instead of a real title, e.g. `"Codex Companion Task: <task> Repo: /Users/x/y"`. Strips
    /// that wrapper down to just `<task>`, so a real title underneath still gets used; a
    /// wrapper with nothing usable left over falls through to `isUsableThreadName`'s
    /// cwd-basename fallback.
    private static func stripMachineGeneratedPrefix(from value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefixRange = value.range(
            of: "Codex Companion Task:",
            options: [.caseInsensitive, .anchored]
        ) else { return value }
        value = String(value[prefixRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Trailing "Repo: /some/path" boilerplate the wrapper appends after the task text.
        if let repoRange = value.range(of: "Repo:", options: [.caseInsensitive]) {
            value = String(value[..<repoRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func isUsableThreadName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return false }
        // A leftover template placeholder (e.g. an unfilled "<task>") is not a real title.
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") { return false }
        return true
    }

    /// The "You: …" subtitle text, or nil when there is nothing worth showing — no placeholder
    /// string, no empty row taking vertical space in the card.
    static func subtitle(forPrompt prompt: String?, max: Int = 60) -> String? {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return nil }
        return truncate(prompt, max: max)
    }

    /// Truncates at the last whole word that fits within `max` characters, appending an
    /// ellipsis — never mid-word, unlike a hard character slice. A single word longer than
    /// `max` has no earlier boundary to use, so it still gets hard-cut + ellipsis.
    static func truncate(_ value: String, max limit: Int) -> String {
        guard value.count > limit else { return value }
        let prefix = value.prefix(limit)
        if let lastSpace = prefix.lastIndex(of: " "), lastSpace > prefix.startIndex {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }

    // Harness-generated turns (task notifications, system reminders, slash-command
    // wrappers) arrive through the UserPromptSubmit hook too — they are not something
    // the user typed and make terrible titles ("<task-notification>…").
    static func displayablePrompt(_ prompt: String?) -> String? {
        guard var prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return nil }
        let machineMarkers = [
            "<task-notification", "<system-reminder", "<command-name",
            "<local-command", "<command-message", "[SYSTEM NOTIFICATION"
        ]
        // Strip a leading harness wrapper block first — a real prompt may follow one
        // (e.g. "<local-command-caveat>…</…>\nactual prompt").
        if prompt.hasPrefix("<"), let close = prompt.range(of: ">\n") {
            let rest = prompt[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty, !rest.hasPrefix("<"), !rest.hasPrefix("[SYSTEM") { prompt = rest }
        }
        if machineMarkers.contains(where: { prompt.hasPrefix($0) }) { return nil }
        return prompt.isEmpty ? nil : prompt
    }

    private static func metadata(in url: URL) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > 65_536 ? end - 65_536 : 0
        try? handle.seek(toOffset: start)
        guard let tail = try? handle.readToEnd() else { return nil }
        // Scan every line in the byte-bounded window, not just the last N by count: a
        // tool-heavy transcript can pack more than a fixed line cap into 64KB, which let a
        // real custom-title/summary line inside this window still be silently skipped (#21).
        let tailMetadata = metadata(
            in: tail.split(separator: 0x0A).reversed(),
            basePosition: start
        )

        // Resumed sessions can carry title metadata at the file HEAD, not the tail.
        guard start > 0 else { return tailMetadata }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 16_384) else { return tailMetadata }
        let headMetadata = metadata(
            in: head.split(separator: 0x0A),
            basePosition: 0
        )
        return merged(tailMetadata, fallback: headMetadata)
    }

    private static func metadata<S: Sequence>(
        in lines: S,
        basePosition: UInt64
    ) -> Metadata where S.Element == Data {
        var metadata = Metadata()

        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            let position = basePosition + UInt64(line.startIndex)

            switch type {
            case "custom-title":
                guard let value = object["customTitle"] as? String, !value.isEmpty else { continue }
                metadata.customTitle = latest(
                    metadata.customTitle,
                    LocatedValue(value: value, position: position)
                )
            case "agent-name":
                guard let value = object["agentName"] as? String, !value.isEmpty else { continue }
                metadata.agentName = latest(
                    metadata.agentName,
                    LocatedValue(value: value, position: position)
                )
            case "summary":
                guard metadata.summary == nil,
                      let value = object["summary"] as? String,
                      !value.isEmpty else { continue }
                metadata.summary = LocatedValue(value: value, position: position)
            default:
                continue
            }
        }

        return metadata
    }

    private static func latest(_ first: LocatedValue?, _ second: LocatedValue?) -> LocatedValue? {
        guard let first else { return second }
        guard let second else { return first }
        return first.position >= second.position ? first : second
    }

    private static func merged(_ metadata: Metadata, fallback: Metadata) -> Metadata {
        Metadata(
            customTitle: latest(metadata.customTitle, fallback.customTitle),
            agentName: latest(metadata.agentName, fallback.agentName),
            summary: metadata.summary ?? fallback.summary
        )
    }
}
