import Foundation

enum DiffLineKind: Equatable, Sendable {
    case removed
    case added
}

struct DiffLine: Equatable, Sendable {
    let kind: DiffLineKind
    let text: String
}

struct DiffPreview: Equatable, Sendable {
    let lines: [DiffLine]
    let addedCount: Int
    let removedCount: Int
    let isTruncated: Bool

    static func build(removed: String, added: String, limit: Int = 8) -> DiffPreview {
        let removedLines = split(removed)
        let addedLines = split(added)
        let allLines = removedLines.map { DiffLine(kind: .removed, text: $0) }
            + addedLines.map { DiffLine(kind: .added, text: $0) }
        return DiffPreview(
            lines: Array(allLines.prefix(limit)),
            addedCount: addedLines.count,
            removedCount: removedLines.count,
            isTruncated: allLines.count > limit
        )
    }

    private static func split(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

struct PermissionRequest: Equatable, Sendable {
    let toolName: String
    let target: String
    let details: String
    let diff: DiffPreview?
}

struct QuestionPrompt: Equatable, Sendable {
    let question: String
    let header: String?
    let options: [String]
    let descriptions: [String?]
    let multiSelect: Bool
}

/// What an answered card shows in place of its buttons, for the ~1s it stays on screen.
enum ActionResolution: Equatable, Sendable {
    /// The answer went into the terminal. The label is what the user chose ("Approved ✓").
    case answered(String)
    /// Injection refused (unsupported terminal, Accessibility not granted, tab not found), so
    /// nothing was typed anywhere and the user still has to answer by hand.
    case failed
}

enum PendingAction: Equatable, Sendable {
    case permission(PermissionRequest)
    case plan(String)
    case question(QuestionPrompt)

    /// The single answer to "is this session really waiting on the user, and for what".
    ///
    /// `PreToolUse` fires for EVERY matching tool call, auto-approved ones included, so a recorded
    /// tool input is no evidence that anything is waiting. The `Notification` payload is: it fires
    /// both for genuine permission requests and for plain idle nudges, and only its message says
    /// which. Pairing an idle notification with the last, already-approved tool call is what used
    /// to fabricate "Permission Request — Bash grep -n …" cards for greps nobody was asked about,
    /// whose Allow button typed a "1" at a prompt that was not waiting for one.
    ///
    /// - Returns: the card to show, or `nil` for "no answerable card" — a needs-input session with
    ///   nothing blocked falls back to its normal card body.
    static func resolve(
        status: SessionStatus,
        notificationMessage: String?,
        toolName: String?,
        toolInput: JSONValue?
    ) -> PendingAction? {
        guard status == .needsAction else { return nil }
        let recorded = parse(toolName: toolName, input: toolInput)
        switch recorded {
        // A question or a plan IS the thing being waited on: `AskUserQuestion`/`ExitPlanMode`
        // block on the user by definition, so the tool call corroborates itself and needs no
        // notification to back it up.
        case .some(.question), .some(.plan):
            return recorded
        case .some(.permission), .none:
            break
        }

        guard let notificationMessage,
              case let .permission(tool) = NotificationKind.classify(notificationMessage) else {
            return nil
        }
        if case let .some(.permission(request)) = recorded {
            if let tool {
                // The message named a tool, so it has to agree with the recorded call. It is the
                // disagreement that is dangerous: showing tool B's diff under tool A's name is how
                // a user approves something they were never shown.
                if request.toolName.lowercased() == tool.lowercased() { return recorded }
            } else {
                // The message named no tool — "Claude needs your permission" is the wording for a
                // Write, with nothing after "to use " to parse. The recorded call is still the last
                // tool this turn to reach `PreToolUse`, cleared on every prompt and every `Stop`,
                // so it is the tool being asked about in all but a contrived case. This used to
                // fall through to the generic card below, which told the user nothing: they were
                // pressing ⌘Y on "Claude needs your permission" with no idea what they were
                // approving.
                //
                // The contrived case: a tool OUTSIDE the hook's matcher (WebFetch, an MCP tool)
                // blocks with an equally nameless message, leaving the previous matched call
                // recorded. Not observed — those messages do name their tool, which lands in the
                // branch above and is caught by the mismatch check.
                return recorded
            }
        }
        // Nothing recorded to attribute this to, or a recorded call that provably belongs to a
        // different tool: show the request, but never someone else's diff or command.
        return .permission(PermissionRequest(
            toolName: tool ?? "",
            target: "",
            details: notificationMessage,
            diff: nil
        ))
    }

    static func parse(toolName: String?, input: JSONValue?) -> PendingAction? {
        guard let toolName, let input, case let .object(object) = input else { return nil }
        if toolName == "AskUserQuestion" {
            guard let fields = object["questions"]?.arrayValue?.first?.objectValue,
                  let question = fields["question"]?.string,
                  !question.isEmpty,
                  let values = fields["options"]?.arrayValue else { return nil }
            let options = values.prefix(9).compactMap { value -> (label: String, description: String?)? in
                guard let option = value.objectValue,
                      let label = option["label"]?.string,
                      !label.isEmpty else { return nil }
                return (label, option["description"]?.string)
            }
            guard !options.isEmpty else { return nil }
            return .question(QuestionPrompt(
                question: question,
                header: fields["header"]?.string,
                options: options.map { $0.label },
                descriptions: options.map { $0.description },
                multiSelect: fields["multiSelect"] == .bool(true)
            ))
        }
        if toolName == "ExitPlanMode" {
            guard let plan = object["plan"]?.string, !plan.isEmpty else { return nil }
            return .plan(plan)
        }

        let path = object["file_path"]?.string ?? object["notebook_path"]?.string
        let command = object["command"]?.string
        let target = path.map(shortPath) ?? command.map { truncated($0, at: 60) } ?? toolName
        let diff: DiffPreview?
        switch toolName {
        case "Edit":
            diff = .build(
                removed: object["old_string"]?.string ?? "",
                added: object["new_string"]?.string ?? ""
            )
        case "MultiEdit":
            let edits = object["edits"]?.arrayValue ?? []
            let removed = edits.compactMap { $0.objectValue?["old_string"]?.string }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let added = edits.compactMap { $0.objectValue?["new_string"]?.string }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            diff = .build(removed: removed, added: added)
        case "Write":
            diff = .build(removed: "", added: object["content"]?.string ?? "")
        default:
            diff = nil
        }

        return .permission(PermissionRequest(
            toolName: toolName,
            target: target,
            details: command ?? input.displayText,
            diff: diff
        ))
    }

    private static func shortPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
    }

    private static func truncated(_ value: String, at limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit)) + "…" : value
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var displayText: String {
        switch self {
        case let .string(value): value
        case let .number(value): String(value)
        case let .bool(value): String(value)
        case let .object(value): value.keys.sorted().map { "\($0): \(value[$0]!.displayText)" }.joined(separator: "\n")
        case let .array(value): value.map(\.displayText).joined(separator: "\n")
        case .null: "null"
        }
    }
}
