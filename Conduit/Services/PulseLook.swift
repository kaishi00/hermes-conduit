//
//  PulseLook.swift
//  Conduit
//
//  What a Pulse card shows besides its words (plugin 0.150.0,
//  `pulse_looks`): the pick it was made from, checked by the plugin
//  (pulse_picks.py). A shape with its facts (a date, something due, a
//  job's recent runs, a promise in the words it was made, a status, the
//  steps of something underway, a card body drawn like a chat's
//  conduit_show card, or plain words) and at most two actions. The
//  morning brief's card carries its parts the same way: its summary, what's
//  on today, what's still open, and how many of each. A card from an older
//  plugin, or one whose look this build can't read, has none and shows its
//  words as before.
//

import Foundation

struct PulseLook: Equatable {
    enum State: String {
        case ok, warn, fail
    }

    enum Body: Equatable {
        /// A date every year or once (a birthday, an appointment): the day,
        /// what it is and whose.
        case date(day: Date, what: String, whose: String)
        /// Something to get done by a day, or a day and time.
        case due(due: Date, hasTime: Bool, noticed: Date?)
        /// A scheduled job's recent runs, oldest first: true for one that went fine.
        case runs(job: String, results: [Bool])
        /// What someone said they'd do, in their words.
        case promise(said: String, person: String, place: String, when: String)
        case status(label: String, state: State)
        /// Named steps and the one it's at, counted from 0.
        case steps(names: [String], at: Int)
        /// A card body drawn as a chat's conduit_show card is.
        case drawn(RichCard)
        /// The morning brief's parts (pulse_brief.look).
        case brief(summary: String, today: [String], open: [String], held: Int)
        case plain
    }

    struct Action: Equatable {
        enum Does: String {
            case ask, open, draft, done, later
        }

        let label: String
        let does: Does
        /// ask: the words for the chat's composer. draft: the message to
        /// send someone. open: the link.
        let value: String

