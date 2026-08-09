import Combine
import Foundation

struct UsageWindow: Equatable, Sendable {
    let utilization: Double
    let resetsAt: Date

    var level: UsageLevel {
        if utilization < 50 { return .low }
        if utilization < 80 { return .medium }
        return .high
    }

    func resetText(from now: Date = Date()) -> String {
        let totalMinutes = max(0, Int(resetsAt.timeIntervalSince(now)) / 60)
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

enum UsageLevel: Equatable, Sendable {
    case low
    case medium
    case high
}

struct UsageSnapshot: Equatable, Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let raw = try JSONDecoder().decode(RawUsage.self, from: data)
        return UsageSnapshot(
            fiveHour: try raw.fiveHour.value,
            sevenDay: try raw.sevenDay.value
        )
    }
}

enum CredentialParser {
    static func accessToken(from data: Data) throws -> String {
        let credentials = try JSONDecoder().decode(Credentials.self, from: data)
        guard !credentials.claudeAiOauth.accessToken.isEmpty else {
            throw CocoaError(.coderValueNotFound)
        }
        return credentials.claudeAiOauth.accessToken
    }

    private struct Credentials: Decodable {
        let claudeAiOauth: OAuth
    }

    private struct OAuth: Decodable {
        let accessToken: String
    }
}

protocol UsageTokenSource {
    func accessToken() -> String?
}

protocol UsageLoading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UsageLoading {}

struct RuntimeUsageTokenSource: UsageTokenSource {
    let credentialsURL: URL

    init(credentialsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")) {
        self.credentialsURL = credentialsURL
    }

    func accessToken() -> String? {
        if let data = securityOutput(), let token = try? CredentialParser.accessToken(from: data) {
            return token
        }
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return try? CredentialParser.accessToken(from: data)
    }

    private func securityOutput() -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

@MainActor
final class UsageProvider: ObservableObject {
    @Published private(set) var usage: UsageSnapshot?
    private var lastGood: UsageSnapshot?
    private let tokenSource: UsageTokenSource
    private let loader: UsageLoading

    init(
        tokenSource: UsageTokenSource = RuntimeUsageTokenSource(),
        loader: UsageLoading = URLSession.shared
    ) {
        self.tokenSource = tokenSource
        self.loader = loader
    }

    func showCached() {
        usage = lastGood
    }

    func refresh() async {
        guard let token = tokenSource.accessToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            usage = nil
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await loader.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  200..<300 ~= response.statusCode else {
                usage = nil
                return
            }
            let parsed = try UsageSnapshot.parse(data)
            lastGood = parsed
            usage = parsed
        } catch {
            usage = nil
        }
    }
}

private struct RawUsage: Decodable {
    let fiveHour: RawUsageWindow
    let sevenDay: RawUsageWindow

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct RawUsageWindow: Decodable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var value: UsageWindow {
        get throws {
            guard let date = Self.parseDate(resetsAt) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return UsageWindow(utilization: utilization, resetsAt: date)
        }
    }

    // The API sends fractional seconds ("...59.588521+00:00"), which a default
    // ISO8601DateFormatter can't parse — try with fractional seconds first, then without.
    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
