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

    // MARK: - Apply flow

    private let draft = ModelPickerApplyDraft(
        model: "big-model", provider: "openrouter",
        yoloChanged: true, yolo: true,
        reasoningEffort: "high", fast: false
    )

    /// Records the order of gateway writes and answers each model switch
    /// with the next queued outcome.
    @MainActor
    private final class GatewayRecorder {
        var calls: [String] = []
        var modelOutcomes: [ModelSwitchOutcome] = []
        var yoloFailure: AppState.YoloWriteFailure?
        var reasoningError: Error?

        var actions: ModelPickerApplyActions {
            ModelPickerApplyActions(
                setModel: { model, _, confirmed in
                    self.calls.append(confirmed ? "model(confirmed)" : "model")
                    return self.modelOutcomes.isEmpty ? ModelSwitchOutcome(model: model) : self.modelOutcomes.removeFirst()
                },
                setYolo: { _ in
                    self.calls.append("yolo")
                    return self.yoloFailure
                },
                setReasoning: { _ in
                    self.calls.append("reasoning")
                    if let error = self.reasoningError { throw error }
                },
                setFast: { _ in self.calls.append("fast") }
            )
        }
    }

    private struct StubError: LocalizedError {
        var errorDescription: String? { "reasoning failed" }
    }

    @MainActor
    func testGuardedSwitchStopsBeforeAnyOtherWrite() async {
        let gateway = GatewayRecorder()
        gateway.modelOutcomes = [ModelSwitchOutcome(model: "big-model", confirmRequired: true, confirmMessage: "Expensive")]

        let result = await runModelPickerApply(draft, sendModelSwitch: true, confirmedModelSwitch: false, actions: gateway.actions)

        XCTAssertEqual(result, .needsConfirmation("Expensive"))
        XCTAssertEqual(gateway.calls, ["model"])
    }

    @MainActor
    func testConfirmedRetrySendsTheFlagThenTheRestInOrder() async {
        let gateway = GatewayRecorder()

        let result = await runModelPickerApply(draft, sendModelSwitch: false, confirmedModelSwitch: true, actions: gateway.actions)

        XCTAssertEqual(gateway.calls, ["model(confirmed)", "yolo", "reasoning", "fast"])
        XCTAssertEqual(result, .completed(ModelPickerApplyProgress(
            switchedModel: "big-model", yoloApplied: true, reasoningApplied: true, fastApplied: true)))
    }

    @MainActor
    func testGatewayThatKeepsAskingAfterConfirmationIsReportedNotLooped() async {
        let gateway = GatewayRecorder()
        gateway.modelOutcomes = [ModelSwitchOutcome(model: "big-model", confirmRequired: true, confirmMessage: "Still no")]

        let result = await runModelPickerApply(draft, sendModelSwitch: true, confirmedModelSwitch: true, actions: gateway.actions)

        XCTAssertEqual(result, .failed("Still no", ModelPickerApplyProgress()))
        XCTAssertEqual(gateway.calls, ["model(confirmed)"])
    }

    @MainActor
    func testUnchangedModelSkipsTheSwitch() async {
        let gateway = GatewayRecorder()

        _ = await runModelPickerApply(draft, sendModelSwitch: false, confirmedModelSwitch: false, actions: gateway.actions)

        XCTAssertEqual(gateway.calls, ["yolo", "reasoning", "fast"])
    }

    @MainActor
    func testLaterFailureKeepsTheStepsAlreadyApplied() async {
        let gateway = GatewayRecorder()
        gateway.modelOutcomes = [ModelSwitchOutcome(model: "anthropic/claude-sonnet")]
        gateway.reasoningError = StubError()

        let result = await runModelPickerApply(draft, sendModelSwitch: true, confirmedModelSwitch: false, actions: gateway.actions)

        XCTAssertEqual(result, .failed("reasoning failed", ModelPickerApplyProgress(
            switchedModel: "anthropic/claude-sonnet", yoloApplied: true)))
        XCTAssertEqual(gateway.calls, ["model", "yolo", "reasoning"])
    }

    @MainActor
    func testYoloFailureStopsBeforeReasoning() async {
        let gateway = GatewayRecorder()
        gateway.yoloFailure = AppState.YoloWriteFailure(message: "Unable to change YOLO mode: offline")

        let result = await runModelPickerApply(draft, sendModelSwitch: false, confirmedModelSwitch: false, actions: gateway.actions)

        XCTAssertEqual(result, .failed("Unable to change YOLO mode: offline", ModelPickerApplyProgress()))
        XCTAssertEqual(gateway.calls, ["yolo"])
    }
}
