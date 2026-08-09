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

// MARK: - Closes that aren't hover's

extension NotchHoverTests {
    func testUserDismissDoesNotReopenUnderTheStationaryCursor() {
        var s = NotchHoverController.State()
        _ = step(&s, inside: true, now: 0)              // hover opened it
        s.dismiss()                                     // user jumped to the terminal
        XCTAssertFalse(s.expanded)

        // Cursor never moved: it is still over the notch, tick after tick.
        XCTAssertEqual(step(&s, inside: true, now: 0.1), .none)
        XCTAssertEqual(step(&s, inside: true, now: 0.2), .none)
        XCTAssertEqual(step(&s, inside: true, now: 5.0), .none)
        XCTAssertFalse(s.expanded)
    }

    func testUserDismissLatchClearsOnceTheCursorLeaves() {
        var s = NotchHoverController.State()
        s.dismiss()
        XCTAssertEqual(step(&s, inside: false, now: 1.0), .none) // leaving clears the latch
        XCTAssertFalse(s.suppressedUntilExit)
        XCTAssertEqual(step(&s, inside: true, now: 1.1), .expand) // deliberate re-hover works
    }

    func testDismissDoesNotStickAfterTheCollapseItCausedIsUndone() {
        var s = NotchHoverController.State()
        s.dismiss()
        _ = step(&s, inside: false, now: 1.0)
        _ = step(&s, inside: true, now: 1.1)
        // Back to plain hover semantics: the exit grace applies again.
        XCTAssertEqual(step(&s, inside: false, now: 2.0), .none)
        XCTAssertEqual(step(&s, inside: false, now: 2.0 + grace), .collapse)
    }

    func testNeedsActionExpansionSurvivesUntilTheCursorVisitsIt() {
        var s = NotchHoverController.State()
        s.adoptExternalExpansion() // alert opened the panel; cursor is elsewhere entirely
        XCTAssertTrue(s.expanded)

        // The exit grace must not close an alert the user hasn't even looked at yet.
        XCTAssertEqual(step(&s, inside: false, now: 1.0), .none)
        XCTAssertEqual(step(&s, inside: false, now: 1.0 + grace), .none)
        XCTAssertEqual(step(&s, inside: false, now: 60), .none)
        XCTAssertTrue(s.expanded)
    }

    func testHoverTakesOverANeedsActionExpansionOnFirstEntry() {
        var s = NotchHoverController.State()
        s.adoptExternalExpansion()
        _ = step(&s, inside: false, now: 1.0)

        // Cursor arrives: no second expand (it is already open), but hover now owns it.
        XCTAssertEqual(step(&s, inside: true, now: 2.0), .none)
        XCTAssertFalse(s.awaitingFirstEntry)

        XCTAssertEqual(step(&s, inside: false, now: 3.0), .none)
        XCTAssertEqual(step(&s, inside: false, now: 3.0 + grace), .collapse)
    }

    func testDismissLatchIsVisibleToHoverTriggersOutsideTheController() {
        // AppDelegate.expandOnHover() reads this to decline a `.onHover(true)` that the compact
        // view fires just by reappearing under a cursor that never moved. Adoption clears the
        // latch, so a hover that skipped the check would silently undo the dismissal.
        var s = NotchHoverController.State()
        _ = step(&s, inside: true, now: 0)
        XCTAssertFalse(s.suppressedUntilExit)

        s.dismiss()
        XCTAssertTrue(s.suppressedUntilExit)

        _ = step(&s, inside: false, now: 1.0)
        XCTAssertFalse(s.suppressedUntilExit) // cursor left: hover may open again
    }

    func testAdoptingAnExpansionClearsAPendingDismissLatch() {
        var s = NotchHoverController.State()
        s.dismiss()
        s.adoptExternalExpansion() // an alert outranks a stale dismissal
        XCTAssertFalse(s.suppressedUntilExit)
        XCTAssertTrue(s.expanded)
    }

    func testForgettingAnExpansionLetsTheNextHoverReopen() {
        var s = NotchHoverController.State()
        _ = step(&s, inside: true, now: 0)
        s.forgetExpansion() // dwell expired / mode re-applied with the cursor away
        XCTAssertEqual(step(&s, inside: true, now: 1.0), .expand)
    }

    func testForgettingAnExpansionDoesNotLatchLikeADismissal() {
        var s = NotchHoverController.State()
        s.adoptExternalExpansion()
        s.forgetExpansion()
        XCTAssertFalse(s.suppressedUntilExit)
        XCTAssertFalse(s.awaitingFirstEntry)
    }

