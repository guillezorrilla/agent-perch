import CoreServices
import Foundation

enum ClaudeProjectPathDecoder {
    static func decode(
        _ encoded: String,
        exists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> String {
        guard encoded.hasPrefix("-") else { return encoded }

        let pieces = encoded.dropFirst().split(
            separator: "-",
            omittingEmptySubsequences: false
        ).map(String.init)

        func resolve(from index: Int, beneath parent: String) -> String? {
            guard index < pieces.count else { return exists(parent) ? parent : nil }

            var component = ""
            for end in index..<pieces.count {
                if end > index { component += "-" }
                component += pieces[end]
                guard !component.isEmpty else { continue }

                let candidate = parent == "/"
                    ? "/\(component)"
                    : "\(parent)/\(component)"
                if exists(candidate),
                   let resolved = resolve(from: end + 1, beneath: candidate) {
                    return resolved
                }
            }
            return nil
        }

        return resolve(from: 0, beneath: "/") ?? encoded
    }
}

private let claudeProjectsEventCallback: FSEventStreamCallback = {
    _, clientInfo, _, _, _, _ in
    guard let clientInfo else { return }
    Unmanaged<ClaudeProjectsWatcher>
        .fromOpaque(clientInfo)
        .takeUnretainedValue()
        .scheduleRefresh()
}

final class ClaudeProjectsWatcher: @unchecked Sendable {
    private let directoryURL: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?

    init(directoryURL: URL, onChange: @escaping () -> Void) {
        self.directoryURL = directoryURL
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

    private func startEventStreamIfPossible() {
        guard stream == nil,
              FileManager.default.fileExists(atPath: directoryURL.path) else { return }

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
            claudeProjectsEventCallback,
            &context,
            [directoryURL.path] as CFArray,
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
