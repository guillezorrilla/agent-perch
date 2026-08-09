import Foundation

enum SessionTitle {
    static func resolve(
        sessionFileURL: URL?,
        lastPrompt: String?,
        cwd: String
    ) -> String {
        if let sessionFileURL, let summary = summary(in: sessionFileURL) {
            return summary
        }
        if let prompt = displayablePrompt(lastPrompt) {
            return String(prompt.prefix(40))
        }
        return cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
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

    private static func summary(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > 65_536 ? end - 65_536 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let tail = String(data: data, encoding: .utf8) else { return nil }

        if let found = firstSummary(in: tail.split(whereSeparator: \Character.isNewline).suffix(50).reversed()) {
            return found
        }
        // Resumed sessions carry their summary lines at the file HEAD, not the tail.
        guard start > 0 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let headData = try? handle.read(upToCount: 16_384),
              let head = String(data: headData, encoding: .utf8) else { return nil }
        return firstSummary(in: head.split(whereSeparator: \Character.isNewline).prefix(20))
    }

    private static func firstSummary<S: Sequence>(in lines: S) -> String? where S.Element == Substring {
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any],
                  object["type"] as? String == "summary",
                  let summary = object["summary"] as? String,
                  !summary.isEmpty else { continue }
            return summary
        }
        return nil
    }
}
