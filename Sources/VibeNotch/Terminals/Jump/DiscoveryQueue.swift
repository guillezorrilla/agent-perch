import Foundation

/// The one background queue every "where does this session actually live?" question is answered
/// on — the process table, a terminal's identity, a Warp tab index, a tmux pane.
///
/// Serial and shared on purpose: two rapid clicks resolve one after the other rather than scanning
/// on top of each other, which also keeps the ancestry and Warp-database caches behind them
/// effectively single-threaded. Jumping was moved onto it in #23; answering joins it in #32, where
/// the same discovery ran inline on the main thread and a ~30MB copy of Warp's sqlite behind a
/// click froze the whole app for as long as the copy took.
enum DiscoveryQueue {
    static let shared = DispatchQueue(label: "dev.vibenotch.jump.discovery", qos: .userInitiated)

    /// Runs `work` on the queue and hands its result back to the calling async context — the
    /// single bridge every two-phase "resolve, then act on the main actor" path uses.
    static func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            shared.async { continuation.resume(returning: work()) }
        }
    }
}
