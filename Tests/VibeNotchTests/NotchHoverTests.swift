import XCTest
@testable import VibeNotch

final class NotchHoverTests: XCTestCase {
    private let grace = 0.35

    private func step(_ state: inout NotchHoverController.State, inside: Bool, now: TimeInterval)
        -> NotchHoverController.Effect {
        NotchHoverController.step(&state, mouseInside: inside, now: now, exitGrace: grace)
    }

    func testEntersOnceThenStaysExpandedWhileInside() {
        var s = NotchHoverController.State()
        XCTAssertEqual(step(&s, inside: true, now: 0), .expand)
        XCTAssertEqual(step(&s, inside: true, now: 0.1), .none) // already expanded, no re-fire
        XCTAssertEqual(step(&s, inside: true, now: 0.2), .none)
    }

    func testBriefExitDoesNotCollapse_theFlickerCase() {
        var s = NotchHoverController.State()
        _ = step(&s, inside: true, now: 0)          // expand (cursor over notch)
        _ = step(&s, inside: false, now: 0.1)       // cursor crossed into panel gap: outside notch
        _ = step(&s, inside: true, now: 0.2)        // cursor now over panel (union) again
        // Still expanded, never collapsed during the transition.
        XCTAssertTrue(s.expanded)
    }

    func testCollapsesOnlyAfterGraceFullyOutside() {
        var s = NotchHoverController.State()
        _ = step(&s, inside: true, now: 0)
        XCTAssertEqual(step(&s, inside: false, now: 1.0), .none)          // grace starts
        XCTAssertEqual(step(&s, inside: false, now: 1.0 + grace - 0.01), .none) // not yet
        XCTAssertEqual(step(&s, inside: false, now: 1.0 + grace), .collapse)    // now
        XCTAssertFalse(s.expanded)
    }

    func testReturningInsideDuringGraceCancelsCollapse() {
        var s = NotchHoverController.State()
        _ = step(&s, inside: true, now: 0)
        _ = step(&s, inside: false, now: 1.0)                 // grace armed
        XCTAssertEqual(step(&s, inside: true, now: 1.1), .none) // back inside, cancels
        XCTAssertNil(s.outsideSince)
        XCTAssertEqual(step(&s, inside: false, now: 5.0), .none) // grace must re-arm from scratch
    }
}