        init?(json: Any) {
            guard let object = json as? [String: Any],
                  let does = (object["does"] as? String).flatMap(Does.init(rawValue:)) else { return nil }
            let label = (object["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String
            switch does {
            case .ask: value = object["say"] as? String ?? ""
            case .draft: value = object["text"] as? String ?? ""
            case .open: value = object["url"] as? String ?? ""
            case .done, .later: value = ""
            }
            let needsValue = does == .ask || does == .draft || does == .open
            // Done and Later draw the app's own words, so they need no label.
            guard !label.isEmpty || !needsValue,
                  !needsValue || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            if does == .open {
                guard let url = URL(string: value), url.scheme == "https" else { return nil }
            }
            self.label = label
            self.does = does
            self.value = value
        }

        /// The link an open action opens.
        var url: URL? { does == .open ? URL(string: value) : nil }
    }

    let body: Body
    let line: String
    let detail: String
    /// At most two, one each of what they do.
    let actions: [Action]

    /// Nil for no look, or a shape this build doesn't know with nothing to
    /// draw: the card shows its words.
    /// The plugin's dates are Gregorian whatever calendar the phone uses
    /// (as PhoneSync reads them), in the phone's time zone.
    static var wireCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    init?(json: Any?, calendar: Calendar = PulseLook.wireCalendar) {
        guard let object = json as? [String: Any], let shape = object["shape"] as? String else { return nil }
        let facts = object["facts"] as? [String: Any] ?? [:]
        line = object["line"] as? String ?? ""
        detail = object["detail"] as? String ?? ""
        var actions: [Action] = []
        for raw in object["actions"] as? [Any] ?? [] where actions.count < 2 {
            if let action = Action(json: raw), !actions.contains(where: { $0.does == action.does }) {
                actions.append(action)
            }
        }
        self.actions = actions
        body = Self.body(shape, facts, calendar: calendar) ?? .plain
    }

    private static func body(_ shape: String, _ facts: [String: Any], calendar: Calendar) -> Body? {
        let text = { (key: String) in (facts[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch shape {
        case "date":
            guard let found = Self.day(text("day"), calendar: calendar) else { return nil }
            return .date(day: found.date, what: text("what"), whose: text("whose"))
        case "due":
            guard let found = Self.day(text("due"), calendar: calendar) else { return nil }
            return .due(due: found.date, hasTime: found.hasTime,
                        noticed: Self.day(text("noticed"), calendar: calendar)?.date)
        case "runs":
            let rawResults = facts["results"] as? [Any] ?? []
            let results = rawResults.compactMap { $0 as? String }
            guard !results.isEmpty, results.count == rawResults.count, results.allSatisfy({ $0 == "ok" || $0 == "fail" }) else { return nil }
            return .runs(job: text("job"), results: results.suffix(10).map { $0 == "ok" })
        case "promise":
            guard !text("said").isEmpty else { return nil }
            return .promise(said: text("said"), person: text("person"), place: text("where"), when: text("when"))
        case "status":
            guard !text("label").isEmpty, let state = State(rawValue: text("state")) else { return nil }
            return .status(label: text("label"), state: state)
        case "steps":
            // Every name kept in place: "at" counts the plugin's list as sent.
            let raw = facts["names"] as? [Any] ?? []
            let names = raw.compactMap { $0 as? String }
            guard names.count == raw.count, !names.contains(where: \.isEmpty), names.count >= 2, let at = PulseJSON.int(facts["at"]), names.indices.contains(at) else { return nil }
            return .steps(names: names, at: at)
        case "drawn":
            guard let body = facts["body"], let card = RichCard.cards(raw: [body]).first else { return nil }
            return .drawn(card)
        case "brief":
            let counts = facts["counts"] as? [String: Any] ?? [:]
            return .brief(summary: text("summary"), today: PulseJSON.strings(facts["today"]),
                          open: PulseJSON.strings(facts["open"]), held: max(0, PulseJSON.int(counts["held"]) ?? 0))
        default:
            return nil
        }
    }

    /// "2026-11-20" (the start of that day) or "2026-11-20T15:00", in the
    /// phone's time zone, which is the user's.
    /// The last moment of `date`'s day, by which a due with no time is due.
    /// A day with no time said in whole days ("today", "tomorrow", "in 3
    /// days"), so a date due today never reads "8 hours ago".
    static func relativeDay(_ day: Date, now: Date = Date(), calendar: Calendar = PulseLook.wireCalendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: day)).day ?? 0
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.locale = AppLocalization.formattingLocale
        return formatter.localizedString(from: DateComponents(day: days))
    }

    static func endOfDay(_ date: Date, calendar: Calendar = PulseLook.wireCalendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? date
    }

    static func day(_ value: String, calendar: Calendar = PulseLook.wireCalendar) -> (date: Date, hasTime: Bool)? {
        let parts = value.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        // Every part a number: a junk part reads as no date, never a shifted one.
        let dayParts = parts.first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
        let day = dayParts.compactMap { Int($0) }
        guard dayParts.count == 3, day.count == 3 else { return nil }
        var components = DateComponents(year: day[0], month: day[1], day: day[2])
        var hasTime = false
        if parts.count == 2 {
            let clockParts = parts[1].split(separator: ":", omittingEmptySubsequences: false)
            let clock = clockParts.compactMap { Int($0) }
            guard clockParts.count == 2, clock.count == 2, (0..<24).contains(clock[0]), (0..<60).contains(clock[1]) else { return nil }
            components.hour = clock[0]
            components.minute = clock[1]
            hasTime = true
        }
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return (date, hasTime)
    }

    /// Something to draw beyond the words.
    var drawsBody: Bool {
        if case .plain = body { return false }
        return true
    }

    /// The ask action, which takes the place of Do it.
    var ask: Action? { actions.first { $0.does == .ask } }

    /// The actions drawn as their own buttons: done and later are the
    /// card's own Done and Not now, and ask is Do it.
    var extraActions: [Action] { actions.filter { $0.does == .open || $0.does == .draft } }

    var offersLater: Bool { actions.contains { $0.does == .later } }

    /// Brief: the summary as the brief's first line.
    var briefParts: (summary: String, today: [String], open: [String], held: Int)? {
        if case let .brief(summary, today, open, held) = body { return (summary, today, open, held) }
        return nil
    }
}

extension PulseCard {
    /// Its look quotes what was promised, so the card's own quote would
    /// say it twice.
    var drawsPromise: Bool {
        if case .promise = look?.body { return true }
        return false
    }
}
