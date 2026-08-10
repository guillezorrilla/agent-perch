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
            return String(prompt.prefix(40))
        }
        return cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }

    /// Codex has no transcript metadata or hook-provided prompt to fall back on — just the
    /// session index's `thread_name` (when it looks like a real title, not a stored path) and
    /// the cwd basename.
    static func resolveCodex(threadName: String?, cwd: String) -> String {
        if let threadName, isUsableThreadName(threadName) {
            return String(threadName.prefix(60))
        }
        return cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }

    private static func isUsableThreadName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.hasPrefix("/") && !trimmed.hasPrefix("~/")
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
        let tailMetadata = metadata(
            in: tail.split(separator: 0x0A).suffix(50).reversed(),
            basePosition: start
        )

        // Resumed sessions can carry title metadata at the file HEAD, not the tail.
        guard start > 0 else { return tailMetadata }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 16_384) else { return tailMetadata }
        let headMetadata = metadata(
            in: head.split(separator: 0x0A).prefix(20),
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
