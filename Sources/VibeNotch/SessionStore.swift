import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    let projectsDirectory: URL
    private let fileManager: FileManager
    private let resolver = TTYResolver()

    init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.projectsDirectory = projectsDirectory
        self.fileManager = fileManager
    }

    func refresh(now: Date = Date()) {
        var discovered: [(id: String, cwd: String, modifiedAt: Date, status: SessionStatus)] = []
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
                discovered.append((
                    id: file.deletingPathExtension().lastPathComponent,
                    cwd: cwd,
                    modifiedAt: modifiedAt,
                    status: status
                ))
            }
        }

        let processes = discovered.isEmpty ? [] : resolver.processes()
        sessions = discovered
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(10)
            .map {
                AgentSession(
                    sessionId: $0.id,
                    cwd: $0.cwd,
                    modifiedAt: $0.modifiedAt,
                    status: $0.status,
                    jumpRung: Jumper.rung(for: $0.cwd, processes: processes)
                )
            }
    }
}
