import Foundation
import XCTest
@testable import Conduit

/// Settings > Model must show the profile's saved default, not the first
/// catalog row, even when the saved provider is spelled differently from the
/// row slug the options payload uses.
final class ProfileModelDefaultsTests: XCTestCase {

    private func provider(_ slug: String, name: String? = nil, aliases: [String] = [], current: Bool = false, models: [String]) -> ProviderInfo {
        ProviderInfo(
            name: slug,
            models: models.map { ModelInfo(id: $0, label: nil, reasoningCapable: false) },
            displayName: name,
            aliases: aliases,
            isCurrent: current
        )
    }

    private func defaults(_ providers: [ProviderInfo], provider: String, model: String) -> ProfileModelDefaults {
        ProfileModelDefaults(providers: providers, model: model, provider: provider, reasoning: "medium")
    }

    func testDecodesDisplayNameAliasesAndCurrentFlag() {
        let row = ProviderInfo(from: .object([
            "slug": .string("my-box"),
            "name": .string("My Box"),
            "aliases": .array([.string("custom:my-box")]),
            "is_current": .bool(true),
            "models": .array([.string("qwen")])
        ]))
        XCTAssertEqual(row?.name, "my-box")
        XCTAssertEqual(row?.displayName, "My Box")
        XCTAssertEqual(row?.aliases, ["custom:my-box"])
        XCTAssertEqual(row?.isCurrent, true)
    }

    func testExactSlugSelectsSavedProviderAndModel() {
        let value = defaults([
            provider("anthropic", models: ["claude-a", "claude-b"]),
            provider("openrouter", models: ["x", "y"])
        ], provider: "openrouter", model: "y")
        XCTAssertEqual(value.selection.provider, "openrouter")
        XCTAssertEqual(value.selection.model, "y")
    }

    func testCustomProviderAliasMatchesItsRow() {
        let value = defaults([
            provider("anthropic", models: ["claude-a"]),
            provider("my-box", name: "My Box", aliases: ["custom:my-box"], models: ["qwen"])
        ], provider: "custom:my-box", model: "qwen")
        XCTAssertEqual(value.selection.provider, "my-box")
        XCTAssertEqual(value.selection.model, "qwen")
    }

    func testDisplayNameMatchIsCaseInsensitive() {
        let value = defaults([
            provider("anthropic", name: "Anthropic", models: ["claude-a"]),
            provider("openai-codex", name: "OpenAI Codex", models: ["gpt"])
        ], provider: "openai codex", model: "gpt")
        XCTAssertEqual(value.selection.provider, "openai-codex")
    }

    func testUnmatchedProviderFallsBackToCurrentRow() {
        let value = defaults([
            provider("anthropic", models: ["claude-a"]),
            provider("nous", current: true, models: ["hermes"])
        ], provider: "auto", model: "hermes")
        XCTAssertEqual(value.selection.provider, "nous")
        XCTAssertEqual(value.selection.model, "hermes")
    }

    func testUnmatchedProviderFallsBackToRowListingModel() {
        let value = defaults([
            provider("anthropic", models: ["claude-a"]),
            provider("openrouter", models: ["hermes"])
        ], provider: "auto", model: "hermes")
        XCTAssertEqual(value.selection.provider, "openrouter")
    }

    func testSavedModelMissingFromCatalogIsKept() {
        let value = defaults([
            provider("anthropic", models: ["claude-a"]),
            provider("openrouter", models: ["x"])
        ], provider: "openrouter", model: "unlisted")
        XCTAssertEqual(value.selection.provider, "openrouter")
        XCTAssertEqual(value.selection.model, "unlisted")
    }

    func testNoSavedDefaultUsesFirstRow() {
        let value = defaults([provider("anthropic", models: ["claude-a"])], provider: "", model: "")
        XCTAssertEqual(value.selection.provider, "anthropic")
        XCTAssertEqual(value.selection.model, "claude-a")
    }

    func testUnmatchedSavedDefaultIsKeptInsteadOfFirstRow() {
        let value = defaults([
            provider("anthropic", models: ["claude-a"]),
            provider("openrouter", models: ["x"])
        ], provider: "gone", model: "unlisted")
        XCTAssertEqual(value.selection.provider, "gone")
        XCTAssertEqual(value.selection.model, "unlisted")
    }

