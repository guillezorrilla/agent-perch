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

    /// Whether this action blocks on the user by itself.
    ///
    /// `AskUserQuestion` and `ExitPlanMode` block by definition — the tool call IS the wait — so
    /// they corroborate themselves and need no notification to back them up. A permission request
    /// does not: `PreToolUse` fires for every matching call, auto-approved ones included.
    ///
    /// This one property replaces the same three-arm switch written out in two files, once in
    /// `NotificationOutcome.of` (the write-time gate that flips a session to `.needsAction`) and
    /// once in `resolve` below (the read-time gate that picks the card). They agreed only because
    /// somebody kept them agreeing.
    var blocksOnItsOwn: Bool {
        switch self {
        case .question, .plan: true
        case .permission: false
        }
    }

    /// The numbered choices this card offers, in ⌘1…⌘n order.
    ///
    /// Empty for a question, whose choices come from the prompt itself and are answered through it
    /// rather than by label.
    ///
    /// This lives on the action rather than on the card views because the card is not the only
    /// thing that answers it: the keyboard monitor does too, and when each derived the list
    /// separately they could disagree about which numbers were valid and what pressing one meant.
    var numberedOptions: [(label: String, description: String)] {
        switch self {
        case let .permission(request): Self.permissionAffirmatives(forTool: request.toolName)
        case .plan: Self.planOptions
        case .question: []
        }
    }

    /// Whether ⌘Y / ⌘N mean anything for this card.
    ///
    /// A question has numbered answers only — allow/deny would be a guess. For a plan, ⌘Y used to
    /// type a `1`, and `1` on the plan prompt is AUTO MODE: the one choice a user pressing
    /// "Approve" is least likely to have meant (#66).
    var acceptsAllowDeny: Bool {
        switch self {
        case .permission: true
        case .plan, .question: false
        }
    }

    /// The label for a 1-based option number, or `nil` when that number is not on offer.
    ///
    /// The bounds check `pendingCard` and `handleShortcut` each used to make separately — and
    /// which `pendingCard`'s plan arm did not make at all, indexing the array directly.
    func optionLabel(_ number: Int) -> String? {
        let options = numberedOptions
        guard options.indices.contains(number - 1) else { return nil }
        return options[number - 1].label
    }

    /// The affirmative half of Claude Code's permission prompt, which has three options where this
    /// card used to offer two (#61). Only "yes" is spelled the same for every tool; option 2 —
    /// the one worth having, since it is the difference between answering one card and answering
    /// ten — is worded per tool, so it is derived from the recorded tool name rather than guessed.
    ///
    /// Deny is NOT a third row here on purpose. Typing `3` assumes the prompt has exactly three
    /// options, which is true for the tools above and not something this app can know in general;
    /// Escape cancels whatever shape the prompt is. So the digits cover the two "yes" paths and
    /// the proven Escape path stays where it was, unchanged and untouched by this.
    static func permissionAffirmatives(forTool tool: String) -> [(label: String, description: String)] {
        [
            ("Yes", "Just this once"),
            (rememberLabel(forTool: tool), "Stops this card coming back")
        ]
    }

    private static func rememberLabel(forTool tool: String) -> String {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return "Yes, allow all edits this session"
        case "Bash":
            return "Yes, don't ask again for this command"
        default:
            return "Yes, and don't ask again"
        }
    }

    /// Claude Code's own plan prompt, in its own order — the card exists to answer THAT prompt, and
    /// ⌘1…⌘3 type the matching digit into it.
    ///
    /// Approve/Deny was not just incomplete, it was misleading: "Approve" typed a `1`, and `1` on
    /// this prompt is *auto mode*, not the manual approval the button implied (#66). Naming the
    /// three real choices is the only way the card can be honest about what it is about to send.
    ///
    /// Coupled to another app's wording by construction. The DIGITS are the contract — those have
    /// been stable — and the labels are what the user reads before pressing one, so a wording drift
    /// shows up as a stale label rather than a wrong keystroke.
    static let planOptions: [(label: String, description: String)] = [
        ("Yes, and use auto mode", "Claude edits without asking again"),
        ("Yes, manually approve edits", "Every edit still asks first"),
        ("Tell Claude what to change", "Opens the session so you can type feedback")
    ]

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
        // A question or a plan IS the thing being waited on, so the tool call corroborates itself
        // and needs no notification to back it up. See `blocksOnItsOwn`.
        if recorded?.blocksOnItsOwn == true { return recorded }

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
