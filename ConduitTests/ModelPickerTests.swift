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

    // MARK: - Model switch

    func testTapOnlySwitchesModelWhenTheSelectionDiffers() {
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

    func testTapDoesNotSwitchWithoutACompleteSelection() {
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

    // MARK: - Switch on tap

    /// Counts the switches sent and answers each with the next queued outcome.
    @MainActor
    private final class SwitchRecorder {
        var calls: [String] = []
        var outcomes: [ModelSwitchOutcome] = []
        var error: Error?

        func setModel(_ confirmed: Bool) async throws -> ModelSwitchOutcome {
            calls.append(confirmed ? "model(confirmed)" : "model")
            if let error { throw error }
            return outcomes.isEmpty ? ModelSwitchOutcome(model: "big-model") : outcomes.removeFirst()
        }
    }

    private struct StubError: LocalizedError {
        var errorDescription: String? { "offline" }
    }

    @MainActor
    func testTappedRowSwitchesAtOnceWithTheResolvedModel() async {
        let gateway = SwitchRecorder()
        gateway.outcomes = [ModelSwitchOutcome(model: "anthropic/claude-sonnet")]

        let result = await runModelPickerSwitch(to: "sonnet", confirmed: false, setModel: gateway.setModel)

        XCTAssertEqual(result, .switched(model: "anthropic/claude-sonnet", deferred: false))
        XCTAssertEqual(gateway.calls, ["model"])
    }

    @MainActor
    func testSwitchMidTurnSaysItIsDeferred() async {
        let gateway = SwitchRecorder()
        gateway.outcomes = [ModelSwitchOutcome(model: "next-model", deferred: true)]

        let result = await runModelPickerSwitch(to: "next-model", confirmed: false, setModel: gateway.setModel)

        XCTAssertEqual(result, .switched(model: "next-model", deferred: true))
    }

    @MainActor
    func testGuardedRowAsksBeforeSwitching() async {
        let gateway = SwitchRecorder()
        gateway.outcomes = [ModelSwitchOutcome(model: "big-model", confirmRequired: true, confirmMessage: "Expensive")]

        let result = await runModelPickerSwitch(to: "big-model", confirmed: false, setModel: gateway.setModel)

        XCTAssertEqual(result, .needsConfirmation("Expensive"))
        XCTAssertEqual(gateway.calls, ["model"])
    }

    @MainActor
    func testGuardWithoutAMessageNamesTheModel() async {
        let gateway = SwitchRecorder()
        gateway.outcomes = [ModelSwitchOutcome(model: "big-model", confirmRequired: true)]

        let result = await runModelPickerSwitch(to: "big-model", confirmed: false, setModel: gateway.setModel)

        XCTAssertEqual(result, .needsConfirmation("Hermes asks you to confirm switching to big-model."))
    }

    @MainActor
    func testConfirmedRetrySendsTheFlag() async {
        let gateway = SwitchRecorder()

        let result = await runModelPickerSwitch(to: "big-model", confirmed: true, setModel: gateway.setModel)

        XCTAssertEqual(result, .switched(model: "big-model", deferred: false))
        XCTAssertEqual(gateway.calls, ["model(confirmed)"])
    }

    @MainActor
    func testGatewayThatKeepsAskingAfterConfirmationIsReportedNotLooped() async {
        let gateway = SwitchRecorder()
        gateway.outcomes = [ModelSwitchOutcome(model: "big-model", confirmRequired: true, confirmMessage: "Still no")]

        let result = await runModelPickerSwitch(to: "big-model", confirmed: true, setModel: gateway.setModel)

        XCTAssertEqual(result, .failed("Still no"))
    }

    @MainActor
    func testFailedSwitchIsReported() async {
        let gateway = SwitchRecorder()
        gateway.error = StubError()

        let result = await runModelPickerSwitch(to: "big-model", confirmed: false, setModel: gateway.setModel)

        XCTAssertEqual(result, .failed("offline"))
    }

    func testUltrafastFallsBackToFastOnAModelWithoutIt() {
        XCTAssertEqual(modelPickerSpeedAfterSwitch(.ultrafast, ultrafastOffered: false), .fast)
        // A row that says nothing about Ultrafast counts as lacking it.
        XCTAssertEqual(modelPickerSpeedAfterSwitch(.ultrafast, ultrafastOffered: nil), .fast)
        XCTAssertNil(modelPickerSpeedAfterSwitch(.ultrafast, ultrafastOffered: true))
        XCTAssertNil(modelPickerSpeedAfterSwitch(.fast, ultrafastOffered: false))
        XCTAssertNil(modelPickerSpeedAfterSwitch(.normal, ultrafastOffered: nil))
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

    // MARK: - Search (#1388)

    private let searchCatalog = [
        ProviderInfo(
            name: "openrouter",
            models: [
                ModelInfo(id: "anthropic/claude-sonnet-4.5", label: nil, reasoningCapable: true),
                ModelInfo(id: "openai/gpt-5", label: nil, reasoningCapable: true),
            ],
            displayName: "OpenRouter"
        ),
        ProviderInfo(
            name: "anthropic",
            models: [ModelInfo(id: "claude-sonnet-4-5", label: "Claude Sonnet 4.5", reasoningCapable: true)]
        ),
    ]

    /// The same model from two providers comes back twice, each match
    /// carrying the provider that serves it.
    func testSearchKeepsEachProviderOfTheSameModel() {
        let matches = modelSearchMatches(in: searchCatalog, query: "sonnet")
        XCTAssertEqual(matches.map(\.provider.name), ["openrouter", "anthropic"])
        XCTAssertEqual(matches.map(\.model.id), ["anthropic/claude-sonnet-4.5", "claude-sonnet-4-5"])
        XCTAssertEqual(matches.map(\.provider.title), ["OpenRouter", "anthropic"])
        XCTAssertEqual(Set(matches.map(\.id)).count, 2)
    }

    /// Every word must match the model or its provider, so a provider's
    /// name narrows a model several serve down to one of them.
    func testSearchWordsCanNameTheProvider() {
        XCTAssertEqual(modelSearchMatches(in: searchCatalog, query: "Sonnet  openrouter").map(\.provider.name), ["openrouter"])
        XCTAssertEqual(modelSearchMatches(in: searchCatalog, query: "OPENROUTER").count, 2)
        // A label matches too.
        XCTAssertEqual(modelSearchMatches(in: searchCatalog, query: "sonnet 4.5").count, 2)
        XCTAssertTrue(modelSearchMatches(in: searchCatalog, query: "luna").isEmpty)
        XCTAssertTrue(modelSearchMatches(in: searchCatalog, query: "   ").isEmpty)
    }

    func testArrowKeysStayOnTheResults() {
        XCTAssertEqual(modelSearchHighlight(0, moving: 1, count: 3), 1)
        XCTAssertEqual(modelSearchHighlight(2, moving: 1, count: 3), 2)
        XCTAssertEqual(modelSearchHighlight(0, moving: -1, count: 3), 0)
        XCTAssertEqual(modelSearchHighlight(4, moving: 0, count: 0), 0)
    }

    /// Only a Mac or a hardware keyboard opens the sheet typing; a touch
    /// phone keeps its keyboard down.
    func testSearchTakesFocusOnlyWithAKeyboard() {
        XCTAssertTrue(modelSearchFocusesOnOpen(onMac: true, hardwareKeyboard: false))
        XCTAssertTrue(modelSearchFocusesOnOpen(onMac: false, hardwareKeyboard: true))
        XCTAssertFalse(modelSearchFocusesOnOpen(onMac: false, hardwareKeyboard: false))
    }
}
