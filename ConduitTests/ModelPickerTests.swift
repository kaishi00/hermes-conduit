import XCTest
@testable import Conduit

final class ModelPickerTests: XCTestCase {
    /// A catalog fetch that failed says so, with Try Again, instead of
    /// "No models are available" or loading forever (#1016). A re-load that
    /// fails keeps the rows it already had.
    func testModelCatalogTellsAFailedFetchFromAnEmptyOne() {
        let row = ProviderInfo(name: "openai", models: [ModelInfo(id: "gpt-5", label: nil, reasoningCapable: false)])
        XCTAssertEqual(ModelCatalogState.of(providers: nil, failed: false), .loading)
        XCTAssertEqual(ModelCatalogState.of(providers: nil, failed: true), .failed)
        XCTAssertEqual(ModelCatalogState.of(providers: [], failed: false), .empty)
        XCTAssertEqual(ModelCatalogState.of(providers: [], failed: true), .failed)
        XCTAssertEqual(ModelCatalogState.of(providers: [row], failed: false), .ready)
        XCTAssertEqual(ModelCatalogState.of(providers: [row], failed: true), .ready)
    }

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
        reasoningEffort: "high", speedChanged: true, speed: .ultrafast
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
                setSpeed: { speed in self.calls.append(speed.rawValue) }
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

        XCTAssertEqual(gateway.calls, ["model(confirmed)", "yolo", "reasoning", "ultrafast"])
        XCTAssertEqual(result, .completed(ModelPickerApplyProgress(
            switchedModel: "big-model", yoloApplied: true, reasoningApplied: true, speedApplied: true)))
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

        XCTAssertEqual(gateway.calls, ["yolo", "reasoning", "ultrafast"])
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

    @MainActor
    func testUnchangedYoloSkipsTheWrite() async {
        let gateway = GatewayRecorder()
        var unchangedYolo = draft
        unchangedYolo.yoloChanged = false

        let result = await runModelPickerApply(unchangedYolo, sendModelSwitch: false, confirmedModelSwitch: false, actions: gateway.actions)

        XCTAssertEqual(gateway.calls, ["reasoning", "ultrafast"])
        XCTAssertEqual(result, .completed(ModelPickerApplyProgress(reasoningApplied: true, speedApplied: true)))
    }

    @MainActor
    func testApplyWithoutReasoningLeavesReasoningAlone() async {
        let gateway = GatewayRecorder()
        var sheetDraft = draft
        sheetDraft.yoloChanged = false
        sheetDraft.reasoningEffort = nil

        let result = await runModelPickerApply(sheetDraft, sendModelSwitch: false, confirmedModelSwitch: false, actions: gateway.actions)

        XCTAssertEqual(gateway.calls, ["ultrafast"])
        XCTAssertEqual(result, .completed(ModelPickerApplyProgress(speedApplied: true)))
    }

    @MainActor
    func testUnchangedSpeedSkipsTheWrite() async {
        let gateway = GatewayRecorder()
        var sheetDraft = draft
        sheetDraft.yoloChanged = false
        sheetDraft.reasoningEffort = nil
        sheetDraft.speedChanged = false

        let result = await runModelPickerApply(sheetDraft, sendModelSwitch: false, confirmedModelSwitch: false, actions: gateway.actions)

        XCTAssertEqual(gateway.calls, [])
        XCTAssertEqual(result, .completed(ModelPickerApplyProgress()))
    }

    // MARK: - Speed

    func testSpeedReadsTheRuntimeTier() {
        XCTAssertEqual(ModelSpeed(fast: false, serviceTier: ""), .normal)
        XCTAssertEqual(ModelSpeed(fast: true, serviceTier: "priority"), .fast)
        XCTAssertEqual(ModelSpeed(fast: true, serviceTier: "Ultrafast"), .ultrafast)
        // A gateway that only reports `fast`.
        XCTAssertEqual(ModelSpeed(fast: true, serviceTier: ""), .fast)
        // Ultrafast the route can't carry is not running fast.
        XCTAssertEqual(ModelSpeed(fast: false, serviceTier: "ultrafast"), .normal)
        // `/fast auto` and `/fast cold` report fast: false until they kick in.
        XCTAssertEqual(ModelSpeed(fast: false, serviceTier: "auto"), .normal)
    }

