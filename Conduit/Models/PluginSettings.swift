//
//  PluginSettings.swift
//  Conduit
//
//  A plugin's own settings, as a plugin's page in Settings > Capabilities >
//  Plugins edits them: the fields its manifest's `config_schema` declares,
//  which Hermes lists with each plugin (`plugins.manage` `list`, the row's
//  `settings_schema`) and writes with `plugins.manage` `settings`. A secret
//  field carries only where it lives (`env`) and whether it's set: its value
//  is written to the profile's `.env` and never read back.
//

import Foundation

struct PluginSettingField: Equatable, Identifiable {
    enum Kind: String {
        case string, number, boolean, `enum`, json, secret
    }

    var id: String { key }
    let key: String
    let kind: Kind
    let label: String
    let description: String
    let required: Bool
    /// The value as the form starts it: text for every kind, `true` or
    /// `false` for a switch, empty for a secret.
    let initialText: String
    let choices: [String]
    /// A secret's `.env` variable.
    let env: String?
    /// A secret that already has a value.
    let hasValue: Bool

    init?(_ value: Any) {
        guard let dict = value as? [String: Any],
              let key = PluginSettings.text(dict["key"]) else { return nil }
        let kind = PluginSettings.text(dict["type"]).flatMap(Kind.init(rawValue:)) ?? .string
        self.key = key
        self.kind = kind
        label = PluginSettings.text(dict["label"]) ?? key
        description = PluginSettings.text(dict["description"]) ?? ""
        required = dict["required"] as? Bool ?? false
        choices = (dict["choices"] as? [Any] ?? []).compactMap { PluginSettings.text($0) }
        env = kind == .secret ? PluginSettings.text(dict["env"]) : nil
        hasValue = kind == .secret && dict["has_value"] as? Bool == true
        let current = dict["value"] ?? dict["default"]
        initialText = PluginSettings.initialText(kind: kind, value: current, choices: choices)
    }

    /// The form's text as Hermes takes it. Throws a message for the field
    /// when the text doesn't fit.
    func wireValue(_ raw: String, locale: Locale = AppLocalization.formattingLocale) throws -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .boolean:
            return trimmed == "true"
        case .enum:
            guard choices.contains(trimmed) else {
                throw PluginSettings.FieldError(message: AppLocalization.string("\(label): pick one of the choices."))
            }
            return trimmed
        case .number:
            if trimmed.isEmpty, !required { return NSNull() }
            // The number pad types the locale's separator, a comma in many.
            let separator = locale.decimalSeparator ?? "."
            let text = separator == "." ? trimmed : trimmed.replacingOccurrences(of: separator, with: ".")
            if let integer = Int(text) { return integer }
            guard let number = Double(text), number.isFinite else {
                throw PluginSettings.FieldError(message: AppLocalization.string("\(label): enter a number."))
            }
            return number
        case .json:
            let text = trimmed.isEmpty ? "null" : trimmed
            guard let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  parsed is [Any] || parsed is [String: Any] else {
                throw PluginSettings.FieldError(message: AppLocalization.string("\(label): enter a JSON list or object."))
            }
            return parsed
        case .string:
            return raw
        case .secret:
            return trimmed
        }
    }
}

enum PluginSettings {
    struct FieldError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// What one save sends: the values Hermes writes to the plugin's
    /// settings, and the secrets the profile's `.env` takes.
    struct Save: Equatable {
        var values: [String: AnyHashable]
        var secrets: [String: String]

        var isEmpty: Bool { values.isEmpty && secrets.isEmpty }
    }

    /// The fields one plugin's row declares (`settings_schema`).
    static func fields(from row: [String: Any]) -> [PluginSettingField] {
        var seen = Set<String>()
        return (row["settings_schema"] as? [Any] ?? []).compactMap(PluginSettingField.init).filter { seen.insert($0.key).inserted }
    }

    /// The row Hermes lists for a plugin, by its key or its name.
    static func row(named name: String, in response: [String: Any]) -> [String: Any]? {
        let rows = (response["plugins"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        return rows.first { text($0["key"]) == name } ?? rows.first { text($0["name"]) == name }
    }

    /// The changed fields of a form, ready to send. A secret left blank
    /// stays as it is; a value the form didn't change isn't sent.
    static func save(fields: [PluginSettingField], draft: [String: String]) throws -> Save {
        var values: [String: AnyHashable] = [:]
        var secrets: [String: String] = [:]
        for field in fields {
            guard let raw = draft[field.key] else { continue }
            if field.kind == .secret {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let env = field.env { secrets[env] = trimmed }
                continue
            }
            guard raw != field.initialText else { continue }
            if field.required, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, field.kind != .boolean {
                throw FieldError(message: AppLocalization.string("\(field.label) is required."))
            }
            values[field.key] = hashable(try field.wireValue(raw))
        }
        return Save(values: values, secrets: secrets)
    }

    static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func initialText(kind: PluginSettingField.Kind, value: Any?, choices: [String]) -> String {
        switch kind {
        case .secret:
            return ""
        case .boolean:
            return value as? Bool == true ? "true" : "false"
        case .enum:
            return (value as? String) ?? (value as? NSNumber)?.stringValue ?? choices.first ?? ""
        case .json:
            guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        case .number:
            if let number = value as? NSNumber, !(value is Bool) {
                let double = number.doubleValue
                return double.rounded() == double && abs(double) < 1e15 ? String(Int(double)) : number.stringValue
            }
            return (value as? String) ?? ""
        case .string:
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return ""
        }
    }

    /// Values for a dictionary the request body carries.
    private static func hashable(_ value: Any) -> AnyHashable {
        switch value {
        case let value as Bool: return value
        case let value as Int: return value
        case let value as Double: return value
        case let value as String: return value
        case is NSNull: return NSNull()
        default:
            // A JSON list or object: kept as its text's parse, wrapped.
            return JSONBox(value)
        }
    }

    /// A parsed JSON list or object, carried to the request body as is.
    struct JSONBox: Hashable {
        let value: Any
        private let text: String

        init(_ value: Any) {
            self.value = Self.native(value)
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
            text = String(decoding: data, as: UTF8.self)
        }

        /// JSONSerialization's numbers as Swift's own Bool, Int and Double,
        /// so the RPC's encoder can't read a 0 or 1 as a switch.
        static func native(_ value: Any) -> Any {
            switch value {
            case let number as NSNumber:
                if AnyCodable.isBoolean(number) { return number.boolValue }
                let double = number.doubleValue
                if double.rounded() == double, abs(double) < 1e15 { return Int(double) }
                return double
            case let object as [String: Any]:
                return object.mapValues(native)
            case let array as [Any]:
                return array.map(native)
            default:
                return value
            }
        }

        static func == (lhs: JSONBox, rhs: JSONBox) -> Bool { lhs.text == rhs.text }
        func hash(into hasher: inout Hasher) { hasher.combine(text) }
    }

    /// The values as the request body takes them.
    static func body(_ values: [String: AnyHashable]) -> [String: Any] {
        values.mapValues { value in
            if let box = value as? JSONBox { return box.value }
            return value.base
        }
    }
}
