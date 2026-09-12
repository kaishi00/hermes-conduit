//
//  ConfigFieldLocalizationTests.swift
//  Conduit
//
//  Guards the invariant that Hermes profile config VALUES are never
//  localized: option choices and defaultValues are raw protocol values that
//  are persisted verbatim and must round-trip under every app language
//  (review finding: zh-Hans turned `agent.image_input_mode` into「自动」).
//  Localized display names live separately in AuxiliaryViews'
//  optionValueDisplay table.
//

import XCTest
@testable import Conduit

final class ConfigFieldLocalizationTests: XCTestCase {
    private var allFields: [ProfileSettingField] {
        ChatSettingsDetail.fields
            + SettingsView.workspaceFields
            + SettingsView.memoryFields
    }

    /// Raw protocol values each config key accepts. Persisted values must be
    /// drawn from these sets — never from localized display names.
    private static let rawValuesByField: [String: Set<String>] = [
        "display.personality": ["", "helpful", "concise", "technical", "creative",
                                "teacher", "kawaii", "catgirl", "pirate", "shakespeare",
                                "surfer", "noir", "uwu", "philosopher", "hype"],
        "code_execution.mode": ["project", "strict"],
        "approvals.mode": ["manual", "smart", "off"],
        "agent.image_input_mode": ["auto", "native", "text"],
        "memory.provider": [],
        "context.engine": ["default"],
        "display.memory_notifications": ["default", "on", "off"],
    ]

    func testImageInputModeOptionsAreRawProtocolValues() {
        let field = allFields.first { $0.key == "agent.image_input_mode" }
        guard case .options(let options, let defaultValue)? = field?.control else {
            return XCTFail("agent.image_input_mode must use the .options control")
        }
        XCTAssertEqual(options, ["auto", "native", "text"])
        XCTAssertEqual(defaultValue, "auto")
    }

    func testOptionChoicesAndDefaultsAreNeverLocalized() {
        for field in allFields {
            switch field.control {
            case .options(let options, let defaultValue):
                // Fully dynamic fields (options populated from the server,
                // nothing chosen yet) legitimately have no static allowlist.
                if options.isEmpty && defaultValue.isEmpty { continue }
                let allowed = Self.rawValuesByField[field.key] ?? []
                XCTAssertFalse(allowed.isEmpty,
                               "\(field.key) must have a raw-value allowlist entry")
                for option in options {
                    XCTAssertTrue(allowed.contains(option),
                                  "\(field.key) option \(option) is not a raw protocol value")
                }
                XCTAssertTrue(allowed.contains(defaultValue),
                              "\(field.key) defaultValue \(defaultValue) is not a raw protocol value")
            case .labeledOptions(let options, let defaultValue):
                let allowed = Self.rawValuesByField[field.key] ?? []
                XCTAssertFalse(allowed.isEmpty,
                               "\(field.key) must have a raw-value allowlist entry")
                for option in options {
                    XCTAssertTrue(allowed.contains(option.value),
                                  "\(field.key) option \(option.value) is not a raw protocol value")
                }
                XCTAssertTrue(allowed.contains(defaultValue),
                              "\(field.key) defaultValue \(defaultValue) is not a raw protocol value")
            default:
                break
            }
        }
    }

    /// Every known value of a display-mapped field must have an entry in the
    /// ProfileConfigValueDisplay table, so raw values never surface in the
    /// menu. (Locale-neutral names like "uwu" may map to themselves.)
    func testOptionsHaveDisplayLabels() {
        let displayMappedFields = ["approvals.mode", "code_execution.mode",
                                   "agent.image_input_mode", "display.personality"]
        for key in displayMappedFields {
            for value in Self.rawValuesByField[key] ?? [] {
                XCTAssertNotNil(ProfileConfigValueDisplay.optionValueDisplay[key]?[value],
                                "\(key) value \(value) has no display label mapping")
            }
        }
    }
}
