import Foundation

/// Finds the executable a resume command should name, for the agents whose CLI is not reliably on
/// `PATH` (#11).
///
/// `Jumper` runs a resume command through `/bin/zsh -lc`, so a bare name only resolves if a LOGIN
/// shell can find it — and a GUI app's own `PATH` is launchd's, which says nothing about that.
/// Verified on this machine: a login shell finds `gemini` and `kiro-cli` but NOT `opencode`, which
/// installs to `~/.opencode/bin/opencode`. Naming a binary the shell cannot find turns the new-tab
/// fallback into a tab that prints "command not found", so every resume command here is built from
/// an absolute path that was checked to exist, and only falls back to the bare name when no
/// candidate did.
enum AgentBinary {
    /// The usual places a CLI lands on macOS, in the order a login shell would reach them. Callers
    /// prepend anything agent-specific (`~/.opencode/bin`, say) rather than this list growing one
    /// agent at a time.
    static func standardDirectories(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        ]
    }

    /// The first `<directory>/<name>` that exists and is executable, or `nil` when none does.
    /// Deliberately a plain filesystem check rather than a `which` subprocess: this is asked on a
    /// refresh tick, and spawning a shell to answer it would cost more than the whole enumeration
    /// around it.
    static func firstExecutable(
        named name: String,
        in directories: [URL],
        fileManager: FileManager = .default
    ) -> String? {
        directories
            .map { $0.appendingPathComponent(name).path }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }
}
