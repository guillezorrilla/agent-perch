import AppKit

/// The seam `Jumper` was missing. Every other collaborator it uses arrives through its
/// initializer; this one was a hardwired `let`, which put every AppleScript string in the
/// jump path out of reach of any test — including the opener ladder, where a terminal with
/// no arm of its own silently fell through to somebody else's app.
protocol AppleScripting: Sendable {
    func run(_ source: String) -> Bool
}

struct AppleScriptRunner: AppleScripting {
    func run(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func stringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
