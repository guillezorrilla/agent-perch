import Foundation

enum HookScript {
    static func url(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("vibenotch-hook")
    }

    static func content(applicationSupportDirectory: URL) -> String {
        let root = AppleScriptRunner.shellQuote(applicationSupportDirectory.path)
        return """
        #!/bin/zsh
        exec 2>/dev/null
        event="$1"
        events=\(root)/events
        staging="$events/.staging"
        /bin/mkdir -p "$staging" || exit 0
        temporary="$(/usr/bin/mktemp "$staging/event.XXXXXX")" || exit 0
        tty="$(/bin/ps -o tty= -p $$ | /usr/bin/xargs)"
        timestamp="$(/bin/date +%s)"
        if {
            /usr/bin/printf '{"event":"%s","tty":"%s","ts":%s,"payload":' "$event" "$tty" "$timestamp"
            /bin/cat
            /usr/bin/printf '}\n'
        } > "$temporary"; then
            /bin/mv "$temporary" "$events/event-$timestamp-$$-$RANDOM.json" || /bin/rm -f "$temporary"
        else
            /bin/rm -f "$temporary"
        fi
        exit 0

        """
    }

    @discardableResult
    static func materialize(
        in applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let scriptURL = url(in: applicationSupportDirectory)
        let content = Data(content(applicationSupportDirectory: applicationSupportDirectory).utf8)
        if (try? Data(contentsOf: scriptURL)) == content { return false }

        try fileManager.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: applicationSupportDirectory
                .appendingPathComponent("events/.staging", isDirectory: true),
            withIntermediateDirectories: true
        )
        try content.write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return true
    }
}
