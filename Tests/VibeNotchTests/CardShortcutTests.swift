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
