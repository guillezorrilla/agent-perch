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

enum PendingAction: Equatable, Sendable {
    case permission(PermissionRequest)
    case plan(String)

    static func parse(toolName: String?, input: JSONValue?) -> PendingAction? {
        guard let toolName, let input, case let .object(object) = input else { return nil }
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
