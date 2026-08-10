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

    func testAskUserQuestionParsesFirstPromptAndOptionLabels() throws {
        let action = try XCTUnwrap(PendingAction.parse(
            toolName: "AskUserQuestion",
            input: .object([
                "questions": .array([
                    .object([
                        "question": .string("Which deployment target?"),
                        "header": .string("Target"),
                        "multiSelect": .bool(false),
                        "options": .array([
                            .object([
                                "label": .string("Production"),
                                "description": .string("Deploy to customers")
                            ]),
                            .object([
                                "label": .string("Staging"),
                                "description": .string("Deploy for testing")
                            ]),
                            .object(["label": .string("Local only")])
                        ])
                    ])
                ])
            ])
        ))

        guard case let .question(prompt) = action else {
            return XCTFail("Expected a question prompt")
        }
        XCTAssertEqual(prompt.question, "Which deployment target?")
        XCTAssertEqual(prompt.header, "Target")
        XCTAssertEqual(prompt.options, ["Production", "Staging", "Local only"])
        XCTAssertEqual(prompt.descriptions, ["Deploy to customers", "Deploy for testing", nil])
        XCTAssertFalse(prompt.multiSelect)
    }

    func testAskUserQuestionCapsOptionsAtNine() throws {
        let options = (1...12).map { number in
            JSONValue.object(["label": .string("Option \(number)")])
        }
        let action = try XCTUnwrap(PendingAction.parse(
            toolName: "AskUserQuestion",
            input: .object([
                "questions": .array([
                    .object([
                        "question": .string("Pick one"),
                        "multiSelect": .bool(false),
                        "options": .array(options)
                    ])
                ])
            ])
        ))

        guard case let .question(prompt) = action else {
            return XCTFail("Expected a question prompt")
        }
        XCTAssertEqual(
            prompt.options,
            [
                "Option 1", "Option 2", "Option 3",
                "Option 4", "Option 5", "Option 6",
                "Option 7", "Option 8", "Option 9"
            ]
        )
    }

    func testAskUserQuestionRequiresNonEmptyOptions() {
        let fields: [String: JSONValue] = [
            "question": .string("Pick one"),
            "multiSelect": .bool(false)
        ]
        var emptyFields = fields
        emptyFields["options"] = .array([])

        XCTAssertNil(PendingAction.parse(
            toolName: "AskUserQuestion",
            input: .object(["questions": .array([.object(fields)])])
        ))
        XCTAssertNil(PendingAction.parse(
            toolName: "AskUserQuestion",
            input: .object(["questions": .array([.object(emptyFields)])])
        ))
    }
}