    func testSpeedSendsHermesFastWords() {
        XCTAssertEqual(ModelSpeed.allCases.map(\.rawValue), ["normal", "fast", "ultrafast"])
        XCTAssertEqual(ModelSpeed.allCases.map(\.serviceTier), ["", "priority", "ultrafast"])
    }

    func testProviderRowReadsUltrafastCapability() {
        let row = ProviderInfo(from: .object([
            "slug": .string("openai-codex"),
            "models": .array([.string("gpt-6.1-sol"), .string("gpt-6-mini")]),
            "capabilities": .object([
                "gpt-6.1-sol": .object(["fast": .bool(true), "reasoning": .bool(true), "ultrafast": .bool(true)]),
                "gpt-6-mini": .object(["fast": .bool(true), "reasoning": .bool(true)]),
            ]),
        ]))

        XCTAssertEqual(row?.offersUltrafast("gpt-6.1-sol"), true)
        XCTAssertEqual(row?.offersUltrafast("gpt-6-mini"), false)
        XCTAssertNil(row?.offersUltrafast("unknown-model"))
        XCTAssertEqual(row?.offersUltrafast(" GPT-6.1-Sol "), true)
    }

    // MARK: - Reasoning levels

    func testReasoningLevelReadsTheRuntimeEffortWord() {
        XCTAssertEqual(ReasoningEffortLevel(runtimeEffort: ""), .off)
        XCTAssertEqual(ReasoningEffortLevel(runtimeEffort: "off"), .off)
        XCTAssertEqual(ReasoningEffortLevel(runtimeEffort: " High "), .high)
        XCTAssertEqual(ReasoningEffortLevel(runtimeEffort: "xhigh"), .xhigh)
        XCTAssertNil(ReasoningEffortLevel(runtimeEffort: "turbo"))
    }

    func testReasoningDisplayTitleReadsUnlistedWords() {
        XCTAssertEqual(ReasoningEffortLevel.displayTitle(for: "high"), ReasoningEffortLevel.high.title)
        XCTAssertEqual(ReasoningEffortLevel.displayTitle(for: ""), ReasoningEffortLevel.off.title)
        XCTAssertEqual(ReasoningEffortLevel.displayTitle(for: "extra-high"), "Extra High")
        XCTAssertEqual(ReasoningEffortLevel.displayTitle(for: "deep_think"), "Deep Think")
    }

    func testReasoningLevelsRunFromOffToUltra() {
        XCTAssertEqual(ReasoningEffortLevel.allCases.map(\.rawValue),
                       ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
    }

    // MARK: - Switched row

    private let sonnetRow = ModelPickerSelection(model: "sonnet", provider: "anthropic")

    func testAliasRowAlreadySwitchedIsNotSentAgain() {
        let last = ModelPickerSwitchedRow(selection: sonnetRow, resolvedModel: "anthropic/claude-sonnet")

        XCTAssertFalse(modelPickerShouldSwitch(
            sonnetRow, lastSwitched: last,
            runtimeModel: "anthropic/claude-sonnet", runtimeProvider: "anthropic"))
    }

    func testSwitchedRowResyncsWhenTheRuntimeMoved() {
        let last = ModelPickerSwitchedRow(selection: sonnetRow, resolvedModel: "anthropic/claude-sonnet")

        XCTAssertTrue(modelPickerShouldSwitch(
            sonnetRow, lastSwitched: last,
            runtimeModel: "gpt-5", runtimeProvider: "openrouter"))
    }

    func testAliasRowIsSentWhenNothingWasSwitchedYet() {
        XCTAssertTrue(modelPickerShouldSwitch(
            sonnetRow, lastSwitched: nil,
            runtimeModel: "anthropic/claude-sonnet", runtimeProvider: "anthropic"))
    }
}
