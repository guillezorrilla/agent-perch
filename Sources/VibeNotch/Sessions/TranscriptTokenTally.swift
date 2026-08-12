import Foundation

/// Summing a Claude transcript's `usage` records into "tokens this session has burned" (#15).
///
/// Two traps live in that sentence, both measured against real transcripts on this machine:
///
/// 1. **One response, many lines.** Claude Code writes one jsonl line per content block of a
///    single API response — text, thinking, and each `tool_use` — and every one of them repeats
///    that response's entire `usage` object. A 932KB transcript held 165 usage-bearing lines for
///    63 actual responses, so summing lines rather than responses inflated it 2.6x on its own.
///    Responses are always written contiguously (verified across the 40 newest transcripts here),
///    which is why deduplicating needs nothing but the previous `message.id`.
/// 2. **Cache reads are the same tokens, over and over.** `cache_read_input_tokens` is the whole
///    conversation re-read from cache on every turn, so it grows quadratically with the session.
///    Including it reported 6.5M tokens for that same 932KB transcript, and 121M for a 4MB one.
enum TranscriptTokens {
    /// Every distinct token exactly once: what newly entered the context (`input_tokens` for the
    /// uncached remainder, `cache_creation_input_tokens` for what was written to the cache) plus
    /// what came out. Deliberately excludes `cache_read_input_tokens` — see above. On the two
    /// transcripts measured this reports 204k and 1.69M, against real spends of that order.
    static func tokens(in usage: [String: Any]) -> Int {
        ["input_tokens", "output_tokens", "cache_creation_input_tokens"]
            .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
    }

    /// Sums a run of complete transcript lines, skipping any leading ones that still belong to
    /// `lastMessageID` (the tail of a response the previous chunk already counted).
    static func scan(
        _ chunk: String,
        after lastMessageID: String?
    ) -> (added: Int, lastMessageID: String?) {
        var added = 0
        var previous = lastMessageID
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            // Most of a transcript by volume is tool results, which carry no usage at all. This
            // keeps the JSON parser off them — it is the difference between decoding a megabyte
            // and decoding the few kilobytes of it that matter.
            guard line.contains("\"usage\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let id = message["id"] as? String
            if let id, id == previous { continue }
            previous = id ?? previous
            added += tokens(in: usage)
        }
        return (added, previous)
    }
}

/// Cumulative token counts for the sessions on screen, read from the tail of each transcript.
///
/// Hook payloads carry no token counts, so the transcript is the only source — and these files
/// reach tens of megabytes while `SessionStore.reconcile` runs on every hook event. So the tally
/// remembers where it stopped in each file and decodes only the bytes appended since, at most
/// `maxBytesPerPass` of them and at most once per `minimumInterval`. First sight of a large
/// backlog is therefore spread across a few refreshes — the number climbs to the truth over a
/// few seconds instead of blocking one reconcile for all of it (#15).
final class TranscriptTokenTally {
    /// Enough to keep up with a live turn several times over, small enough that a cold 12MB
    /// transcript never lands in a single main-actor pass.
    static let maxBytesPerPass = 256 * 1024
    /// Reconcile fires several times a second during a busy turn. Re-reading that often buys
    /// nothing — this is a running total, not a cursor anyone is watching — and would multiply
    /// the cold-start catch-up by the event rate.
    static let minimumInterval: TimeInterval = 1.0

    private struct Cursor {
        var offset: UInt64 = 0
        var lastMessageID: String?
        var total: Int = 0
        var readAt: Date?
    }

    private var cursors: [String: Cursor] = [:]

    func tokens(forSessionID id: String, transcript: URL, now: Date = Date()) -> Int {
        var cursor = cursors[id] ?? Cursor()
        if let readAt = cursor.readAt, now.timeIntervalSince(readAt) < Self.minimumInterval {
            return cursor.total
        }
        cursor.readAt = now
        defer { cursors[id] = cursor }

        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return cursor.total }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        // Truncated or replaced under us — start over rather than reading from an offset that
        // now means something else entirely.
        if size < cursor.offset {
            cursor = Cursor(readAt: now)
        }
        guard size > cursor.offset else { return cursor.total }

        try? handle.seek(toOffset: cursor.offset)
        let wanted = min(size - cursor.offset, UInt64(Self.maxBytesPerPass))
        guard let data = try? handle.read(upToCount: Int(wanted)), !data.isEmpty else {
            return cursor.total
        }

        // Stop at the last complete line: the file is being appended to right now, and half a
        // JSON object parses as nothing and would be skipped forever.
        guard let newline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            // A single line longer than a whole pass. Skip past what was read rather than
            // reading it again forever; the next newline resynchronises, at the cost of that one
            // line's usage.
            if data.count == Self.maxBytesPerPass { cursor.offset += UInt64(data.count) }
            return cursor.total
        }
        let consumed = data.distance(from: data.startIndex, to: newline) + 1
        cursor.offset += UInt64(consumed)
        if let chunk = String(data: data[data.startIndex..<newline], encoding: .utf8) {
            let scanned = TranscriptTokens.scan(chunk, after: cursor.lastMessageID)
            cursor.total += scanned.added
            cursor.lastMessageID = scanned.lastMessageID
        }
        return cursor.total
    }

    /// Drops cursors for sessions no longer in the list, so an app left running for a week
    /// doesn't hold one per session it ever saw.
    func retain(sessionIDs: Set<String>) {
        guard cursors.count > sessionIDs.count else { return }
        cursors = cursors.filter { sessionIDs.contains($0.key) }
    }
}
