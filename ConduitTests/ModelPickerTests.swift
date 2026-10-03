import XCTest
@testable import Conduit

final class ModelPickerTests: XCTestCase {
    func testModelPickerYoloDraftStartsFromCurrentRuntimeValue() {
        let draft = ModelPickerYoloDraft(runtimeYolo: true)

        XCTAssertTrue(draft.initial)
        XCTAssertTrue(draft.selected)
    }

    func testModelPickerYoloDraftSeedsWhenInitialBaselineIsMissing() {
        let draft = ModelPickerYoloDraft.seededIfNeeded(initial: nil, runtimeYolo: true)

        XCTAssertEqual(draft, ModelPickerYoloDraft(runtimeYolo: true))
    }

    func testModelPickerYoloDraftDoesNotReseedAnExistingBaseline() {
        let draft = ModelPickerYoloDraft.seededIfNeeded(initial: false, runtimeYolo: true)

        XCTAssertNil(draft)
    }

    func testUnchangedYoloSelectionDoesNotPersistASessionOverride() {
        XCTAssertFalse(sessionYoloSelectionChanged(from: true, to: true))
    }

    func testChangedYoloSelectionPersistsTheNewSessionOverride() {
        XCTAssertTrue(sessionYoloSelectionChanged(from: false, to: true))
        XCTAssertTrue(sessionYoloSelectionChanged(from: true, to: false))
    }

    func testSelectionBeforeInitialLoadDoesNotPersistAnOverride() {
        XCTAssertFalse(sessionYoloSelectionChanged(from: nil, to: true))
    }

    func testFloorBoundaryOnlyCrossesBetweenOffAndNonOff() {
        // Boundary crossings re-seed the toggle.
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: nil, to: "off"))
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: "manual", to: "off"))
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: "manual", to: "OFF"))
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: "Off", to: "manual"))
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: "off", to: "manual"))
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: "off", to: nil))
        // Same-side transitions must not discard an in-progress draft.
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: nil, to: "manual"))
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: "manual", to: "smart"))
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: "smart", to: "manual"))
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: "off", to: "off"))
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: nil, to: nil))
    }

    // MARK: - Model switch

    func testApplyOnlySwitchesModelWhenTheSelectionDiffers() {
        XCTAssertFalse(modelPickerSelectionChanged(
            selectedModel: "gpt-5", selectedProvider: "openrouter",
            runtimeModel: "gpt-5", runtimeProvider: "OpenRouter"))
        XCTAssertTrue(modelPickerSelectionChanged(
            selectedModel: "claude-x", selectedProvider: "openrouter",
            runtimeModel: "gpt-5", runtimeProvider: "openrouter"))
        XCTAssertTrue(modelPickerSelectionChanged(
            selectedModel: "gpt-5", selectedProvider: "openai",
            runtimeModel: "gpt-5", runtimeProvider: "openrouter"))
    }

    func testApplyDoesNotSwitchWithoutACompleteSelection() {
        XCTAssertFalse(modelPickerSelectionChanged(
            selectedModel: "", selectedProvider: "openrouter",
            runtimeModel: "gpt-5", runtimeProvider: "openrouter"))
        XCTAssertFalse(modelPickerSelectionChanged(
            selectedModel: "gpt-5", selectedProvider: "",
            runtimeModel: "", runtimeProvider: ""))
    }

    func testGuardedModelSwitchIsReportedAsNeedingConfirmation() {
        let result: AnyCodable = .object([
            "key": .string("model"),
            "value": .string("big-model"),
            "warning": .string("legacy"),
            "confirm_required": .bool(true),
            "confirm_message": .string("This session holds ~150,000 tokens of context."),
            "scope": .string("session")
        ])

        let outcome = ModelSwitchOutcome(from: result, requestedModel: "big-model")

        XCTAssertTrue(outcome.confirmRequired)
        XCTAssertEqual(outcome.confirmMessage, "This session holds ~150,000 tokens of context.")
    }

    func testAppliedModelSwitchReportsTheResolvedModel() {
        let result: AnyCodable = .object([
            "key": .string("model"),
            "value": .string("anthropic/claude-sonnet"),
            "confirm_required": .bool(false),
            "confirm_message": .string("")
        ])

        let outcome = ModelSwitchOutcome(from: result, requestedModel: "sonnet")

        XCTAssertEqual(outcome, ModelSwitchOutcome(model: "anthropic/claude-sonnet"))
    }

    func testDeferredModelSwitchKeepsThePick() {
        let result: AnyCodable = .object([
            "value": .string("next-model"),
            "confirm_required": .bool(false),
            "deferred": .bool(true)
        ])

        let outcome = ModelSwitchOutcome(from: result, requestedModel: "next-model")

        XCTAssertTrue(outcome.deferred)
        XCTAssertFalse(outcome.confirmRequired)
        XCTAssertEqual(outcome.model, "next-model")
    }

    func testOlderGatewayWithoutConfirmFieldsCountsAsApplied() {
        let outcome = ModelSwitchOutcome(from: .object([:]), requestedModel: "m")

        XCTAssertEqual(outcome, ModelSwitchOutcome(model: "m"))
    }

    func testEchoedRequestFlagsNeverBecomeTheModelName() {
        let result: AnyCodable = .object([
            "value": .string("gpt-5 --provider openrouter --session")
        ])

        let outcome = ModelSwitchOutcome(from: result, requestedModel: "gpt-5")

        XCTAssertEqual(outcome.model, "gpt-5")
    }

    func testLegacyWarningCarriesTheConfirmationMessage() {
        let result: AnyCodable = .object([
            "value": .string("big-model"),
            "warning": .string("Expensive model"),
            "confirm_required": .bool(true),
            "confirm_message": .string("")
        ])

        let outcome = ModelSwitchOutcome(from: result, requestedModel: "big-model")

        XCTAssertEqual(outcome.confirmMessage, "Expensive model")
    }
}
