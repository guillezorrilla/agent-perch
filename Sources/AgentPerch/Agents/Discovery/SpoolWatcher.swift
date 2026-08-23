import Darwin
import Foundation

final class SpoolWatcher: @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let onEvent: (HookEvent) -> Void
    private var source: DispatchSourceFileSystemObject?

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        onEvent: @escaping (HookEvent) -> Void
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.onEvent = onEvent
    }

    func start() {
        guard source == nil else { return }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.processPendingFiles() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        processPendingFiles()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    func processPendingFiles() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = ((try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []).compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted {
            $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 < $1.1
        }

        for (url, _) in files {
            if let data = try? Data(contentsOf: url),
               let event = try? HookEvent.parse(data) {
                onEvent(event)
            }
            try? fileManager.removeItem(at: url)
        }
    }

    deinit {
        stop()
    }
}
