import Foundation

/// Reading a credential file, keeping the one distinction that matters: a file that is *not there*
/// means the user never logged in to this provider, and a file that *is* there but could not be
/// read right now is a transient failure.
///
/// Collapsing those two into "not configured" is what #56 fixed for Claude, where a dark-wake
/// keychain failure latched the row off until relaunch. The fix landed inside
/// `RuntimeUsageTokenSource` and was never generalised: Codex and Gemini both read their token
/// files with a bare `try? Data(contentsOf:)`, so a transient disk error still reads to them as
/// "never logged in" and silently drops the row instead of showing it as retryable.
///
/// The `UsageSource` seam already had somewhere to put the answer — `UsageAvailability` has had
/// `.unavailable` alongside `.notConfigured` since #28. Only the file readers never told it apart.
enum CredentialFile {
    enum ReadOutcome: Equatable, Sendable {
        case contents(Data)
        /// No file. The user has not logged in to this provider on this machine — omit the row.
        case absent
        /// The file exists and this read failed. Say so and let the refresh button retry, rather
        /// than concluding anything about whether the user is logged in.
        case unreadable(String)
    }

    static func read(_ url: URL) -> ReadOutcome {
        do {
            return .contents(try Data(contentsOf: url))
        } catch {
            // Asked after the fact rather than before: the happy path stays a single read, and a
            // file that vanishes between the two is reported absent, which is what the old
            // behavior would have said anyway.
            guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
            return .unreadable((error as NSError).localizedDescription)
        }
    }

    /// The outcome above, expressed as the availability the strip renders. `parse` returning `nil`
    /// means the file is there and is not credentials — configured wrongly, not configured at all,
    /// which stays an omitted row exactly as before.
    static func availability<T>(of url: URL, parse: (Data) -> T?) -> UsageAvailability {
        switch read(url) {
        case let .contents(data): return parse(data) != nil ? .ready : .notConfigured
        case .absent: return .notConfigured
        case let .unreadable(reason): return .unavailable(reason)
        }
    }
}
