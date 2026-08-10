import Foundation

/// What a Claude Code `Notification` hook is actually telling us.
///
/// The same hook fires for two very different things: "Claude needs your permission to use Bash"
/// (a tool call is blocked until the user answers) and "Claude is waiting for your input" (the
/// prompt has simply gone idle). Only the `message` distinguishes them, which makes this text
/// the single source of truth for whether anything is waiting on an answer at all.
enum NotificationKind: Equatable, Sendable {
    /// A tool call is blocked on a permission answer. `tool` is the name when the wording yields
    /// one, `nil` when it doesn't — a `nil` tool still means "show the request", it just means we
    /// cannot prove which recorded tool call it belongs to.
    case permission(tool: String?)
    /// An idle nudge — and everything we don't recognise. Unknown wording is deliberately NOT
    /// treated as a permission request: a missing Allow/Deny card is a nuisance, a fabricated one
    /// asks the user to answer a question nobody asked and injects a keystroke into their shell.
    case waiting

    /// Deliberately loose: any mention of "permission" counts, because the exact sentence is
    /// Claude Code's to change. Everything else — including a message we've never seen — is
    /// `.waiting`.
    static func classify(_ message: String?) -> NotificationKind {
        guard let message,
              message.range(of: "permission", options: .caseInsensitive) != nil else {
            return .waiting
        }
        return .permission(tool: tool(in: message))
    }

    /// The tool name that follows "to use " ("…permission to use Bash" -> "Bash"), tolerating a
    /// leading article and trailing sentence punctuation. Nothing else is guessed: a name we made
    /// up would pair the request with the wrong recorded tool call, which is the bug this whole
    /// type exists to prevent.
    private static func tool(in message: String) -> String? {
        guard let marker = message.range(of: "to use ", options: .caseInsensitive) else {
            return nil
        }
        var rest = message[marker.upperBound...]
        if let article = rest.range(of: "the ", options: [.caseInsensitive, .anchored]) {
            rest = rest[article.upperBound...]
        }
        // Stops at whitespace and sentence punctuation only — `isPunctuation` would also cut at
        // the underscores in MCP tool names like `mcp__ide__getDiagnostics`.
        let terminators: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "'", "(", ")"]
        let name = rest.prefix { !$0.isWhitespace && !terminators.contains($0) }
        return name.isEmpty ? nil : String(name)
    }
}
