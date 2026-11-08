import XCTest
@testable import Conduit

final class ModelQuickPicksTests: XCTestCase {
    private func model(_ id: String) -> ModelInfo {
        ModelInfo(id: id, label: nil, reasoningCapable: true)
    }

    private lazy var openrouter = ProviderInfo(
        name: "openrouter",
        models: [model("opus"), model("sonnet"), model("deepseek")],
        aliases: ["custom:openrouter"]
    )
    private lazy var zai = ProviderInfo(name: "zai", models: [model("glm"), model("opus")])

    /// Pins keep their order and their provider: the same model from two
    /// providers is two pins, and a pin made under an alias is that row's.
    func testPinsArePerProviderInPinOrder() {
        var picks = ModelQuickPicks()
        picks.togglePin(model: "glm", provider: zai)
        picks.togglePin(model: "opus", provider: openrouter)
        XCTAssertTrue(picks.isPinned(model: "opus", provider: openrouter))
        XCTAssertFalse(picks.isPinned(model: "opus", provider: zai))

        let rows = picks.pinnedRows(in: [openrouter, zai])
        XCTAssertEqual(rows.map(\.id), ["zai\u{1F}glm", "openrouter\u{1F}opus"])

        picks.togglePin(model: "opus", provider: openrouter)
        XCTAssertEqual(picks.pinnedRows(in: [openrouter, zai]).map(\.model.id), ["glm"])

        let aliased = ModelQuickPicks(pinned: [ModelQuickPick(provider: "custom:openrouter", model: "sonnet")])
        XCTAssertTrue(aliased.isPinned(model: "sonnet", provider: openrouter))
        XCTAssertEqual(aliased.pinnedRows(in: [openrouter]).map(\.provider.name), ["openrouter"])
    }

    /// A switch puts the model switched to first and the one left next, so
    /// switching back is one tap; the list stays at its limit.
    func testASwitchLeadsTheRecentModelsWithTheOneLeftNext() {
        var picks = ModelQuickPicks()
        picks.recordSwitch(
            to: ModelQuickPick(provider: "zai", model: "glm"),
            from: ModelQuickPick(provider: "openrouter", model: "opus")
        )
        XCTAssertEqual(picks.recent.map(\.model), ["glm", "opus"])

        picks.recordSwitch(
            to: ModelQuickPick(provider: "openrouter", model: "opus"),
            from: ModelQuickPick(provider: "zai", model: "glm")
        )
        XCTAssertEqual(picks.recent.map(\.model), ["opus", "glm"], "No duplicates")

        for index in 0..<20 {
            picks.recordSwitch(to: ModelQuickPick(provider: "p", model: "m\(index)"), from: nil)
        }
        XCTAssertEqual(picks.recent.count, ModelQuickPicks.recentLimit)
        XCTAssertEqual(picks.recent.first?.model, "m19")
    }

    /// Recent rows leave out the model in use (shown above them), pinned
    /// models, and models the catalog doesn't list (or hides), up to three.
    func testRecentRowsSkipTheCurrentPinnedAndUnlistedModels() {
        let picks = ModelQuickPicks(
            pinned: [ModelQuickPick(provider: "zai", model: "glm")],
            recent: [
                ModelQuickPick(provider: "openrouter", model: "opus"),
                ModelQuickPick(provider: "zai", model: "glm"),
                ModelQuickPick(provider: "gone", model: "old"),
                ModelQuickPick(provider: "openrouter", model: "sonnet"),
                ModelQuickPick(provider: "zai", model: "opus"),
                ModelQuickPick(provider: "openrouter", model: "deepseek"),
                ModelQuickPick(provider: "openrouter", model: "extra"),
            ]
        )
        let rows = picks.recentRows(
            in: [openrouter, zai],
            excluding: ModelPickerSelection(model: "opus", provider: "custom:openrouter")
        )
        XCTAssertEqual(rows.map(\.id), ["openrouter\u{1F}sonnet", "zai\u{1F}opus", "openrouter\u{1F}deepseek"])
    }

    /// Each level owns an equal column the strip's full height, and a
    /// finger past either end stays on the end level.
    func testReasoningBarsPickTheColumnUnderTheFinger() {
        let width: CGFloat = 320
        XCTAssertEqual(ReasoningEffortBars.level(atX: 0, width: width), .off)
        XCTAssertEqual(ReasoningEffortBars.level(atX: 39.9, width: width), .off)
        XCTAssertEqual(ReasoningEffortBars.level(atX: 40, width: width), .minimal)
        XCTAssertEqual(ReasoningEffortBars.level(atX: 150, width: width), .medium)
        XCTAssertEqual(ReasoningEffortBars.level(atX: 319, width: width), .ultra)
        XCTAssertEqual(ReasoningEffortBars.level(atX: -30, width: width), .off)
        XCTAssertEqual(ReasoningEffortBars.level(atX: 500, width: width), .ultra)
        XCTAssertEqual(ReasoningEffortBars.level(atX: 10, width: 0), .off)
    }

    /// VoiceOver's swipes step one level and stop at the ends; a level
    /// Conduit doesn't list steps from Medium.
    func testReasoningBarsStepForVoiceOver() {
        XCTAssertEqual(ReasoningEffortBars.level(stepping: .medium, by: 1), .high)
        XCTAssertEqual(ReasoningEffortBars.level(stepping: .off, by: -1), .off)
        XCTAssertEqual(ReasoningEffortBars.level(stepping: .ultra, by: 1), .ultra)
        XCTAssertEqual(ReasoningEffortBars.level(stepping: nil, by: 1), .high)
    }
}
