//
//  PhoneVoiceTools.swift
//  Conduit
//
//  The phone's own tools for a live voice call, next to the host's calendar
//  reads: answering the calendar changes Hermes asked for (the card, out
//  loud), and adding an event or reminder the user asks for, applied here
//  straight away with no host trip. Updates and deletions stay with Hermes.
//  Offered only when the user lets that voice mode use the calendar and
//  phone (Settings > Calendar & phone). Descriptions and answers are for the
//  model, not UI copy, so not localized.
//  (designs/calendar-reminders-and-more.md, Voice)
//

import Foundation

@MainActor
enum PhoneVoiceTools {
    static let changesTool = "phone_changes"
    static let addTool = "phone_add"
    /// What seals them: nothing, they never leave the phone.
    static let key = "local"

    /// The tools for what's shared: changes whenever sharing is on (Hermes
    /// can ask for one), adding when events or reminders can be written,
    /// both by the user's choice and by what iOS still allows.
    static func tools(for preferences: PhoneSyncPreferences, access: PhoneCalendarAccess,
                      remindersAuthorized: Bool) -> [VoiceHostTool] {
        guard preferences.isOn else { return [] }
        var tools = [changes]
        let allowed = addable(preferences, access: access, remindersAuthorized: remindersAuthorized)
        if allowed.events || allowed.reminders {
            tools.append(add(events: allowed.events, reminders: allowed.reminders))
        }
        return tools
    }

    private static func addable(_ preferences: PhoneSyncPreferences, access: PhoneCalendarAccess,
                                remindersAuthorized: Bool) -> (events: Bool, reminders: Bool) {
        (preferences.calendar != .off && access != .off, preferences.reminders && remindersAuthorized)
    }

