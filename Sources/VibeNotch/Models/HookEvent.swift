import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var object: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

struct HookEvent: Codable, Equatable, Sendable {
    let event: String
    let tty: String
    let ts: TimeInterval
    let payload: [String: JSONValue]

    var timestamp: Date { Date(timeIntervalSince1970: ts) }
    var sessionID: String? { payload["session_id"]?.string }
    var cwd: String? { payload["cwd"]?.string }
    var message: String? { payload["message"]?.string }
    var prompt: String? { payload["prompt"]?.string }
    var toolName: String? { payload["tool_name"]?.string }
    var toolInput: JSONValue? { payload["tool_input"] }

    static func parse(_ data: Data) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: data)
    }
}

enum ActivityLine {
    static func describe(toolName: String?, toolInput: JSONValue?) -> String? {
        guard let toolName else { return nil }

        switch toolName {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            guard let path = field("file_path", in: toolInput) else { return nil }
            return "Writing \(URL(fileURLWithPath: path).lastPathComponent)"
        case "Read":
            guard let path = field("file_path", in: toolInput) else { return nil }
            return "Reading \(URL(fileURLWithPath: path).lastPathComponent)"
        case "Bash":
            guard let command = field("command", in: toolInput) else { return nil }
            let singleLine = command.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            guard !singleLine.isEmpty else { return nil }
            return "Running \(singleLine.prefix(40))"
        case "Grep", "Glob":
            guard let query = field("pattern", in: toolInput) ?? field("path", in: toolInput) else {
                return nil
            }
            return "Searching \(query)"
        case "WebFetch":
            guard let url = field("url", in: toolInput),
                  let host = URLComponents(string: url)?.host else { return nil }
            return "Fetching \(host)"
        case "WebSearch":
            return "Searching the web"
        case "TodoWrite":
            return "Updating the plan"
        case "Task":
            return "Delegating a subtask"
        case "ExitPlanMode":
            return "Awaiting plan approval"
        default:
            return nil
        }
    }

    private static func field(_ name: String, in input: JSONValue?) -> String? {
        guard let value = input?.object?[name]?.string, !value.isEmpty else { return nil }
        return value
    }
}
