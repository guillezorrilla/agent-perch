import XCTest
@testable import VibeNotch

final class ProjectPathDecoderTests: XCTestCase {
    func testDecodesAnEncodedAbsolutePath() {
        let existing = Set([
            "/Users",
            "/Users/gzorrilla",
            "/Users/gzorrilla/Developer",
            "/Users/gzorrilla/Developer/personal",
            "/Users/gzorrilla/Developer/personal/vibe"
        ])

        let decoded = ClaudeProjectPathDecoder.decode(
            "-Users-gzorrilla-Developer-personal-vibe",
            exists: { existing.contains($0) }
        )

        XCTAssertEqual(decoded, "/Users/gzorrilla/Developer/personal/vibe")
    }

    func testResolvesDashesInsideDirectoryNamesUsingExistingPaths() {
        let existing = Set([
            "/Users",
            "/Users/gzorrilla",
            "/Users/gzorrilla/Developer",
            "/Users/gzorrilla/Developer/personal",
            "/Users/gzorrilla/Developer/personal/vibe-notch"
        ])

        let decoded = ClaudeProjectPathDecoder.decode(
            "-Users-gzorrilla-Developer-personal-vibe-notch",
            exists: { existing.contains($0) }
        )

        XCTAssertEqual(decoded, "/Users/gzorrilla/Developer/personal/vibe-notch")
    }

    func testFallsBackToRawEncodedNameWhenNoCandidateExists() {
        let encoded = "-missing-project"

        XCTAssertEqual(
            ClaudeProjectPathDecoder.decode(encoded, exists: { _ in false }),
            encoded
        )
    }
}
