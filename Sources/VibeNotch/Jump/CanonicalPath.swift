import Foundation

/// One spelling for a directory, so that two paths naming the same place compare equal.
///
/// The same cwd reaches us spelled several ways: `lsof` reports the fully resolved path
/// (`/private/var/folders/…`), a hook reports whatever the shell had (`/var/folders/…`), a
/// session file can carry a trailing slash, and any of them can sit behind a symlink the user
/// made themselves. Comparing those raw strings is how a jump lands in the wrong tab — or in no
/// tab at all, falling back to opening a new one beside the terminal it was looking for.
enum CanonicalPath {
    /// Symlinks resolved, `.`/`..` collapsed, no trailing slash.
    ///
    /// `resolvingSymlinksInPath()` only strips macOS's `/private` prefix for paths that still
    /// exist, so the prefix is normalized explicitly afterwards: a session whose directory was
    /// deleted while its card is on screen must still compare equal to itself.
    static func canonical(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let resolved = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return withoutTrailingSlash(withoutPrivatePrefix(resolved))
    }

    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    /// `/private/var`, `/private/tmp` and `/private/etc` are the three directories macOS also
    /// publishes at the root; every other `/private/…` path is a real one and is left alone.
    private static func withoutPrivatePrefix(_ path: String) -> String {
        for root in ["/private/var", "/private/tmp", "/private/etc"] where path == root
            || path.hasPrefix(root + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