    private static let changes = VoiceHostTool(
        name: changesTool,
        description: "Calendar and reminder changes Hermes asked for that wait on the user's answer on this iPhone. "
            + "list: what's waiting. approve or dismiss: answer one by its id from list, only after the user said "
            + "so out loud in this call. Approving applies it on the phone at once. Tell the user what it is in "
            + "a sentence (what, when, which calendar, and why if Hermes said) before asking. List once early "
            + "in the call: some may be waiting from before it.",
        parameters: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["list", "approve", "dismiss"]],
                "id": ["type": "string", "description": "approve, dismiss: the change's id from list."],
            ],
            "required": ["action"],
        ],
        key: key
    )

    private static func add(events: Bool, reminders: Bool) -> VoiceHostTool {
        let kinds = (events ? ["event"] : []) + (reminders ? ["reminder"] : [])
        return VoiceHostTool(
            name: addTool,
            description: "Adds \(kinds.map { $0 == "event" ? "an event" : "a reminder" }.joined(separator: " or ")) to the user's iPhone at once. "
                + "Only when the user asked for it in this call: say back what you'll add (title, day and time, "
                + "calendar or list) and add it once they agree, then confirm in a few words. To change or delete "
                + "something, send the request to Hermes instead.",
            parameters: [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": kinds],
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "event: the local start, like 2026-10-16T15:00, or a date (2026-10-16) for all day."],
                    "end": ["type": "string", "description": "event: the local end; default an hour after the start."],
                    "all_day": ["type": "boolean", "description": "event: all day."],
                    "due": ["type": "string", "description": "reminder: when it's due, a local time like 2026-10-16T09:00 or a date. Optional."],
                    "calendar": ["type": "string", "description": "The calendar or reminder list by name; the user's default when left out."],
                    "location": ["type": "string", "description": "event: where."],
                    "notes": ["type": "string"],
                ],
                "required": ["kind", "title"],
            ],
            key: key
        )
    }

    // MARK: Running them

    /// One call of a local tool. What the model hears back.
    static func run(_ tool: VoiceHostTool, arguments: [String: Any], engine: PhoneSyncEngine,
                    answer: (PhoneChangePrompt, Bool) async -> Void) async -> [String: String] {
        switch tool.name {
        case changesTool:
            return await runChanges(arguments, engine: engine, answer: answer)
        case addTool:
            return await runAdd(arguments, engine: engine)
        default:
            return ["error": "That isn't available on this call."]
        }
    }

    private static func runChanges(_ arguments: [String: Any], engine: PhoneSyncEngine,
                                   answer: (PhoneChangePrompt, Bool) async -> Void) async -> [String: String] {
        let action = arguments["action"] as? String ?? ""
        switch action {
        case "list":
            let waiting = engine.prompts.map(describe)
            return VoiceHostTool.modelResult(waiting.isEmpty
                ? ["changes": [Any](), "note": "Nothing is waiting."] as [String: Any]
                : ["changes": waiting] as [String: Any])
        case "approve", "dismiss":
            guard let id = arguments["id"] as? String,
                  let prompt = engine.prompts.first(where: { $0.id == id }) else {
                return ["error": "No change with that id is waiting. List them again."]
            }
            await answer(prompt, action == "approve")
            if action == "dismiss" { return ["result": "Dismissed. Hermes will hear the user said no."] }
            if let result = engine.state.answered[id], result.outcome == .failed {
                return ["error": "It couldn't be applied: \(result.note ?? "the phone refused it")."]
            }
            return ["result": "Done on the phone; Hermes will hear it went in."]
        default:
            return ["error": "action is list, approve or dismiss."]
        }
    }

    private static func runAdd(_ arguments: [String: Any], engine: PhoneSyncEngine) async -> [String: String] {
        let allowed = addable(engine.preferences, access: engine.calendarSource.eventAccess,
                              remindersAuthorized: engine.calendarSource.remindersAuthorized)
        guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return ["error": "An event or reminder needs a title."]
        }
        let isEvent: Bool
        switch arguments["kind"] as? String ?? "" {
        case "event" where allowed.events: isEvent = true
        case "reminder" where allowed.reminders: isEvent = false
        case "event", "reminder": return ["error": "The user doesn't let Hermes add those. They can turn it on in Conduit's Settings."]
        default: return ["error": "kind is event or reminder."]
        }
        var fields: [String: Any] = ["title": title]
        if let notes = arguments["notes"] as? String { fields["notes"] = notes }
        let calendarName = (arguments["calendar"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarID = calendarName.flatMap { name in
            engine.calendarSource.calendars(eventsReadable: engine.calendarSource.eventAccess == .full,
                                            reminders: engine.calendarSource.remindersAuthorized)
                .first { entry in
                    entry["kind"] as? String == (isEvent ? "event" : "reminder")
                        && (entry["title"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
                }?["id"] as? String
        }
        if calendarName?.isEmpty == false, calendarID == nil {
            return ["error": "There's no \(isEvent ? "calendar" : "list") called \(calendarName ?? "") on this phone. Ask which one, or leave it out for the default."]
        }
        if isEvent {
            guard let start = (arguments["start"] as? String).flatMap(localTime) else {
                return ["error": "An event needs a start, like 2026-10-16T15:00."]
            }
            let allDay = (arguments["all_day"] as? Bool) ?? (start.isDate)
            fields["start"] = start.text
            fields["all_day"] = allDay
            if let end = (arguments["end"] as? String).flatMap(localTime) { fields["end"] = end.text }
            if let location = arguments["location"] as? String { fields["location"] = location }
            if let calendarID { fields["calendar_id"] = calendarID }
        } else {
            if let due = (arguments["due"] as? String).flatMap(localTime) {
                fields["due"] = due.text
                fields["due_all_day"] = due.isDate
            }
            if let calendarID { fields["list_id"] = calendarID }
        }
        let id = "voice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let change = PhoneChange(json: ["id": id, "kind": isEvent ? "add_event" : "add_reminder", "fields": fields]) else {
            return ["error": "That couldn't be added; check the title and time."]
        }
        do {
            _ = try await engine.addFromVoice(change)
            return ["result": "Added on the phone. Confirm it to the user in a few words."]
        } catch {
            return ["error": "It couldn't be added: \(PhoneSyncEngine.describe(error))"]
        }
    }

    // MARK: Wording for the model

    /// A waiting change as the model hears it.
    static func describe(_ prompt: PhoneChangePrompt) -> [String: Any] {
        let change = prompt.change
        var entry: [String: Any] = ["id": change.id, "kind": change.kind.rawValue.replacingOccurrences(of: "_", with: " ")]
        if let title = change.fields.title { entry["title"] = title }
        if let start = change.fields.start { entry["start"] = PhoneDates.format(start) }
        if let end = change.fields.end { entry["end"] = PhoneDates.format(end) }
        if change.fields.allDay == true { entry["all_day"] = true }
        if let due = change.fields.dueText { entry["due"] = due }
        if let calendar = prompt.calendarTitle { entry["calendar"] = calendar }
        if let location = change.fields.location { entry["location"] = location }
        if let reason = change.reason { entry["reason"] = reason }
        return entry
    }

    /// The quiet note a call gets when Hermes asks for a change mid-call.
    static func note(for prompt: PhoneChangePrompt) -> String {
        let entry = describe(prompt)
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])) ?? Data()
        let details = String(data: data, encoding: .utf8) ?? ""
        return "[Hermes is asking for a change on this iPhone: \(details). At the next natural pause, tell the user in a sentence and ask whether to go ahead; then call \(changesTool) with approve or dismiss and its id. Don't interrupt the user for it.]"
    }

    // MARK: Times

    /// A time as the model says it: with an offset, a local time without one
    /// (this phone's zone), or a date. `text` is what a change carries.
    static func localTime(_ text: String) -> (text: String, isDate: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 10, PhoneDates.parse(trimmed) != nil { return (trimmed, true) }
        if PhoneDates.parse(trimmed) != nil { return (trimmed, false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return (PhoneDates.format(date), false) }
        }
        return nil
    }
}
