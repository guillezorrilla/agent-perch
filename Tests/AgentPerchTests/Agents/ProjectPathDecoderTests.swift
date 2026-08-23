import XCTest
@testable import AgentPerch

final class ProjectPathDecoderTests: XCTestCase {
    func testDecodesAnEncodedAbsolutePath() {
        let existing = Set([
            "/Users",
            "/Users/gzorrilla",
            "/Users/gzorrilla/Developer",
            "/Users/gzorrilla/Developer/personal",
            "/Users/gzorrilla/Developer/personal/agent-perch"
        ])

        let decoded = ClaudeProjectPathDecoder.decode(
            "-Users-gzorrilla-Developer-personal-agent-perch",
            exists: { existing.contains($0) }
        )

        XCTAssertEqual(decoded, "/Users/gzorrilla/Developer/personal/agent-perch")
    }

    func testResolvesDashesInsideDirectoryNamesUsingExistingPaths() {
        let existing = Set([
            "/Users",
            "/Users/gzorrilla",
            "/Users/gzorrilla/Developer",
            "/Users/gzorrilla/Developer/personal",
            "/Users/gzorrilla/Developer/personal/agent-perch"
        ])

        let decoded = ClaudeProjectPathDecoder.decode(
            "-Users-gzorrilla-Developer-personal-agent-perch",
            exists: { existing.contains($0) }
        )

        XCTAssertEqual(decoded, "/Users/gzorrilla/Developer/personal/agent-perch")
    }

    func testFallsBackToRawEncodedNameWhenNoCandidateExists() {
        let encoded = "-missing-project"

        XCTAssertEqual(
            ClaudeProjectPathDecoder.decode(encoded, exists: { _ in false }),
            encoded
        )
    }
}
