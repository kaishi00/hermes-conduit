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
}
