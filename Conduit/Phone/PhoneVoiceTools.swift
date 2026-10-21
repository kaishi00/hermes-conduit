//
//  PhoneVoiceTools.swift
//  Conduit
//
//  The phone's own tools for a live voice call, next to the host's calendar
//  reads: answering the calendar changes Hermes asked for (the card, out
//  loud), and adding, changing or deleting an event or reminder, or setting
//  or cancelling an alarm, the user asks for, applied here straight away with
//  no host trip. Whatever the phone can do itself never goes to Hermes.
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
    static let removeTool = "phone_remove"
    static let updateTool = "phone_update"
    static let alarmTool = "phone_alarm"
    /// What seals them: nothing, they never leave the phone.
    static let key = "local"
    /// The user turn that last agreed to a change or deletion: each yes
    /// answers one. Only the latest turn can agree, so earlier ones needn't
    /// be kept.
    static var usedConfirmation: UUID?
    /// The user turn current when the model first heard of each waiting
    /// change: words from before that can't approve it.
    static var arrivalTurns: [String: UUID] = [:]

    /// Notes the user's turn as the model first hears of a change (a list,
    /// or the mid-call note): the first note wins.
    static func noteArrival(_ promptID: String, userTurn: UUID?) {
        guard arrivalTurns[promptID] == nil, let userTurn else { return }
        arrivalTurns[promptID] = userTurn
    }

    /// A call starts watching: arrivals noted in an earlier call are dropped,
    /// so a change still waiting from one is anchored to this call's turn.
    static func beginWatch(waiting: Set<String>, turn: UUID?) {
        arrivalTurns = [:]
        for id in waiting { noteArrival(id, userTurn: turn) }
    }

    /// The tools for what's shared: changes whenever sharing is on (Hermes
    /// can ask for one), adding when events or reminders can be written,
    /// both by the user's choice and by what iOS still allows, and changing
    /// or deleting what the call can read (it needs the item's id from a
    /// read).
    static func tools(for preferences: PhoneSyncPreferences, access: PhoneCalendarAccess,
                      remindersAuthorized: Bool, alarmsAuthorized: Bool = false) -> [VoiceHostTool] {
        guard preferences.isOn else { return [] }
        var tools = [changes]
        let allowed = addable(preferences, access: access, remindersAuthorized: remindersAuthorized)
        if allowed.events || allowed.reminders {
            tools.append(add(events: allowed.events, reminders: allowed.reminders,
                             calendarsVisible: access == .full))
        }
        let removable = removable(preferences, access: access, remindersAuthorized: remindersAuthorized)
        if removable.events || removable.reminders {
            tools.append(update(events: removable.events, reminders: removable.reminders))
            tools.append(remove(events: removable.events, reminders: removable.reminders))
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
        (preferences.allows(.addEvent) && access != .off, preferences.allows(.addReminder) && remindersAuthorized)
    }

    /// Changing or deleting finds the item by the id a read gave, so
    /// add-only events (never read) can't be, nor anything read-only.
    private static func removable(_ preferences: PhoneSyncPreferences, access: PhoneCalendarAccess,
                                  remindersAuthorized: Bool) -> (events: Bool, reminders: Bool) {
        (preferences.allows(.deleteEvent) && access == .full, preferences.allows(.deleteReminder) && remindersAuthorized)
    }

    private static let changes = VoiceHostTool(
        name: changesTool,
        description: "Calendar and reminder changes Hermes asked for that wait on the user's answer on this iPhone. "
            + "list: what's waiting. approve or dismiss: answer one by its id from list, only after the user said "
            + "so out loud in this call; Conduit checks their words and refuses otherwise. Approving applies it "
            + "on the phone at once. Tell the user what it is in a sentence (what, when, which calendar, and why "
            + "if Hermes said) before asking. List once early in the call: some may be waiting from before it.",
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
                + "and the calendar or list if named) and add it once they agree, then confirm in a few words. Use this, "
                + "not Hermes, for a new one." + addOnly,
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

    private static func update(events: Bool, reminders: Bool) -> VoiceHostTool {
        let kinds = (events ? ["event"] : []) + (reminders ? ["reminder"] : [])
        let things = kinds.map { $0 == "event" ? "an event" : "a reminder" }.joined(separator: " or ")
        var properties: [String: Any] = [
            "kind": ["type": "string", "enum": kinds],
            "id": ["type": "string", "description": "The event's or reminder's id from the calendar read."],
            "title": ["type": "string", "description": "The new title."],
            "notes": ["type": "string", "description": "The new notes."],
        ]
        if events {
            properties["start"] = ["type": "string", "description": "event: the new local start, like 2026-10-16T15:00, or a date for all day."]
            properties["end"] = ["type": "string", "description": "event: the new local end; moving the start keeps its length."]
            properties["all_day"] = ["type": "boolean", "description": "event: all day."]
            properties["location"] = ["type": "string", "description": "event: where."]
            properties["span"] = ["type": "string", "enum": ["this", "future"],
                                  "description": "event: for a repeating event, this one only (default) or this and all later ones."] as [String: Any]
        }
        if reminders {
            properties["due"] = ["type": "string", "description": "reminder: when it's due, a local time like 2026-10-16T09:00 or a date."]
            properties["completed"] = ["type": "boolean", "description": "reminder: true marks it done, false not done."]
        }
        return VoiceHostTool(
            name: updateTool,
            description: "Changes \(things) on the user's iPhone at once, by its id from the calendar read "
                + "(or from \(addTool) for one added in this call): move or reschedule it, rename it, change its notes"
                + (events ? " or place" : "") + (reminders ? ", or mark a reminder done" : "") + ". Use this, not Hermes, "
                + "when the user asks to change, move, reschedule, rename or complete one. Only when the user asked for it in "
                + "this call: find it first, say back the change (which one, and what it becomes) and make it once they say "
                + "yes, then confirm in a few words. Only what you pass changes; the rest stays.",
            parameters: [
                "type": "object",
                "properties": properties,
                "required": ["kind", "id"],
            ],
            key: key
        )
    }

    private static func remove(events: Bool, reminders: Bool) -> VoiceHostTool {
        let kinds = (events ? ["event"] : []) + (reminders ? ["reminder"] : [])
        let things = kinds.map { $0 == "event" ? "an event" : "a reminder" }.joined(separator: " or ")
        return VoiceHostTool(
            name: removeTool,
            description: "Deletes \(things) from the user's iPhone at once, by its id from the calendar read "
                + "(or from \(addTool) for one added in this call). Use this, not Hermes, when the user asks to remove, "
                + "delete or cancel one. Only when the user asked for it in this call: find it first, say back which one "
                + "you'll delete (title, day and time) and delete it once they say yes, then confirm in a few words. "
                + "Each deletion needs its own yes: for several, ask about each in turn. "
                + "For one event of a repeating series, span this (the default) deletes only that one; future deletes "
                + "it and all later ones, only when the user said so.",
            parameters: [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": kinds],
                    "id": ["type": "string", "description": "The event's or reminder's id from the calendar read."],
                    "span": ["type": "string", "enum": ["this", "future"],
                             "description": "event: for a repeating event, this one only (default) or this and all later ones."],
                ],
                "required": ["kind", "id"],
            ],
            key: key
        )
    }

    private static let alarm = VoiceHostTool(
        name: alarmTool,
        description: "Sets an alarm or starts a timer on the user's iPhone at once (it rings even in Silent mode), "
            + "lists the ones Conduit set, or cancels one. Use this, not Hermes, for alarms and timers. To set one, only "
            + "when the user asked for it in this call: say back what you'll set (the time and days, or how long, "
            + "and its name if any) and set it once they agree, then confirm in a few words. To cancel one: list them, "
            + "say back which one you'll cancel and cancel it by its id once they say yes.",
        parameters: [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["alarm", "timer", "list", "cancel"],
                         "description": "alarm or timer: set one. list: the alarms and timers Conduit set. cancel: cancel one by its id."],
                "id": ["type": "string", "description": "cancel: the alarm's or timer's id from list (or from setting it in this call)."],
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
    /// `confirmed` says whether the user's own last words agree to a change,
    /// deletion or cancellation (it changes what the user already has, so
    /// the model's word isn't enough); a turn equal to `excluding` (the turn
    /// current when a waiting change arrived) can't be that yes.
    /// `lastUserTurn` is the user's most recent turn in the call, which
    /// approving a waiting change needs to be a yes said after it was noted.
    static func run(_ tool: VoiceHostTool, arguments: [String: Any], engine: PhoneSyncEngine,
                    confirmed: (_ cancelsAlarm: Bool, _ excluding: UUID?) async -> Bool = { _, _ in false },
                    lastUserTurn: @escaping @MainActor () -> (id: UUID?, text: String) = { (nil, "") },
                    answer: (PhoneChangePrompt, Bool) async -> Void) async -> [String: String] {
        switch tool.name {
        case changesTool:
            return await runChanges(arguments, engine: engine, confirmed: confirmed,
                                    lastUserTurn: lastUserTurn, answer: answer)
        case addTool:
            return await runAdd(arguments, engine: engine)
        case updateTool:
            return await runUpdate(arguments, engine: engine, confirmed: confirmed)
        case removeTool:
            return await runRemove(arguments, engine: engine, confirmed: confirmed)
        case alarmTool:
            return await runAlarm(arguments, engine: engine, confirmed: confirmed)
        default:
            return ["error": "That isn't available on this call."]
        }
    }

    private static func runChanges(_ arguments: [String: Any], engine: PhoneSyncEngine,
                                   confirmed: (_ cancelsAlarm: Bool, _ excluding: UUID?) async -> Bool,
                                   lastUserTurn: @escaping @MainActor () -> (id: UUID?, text: String),
                                   answer: (PhoneChangePrompt, Bool) async -> Void) async -> [String: String] {
        let action = arguments["action"] as? String ?? ""
        // Arrivals for changes no longer waiting are dead weight.
        let waiting = Set(engine.prompts.map(\.id))
        arrivalTurns = arrivalTurns.filter { waiting.contains($0.key) }
        switch action {
        case "list":
            let turn = lastUserTurn().id
            for prompt in engine.prompts { noteArrival(prompt.id, userTurn: turn) }
            let listed = engine.prompts.map(describe)
            return VoiceHostTool.modelResult(waiting.isEmpty
                ? ["changes": [Any](), "note": "Nothing is waiting."] as [String: Any]
                : ["changes": listed] as [String: Any])
        case "approve", "dismiss":
            guard let id = arguments["id"] as? String,
                  let prompt = engine.prompts.first(where: { $0.id == id }) else {
                return ["error": "No change with that id is waiting. List them again."]
            }
            // Applying one takes the user's own yes, as a change made here does.
            if action == "approve", !(await confirmed(prompt.change.kind == .cancelAlarm, arrivalTurns[prompt.id])) {
                return ["error": "Not approved: the user's own last words weren't a yes. Say back the change and approve "
                    + "it only once they say yes."]
            }
            // The turn current when the model first heard of the change can't
            // approve it (checked in the poll too; kept here as a backstop): words from before it was there to hear about answer
            // something else.
            if action == "approve", let shownAfter = arrivalTurns[prompt.id],
               lastUserTurn().id == shownAfter {
                return ["error": "Not approved: the user's own words weren't a yes. Tell the user what it is "
                    + "in a sentence and approve only once they say yes."]
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
            let itemID = try await engine.applyFromVoice(change)
            // Its id, so "actually, take that off" needs no read.
            return ["result": "Added on the phone. Confirm it to the user in a few words."
                + (itemID.map { " Its id, for \(removeTool) should they want it deleted (never say it aloud): \($0)." } ?? "")]
        } catch {
            return ["error": "It couldn't be added: \(PhoneSyncEngine.describe(error))"]
        }
    }

    private static func runUpdate(_ arguments: [String: Any], engine: PhoneSyncEngine,
                                  confirmed: (_ cancelsAlarm: Bool, _ excluding: UUID?) async -> Bool) async -> [String: String] {
        let allowed = removable(engine.preferences, access: engine.calendarSource.eventAccess,
                                remindersAuthorized: engine.calendarSource.remindersAuthorized)
        guard let itemID = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemID.isEmpty, itemID.count <= 200 else {
            return ["error": "Give the id from the calendar read; read the calendar first to find it."]
        }
        let isEvent: Bool
        switch arguments["kind"] as? String ?? "" {
        case "event" where allowed.events: isEvent = true
        case "reminder" where allowed.reminders: isEvent = false
        case "event", "reminder": return ["error": "The user doesn't let Hermes change those. They can turn it on in Conduit's Settings."]
        default: return ["error": "kind is event or reminder."]
        }
        var fields: [String: Any] = [:]
        if let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !title.isEmpty else { return ["error": "A title can't be empty; leave it out to keep it."] }
            fields["title"] = title
        }
        if let notes = arguments["notes"] as? String { fields["notes"] = notes }
        let kind: String
        if isEvent {
            if let text = arguments["start"] as? String {
                guard let start = localTime(text) else { return ["error": "start is a local time like 2026-10-16T15:00, or a date."] }
                fields["start"] = start.text
                if arguments["all_day"] == nil, start.isDate { fields["all_day"] = true }
            }
            if let text = arguments["end"] as? String {
                guard let end = localTime(text) else { return ["error": "end is a local time like 2026-10-16T16:00, or a date."] }
                fields["end"] = end.text
            }
            if let allDay = arguments["all_day"] as? Bool { fields["all_day"] = allDay }
            if let location = arguments["location"] as? String { fields["location"] = location }
            let span = (arguments["span"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "this"
            guard span == "this" || span == "future" else { return ["error": "span is this or future."] }
            fields["span"] = span
            kind = "update_event"
        } else {
            if let text = arguments["due"] as? String {
                guard let due = localTime(text) else { return ["error": "due is a local time like 2026-10-16T09:00, or a date."] }
                fields["due"] = due.text
                fields["due_all_day"] = due.isDate
            }
            let completed = arguments["completed"] as? Bool
            // Marking it done and nothing else is a completion, which the
            // phone applies as one.
            if let completed, fields.isEmpty {
                fields["completed"] = completed
                kind = "complete_reminder"
            } else {
                if completed != nil {
                    return ["error": "Mark it done on its own, then make the other change."]
                }
                kind = "update_reminder"
            }
        }
        guard kind == "complete_reminder" || fields.keys.contains(where: { $0 != "span" }) else {
            return ["error": "Nothing to change: say what changes (a title, time, notes\(isEvent ? " or place" : " or due time"))."]
        }
        let id = "voice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let target = isEvent ? "event_id" : "reminder_id"
        guard let change = PhoneChange(json: ["id": id, "kind": kind, "target": [target: itemID], "fields": fields]) else {
            return ["error": "That couldn't be changed; check the id and times."]
        }
        guard await confirmed(false, nil) else {
            return ["error": "Not changed: the user's own last words weren't a yes. Say back the change and make it only "
                + "once they say yes."]
        }
        do {
            _ = try await engine.applyFromVoice(change)
            return ["result": "Changed on the phone. Confirm it to the user in a few words."]
        } catch PhoneCalendarSourceError.notFound {
            return ["error": "There's no \(isEvent ? "event" : "reminder") with that id on this phone. Read the calendar again for its id."]
        } catch {
            return ["error": "It couldn't be changed: \(PhoneSyncEngine.describe(error))"]
        }
    }

    private static func runRemove(_ arguments: [String: Any], engine: PhoneSyncEngine,
                                  confirmed: (_ cancelsAlarm: Bool, _ excluding: UUID?) async -> Bool) async -> [String: String] {
        let allowed = removable(engine.preferences, access: engine.calendarSource.eventAccess,
                                remindersAuthorized: engine.calendarSource.remindersAuthorized)
        guard let itemID = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemID.isEmpty, itemID.count <= 200 else {
            return ["error": "Give the id from the calendar read; read the calendar first to find it."]
        }
        let isEvent: Bool
        switch arguments["kind"] as? String ?? "" {
        case "event" where allowed.events: isEvent = true
        case "reminder" where allowed.reminders: isEvent = false
        case "event", "reminder": return ["error": "The user doesn't let Hermes delete those. They can turn it on in Conduit's Settings."]
        default: return ["error": "kind is event or reminder."]
        }
        var fields: [String: Any] = [:]
        if isEvent {
            let span = (arguments["span"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "this"
            guard span == "this" || span == "future" else { return ["error": "span is this or future."] }
            fields["span"] = span
        }
        let id = "voice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let target = isEvent ? "event_id" : "reminder_id"
        guard let change = PhoneChange(json: ["id": id, "kind": isEvent ? "delete_event" : "delete_reminder",
                                              "target": [target: itemID], "fields": fields]) else {
            return ["error": "That couldn't be deleted; check the id."]
        }
        guard await confirmed(false, nil) else {
            return ["error": "Not deleted: the user's own last words weren't a yes. Say back which one you'll delete and "
                + "delete it only once they say yes."]
        }
        do {
            _ = try await engine.applyFromVoice(change)
            return ["result": "Deleted on the phone. Confirm it to the user in a few words."]
        } catch PhoneCalendarSourceError.notFound {
            return ["error": "There's no \(isEvent ? "event" : "reminder") with that id on this phone. Read the calendar again for its id."]
        } catch {
            return ["error": "It couldn't be deleted: \(PhoneSyncEngine.describe(error))"]
        }
    }

    private static func runAlarm(_ arguments: [String: Any], engine: PhoneSyncEngine,
                                 confirmed: (_ cancelsAlarm: Bool, _ excluding: UUID?) async -> Bool) async -> [String: String] {
        guard engine.preferences.alarms, engine.alarmSource.authorized else {
            return ["error": "The user doesn't let Hermes set alarms. They can turn it on in Conduit's Settings."]
        }
        switch arguments["kind"] as? String ?? "" {
        case "list":
            guard let alarms = engine.alarmSource.alarms(now: Date(), calendar: .current) else {
                return ["error": "The alarms couldn't be read just now."]
            }
            return VoiceHostTool.modelResult(alarms.isEmpty
                ? ["alarms": [Any](), "note": "Conduit has no alarms or timers set."] as [String: Any]
                : ["alarms": alarms] as [String: Any])
        case "cancel":
            guard let alarmID = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !alarmID.isEmpty, alarmID.count <= 80 else {
                return ["error": "Give the alarm's id; list them first to find it."]
            }
            let id = "voice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            guard let change = PhoneChange(json: ["id": id, "kind": "cancel_alarm", "target": ["alarm_id": alarmID]]) else {
                return ["error": "That couldn't be cancelled; check the id."]
            }
            guard await confirmed(true, nil) else {
                return ["error": "Not cancelled: the user's own last words weren't a yes. Say back which one you'll cancel "
                    + "and cancel it only once they say yes."]
            }
            do {
                _ = try await engine.applyFromVoice(change)
                return ["result": "Cancelled on the phone. Confirm it to the user in a few words."]
            } catch {
                return ["error": "It couldn't be cancelled: \(PhoneSyncEngine.describe(error))"]
            }
        default:
            break
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
            guard let seconds = Int(exactly: (minutes * 60).rounded()),
                  (5...86_400).contains(seconds) else {
                return ["error": "A timer runs from 5 seconds to 24 hours."]
            }
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
            return ["error": "kind is alarm, timer, list or cancel."]
        }
        let id = "voice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let change = PhoneChange(json: ["id": id, "kind": kind, "fields": fields]) else {
            return ["error": "That couldn't be set; check the time."]
        }
        do {
            let alarmID = try await engine.applyFromVoice(change)
            return ["result": "Set on the phone: \(PhoneChangeWording.alarmSummary(change.fields, kind: change.kind)). Confirm it to the user in a few words."
                + (alarmID.map { " Its id, for cancelling it (never say it aloud): \($0)." } ?? "")]
        } catch {
            return ["error": "It couldn't be set: \(PhoneSyncEngine.describe(error))"]
        }
    }

    /// Whether the user's words agree to a change, deletion or cancellation:
    /// a yes (in any language the call's own yes check knows), or a short
    /// "delete it" / "yes, move it" / "mark it done" naming it, in each of
    /// the app's languages. Never a question, never a longer request.
    static func confirmsChange(_ words: String, cancelsAlarm: Bool = false) -> Bool {
        VoiceCallDecisionOutcome.isYes(words) || PhoneChangeConfirmation.confirms(words, cancelsAlarm: cancelsAlarm)
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
