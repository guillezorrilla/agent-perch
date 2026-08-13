import CoreServices
import Foundation

private let pathWatcherEventCallback: FSEventStreamCallback = {
    _, clientInfo, _, _, _, _ in
    guard let clientInfo else { return }
    Unmanaged<PathWatcher>
        .fromOpaque(clientInfo)
        .takeUnretainedValue()
        .scheduleRefresh()
}

/// Watches a fixed set of paths (directories or individual files) for changes via FSEvents,
/// generalized from the original Claude-projects-only watcher so the same mechanism covers
/// every agent source (Claude's `~/.claude/projects`, Codex's `sessions/` directory and
/// `session_index.jsonl`, and whatever a future agent adds). One FSEventStream root list
/// covers all of them — no need for one stream per path.
final class PathWatcher: @unchecked Sendable {
    private let paths: [URL]
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?

    init(directoryURLs: [URL], onChange: @escaping () -> Void) {
        self.paths = directoryURLs
        self.onChange = onChange
    }

    func start() {
        startEventStreamIfPossible()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.startEventStreamIfPossible()
            self.onChange()
        }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        debounceWorkItem?.cancel()
        pollTimer?.cancel()
        pollTimer = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func scheduleRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    /// Only the paths that exist yet can be handed to FSEvents; a path that appears later
    /// (e.g. `~/.codex` before Codex has ever run) is still covered by the 30s poll above,
    /// which calls `onChange()` unconditionally regardless of stream state.
    private func startEventStreamIfPossible() {
        guard stream == nil else { return }
        let existingPaths = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            pathWatcherEventCallback,
            &context,
            existingPaths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    deinit {
        stop()
    }
}
