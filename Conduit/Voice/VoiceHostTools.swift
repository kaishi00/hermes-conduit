//
//  VoiceHostTools.swift
//  Conduit
//
//  Hermes tools a live voice model calls directly: the user's shared health
//  data (conduit_health) and location (conduit_location), read through the
//  plugin's sealed /voice-tools route rather than a whole Hermes job. The
//  host lists each tool with its description and parameters, so the voice
//  model reads the same use policy the agent does. Each tool's key is its
//  own consent in Conduit (AppState+VoiceHostTools.swift), so a new kind of
//  data needs an app change before a call can read it.
//
//  Gemini and Grok get them as function tools. Conduit's live sessions pass
//  string arguments only: numbers and booleans keep their declared type (the
//  model still sends text), lists and objects are declared as strings, and
//  each value is turned back into its JSON type from the host's schema.
//  GPT-Live has no function tools: it delegates "Health: {json}" or
//  "Location: {json}".
//

import Foundation

struct VoiceHostTool {
    /// The Hermes tool's name ("conduit_health").
    let name: String
    let description: String
    /// The host's JSON Schema for the arguments (lowercase types).
    let parameters: [String: Any]
    /// Which agreed key seals its calls ("health").
    let key: String

    /// The tools in a `GET /voice-tools` answer.
    static func tools(from response: [String: Any]) -> [VoiceHostTool] {
        (response["tools"] as? [[String: Any]] ?? []).compactMap { entry in
            // The name goes into each read's associated data: plain
            // identifiers only.
            guard let name = entry["name"] as? String, isToolName(name),
                  let description = entry["description"] as? String,
                  let parameters = entry["parameters"] as? [String: Any],
                  let key = entry["key"] as? String else { return nil }
            return VoiceHostTool(name: name, description: description, parameters: parameters, key: key)
        }
    }

