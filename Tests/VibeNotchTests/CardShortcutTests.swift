import AppKit
import XCTest
@testable import VibeNotch

final class CardShortcutTests: XCTestCase {
    func testCommandYAllowsAndCommandNDenies() {
        XCTAssertEqual(CardShortcut.map(characters: "y", modifiers: .command), .allow)
        XCTAssertEqual(CardShortcut.map(characters: "n", modifiers: .command), .deny)
    }

    // Global monitors report the shifted characters when caps lock is on.
    func testShortcutsAreCaseInsensitive() {
        XCTAssertEqual(CardShortcut.map(characters: "Y", modifiers: .command), .allow)
        XCTAssertEqual(CardShortcut.map(characters: "N", modifiers: .command), .deny)
    }

    func testCommandDigitsPickThatOption() {
        for number in 1...9 {
            XCTAssertEqual(
                CardShortcut.map(characters: String(number), modifiers: .command),
                .option(number)
            )
        }
    }

    func testZeroAndMultiCharacterInputAreNotShortcuts() {
        XCTAssertNil(CardShortcut.map(characters: "0", modifiers: .command))
        XCTAssertNil(CardShortcut.map(characters: "10", modifiers: .command))
        XCTAssertNil(CardShortcut.map(characters: "", modifiers: .command))
        XCTAssertNil(CardShortcut.map(characters: nil, modifiers: .command))
        XCTAssertNil(CardShortcut.map(characters: "a", modifiers: .command))
    }

    // This monitor sees every keystroke the user makes anywhere, so anything that is not
    // exactly Command has to stay with the app it was typed into.
    func testCommandMustBeTheOnlyModifier() {
        XCTAssertNil(CardShortcut.map(characters: "y", modifiers: []))
        XCTAssertNil(CardShortcut.map(characters: "y", modifiers: [.command, .shift]))
        XCTAssertNil(CardShortcut.map(characters: "y", modifiers: [.command, .option]))
        XCTAssertNil(CardShortcut.map(characters: "y", modifiers: [.command, .control]))
        XCTAssertNil(CardShortcut.map(characters: "1", modifiers: [.command, .shift]))
        XCTAssertNil(CardShortcut.map(characters: "n", modifiers: .control))
    }

    // Global key events carry hardware flags AppKit does not treat as modifiers.
    func testIncidentalFlagsDoNotBlockAShortcut() {
        XCTAssertEqual(
            CardShortcut.map(characters: "y", modifiers: [.command, .init(rawValue: 0x100)]),
            .allow
        )
    }
}

/// The permission prompt has three options; the card offered two (#61). The valuable one —
/// "allow all edits this session" — was unreachable from the notch, so a run of edits meant
/// answering a card each time.
final class PermissionAffirmativeTests: XCTestCase {
    /// Option 2's wording is Claude Code's, and it differs by tool. Getting it from the recorded
    /// tool name beats printing one guess for everything.
    func testTheRememberOptionIsWordedForTheToolBeingApproved() {
        XCTAssertEqual(
            PermissionRequestCard.affirmatives(forTool: "Write")[1].label,
            "Yes, allow all edits this session"
        )
        XCTAssertEqual(
            PermissionRequestCard.affirmatives(forTool: "Edit")[1].label,
            "Yes, allow all edits this session"
        )
        XCTAssertEqual(
            PermissionRequestCard.affirmatives(forTool: "Bash")[1].label,
            "Yes, don't ask again for this command"
        )
    }

    /// An unrecognised tool still gets a truthful label rather than an edit-specific one.
    func testAnUnknownToolFallsBackToNeutralWording() {
        XCTAssertEqual(
            PermissionRequestCard.affirmatives(forTool: "mcp__ide__getDiagnostics")[1].label,
            "Yes, and don't ask again"
        )
        XCTAssertEqual(PermissionRequestCard.affirmatives(forTool: "")[1].label, "Yes, and don't ask again")
    }

    /// Exactly two digits are offered. Deny is Escape, not a `3`: typing 3 would assume the prompt
    /// has three options, which this app cannot know for every tool, while Escape cancels any
    /// shape of prompt.
    func testOnlyTheTwoAffirmativesAreDigits() {
        for tool in ["Write", "Bash", "Edit", "", "mcp__x__y"] {
            XCTAssertEqual(PermissionRequestCard.affirmatives(forTool: tool).count, 2, tool)
            XCTAssertEqual(PermissionRequestCard.affirmatives(forTool: tool)[0].label, "Yes", tool)
        }
    }
}
