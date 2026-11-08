//
//  PluginSettingsTests.swift
//  ConduitTests
//
//  A plugin's own settings: the fields Conduit reads from Hermes' plugin
//  list, how the form's text becomes what Hermes writes, and that a secret
//  is sent only to the profile's `.env` and never read back. An extension
//  of the catalog's tests, since the unit suite is at its class cap.
//

import XCTest
@testable import Conduit

extension PluginCatalogBrowseTests {
    private var settingsResponse: [String: Any] { ["plugins": [
        ["key": "image_gen/fal", "name": "fal", "settings_schema": []],
        ["key": "weather", "name": "weather", "settings_schema": [
            ["key": "units", "type": "enum", "label": "Units", "choices": ["metric", "imperial"], "value": "imperial", "required": true],
            ["key": "days", "type": "number", "label": "Days", "value": 3],
            ["key": "alerts", "type": "boolean", "label": "Alerts", "value": true],
            ["key": "city", "type": "string", "label": "City", "description": "Where you are"],
            ["key": "extra", "type": "json", "label": "Extra", "value": ["b": 1, "a": [2]]],
            ["key": "api_key", "type": "secret", "label": "API key", "env": "WEATHER_API_KEY", "has_value": true, "value": "leaked?"],
            ["key": "units", "type": "string", "label": "Duplicate"],
            ["label": "No key"]
        ]]
    ]] }

    private func settingsFields() throws -> [PluginSettingField] {
        PluginSettings.fields(from: try XCTUnwrap(PluginSettings.row(named: "weather", in: settingsResponse)))
    }

    func testPluginSettingFieldsReadAsHermesSendsThem() throws {
        let fields = try settingsFields()
        XCTAssertEqual(fields.map(\.key), ["units", "days", "alerts", "city", "extra", "api_key"], "First of each key; a field without one is dropped")
        XCTAssertEqual(fields[0].kind, .enum)
        XCTAssertEqual(fields[0].initialText, "imperial")
        XCTAssertTrue(fields[0].required)
        XCTAssertEqual(fields[1].initialText, "3")
        XCTAssertEqual(fields[2].initialText, "true")
        XCTAssertEqual(fields[3].initialText, "")
        XCTAssertEqual(fields[3].description, "Where you are")
        XCTAssertEqual(fields[4].initialText, "{\n  \"a\" : [\n    2\n  ],\n  \"b\" : 1\n}")
        XCTAssertEqual(fields[5].env, "WEATHER_API_KEY")
        XCTAssertTrue(fields[5].hasValue)
        XCTAssertEqual(fields[5].initialText, "", "A secret's value is never shown, even if one is sent")
    }

    func testAPluginsSettingsRowIsFoundByItsKeyOrName() {
        XCTAssertEqual(PluginSettings.row(named: "image_gen/fal", in: settingsResponse)?["name"] as? String, "fal")
        XCTAssertEqual(PluginSettings.row(named: "fal", in: settingsResponse)?["key"] as? String, "image_gen/fal")
        XCTAssertNil(PluginSettings.row(named: "missing", in: settingsResponse))
    }

    func testAPluginSettingsSaveSendsOnlyWhatChangedAndSecretsApart() throws {
        let fields = try settingsFields()
        let save = try PluginSettings.save(fields: fields, draft: [
            "units": "imperial",
            "days": "7",
            "alerts": "false",
            "city": "Lyon",
            "api_key": "  sk-new  "
        ])
        let body = PluginSettings.body(save.values)
        XCTAssertEqual(Set(body.keys), ["days", "alerts", "city"], "An unchanged value isn't sent")
        XCTAssertEqual(body["days"] as? Int, 7)
        XCTAssertEqual(body["alerts"] as? Bool, false)
        XCTAssertEqual(body["city"] as? String, "Lyon")
        XCTAssertEqual(save.secrets, ["WEATHER_API_KEY": "sk-new"])
        XCTAssertNil(body["api_key"], "A secret never rides the settings call")

        let blankSecret = try PluginSettings.save(fields: fields, draft: ["api_key": "   "])
        XCTAssertTrue(blankSecret.isEmpty, "A secret left blank stays as it is")
    }

    func testPluginSettingTextThatDoesNotFitIsRefused() throws {
        let fields = try settingsFields()
        XCTAssertThrowsError(try PluginSettings.save(fields: fields, draft: ["days": "soon"]))
        XCTAssertThrowsError(try PluginSettings.save(fields: fields, draft: ["units": "kelvin"]))
        XCTAssertThrowsError(try PluginSettings.save(fields: fields, draft: ["extra": "42"]), "JSON must be a list or an object")
        XCTAssertThrowsError(try PluginSettings.save(fields: fields, draft: ["units": ""]), "A required field can't be emptied")
        let json = try PluginSettings.save(fields: fields, draft: ["extra": "[1, 2]"])
        XCTAssertEqual(PluginSettings.body(json.values)["extra"] as? [Int], [1, 2])
        let decimal = try PluginSettings.save(fields: fields, draft: ["days": "2.5"])
        XCTAssertEqual(PluginSettings.body(decimal.values)["days"] as? Double, 2.5)
    }
}