    static func isToolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }

    private var properties: [String: [String: Any]] {
        parameters["properties"] as? [String: [String: Any]] ?? [:]
    }

    // MARK: Gemini and Grok

    /// The function declaration for Gemini (Grok lowercases its types).
    /// NON_BLOCKING like recall_memory: a blocking call holds the whole
    /// server stream until it's answered.
    var declaration: GeminiLiveProtocol.FunctionDeclaration {
        var schema: [String: Any] = [
            "type": "OBJECT",
            "properties": properties.mapValues(Self.stringSchema),
        ]
        if let required = parameters["required"] as? [String], !required.isEmpty { schema["required"] = required }
        return GeminiLiveProtocol.FunctionDeclaration(name: name, description: description, parameters: schema, behavior: .nonBlocking)
    }

    static func declarations(_ tools: [VoiceHostTool]) -> [GeminiLiveProtocol.FunctionDeclaration] {
        tools.map(\.declaration)
    }

    /// One parameter as the live sessions can pass it: a string, or a
    /// number or boolean, with what a list or object takes in words.
    static func stringSchema(_ property: [String: Any]) -> [String: Any] {
        let type = (property["type"] as? String)?.lowercased() ?? "string"
        var description = property["description"] as? String ?? ""
        var schema: [String: Any] = [:]
        switch type {
        case "integer", "number", "boolean":
            schema["type"] = type.uppercased()
        case "array":
            schema["type"] = "STRING"
            let choices = (property["items"] as? [String: Any])?["enum"] as? [String] ?? []
            description += choices.isEmpty
                ? " Several values: separate them with commas."
                : " One or more of \(choices.joined(separator: ", ")), separated by commas."
        case "object":
            schema["type"] = "STRING"
            description += " A JSON object."
        default:
            schema["type"] = "STRING"
            if let choices = property["enum"] as? [String] { schema["enum"] = choices }
        }
        let trimmed = description.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { schema["description"] = trimmed }
        return schema
    }

    /// The call's arguments in the host schema's JSON types. Names the
    /// schema doesn't have are dropped.
    func arguments(from values: [String: Any]) -> [String: Any] {
        var arguments: [String: Any] = [:]
        for (name, value) in values {
            guard let property = properties[name], let converted = Self.convert(value, to: property) else { continue }
            arguments[name] = converted
        }
        return arguments
    }

    static func convert(_ value: Any, to property: [String: Any]) -> Any? {
        let type = (property["type"] as? String)?.lowercased() ?? "string"
        guard let text = value as? String else {
            // GPT-Live's JSON already carries real lists and numbers; they
            // meet the same rules as text.
            switch (type, value) {
            case (_, is NSNull): return nil
            case ("integer", let number as NSNumber) where CFGetTypeID(number) != CFBooleanGetTypeID():
                return Int(exactly: number.doubleValue)
            case ("number", let number as NSNumber) where CFGetTypeID(number) != CFBooleanGetTypeID():
                return number.doubleValue
            case ("boolean", let number as NSNumber) where CFGetTypeID(number) == CFBooleanGetTypeID():
                return number.boolValue
            case ("array", let list as [Any]): return list
            case ("object", let object as [String: Any]): return object
            case ("string", let number as NSNumber) where CFGetTypeID(number) != CFBooleanGetTypeID():
                return number.stringValue
            // A phone-local string that may also be a list (the maps tool's
            // `to`, marked "list"): GPT-Live sends the list itself.
            case ("string", let list as [Any]) where (property["list"] as? Bool) == true:
                return list
            default: return nil
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "array":
            if trimmed.hasPrefix("["), let list = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [Any] {
                return list
            }
            let items = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return items.isEmpty ? nil : items
        case "integer":
            // "7" or "7.0"; "7.5" isn't a whole number, so it isn't sent.
            return Int(trimmed) ?? Double(trimmed).flatMap { Int(exactly: $0) }
        case "number":
            return Double(trimmed)
        case "boolean":
            switch trimmed.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        case "object":
            return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        default:
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Gemini's and Grok's counterpart to `gptLiveFirst`, after the
    /// briefing: its start_job rule sends work on the user's "accounts" to
    /// Hermes, and without this a calendar change went out as a Hermes job
    /// although the call had the tool for it. Not UI copy, so not localized.
    static func functionToolsFirst(_ tools: [VoiceHostTool]) -> String {
        let names = tools.filter { $0.key != PresentVoiceTool.key }.map(\.name)
        guard !names.isEmpty else { return "" }
        return "\n\nConduit's own tools: \(names.joined(separator: ", ")). Conduit runs these itself, at once and much "
            + "faster than a Hermes job. When the user asks about or for something one of them covers (reading, adding, "
            + "changing, completing or deleting what they share, or setting or cancelling an alarm, for example), call "
            + "the tool yourself: this takes precedence over the "
            + "start_job rule, and don't say you'll have Hermes do it. Start a job only for what they can't do, or "
            + "when the user asks for Hermes."
    }

    // MARK: GPT-Live

    /// "Health" for conduit_health: the word GPT-Live delegates with.
    var marker: String {
        let bare = name.hasPrefix("conduit_") ? String(name.dropFirst("conduit_".count)) : name
        let words = bare.split(separator: "_").map(String.init)
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// The briefing paragraph that teaches GPT-Live a tool's marker. Not UI
    /// copy, so not localized.
    var gptLiveRule: String {
        let arguments = properties.keys.sorted().map { name -> String in
            let property = properties[name] ?? [:]
            var line = "\"\(name)\""
            if let choices = property["enum"] as? [String] {
                line += " (one of \(choices.joined(separator: ", ")))"
            } else if let choices = (property["items"] as? [String: Any])?["enum"] as? [String] {
                line += " (a list of \(choices.joined(separator: ", ")))"
            }
            if let description = property["description"] as? String, !description.isEmpty { line += ": \(description)" }
            return line
        }
        return "\(description)\nTo use it, delegate \"\(marker):\" followed by its arguments as one JSON object, like \(marker): {\"action\": \"\(exampleAction)\"}. Arguments: \(arguments.joined(separator: "; ")). Conduit answers on that delegation at once (it isn't a Hermes job); answer the user from it. The marker is for Conduit only: never say it aloud."
    }

    /// The first action the schema offers, for the example.
    private var exampleAction: String {
        (properties["action"]?["enum"] as? [String])?.first ?? "overview"
    }

    static func gptLiveRules(_ tools: [VoiceHostTool]) -> String {
        tools.isEmpty ? "" : "\n\n" + gptLiveFirst(tools) + "\n\n" + tools.map(\.gptLiveRule).joined(separator: "\n\n")
    }

    /// Leads the tools' rules: the briefing's first rule sends anything
    /// needing facts or accounts to Hermes, and without this GPT-Live often
    /// delegates "what's on my calendar" as a Hermes job, which is many
    /// seconds slower and may take another route to the same data.
    private static func gptLiveFirst(_ tools: [VoiceHostTool]) -> String {
        let markers = tools.map { "\"\($0.marker):\"" }.joined(separator: ", ")
        return "[Conduit's own tools: \(markers). Conduit answers these itself, much faster than a Hermes job. Use them first. When the user asks about something one of them covers, delegate its marker, not a request for Hermes: this takes precedence over the first rule, which sends real work to Hermes. Don't say you'll have Hermes look: no acknowledgement is needed, answer from what comes back. Delegate to Hermes only what they can't do, or when the user asks for Hermes.]"
    }

    /// "Health: {...}" at the very start of a delegation: the tool and its
    /// JSON arguments (empty when none came).
    static func marked(in request: String, tools: [VoiceHostTool]) -> (tool: VoiceHostTool, arguments: [String: Any])? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        for tool in tools {
            let prefix = tool.marker + ":"
            guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { return (tool, [:]) }
            // The object may be followed by words: the shortest prefix that
            // ends at a brace and parses is the object.
            let braces = rest.indices.filter { rest[$0] == "}" }
            let object = braces.lazy.compactMap {
                (try? JSONSerialization.jsonObject(with: Data(rest[...$0].utf8))) as? [String: Any]
            }.first
            return (tool, object ?? [:])
        }
        return nil
    }

    // MARK: Answers

    /// What the model gets back. Not UI copy, so not localized.
    static func modelResult(_ result: Any) -> [String: String] {
        // A bare string or number is valid JSON too; serialization wants a container.
        let result: Any = result is [Any] || result is [String: Any] ? result : ["value": result]
        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return ["error": "The host's answer couldn't be read."]
        }
        // Cut JSON would read as wrong numbers: ask for less instead.
        guard text.count <= maximumResultCharacters else {
            return ["error": "That answer is too long for a call. Ask for fewer days or metrics."]
        }
        return ["result": text, "note": answerNote]
    }

    /// GPT-Live's delegation answer.
    static func delegatedReply(_ result: [String: String]) -> String {
        if let error = result["error"] { return "[\(error) Tell the user in a few words.]" }
        return "[\(result["note"] ?? answerNote)]\n\(result["result"] ?? "")"
    }

    static let answerNote = "This is the user's own data, shared from their iPhone. Answer from it by ear: the numbers that matter, rounded, and how fresh it is when that matters. Never send it anywhere else."
    static let maximumResultCharacters = 12_000
}