    func testRefusedExpandRetriesOnTheNextTick() {
        // `tick()` rolls `expanded` back when the delegate refuses to open (no sessions yet),
        // so the machine must offer `.expand` again rather than believe it is open.
        var s = NotchHoverController.State()
        XCTAssertEqual(step(&s, inside: true, now: 0), .expand)
        s.expanded = false // delegate refused
        XCTAssertEqual(step(&s, inside: true, now: 0.1), .expand)
    }

    // The reported bug, replayed: the user parks the cursor in the panel while an agent works,
    // so needs-action alerts and mode re-applies land on the state machine continuously. Every
    // one of them used to reset hover state and produce a visible collapse/re-expand.
    func testHoveringThroughAStreamOfExternalExpansionsNeverFlickers() {
        var s = NotchHoverController.State()
        var effects: [NotchHoverController.Effect] = []

        for tick in 0 ..< 200 {
            if tick > 0, tick % 7 == 0 { s.adoptExternalExpansion() } // alert or mode re-apply
            let effect = step(&s, inside: true, now: Double(tick) * 0.1)
            if effect != .none { effects.append(effect) }
        }

        // Opened once by the hover that started it, and never disturbed since.
        XCTAssertEqual(effects, [.expand])
    }

    func testLeavingAfterThatStreamCollapsesExactlyOnce() {
        var s = NotchHoverController.State()
        var effects: [NotchHoverController.Effect] = []

        for tick in 0 ..< 200 {
            let inside = tick < 100
            if inside, tick > 0, tick % 7 == 0 { s.adoptExternalExpansion() }
            let effect = step(&s, inside: inside, now: Double(tick) * 0.1)
            if effect != .none { effects.append(effect) }
        }

        XCTAssertEqual(effects, [.expand, .collapse])
        XCTAssertFalse(s.expanded)
    }

    func testModeReapplyUnderTheCursorKeepsThePanelOpen() {
        // applyDisplayMode() reconstructs hover state instead of resetting it: adopt, and the
        // machine must not emit a fresh `.expand` (which is the visible collapse/re-expand).
        var s = NotchHoverController.State()
        _ = step(&s, inside: true, now: 0)
        s.adoptExternalExpansion() // what a re-apply does when the cursor is inside
        XCTAssertEqual(step(&s, inside: true, now: 0.1), .none)
        XCTAssertTrue(s.expanded)
    }
}

// MARK: - Hot zone geometry

extension NotchHoverTests {
    private var notchScreen: NSRect { NSRect(x: 0, y: 0, width: 1_512, height: 982) }
    private var auxLeft: NSRect { NSRect(x: 0, y: 945, width: 631, height: 37) }
    private var auxRight: NSRect { NSRect(x: 881, y: 945, width: 631, height: 37) }

    func testNotchStripKeepsItsHeightWhenTheMenuBarAutoHides() {
        // Auto-hiding the menu bar drops safeAreaInsets.top and the menu bar height to 0 right
        // as the cursor reaches the top edge. A hot zone that collapses there would expand and
        // re-collapse under a cursor that never moved.
        let shown = NotchHoverController.notchFrame(
            screenFrame: notchScreen,
            menuBarHeight: 37,
            auxiliaryTopLeft: auxLeft,
            auxiliaryTopRight: auxRight,
            safeAreaTop: 37
        )
        let hidden = NotchHoverController.notchFrame(
            screenFrame: notchScreen,
            menuBarHeight: 0,
            auxiliaryTopLeft: auxLeft,
            auxiliaryTopRight: auxRight,
            safeAreaTop: 0
        )

        XCTAssertEqual(shown, hidden)
        XCTAssertEqual(hidden.height, 37)
        XCTAssertEqual(hidden.width, 250)
    }

    func testNotchlessStripKeepsAHoverableHeightWhenTheMenuBarAutoHides() {
        let hidden = NotchHoverController.notchFrame(
            screenFrame: notchScreen,
            menuBarHeight: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            safeAreaTop: 0
        )

        XCTAssertFalse(hidden.isEmpty)
        XCTAssertEqual(hidden.maxY, notchScreen.maxY)
        XCTAssertGreaterThanOrEqual(hidden.height, 24)
    }

    func testDegenerateNotchGeometryStillProducesANonEmptyHotZone() {
        // hotZone() discards an empty notch rect entirely, which would make the notch
        // unhoverable rather than merely mis-sized.
        let frame = NotchHoverController.notchFrame(
            screenFrame: notchScreen,
            menuBarHeight: 0,
            auxiliaryTopLeft: NSRect(x: 0, y: 982, width: 756, height: 0),
            auxiliaryTopRight: NSRect(x: 756, y: 982, width: 756, height: 0),
            safeAreaTop: 0
        )

        XCTAssertFalse(frame.isEmpty)
        XCTAssertEqual(
            NotchHoverController.hotZone(
                notchRect: frame,
                panelFrame: nil,
                screenFrame: notchScreen,
                expanded: false
            ),
            frame
        )
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
