import Foundation
import XCTest
@testable import VibeNotch

final class M2bModelTests: XCTestCase {
    func testDiffPreviewCountsRemovedAndAddedLines() {
        let preview = DiffPreview.build(
            removed: "old one\nold two",
            added: "new one\nnew two\nnew three"
        )

        XCTAssertEqual(preview.removedCount, 2)
        XCTAssertEqual(preview.addedCount, 3)
        XCTAssertEqual(
            preview.lines,
            [
                DiffLine(kind: .removed, text: "old one"),
                DiffLine(kind: .removed, text: "old two"),
                DiffLine(kind: .added, text: "new one"),
                DiffLine(kind: .added, text: "new two"),
                DiffLine(kind: .added, text: "new three")
            ]
        )
        XCTAssertFalse(preview.isTruncated)
    }

    func testDiffPreviewTruncatesAfterEightLinesWithoutChangingCounts() {
        let removed = (1...6).map { "old \($0)" }.joined(separator: "\n")
        let added = (1...5).map { "new \($0)" }.joined(separator: "\n")

        let preview = DiffPreview.build(removed: removed, added: added)

        XCTAssertEqual(preview.lines.count, 8)
        XCTAssertEqual(preview.removedCount, 6)
        XCTAssertEqual(preview.addedCount, 5)
        XCTAssertTrue(preview.isTruncated)
    }

    func testDiffPreviewDoesNotCountTerminalNewlineAsAnEmptyLine() {
        let preview = DiffPreview.build(removed: "old\n", added: "new\n")

        XCTAssertEqual(preview.removedCount, 1)
        XCTAssertEqual(preview.addedCount, 1)
        XCTAssertEqual(preview.lines.count, 2)
    }

    func testWriteRequestIsAllAddedAndUsesParentPlusBasename() throws {
        let action = try XCTUnwrap(PendingAction.parse(
            toolName: "Write",
            input: .object([
                "file_path": .string("/repo/Sources/App.swift"),
                "content": .string("first\nsecond")
            ])
        ))

        guard case let .permission(request) = action else {
            return XCTFail("Expected a permission request")
        }
        XCTAssertEqual(request.target, "Sources/App.swift")
        XCTAssertEqual(request.diff?.addedCount, 2)
        XCTAssertEqual(request.diff?.removedCount, 0)
    }
}
