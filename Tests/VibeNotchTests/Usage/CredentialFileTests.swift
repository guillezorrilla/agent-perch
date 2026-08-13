import XCTest
@testable import VibeNotch

/// The distinction #56 taught Claude's keychain read and nothing else: a credential file that is
/// missing means "never logged in", and one that cannot be read right now means "try again".
/// Codex and Gemini collapsed both into the first, silently dropping their rows.
final class CredentialFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-file-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAMissingFileIsAbsentRatherThanUnreadable() {
        XCTAssertEqual(
            CredentialFile.read(directory.appendingPathComponent("nothing-here.json")),
            .absent
        )
    }

    func testAReadableFileComesBackWithItsContents() throws {
        let url = try write("{}", to: "auth.json")
        XCTAssertEqual(CredentialFile.read(url), .contents(Data("{}".utf8)))
    }

    /// A file that exists and cannot be read is the case that used to look identical to a missing
    /// one. A directory stands in for it: it is present, and reading it as data fails.
    func testAPresentButUnreadableFileIsNotMistakenForAMissingOne() throws {
        let url = directory.appendingPathComponent("a-directory.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        guard case let .unreadable(reason) = CredentialFile.read(url) else {
            return XCTFail("a present-but-unreadable file must not report as absent")
        }
        XCTAssertFalse(reason.isEmpty, "the row shows this reason, so it has to say something")
    }

    // MARK: - availability

    func testAbsentCredentialsOmitTheRow() {
        XCTAssertEqual(
            CredentialFile.availability(of: directory.appendingPathComponent("gone.json")) { _ in "token" },
            .notConfigured
        )
    }

    func testUnreadableCredentialsKeepTheRowAsRetryable() throws {
        let url = directory.appendingPathComponent("a-directory.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        guard case .unavailable = CredentialFile.availability(of: url, parse: { _ in "token" }) else {
            return XCTFail("an unreadable credential file must leave a retryable row on screen")
        }
    }

    /// Present but not credentials is configured *wrongly*, not transient — it stays an omitted
    /// row, exactly as before.
    func testAFileThatIsNotCredentialsStaysNotConfigured() throws {
        let url = try write("not json at all", to: "auth.json")
        XCTAssertEqual(
            CredentialFile.availability(of: url) { try? CodexCredentialParser.credentials(from: $0) },
            .notConfigured
        )
    }

    func testValidCredentialsAreReady() throws {
        let url = try write(
            #"{"tokens":{"access_token":"abc","account_id":"xyz"}}"#,
            to: "auth.json"
        )
        XCTAssertEqual(
            CredentialFile.availability(of: url) { try? CodexCredentialParser.credentials(from: $0) },
            .ready
        )
    }

    // MARK: - the sources that had the bug

    func testCodexReportsAnUnreadableAuthFileAsRetryableRatherThanAbsent() async throws {
        let url = directory.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let source = CodexUsageSource(tokenSource: RuntimeCodexTokenSource(authURL: url))
        guard case .unavailable = await source.availability() else {
            return XCTFail("a transient Codex credential read must not drop the row")
        }
    }

    func testCodexStillOmitsItsRowWhenNobodyHasLoggedIn() async {
        let source = CodexUsageSource(
            tokenSource: RuntimeCodexTokenSource(authURL: directory.appendingPathComponent("none.json"))
        )
        let availability = await source.availability()
        XCTAssertEqual(availability, .notConfigured)
    }

    func testGeminiReportsAnUnreadableCredentialFileAsRetryableRatherThanAbsent() async throws {
        let url = directory.appendingPathComponent("oauth_creds.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let source = GeminiUsageSource(tokenSource: RuntimeGeminiTokenSource(credentialsURL: url))
        guard case .unavailable = await source.availability() else {
            return XCTFail("a transient Gemini credential read must not drop the row")
        }
    }
}
