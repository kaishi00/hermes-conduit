import Foundation
import XCTest
@testable import Conduit

/// Settings pages built on the gateway's config schema, the Model page's
/// fallback list, and the reasoning-effort key Hermes actually reads.
extension ProfileModelDefaultsTests {

    func testSchemaDecodesTypesAndStringChoices() {
        let schema = ProfileConfigSchema(json: [
            "fields": [
                "approvals.timeout": ["type": "number", "description": "Approvals → Timeout"],
                "agent.service_tier": ["type": "select", "options": ["", "normal", "fast", 3]],
                "broken": "not an object",
            ],
            "category_order": ["general"],
        ])
        XCTAssertEqual(schema["approvals.timeout"], ProfileConfigSchema.Field(type: "number"))
        XCTAssertEqual(schema["agent.service_tier"]?.options, ["", "normal", "fast"])
        XCTAssertNil(schema["broken"])
    }

    func testSchemaHidesOnlyFieldsThatRequireIt() {
        let schema = ProfileConfigSchema(fields: ["approvals.mode": .init(type: "select")])
        let required = ProfileSettingField(key: "approvals.timeout", label: "Timeout", help: "", control: .number(defaultValue: 300), requiresSchema: true)
        let classic = ProfileSettingField(key: "display.memory_notifications", label: "Updates", help: "", control: .text(defaultValue: ""))
        XCTAssertNil(required.resolved(with: schema))
        XCTAssertNotNil(classic.resolved(with: schema))
        // A schema that didn't load hides nothing.
        XCTAssertNotNil(required.resolved(with: ProfileConfigSchema()))
    }

    func testSchemaFillsEmptyChoicesButKeepsFixedOnes() {
        let schema = ProfileConfigSchema(fields: [
            "agent.service_tier": .init(type: "select", options: ["", "normal", "fast"]),
            "code_execution.mode": .init(type: "select", options: ["project", "strict", "new"]),
        ])
        let tier = ProfileSettingField(key: "agent.service_tier", label: "", help: "", control: .options([], defaultValue: ""), requiresSchema: true)
        guard case .options(let tierChoices, _)? = tier.resolved(with: schema)?.control else { return XCTFail("expected options") }
        XCTAssertEqual(tierChoices, ["", "normal", "fast"])

        let mode = ProfileSettingField(key: "code_execution.mode", label: "", help: "", control: .options(["project", "strict"], defaultValue: "project"))
        guard case .options(let modeChoices, _)? = mode.resolved(with: schema)?.control else { return XCTFail("expected options") }
        XCTAssertEqual(modeChoices, ["project", "strict"])
    }

    func testFallbackListKeepsRoutingAndReadsLegacyStrings() {
        let entries = ProfileFallbackModel.list(from: [
            ["provider": "custom", "model": "qwen", "base_url": "http://box:8080/v1", "key_env": "BOX_KEY"],
            "openrouter/anthropic/claude",
            "bare-model",
            "",
            42,
        ] as [Any])
        XCTAssertEqual(entries.map(\.provider), ["custom", "openrouter", ""])
        XCTAssertEqual(entries.map(\.model), ["qwen", "anthropic/claude", "bare-model"])
        XCTAssertEqual(entries[0].extras["base_url"], .string("http://box:8080/v1"))
        XCTAssertFalse(entries[2].isComplete)

        let saved = entries[0].jsonObject
        XCTAssertEqual(saved["provider"] as? String, "custom")
        XCTAssertEqual(saved["model"] as? String, "qwen")
        XCTAssertEqual(saved["base_url"] as? String, "http://box:8080/v1")
        XCTAssertEqual(saved["key_env"] as? String, "BOX_KEY")
        XCTAssertEqual(ProfileFallbackModel.list(from: nil), [])
    }

    func testReasoningEffortReadsTheAgentKeyFirst() {
        XCTAssertEqual(AppState.profileReasoningEffort(in: ["agent": ["reasoning_effort": "high"], "reasoning": "low"]), "high")
        // Conduit's old top-level key still reads when the real one is unset.
        XCTAssertEqual(AppState.profileReasoningEffort(in: ["agent": ["reasoning_effort": ""], "reasoning": "low"]), "low")
        XCTAssertEqual(AppState.profileReasoningEffort(in: ["agent": ["reasoning_effort": false]]), "none")
        XCTAssertEqual(AppState.profileReasoningEffort(in: ["agent": ["reasoning_effort": "Off"]]), "none")
        XCTAssertEqual(AppState.profileReasoningEffort(in: [:]), "medium")
    }

    func testWholeNumbersReadWithoutADecimal() {
        XCTAssertEqual(ProfileSettingValue.number(300).textValue, "300")
        XCTAssertEqual(ProfileSettingValue.number(0.8).textValue, "0.8")
        XCTAssertEqual(ProfileSettingValue.list(["git status", "ls"]).textValue, "git status\nls")
    }

    func testNumberFieldsReadADecimalComma() {
        XCTAssertEqual(ProfileSettingValue.parseNumber("0,8"), 0.8)
        XCTAssertEqual(ProfileSettingValue.parseNumber("0.8"), 0.8)
        XCTAssertEqual(ProfileSettingValue.parseNumber(" 300 "), 300)
        XCTAssertEqual(ProfileSettingValue.parseNumber("-1,5"), -1.5)
        XCTAssertNil(ProfileSettingValue.parseNumber("1,000.5"))
        XCTAssertNil(ProfileSettingValue.parseNumber("1,2,3"))
        XCTAssertNil(ProfileSettingValue.parseNumber(","))
        XCTAssertNil(ProfileSettingValue.parseNumber(""))
        XCTAssertNil(ProfileSettingValue.parseNumber("abc"))
    }

    func testNumberFieldsRefuseNotANumberAndInfinity() {
        // The config is sent as JSON, which has neither (JSONSerialization
        // raises on them).
        XCTAssertNil(ProfileSettingValue.parseNumber("nan"))
        XCTAssertNil(ProfileSettingValue.parseNumber("inf"))
        XCTAssertNil(ProfileSettingValue.parseNumber("-infinity"))
        XCTAssertNil(ProfileSettingValue.parseNumber("1e999"))
    }

    func testListEditorDropsBlankLines() {
        XCTAssertEqual(ProfileConfigSettingsPage.listEntries("  git status \n\n ls -la\n"), ["git status", "ls -la"])
        XCTAssertEqual(ProfileConfigSettingsPage.listEntries(""), [])
    }
}
