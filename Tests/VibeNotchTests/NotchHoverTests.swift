import XCTest
@testable import VibeNotch

final class NotchHoverTests: XCTestCase {
    private let grace = 0.35
    private let screenFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
    private let notchRect = NSRect(x: 450, y: 770, width: 100, height: 30)

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

    func testSelectsNotchScreenAmongExternalDisplays() {
        let external = ScreenInfo(id: 1, frame: screenFrame, hasNotch: false, isMain: true)
        let macBook = ScreenInfo(id: 2, frame: screenFrame, hasNotch: true, isMain: false)

        XCTAssertEqual(ScreenInfo.selected(from: [external, macBook])?.id, 2)
    }

    func testSelectsMainScreenWhenNoDisplayHasANotch() {
        let secondary = ScreenInfo(id: 1, frame: screenFrame, hasNotch: false, isMain: false)
        let main = ScreenInfo(id: 2, frame: screenFrame, hasNotch: false, isMain: true)

        XCTAssertEqual(ScreenInfo.selected(from: [secondary, main])?.id, 2)
    }

    func testSelectsSingleExternalScreen() {
        let external = ScreenInfo(id: 1, frame: screenFrame, hasNotch: false, isMain: true)

        XCTAssertEqual(ScreenInfo.selected(from: [external])?.id, 1)
    }

    func testCursorOnOtherScreenIsOutsideNaiveCrossScreenUnion() {
        let otherScreenPanel = NSRect(x: 1_200, y: 500, width: 300, height: 300)
        let cursor = NSPoint(x: 1_300, y: 700)

        XCTAssertFalse(NotchHoverController.isInside(
            cursor: cursor,
            notchRect: notchRect,
            panelFrame: otherScreenPanel,
            screenFrame: screenFrame,
            expanded: true
        ))
    }

    func testPanelOnOtherScreenIsNotUnioned() {
        let otherScreenPanel = NSRect(x: 1_200, y: 500, width: 300, height: 300)

        XCTAssertEqual(NotchHoverController.hotZone(
            notchRect: notchRect,
            panelFrame: otherScreenPanel,
            screenFrame: screenFrame,
            expanded: true
        ), notchRect)
    }

    func testEmptyPanelFrameIsNotUnioned() {
        XCTAssertEqual(NotchHoverController.hotZone(
            notchRect: notchRect,
            panelFrame: .zero,
            screenFrame: screenFrame,
            expanded: true
        ), notchRect)
    }

    func testExpandedPanelOnSelectedScreenRemainsInHotZone() {
        let panel = NSRect(x: 300, y: 500, width: 400, height: 300)

        XCTAssertTrue(NotchHoverController.isInside(
            cursor: NSPoint(x: 350, y: 600),
            notchRect: notchRect,
            panelFrame: panel,
            screenFrame: screenFrame,
            expanded: true
        ))
    }
}

extension NotchHoverTests {
    func testCursorPinnedAtTopEdgeInsideNotchCountsAsInside() {
        // In the physical notch the OS reports y == screen maxY exactly.
        XCTAssertTrue(NotchHoverController.isInside(
            cursor: NSPoint(x: 500, y: 800),
            notchRect: NSRect(x: 450, y: 770, width: 100, height: 30),
            panelFrame: nil,
            screenFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
            expanded: false
        ))
        // But the top edge of a DIFFERENT screen's x-range stays outside.
        XCTAssertFalse(NotchHoverController.isInside(
            cursor: NSPoint(x: 1_500, y: 800),
            notchRect: NSRect(x: 450, y: 770, width: 100, height: 30),
            panelFrame: nil,
            screenFrame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
            expanded: false
        ))
    }
}
