import XCTest
@testable import AgentPerch

/// What a pending card offers, and what pressing a key on it means.
///
/// This lived inside `NotchContentView` as two private switches — one choosing the card, one
/// routing the keystroke — so no test could reach it. They agreed only by hand, and one of them
/// skipped a bounds check the other made.
final class PendingAnswerTests: XCTestCase {
    private let permission = PendingAction.permission(
        PermissionRequest(toolName: "Bash", target: "ls", details: "", diff: nil)
    )
    private let plan = PendingAction.plan("# Plan")
    private let question = PendingAction.question(
        QuestionPrompt(
            question: "Which?",
            header: nil,
            options: ["A", "B"],
            descriptions: [nil, nil],
            multiSelect: false
        )
    )

    // MARK: - blocksOnItsOwn

    /// The property that replaced the same switch in `NotificationOutcome.of` and
    /// `PendingAction.resolve`. A permission request needs a notification to corroborate it,
    /// because `PreToolUse` fires for auto-approved calls too.
    func testOnlyQuestionsAndPlansBlockOnTheirOwn() {
        XCTAssertTrue(plan.blocksOnItsOwn)
        XCTAssertTrue(question.blocksOnItsOwn)
        XCTAssertFalse(permission.blocksOnItsOwn)
    }

    /// The two gates that used to hold copies of that switch still agree — now by construction.
    func testTheWriteGateAndTheReadGateAgreeAboutAPlan() {
        let input = JSONValue.object(["plan": .string("# Plan")])

        XCTAssertEqual(
            NotificationOutcome.of(
                message: "Claude is waiting for your input",
                currentStatus: .working,
                pendingToolName: "ExitPlanMode",
                pendingToolInput: input
            ),
            .needsAction
        )
        XCTAssertEqual(
            PendingAction.resolve(
                status: .needsAction,
                notificationMessage: "Claude is waiting for your input",
                toolName: "ExitPlanMode",
                toolInput: input
            ),
            .plan("# Plan")
        )
    }

    // MARK: - numbered options

    func testAPermissionOffersTwoAffirmativesWordedForItsTool() {
        XCTAssertEqual(permission.numberedOptions.count, 2)
        XCTAssertEqual(permission.optionLabel(1), "Yes")
        XCTAssertEqual(permission.optionLabel(2), "Yes, don't ask again for this command")
    }

    func testAnEditPermissionIsWordedForEdits() {
        let edit = PendingAction.permission(
            PermissionRequest(toolName: "Write", target: "x.swift", details: "", diff: nil)
        )
        XCTAssertEqual(edit.optionLabel(2), "Yes, allow all edits this session")
    }

    func testAPlanOffersItsThreeRealChoices() {
        XCTAssertEqual(plan.numberedOptions.count, 3)
        XCTAssertEqual(plan.optionLabel(1), "Yes, and use auto mode")
        XCTAssertEqual(plan.optionLabel(3), "Tell Claude what to change")
    }

    /// A question's choices come from the prompt and are answered by index through it, so it has no
    /// labelled options of its own.
    func testAQuestionHasNoLabelledOptionsOfItsOwn() {
        XCTAssertTrue(question.numberedOptions.isEmpty)
        XCTAssertNil(question.optionLabel(1))
    }

    /// The bounds check that `pendingCard`'s plan arm did not make — it indexed the array directly,
    /// so an out-of-range option would have trapped rather than been ignored.
    func testOutOfRangeOptionNumbersAreNotOnOffer() {
        for action in [permission, plan, question] {
            XCTAssertNil(action.optionLabel(0))
            XCTAssertNil(action.optionLabel(-1))
            XCTAssertNil(action.optionLabel(99))
        }
        XCTAssertNil(plan.optionLabel(4))
        XCTAssertNil(permission.optionLabel(3))
    }

    // MARK: - allow / deny

    /// ⌘Y on a plan used to type a `1`, and `1` is auto mode — the choice a user pressing
    /// "Approve" is least likely to have meant (#66).
    func testOnlyAPermissionAcceptsAllowAndDeny() {
        XCTAssertTrue(permission.acceptsAllowDeny)
        XCTAssertFalse(plan.acceptsAllowDeny)
        XCTAssertFalse(question.acceptsAllowDeny)
    }

    /// Every numbered option a card renders must be one the keyboard will also honour. When the
    /// card and the monitor derived this separately, nothing checked that.
    func testEveryRenderedOptionIsAlsoAnswerableByKeyboard() {
        for action in [permission, plan, question] {
            for number in 1..<(action.numberedOptions.count + 1) {
                XCTAssertNotNil(
                    action.optionLabel(number),
                    "option \(number) is rendered but would be refused from the keyboard"
                )
            }
        }
    }
}
