// AnchoredFollowUpTests.swift — DecodeTests
// Tests for the Anchored Follow-Up (Reply ↩) feature state management.

import XCTest
@testable import Decode

@MainActor
final class AnchoredFollowUpTests: XCTestCase {

    // MARK: - Pending Selection State

    func testHandleSelectionChangeSetsPendingSelection() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected text")

        XCTAssertNotNil(vm.responseSelection)
        XCTAssertEqual(vm.responseSelection?.text, "selected text")
        XCTAssertEqual(vm.responseSelection?.blockID, blockID)
        XCTAssertEqual(vm.activeSelectionBlockID, blockID)
    }

    func testHandleSelectionChangeStoresCorrectBlockID() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .followUpAnswer, index: 2)

        vm.handleSelectionChange(blockID: blockID, text: "answer text")

        XCTAssertEqual(vm.responseSelection?.blockID.source, .followUpAnswer)
        XCTAssertEqual(vm.responseSelection?.blockID.index, 2)
    }

    func testSameBlockDeselectionClearsPendingSelection() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected")
        XCTAssertNotNil(vm.responseSelection)

        vm.handleSelectionChange(blockID: blockID, text: nil)
        XCTAssertNil(vm.responseSelection)
        XCTAssertNil(vm.activeSelectionBlockID)
    }

    func testEmptyTextClearsPendingSelection() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected")
        vm.handleSelectionChange(blockID: blockID, text: "")

        XCTAssertNil(vm.responseSelection)
    }

    func testSelectionTruncatedToLimit() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)
        let longText = String(repeating: "a", count: 2000)

        vm.handleSelectionChange(blockID: blockID, text: longText)

        XCTAssertEqual(vm.responseSelection?.text.count, AILimits.maxResponseSelectionCharacters)
    }

    // MARK: - Bug 1 Regression: Selection Does NOT Activate Reply

    func testSelectingTextDoesNotCreateAnchoredSelection() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected text")

        XCTAssertNotNil(vm.responseSelection, "Pending selection should exist")
        XCTAssertNil(vm.anchoredResponseSelection, "Selecting text must NOT create anchored reply context")
        XCTAssertFalse(vm.replyActivated, "Selecting text must NOT activate reply mode")
    }

    func testSelectingTextDoesNotChangeFollowUpPlaceholder() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected text")

        // anchoredResponseSelection drives the placeholder, not responseSelection.
        XCTAssertNil(vm.anchoredResponseSelection, "No anchored selection means normal placeholder")
    }

    // MARK: - Reply Activation (Pending → Anchored)

    func testActivateReplyConvertsPendingToAnchored() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected text")
        vm.activateReply()

        XCTAssertNotNil(vm.anchoredResponseSelection)
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "selected text")
        XCTAssertEqual(vm.anchoredResponseSelection?.blockID, blockID)
        XCTAssertNil(vm.responseSelection, "Pending selection consumed by activateReply")
        XCTAssertNil(vm.activeSelectionBlockID, "Active block cleared after Reply")
        XCTAssertTrue(vm.replyActivated)
        XCTAssertEqual(vm.followUpText, "")
    }

    func testActivateReplyDoesNothingWithoutPendingSelection() {
        let vm = ExplanationHUDViewModel()

        vm.activateReply()

        XCTAssertFalse(vm.replyActivated)
        XCTAssertNil(vm.anchoredResponseSelection)
    }

    func testAnchoredSelectionSurvivesNativeSelectionClear() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "important text")
        vm.activateReply()

        // After Reply, activeSelectionBlockID is nil, so deselection from
        // blockID is stale (activeSelectionBlockID != blockID is vacuously true
        // because activeSelectionBlockID is nil, but the guard checks
        // activeSelectionBlockID == blockID which is nil != blockID → ignore).
        vm.handleSelectionChange(blockID: blockID, text: nil)

        XCTAssertNotNil(vm.anchoredResponseSelection, "Anchored selection must survive native clear")
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "important text")
    }

    // MARK: - Bug 2 Regression: Reply Visible With Existing Anchor

    func testReplyVisibleWhenAnchoredSelectionExists() {
        let vm = ExplanationHUDViewModel()
        let blockA = SelectableBlockID(source: .explanation, index: 0)
        let blockB = SelectableBlockID(source: .followUpAnswer, index: 0)

        // Anchor A.
        vm.handleSelectionChange(blockID: blockA, text: "text A")
        vm.activateReply()
        XCTAssertNotNil(vm.anchoredResponseSelection)

        // Select B — a new pending selection should exist.
        vm.handleSelectionChange(blockID: blockB, text: "text B")

        // Pending selection exists alongside anchored A.
        XCTAssertNotNil(vm.responseSelection, "New pending selection must exist")
        XCTAssertEqual(vm.responseSelection?.text, "text B")
        XCTAssertEqual(vm.activeSelectionBlockID, blockB)
        // anchoredResponseSelection remains A until user clicks Reply on B.
        XCTAssertNotNil(vm.anchoredResponseSelection)
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "text A")
    }

    func testReplyOnBReplacesAnchoredA() {
        let vm = ExplanationHUDViewModel()
        let blockA = SelectableBlockID(source: .explanation, index: 0)
        let blockB = SelectableBlockID(source: .followUpAnswer, index: 0)

        // Anchor A.
        vm.handleSelectionChange(blockID: blockA, text: "text A")
        vm.activateReply()

        // Select B, then Reply on B.
        vm.handleSelectionChange(blockID: blockB, text: "text B")
        vm.activateReply()

        // B replaces A as anchored context.
        XCTAssertNotNil(vm.anchoredResponseSelection)
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "text B")
        XCTAssertEqual(vm.anchoredResponseSelection?.blockID, blockB)
        XCTAssertNil(vm.responseSelection, "Pending consumed")
    }

    // MARK: - Cross-Block Selection (Single Active Block)

    func testSelectingBlockBMakesItActiveBlock() {
        let vm = ExplanationHUDViewModel()
        let blockA = SelectableBlockID(source: .explanation, index: 0)
        let blockB = SelectableBlockID(source: .followUpAnswer, index: 0)

        vm.handleSelectionChange(blockID: blockA, text: "first")
        XCTAssertEqual(vm.activeSelectionBlockID, blockA)

        vm.handleSelectionChange(blockID: blockB, text: "second")
        XCTAssertEqual(vm.activeSelectionBlockID, blockB)
        XCTAssertEqual(vm.responseSelection?.text, "second")
    }

    func testStaleDeselectionDoesNotClearNewerSelection() {
        let vm = ExplanationHUDViewModel()
        let blockA = SelectableBlockID(source: .explanation, index: 0)
        let blockB = SelectableBlockID(source: .explanation, index: 1)

        vm.handleSelectionChange(blockID: blockA, text: "old selection")
        vm.handleSelectionChange(blockID: blockB, text: "new selection")

        // Stale deselection from block A must NOT clear block B's selection.
        vm.handleSelectionChange(blockID: blockA, text: nil)

        XCTAssertNotNil(vm.responseSelection)
        XCTAssertEqual(vm.responseSelection?.text, "new selection")
        XCTAssertEqual(vm.activeSelectionBlockID, blockB)
    }

    func testProgrammaticClearOfOldBlockDoesNotAffectNewBlock() {
        let vm = ExplanationHUDViewModel()
        let blockA = SelectableBlockID(source: .explanation, index: 0)
        let blockB = SelectableBlockID(source: .explanation, index: 1)

        vm.handleSelectionChange(blockID: blockA, text: "old")
        vm.handleSelectionChange(blockID: blockB, text: "new")

        // Stale deselection from A (simulating cross-block clear callback).
        vm.handleSelectionChange(blockID: blockA, text: nil)
        vm.handleSelectionChange(blockID: blockA, text: "")

        XCTAssertEqual(vm.activeSelectionBlockID, blockB)
        XCTAssertEqual(vm.responseSelection?.text, "new")
    }

    // MARK: - Augmentation

    func testOnlyAnchoredSelectionDrivesAugmentation() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        // Select text but do NOT click Reply.
        vm.handleSelectionChange(blockID: blockID, text: "pending text")

        XCTAssertNil(vm.anchoredResponseSelection, "Without Reply click, no augmentation context")
    }

    func testAnchoredSelectionCreatedByReply() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "context fragment")
        vm.activateReply()

        XCTAssertNotNil(vm.anchoredResponseSelection, "Reply click creates augmentation context")
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "context fragment")
    }

    func testPendingSelectionCoexistsWithAnchoredWithoutSuppress() {
        let vm = ExplanationHUDViewModel()
        let blockA = SelectableBlockID(source: .explanation, index: 0)
        let blockB = SelectableBlockID(source: .explanation, index: 1)

        // Anchor A.
        vm.handleSelectionChange(blockID: blockA, text: "anchored")
        vm.activateReply()

        // Pending B should coexist without suppressing anything.
        vm.handleSelectionChange(blockID: blockB, text: "pending")

        XCTAssertNotNil(vm.responseSelection)
        XCTAssertEqual(vm.responseSelection?.text, "pending")
        XCTAssertNotNil(vm.anchoredResponseSelection)
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "anchored")
    }

    // MARK: - State Clearing

    func testClearResponseSelectionResetsAllState() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected")
        vm.activateReply()

        vm.clearResponseSelection()

        XCTAssertNil(vm.responseSelection)
        XCTAssertNil(vm.anchoredResponseSelection)
        XCTAssertNil(vm.activeSelectionBlockID)
        XCTAssertFalse(vm.replyActivated)
    }

    func testCancelClearsBothPendingAndAnchored() {
        let vm = ExplanationHUDViewModel()
        let blockA = SelectableBlockID(source: .explanation, index: 0)
        let blockB = SelectableBlockID(source: .explanation, index: 1)

        vm.handleSelectionChange(blockID: blockA, text: "anchored")
        vm.activateReply()
        vm.handleSelectionChange(blockID: blockB, text: "pending")

        vm.clearResponseSelection()

        XCTAssertNil(vm.responseSelection)
        XCTAssertNil(vm.anchoredResponseSelection)
        XCTAssertNil(vm.activeSelectionBlockID)
        XCTAssertFalse(vm.replyActivated)
    }

    func testDismissClearsAllSelectionState() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected")
        vm.activateReply()

        vm.dismiss()

        XCTAssertNil(vm.responseSelection)
        XCTAssertNil(vm.anchoredResponseSelection)
        XCTAssertNil(vm.activeSelectionBlockID)
        XCTAssertFalse(vm.replyActivated)
    }

    func testSuccessfulFollowUpClearsAnchoredSelection() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        vm.handleSelectionChange(blockID: blockID, text: "selected")
        vm.activateReply()
        XCTAssertNotNil(vm.anchoredResponseSelection)

        vm.clearResponseSelection()

        XCTAssertNil(vm.anchoredResponseSelection)
    }

    // MARK: - Block Identity

    func testSelectableBlockIDEquality() {
        let a = SelectableBlockID(source: .explanation, index: 0)
        let b = SelectableBlockID(source: .explanation, index: 0)
        let c = SelectableBlockID(source: .followUpAnswer, index: 0)
        let d = SelectableBlockID(source: .explanation, index: 1)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    func testExplanationAndFollowUpBlockIDsWithSameIndexAreDifferent() {
        let explanationBlock = SelectableBlockID(source: .explanation, index: 0)
        let followUpBlock = SelectableBlockID(source: .followUpAnswer, index: 0)

        XCTAssertNotEqual(explanationBlock, followUpBlock)
    }

    func testResponseSelectionIsFollowUp() {
        let explanationSelection = ResponseSelection(
            blockID: SelectableBlockID(source: .explanation, index: 0),
            text: "test"
        )
        let followUpSelection = ResponseSelection(
            blockID: SelectableBlockID(source: .followUpAnswer, index: 0),
            text: "test"
        )

        XCTAssertFalse(explanationSelection.isFollowUp)
        XCTAssertTrue(followUpSelection.isFollowUp)
    }

    // MARK: - Full Lifecycle

    func testFullLifecycleSelectReplyAskClear() {
        let vm = ExplanationHUDViewModel()
        let blockID = SelectableBlockID(source: .explanation, index: 0)

        // State 0: Nothing selected.
        XCTAssertNil(vm.responseSelection)
        XCTAssertNil(vm.anchoredResponseSelection)

        // State 1: Select text.
        vm.handleSelectionChange(blockID: blockID, text: "important text")
        XCTAssertNotNil(vm.responseSelection)
        XCTAssertNil(vm.anchoredResponseSelection, "No anchored state from selection alone")
        XCTAssertFalse(vm.replyActivated)

        // State 2: Click Reply.
        vm.activateReply()
        XCTAssertNil(vm.responseSelection, "Pending consumed")
        XCTAssertNotNil(vm.anchoredResponseSelection, "Anchored created")
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "important text")
        XCTAssertTrue(vm.replyActivated)

        // State 6: Clear after successful follow-up.
        vm.clearResponseSelection()
        XCTAssertNil(vm.responseSelection)
        XCTAssertNil(vm.anchoredResponseSelection)
        XCTAssertFalse(vm.replyActivated)
    }

    func testFullLifecycleAnchorAThenSelectBThenReplyB() {
        let vm = ExplanationHUDViewModel()
        let blockA = SelectableBlockID(source: .explanation, index: 0)
        let blockB = SelectableBlockID(source: .followUpAnswer, index: 0)

        // Anchor A.
        vm.handleSelectionChange(blockID: blockA, text: "text A")
        vm.activateReply()
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "text A")

        // Select B — pending coexists with anchored A.
        vm.handleSelectionChange(blockID: blockB, text: "text B")
        XCTAssertNotNil(vm.responseSelection)
        XCTAssertEqual(vm.responseSelection?.text, "text B")
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "text A")

        // Reply on B — replaces anchored A.
        vm.activateReply()
        XCTAssertNil(vm.responseSelection)
        XCTAssertEqual(vm.anchoredResponseSelection?.text, "text B")
        XCTAssertEqual(vm.anchoredResponseSelection?.blockID, blockB)
    }
}