    /// `auto` names no row and Hermes marks none current; a model two
    /// aggregators both list must not fall to the first provider's first model.
    func testAutoProviderWithModelInTwoRowsKeepsSavedDefault() {
        let value = defaults([
            provider("anthropic", models: ["claude-a"]),
            provider("nous", models: ["anthropic/claude-b"]),
            provider("openrouter", models: ["anthropic/claude-b"])
        ], provider: "auto", model: "anthropic/claude-b")
        XCTAssertEqual(value.selection.provider, "auto")
        XCTAssertEqual(value.selection.model, "anthropic/claude-b")
    }

    /// A custom endpoint Hermes hides as a duplicate of a built-in provider's
    /// URL (e.g. a custom api.z.ai entry beside `zai`) resolves to the built-in
    /// row that lists the saved model, since that row serves the same endpoint.
    func testHiddenDuplicateCustomEndpointResolvesToBuiltInRowListingModel() {
        let value = defaults([
            provider("anthropic", models: ["claude-a"]),
            provider("zai", name: "Z.AI / GLM", models: ["glm-5.2", "glm-5.3-flash"])
        ], provider: "custom:zai-proxy", model: "glm-5.3-flash")
        XCTAssertEqual(value.selection.provider, "zai")
        XCTAssertEqual(value.selection.model, "glm-5.3-flash")
    }

    func testUnmatchedSavedProviderWithoutModelIsKept() {
        let value = defaults([provider("anthropic", models: ["claude-a"])], provider: "gone", model: "")
        XCTAssertEqual(value.selection.provider, "gone")
        XCTAssertEqual(value.selection.model, "")
    }

    func testSavedModelWithoutProviderIsKept() {
        let value = defaults([provider("anthropic", models: ["claude-a"])], provider: "", model: "unlisted")
        XCTAssertEqual(value.selection.provider, "")
        XCTAssertEqual(value.selection.model, "unlisted")
    }

    func testMatchingTrimsCatalogValuesAndTitleUsesDisplayName() {
        let row = provider("my-box", name: " My Box ", aliases: [" custom:my-box"], models: ["qwen"])
        XCTAssertTrue(row.matches("custom:my-box"))
        XCTAssertTrue(row.matches("my box"))
        XCTAssertFalse(row.matches(""))
        XCTAssertEqual(row.title, "My Box")
        XCTAssertEqual(provider("anthropic", models: []).title, "anthropic")
    }

    func testDelegateModelWithInheritedProviderIsKept() {
        let value = defaults([provider("anthropic", models: ["claude-a"])], provider: "anthropic", model: "claude-a")
        let selection = value.delegateSelection(provider: "  ", model: "cheap-model")
        XCTAssertEqual(selection.provider, "")
        XCTAssertEqual(selection.model, "cheap-model")
    }

    func testDelegateInheritStaysEmpty() {
        let value = defaults([provider("anthropic", models: ["claude-a"])], provider: "anthropic", model: "claude-a")
        let selection = value.delegateSelection(provider: "", model: "")
        XCTAssertEqual(selection.provider, "")
        XCTAssertEqual(selection.model, "")
    }

    func testDelegateAliasResolvesToRowAndKeepsSavedModel() {
        let value = defaults([
            provider("anthropic", models: ["claude-a"]),
            provider("my-box", aliases: ["custom:my-box"], models: ["qwen"])
        ], provider: "anthropic", model: "claude-a")
        let selection = value.delegateSelection(provider: "custom:my-box", model: "unlisted")
        XCTAssertEqual(selection.provider, "my-box")
        XCTAssertEqual(selection.model, "unlisted")
    }

    func testDelegateProviderModelLeftInheritedStaysEmpty() {
        let value = defaults([provider("anthropic", models: ["claude-a"])], provider: "anthropic", model: "claude-a")
        let selection = value.delegateSelection(provider: "anthropic", model: "")
        XCTAssertEqual(selection.provider, "anthropic")
        XCTAssertEqual(selection.model, "")
    }

    func testDelegateUnknownProviderIsKeptAsSaved() {
        let value = defaults([provider("anthropic", models: ["claude-a"])], provider: "anthropic", model: "claude-a")
        let selection = value.delegateSelection(provider: "gone", model: "m")
        XCTAssertEqual(selection.provider, "gone")
        XCTAssertEqual(selection.model, "m")
    }
}
