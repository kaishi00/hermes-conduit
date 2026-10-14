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
    static let alarmTool = "phone_alarm"
    /// What seals them: nothing, they never leave the phone.
    static let key = "local"

    /// The tools for what's shared: changes whenever sharing is on (Hermes
    /// can ask for one), adding when events or reminders can be written,
    /// both by the user's choice and by what iOS still allows.
    static func tools(for preferences: PhoneSyncPreferences, access: PhoneCalendarAccess,
                      remindersAuthorized: Bool, alarmsAuthorized: Bool = false) -> [VoiceHostTool] {
        guard preferences.isOn else { return [] }
        var tools = [changes]
        let allowed = addable(preferences, access: access, remindersAuthorized: remindersAuthorized)
        if allowed.events || allowed.reminders {
            tools.append(add(events: allowed.events, reminders: allowed.reminders,
                             calendarsVisible: access == .full))
        }
        if preferences.alarms, alarmsAuthorized { tools.append(alarm) }
        return tools
    }

    /// For a call whose mode the user hasn't let use what they share with
    /// Hermes: where that's turned on, so the model says so instead of
    /// quietly sending every calendar question to Hermes. Empty otherwise.
    /// Not UI copy, so not localized.
    static func settingHint(for preferences: PhoneSyncPreferences, mode: LiveVoiceModeName) -> String {
        guard preferences.isOn, !preferences.letsVoiceUse(mode),
              preferences.calendar != .off || preferences.reminders || preferences.alarms || preferences.contacts
        else { return "" }
        let shared = [preferences.calendar != .off ? "their calendar" : nil, preferences.reminders ? "their reminders" : nil,
                      preferences.alarms ? "their alarms" : nil, preferences.contacts ? "the people they picked" : nil]
            .compactMap { $0 }
        guard let last = shared.last else { return "" }
        let list = shared.count > 1 ? shared.dropLast().joined(separator: ", ") + " and " + last : last
        // "the people they picked" alone is plural too.
        let (them, those) = shared.count > 1 || preferences.contacts ? ("these", "those") : ("it", "that")
        return "\n\nThe user shares \(list) with Hermes, but hasn't let this call use \(them) directly. "
            + "When they ask about \(those), you can still ask Hermes. The first time in this call, also tell them in "
            + "a sentence that they can let \(mode.displayName) use \(them) directly, which is faster, under Live "
            + "voice calls in Conduit's Settings, Calendar & phone."
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

    private static func add(events: Bool, reminders: Bool, calendarsVisible: Bool) -> VoiceHostTool {
        let kinds = (events ? ["event"] : []) + (reminders ? ["reminder"] : [])
        // Add-only access: the phone can't see its calendars, so the model
        // learns up front not to name one. Set at call start; `runAdd`
        // checks the live access on each add.
        let addOnly = events && !calendarsVisible
            ? " This iPhone lets Conduit add events but not see its calendars: leave the calendar out for events."
            : ""
        return VoiceHostTool(
            name: addTool,
            description: "Adds \(kinds.map { $0 == "event" ? "an event" : "a reminder" }.joined(separator: " or ")) to the user's iPhone at once. "
                + "Only when the user asked for it in this call: say back what you'll add (title, day and time, "
                + "and the calendar or list if named) and add it once they agree, then confirm in a few words. To change or delete "
                + "something, send the request to Hermes instead." + addOnly,
            parameters: [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": kinds],
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "event: the local start, like 2026-10-16T15:00, or a date (2026-10-16) for all day."],
                    "end": ["type": "string", "description": "event: the local end; default an hour after the start."],
                    "all_day": ["type": "boolean", "description": "event: all day."],
                    "due": ["type": "string", "description": "reminder: when it's due, a local time like 2026-10-16T09:00 or a date. Optional."],
                    "calendar": ["type": "string", "description": "The calendar or reminder list by name; the user's default when left out."
                        + (addOnly.isEmpty ? "" : " Leave it out for events.")],
                    "location": ["type": "string", "description": "event: where."],
                    "notes": ["type": "string"],
                ],
                "required": ["kind", "title"],
            ],
            key: key
        )
    }

    private static let alarm = VoiceHostTool(
        name: alarmTool,
        description: "Sets an alarm or starts a timer on the user's iPhone at once; it rings even in Silent mode. "
            + "Only when the user asked for it in this call: say back what you'll set (the time and days, or how long, "
            + "and its name if any) and set it once they agree, then confirm in a few words. To cancel one, send "
            + "the request to Hermes instead.",
        parameters: [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["alarm", "timer"]],
                "time": ["type": "string", "description": "alarm: the local time on a 24-hour clock, like 06:30."],
                "date": ["type": "string", "description": "alarm: the day for a one-off alarm, like 2026-10-16; the next 'time' when left out."],
                "days": ["type": "array", "items": ["type": "string", "enum": PhoneChangeFields.weekdays],
                         "description": "alarm: the weekdays it repeats on; leave out for once."],
                "minutes": ["type": "number", "description": "timer: how long, in minutes (fractions allowed)."],
                "label": ["type": "string", "description": "A short name, like Pasta or Wake up."],
            ],
            "required": ["kind"],
        ],
        key: key
    )

    // MARK: Running them

    /// One call of a local tool. What the model hears back.
    static func run(_ tool: VoiceHostTool, arguments: [String: Any], engine: PhoneSyncEngine,
                    answer: (PhoneChangePrompt, Bool) async -> Void) async -> [String: String] {
        switch tool.name {
        case changesTool:
            return await runChanges(arguments, engine: engine, answer: answer)
        case addTool:
            return await runAdd(arguments, engine: engine)
        case alarmTool:
            return await runAlarm(arguments, engine: engine)
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
            // No outcome yet: another answer to it is still being applied.
            guard let result = engine.state.answered[id] else {
                return ["result": "It's still being applied; Hermes will hear how it went."]
            }
            if result.outcome == .failed {
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
        // Add-only access can't see the calendars, so none can be named.
        if isEvent, calendarName?.isEmpty == false, engine.calendarSource.eventAccess != .full {
            return ["error": "This iPhone lets Conduit add events but not see its calendars. Leave the calendar out to use the default."]
        }
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

    private static func runAlarm(_ arguments: [String: Any], engine: PhoneSyncEngine) async -> [String: String] {
        guard engine.preferences.alarms, engine.alarmSource.authorized else {
            return ["error": "The user doesn't let Hermes set alarms. They can turn it on in Conduit's Settings."]
        }
        var fields: [String: Any] = [:]
        if let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            fields["label"] = label
        }
        let kind: String
        switch arguments["kind"] as? String ?? "" {
        case "timer":
            guard let minutes = (arguments["minutes"] as? NSNumber)?.doubleValue, minutes > 0 else {
                return ["error": "A timer needs minutes, like 10."]
            }
            let seconds = Int((minutes * 60).rounded())
            guard (5...86_400).contains(seconds) else { return ["error": "A timer runs from 5 seconds to 24 hours."] }
            fields["seconds"] = seconds
            kind = "set_timer"
        case "alarm":
            guard let timeText = (arguments["time"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let time = PhoneChangeFields.clockTime(timeText.count == 4 ? "0" + timeText : timeText) else {
                return ["error": "An alarm needs a time like 06:30."]
            }
            let named = (arguments["days"] as? [Any])?.compactMap {
                ($0 as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
            } ?? []
            guard named.allSatisfy({ PhoneChangeFields.weekdays.contains($0) }) else {
                return ["error": "days are mon, tue, wed, thu, fri, sat or sun."]
            }
            // Each day once, in week order.
            let days = PhoneChangeFields.weekdays.filter { named.contains($0) }
            if let date = arguments["date"] as? String, !date.trimmingCharacters(in: .whitespaces).isEmpty, !days.isEmpty {
                return ["error": "An alarm takes a date (once) or days (repeating), not both. Ask which the user means."]
            }
            let dateText = (arguments["date"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !dateText.isEmpty, localTime(dateText)?.isDate != true {
                return ["error": "date is a day, like 2026-10-16; the time goes in time."]
            }
            if let date = localTime(dateText), date.isDate, days.isEmpty {
                guard let at = localTime(date.text + "T" + time.text).flatMap({ PhoneDates.parse($0.text) }) else {
                    return ["error": "That date and time couldn't be read."]
                }
                // A time already gone is refused by the phone's own clock when it's set.
                fields["at"] = PhoneDates.format(at)
            } else {
                fields["time"] = time.text
                if !days.isEmpty { fields["repeats"] = days }
            }
            kind = "set_alarm"
        default:
            return ["error": "kind is alarm or timer."]
        }
        let id = "voice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let change = PhoneChange(json: ["id": id, "kind": kind, "fields": fields]) else {
            return ["error": "That couldn't be set; check the time."]
        }
        do {
            _ = try await engine.addFromVoice(change)
            return ["result": "Set on the phone: \(PhoneChangeWording.alarmSummary(change.fields, kind: change.kind)). Confirm it to the user in a few words."]
        } catch {
            return ["error": "It couldn't be set: \(PhoneSyncEngine.describe(error))"]
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
        if let label = change.fields.label { entry["label"] = label }
        if let at = change.fields.at { entry["at"] = PhoneDates.format(at) }
        if let time = change.fields.time { entry["time"] = time.text }
        if let repeats = change.fields.repeats { entry["repeats"] = repeats }
        if let seconds = change.fields.seconds { entry["seconds"] = seconds }
        if let alarm = prompt.alarmTitle { entry["alarm"] = alarm }
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
