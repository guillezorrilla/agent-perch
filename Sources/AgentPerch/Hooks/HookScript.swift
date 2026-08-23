import Foundation

enum HookScript {
    static func url(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("agentperch-hook")
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
        # Claude Code spawns hooks DETACHED, so this process has no controlling terminal and the
        # line above prints "??". Every session in one folder therefore arrived with no tty, and
        # `JumpTarget.resolve` fell back to matching on cwd alone — where two live sessions share a
        # folder it picked the same process for BOTH, so both cards jumped to one tab (#70). The
        # agent itself does have a terminal, so walk up the parents until one of them admits to it.
        # Bounded, and it stops at pid 1: a walk that finds nothing leaves tty empty, exactly as
        # before, so this can only ever add information.
        pid=$$
        hops=0
        while { [ -z "$tty" ] || [ "$tty" = "??" ]; } && [ "$hops" -lt 8 ]; do
            pid="$(/bin/ps -o ppid= -p "$pid" | /usr/bin/xargs)"
            if [ -z "$pid" ] || [ "$pid" -le 1 ]; then break; fi
            tty="$(/bin/ps -o tty= -p "$pid" | /usr/bin/xargs)"
            hops=$((hops + 1))
        done
        [ "$tty" = "??" ] && tty=""
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
