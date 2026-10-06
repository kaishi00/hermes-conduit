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
        "display.tool_progress": ["all", "off"],
    ]

    func testImageInputModeOptionsAreRawProtocolValues() {
        let field = allFields.first { $0.key == "agent.image_input_mode" }
        guard case .options(let options, let defaultValue)? = field?.control else {
            return XCTFail("agent.image_input_mode must use the .options control")
        }
        XCTAssertEqual(options, ["auto", "native", "text"])
        XCTAssertEqual(defaultValue, "auto")
    }

    func testToolProgressTextToggleValuesAreRawProtocolValues() {
        // display.tool_progress persists "all"/"off" as .text into the Hermes
        // profile config; the toggle's on/off values must stay raw.
        let field = allFields.first { $0.key == "display.tool_progress" }
        guard case .textToggle(let onValue, let offValue, let defaultValue)? = field?.control else {
            return XCTFail("display.tool_progress must use the .textToggle control")
        }
        XCTAssertEqual(onValue, "all")
        XCTAssertEqual(offValue, "off")
        XCTAssertTrue(defaultValue)
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
            case .textToggle(let onValue, let offValue, let defaultValue):
                let allowed = Self.rawValuesByField[field.key] ?? []
                XCTAssertFalse(allowed.isEmpty,
                               "\(field.key) must have a raw-value allowlist entry")
                for value in [onValue, offValue] {
                    XCTAssertTrue(allowed.contains(value),
                                  "\(field.key) textToggle value \(value) is not a raw protocol value")
                }
                XCTAssertTrue(defaultValue || allowed.contains(offValue),
                              "\(field.key) textToggle default must map to a raw protocol value")
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

    /// Raw protocol values must be byte-identical under EVERY App Language.
    /// Each iteration actually persists the selection first, so the loop
    /// exercises different active localization states rather than testing
    /// the same language repeatedly.
    func testProtocolValuesAreIdenticalUnderEveryAppLanguage() {
        let standardDefaults = UserDefaults.standard
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }
        let baseline: [(key: String, control: ProfileSettingControl)] = allFields.map {
            (key: $0.key, control: $0.control)
        }
        XCTAssertFalse(baseline.isEmpty)
        for language in AppLanguage.selectable {
            standardDefaults.set(language.rawValue, forKey: AppLanguageStore.defaultsKey)
            XCTAssertEqual(AppLanguage.current, language,
                           "each iteration must activate a different language")
            let current: [(key: String, control: ProfileSettingControl)] = allFields.map {
                (key: $0.key, control: $0.control)
            }
            for (before, after) in zip(baseline, current) {
                XCTAssertEqual(before.key, after.key)
                switch (before.control, after.control) {
                case (.options(let a, let aDefault), .options(let b, let bDefault)):
                    XCTAssertEqual(a, b, "\(before.key) options must not localize under \(language)")
                    XCTAssertEqual(aDefault, bDefault, "\(before.key) default must not localize under \(language)")
                case (.textToggle(let aOn, let aOff, let aDefault), .textToggle(let bOn, let bOff, let bDefault)):
                    XCTAssertEqual(aOn, bOn, "\(before.key) onValue must not localize under \(language)")
                    XCTAssertEqual(aOff, bOff, "\(before.key) offValue must not localize under \(language)")
                    XCTAssertEqual(aDefault, bDefault)
                case (.labeledOptions(let a, let aDefault), .labeledOptions(let b, let bDefault)):
                    XCTAssertEqual(a.map { $0.value }, b.map { $0.value },
                                   "\(before.key) option values must not localize under \(language)")
                    XCTAssertEqual(aDefault, bDefault)
                case (.text(let a), .text(let b)):
                    XCTAssertEqual(a, b)
                case (.number(let a), .number(let b)):
                    XCTAssertEqual(a, b)
                case (.toggle(let a), .toggle(let b)):
                    XCTAssertEqual(a, b)
                default:
                    XCTFail("\(before.key) control changed shape under \(language)")
                }
            }
        }
    }
}
