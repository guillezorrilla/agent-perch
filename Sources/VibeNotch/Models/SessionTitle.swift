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
        if let lastPrompt, !lastPrompt.isEmpty {
            return String(lastPrompt.prefix(40))
        }
        return cwd.hasPrefix("/") ? URL(fileURLWithPath: cwd).lastPathComponent : cwd
    }

    private static func summary(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > 65_536 ? end - 65_536 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let tail = String(data: data, encoding: .utf8) else { return nil }

        return tail.split(whereSeparator: \Character.isNewline)
            .suffix(50)
            .reversed()
            .lazy
            .compactMap { line -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                      object["type"] as? String == "summary",
                      let summary = object["summary"] as? String,
                      !summary.isEmpty else { return nil }
                return summary
            }
            .first
    }
}
