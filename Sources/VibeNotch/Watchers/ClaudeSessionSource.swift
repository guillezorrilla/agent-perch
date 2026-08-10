import Foundation

/// Ports `SessionStore`'s original file-discovery loop behind `AgentSessionSource`, unchanged:
/// title resolution and hook merging still happen in `SessionStore`, since both need hook
/// state this source has no access to (hook events remain Claude-only and must keep winning
/// over file state exactly as before).
struct ClaudeSessionSource: AgentSessionSource {
    let agentName = "Claude"
    let projectsDirectory: URL
    private let fileManager: FileManager

    init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.projectsDirectory = projectsDirectory
        self.fileManager = fileManager
    }

    func discover(now: Date) -> [DiscoveredSession] {
        var discovered: [String: DiscoveredSession] = [:]
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let projectDirectories = (try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        for projectDirectory in projectDirectories {
            guard (try? projectDirectory.resourceValues(forKeys: keys).isDirectory) == true else {
                continue
            }

            let cwd = ClaudeProjectPathDecoder.decode(
                projectDirectory.lastPathComponent,
                exists: fileManager.fileExists(atPath:)
            )
            let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
            let files = (try? fileManager.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: Array(fileKeys),
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: fileKeys),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      let status = SessionStatus.at(modifiedAt: modifiedAt, now: now) else {
                    continue
                }
                let id = file.deletingPathExtension().lastPathComponent
                if discovered[id]?.lastActivity ?? .distantPast < modifiedAt {
                    discovered[id] = DiscoveredSession(
                        sessionId: id,
                        agentName: agentName,
                        cwd: cwd,
                        title: nil,
                        lastActivity: modifiedAt,
                        status: status,
                        resumeCommand: nil,
                        sessionFileURL: file
                    )
                }
            }
        }

        return Array(discovered.values)
    }
}
