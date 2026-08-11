import Foundation

struct HookInstaller {
    /// Claude Code matches this as a whole-name regex, not a substring one: `TaskCreate` fires only
    /// because it is spelled out here, and `Write` alone would never have matched `TodoWrite`
    /// (verified against a live hook, #41). The checklist tools earn their place because the card's
    /// ✓/■/□ rows are fed from nothing else — without them the panel could never show a real goal.
    static let preToolUseMatcher = "Edit|MultiEdit|Write|Bash|NotebookEdit|ExitPlanMode|AskUserQuestion|TodoWrite|TaskCreate|TaskUpdate"
    static let eventNames = [
        "SessionStart",
        "UserPromptSubmit",
        "Notification",
        "Stop",
        "SessionEnd",
        "PreToolUse"
    ]

    let settingsURL: URL
    private let fileManager: FileManager

    init(settingsURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
    }

    @discardableResult
    func install(binURL: URL) throws -> Bool {
        try update { hooks in
            for eventName in Self.eventNames {
                var entries = (hooks[eventName] as? [Any]) ?? []
                entries = entries.compactMap(Self.removingOurCommands)

                var entry: [String: Any] = [
                    "hooks": [[
                        "type": "command",
                        "command": Self.command(binURL: binURL, eventName: eventName)
                    ]]
                ]
                if eventName == "PreToolUse" {
                    entry["matcher"] = Self.preToolUseMatcher
                }
                entries.append(entry)
                hooks[eventName] = entries
            }
        }
    }

    @discardableResult
    func uninstall() throws -> Bool {
        try update { hooks in
            for eventName in Array(hooks.keys) {
                guard var entries = hooks[eventName] as? [Any] else { continue }
                entries = entries.compactMap(Self.removingOurCommands)
                if entries.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = entries
                }
            }
        }
    }

    func hasInstalledHooks(binURL: URL? = nil) -> Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return Self.eventNames.allSatisfy { eventName in
            guard let entries = hooks[eventName] as? [Any] else { return false }
            return entries.contains {
                Self.isInstalledEntry($0, eventName: eventName, binURL: binURL)
            }
        }
    }

    private func update(_ mutation: (inout [String: Any]) -> Void) throws -> Bool {
        let original = try loadSettings()
        var updated = original
        let hadHooks = updated["hooks"] != nil
        guard !hadHooks || updated["hooks"] is [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var hooks = (updated["hooks"] as? [String: Any]) ?? [:]
        mutation(&hooks)
        if hadHooks || !hooks.isEmpty {
            updated["hooks"] = hooks
        }

        guard !NSDictionary(dictionary: original).isEqual(to: updated) else { return false }

        if fileManager.fileExists(atPath: settingsURL.path) {
            let backupURL = settingsURL.appendingPathExtension("vibenotch-bak")
            if !fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.copyItem(at: settingsURL, to: backupURL)
            }
        } else {
            try fileManager.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
        return true
    }

    private func loadSettings() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
        guard let settings = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return settings
    }

    private static func removingOurCommands(from value: Any) -> Any? {
        guard var entry = value as? [String: Any],
              let hooks = entry["hooks"] as? [Any] else { return value }
        let remaining = hooks.filter { !isOurCommand($0) }
        guard remaining.count != hooks.count else { return value }
        guard !remaining.isEmpty else { return nil }
        entry["hooks"] = remaining
        return entry
    }

    private static func isOurCommand(_ value: Any) -> Bool {
        guard let hook = value as? [String: Any],
              let command = hook["command"] as? String else { return false }
        return command.contains("vibenotch-hook")
    }

    private static func isInstalledEntry(
        _ value: Any,
        eventName: String,
        binURL: URL?
    ) -> Bool {
        guard let entry = value as? [String: Any],
              let hooks = entry["hooks"] as? [Any] else { return false }
        if eventName == "PreToolUse" {
            guard entry["matcher"] as? String == preToolUseMatcher else {
                return false
            }
        } else if entry["matcher"] != nil {
            return false
        }

        return hooks.contains { value in
            guard let hook = value as? [String: Any],
                  hook["type"] as? String == "command",
                  let installedCommand = hook["command"] as? String else { return false }
            if let binURL {
                return installedCommand == command(binURL: binURL, eventName: eventName)
            }
            return installedCommand.contains("vibenotch-hook")
                && installedCommand.hasSuffix(" \(eventName)")
        }
    }

    private static func command(binURL: URL, eventName: String) -> String {
        "\(AppleScriptRunner.shellQuote(binURL.path)) \(eventName)"
    }
}
