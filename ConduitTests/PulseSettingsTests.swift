//
//  PulseSettingsTests.swift
//  Conduit
//
//  Settings > Pulse (beta) reads the notifier plugin's Pulse routes:
//  the state payload as the plugin's pulse_control.state() writes it, a
//  backfill estimate, memory items, the refusal codes its 409s carry, the
//  report times the page edits and the note to Pulse.
//

import XCTest
@testable import Conduit

@MainActor
final class PulseSettingsTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testStateReadsTheNoteToPulse() throws {
        let state = try XCTUnwrap(PulseState(json: json("""
        {"enabled": true, "note": "Never bring up the gym.\\nAlways tell me when a build finishes."}
        """)))
        XCTAssertEqual(state.note, "Never bring up the gym.\nAlways tell me when a build finishes.")
        XCTAssertEqual(PulseNote.limit, 1_500)
        // An older plugin's state has no note.
        XCTAssertEqual(try XCTUnwrap(PulseState(json: json(#"{"enabled": true}"#))).note, "")
    }

    func testStateReadsQuietTimes() throws {
        let state = try XCTUnwrap(PulseState(json: json("""
        {"enabled": true, "quiet_days": [6, 5, 5, 9, "sat", true], "quiet_until": 1800000000,
         "quiet_now": "until", "quiet_ends_at": 1800172800}
        """)))
        // Only the plugin's weekdays (Monday 0 to Sunday 6), once each, in order.
        XCTAssertEqual(state.quietDays, [5, 6])
        XCTAssertEqual(state.quietUntil, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(state.quietNow, .until)
        XCTAssertEqual(state.quietEndsAt, Date(timeIntervalSince1970: 1_800_172_800))
        // A plugin from before quiet times, or a reason this build doesn't know.
        let older = try XCTUnwrap(PulseState(json: json(#"{"enabled": true, "quiet_now": "later"}"#)))
        XCTAssertEqual(older.quietDays, [])
        XCTAssertNil(older.quietUntil)
        XCTAssertNil(older.quietNow)
        XCTAssertNil(older.quietEndsAt)
    }

    func testStateReadsTheNight() throws {
        let state = try XCTUnwrap(PulseState(json: json(#"{"enabled": true, "night": ["23:30", "06:15"]}"#)))
        let night = try XCTUnwrap(state.night)
        XCTAssertEqual(night, PulseNight(start: 23 * 60 + 30, end: 6 * 60 + 15))
        XCTAssertEqual(night.setting, ["23:30", "06:15"])
        XCTAssertTrue(night.contains(23 * 60 + 30) && night.contains(0) && night.contains(6 * 60 + 14))
        XCTAssertFalse(night.contains(6 * 60 + 15) || night.contains(12 * 60) || night.contains(23 * 60 + 29))
        let evening = PulseNight(start: 18 * 60, end: 22 * 60)  // one that doesn't cross midnight
        XCTAssertTrue(evening.contains(18 * 60) && evening.contains(21 * 60 + 59))
        XCTAssertFalse(evening.contains(22 * 60) || evening.contains(60))
        // Night turns on at the plugin's default.
        XCTAssertEqual(PulseNight.default.setting, ["22:00", "07:00"])
        // No night, the same time twice, anything but two times, or a plugin from before.
        for body in [#"{"enabled": true, "night": []}"#, #"{"enabled": true, "night": ["22:00", "22:00"]}"#,
                     #"{"enabled": true, "night": ["22:00"]}"#, #"{"enabled": true, "night": [22, 7]}"#,
                     #"{"enabled": true, "night": ["22:00", "7:00"]}"#, #"{"enabled": true}"#] {
            XCTAssertNil(try XCTUnwrap(PulseState(json: json(body))).night, body)
        }
    }

    func testQuietDaysRunInTheUsersWeekAndAVacationEndsOnADay() {
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.firstWeekday = 1
        XCTAssertEqual(PulseQuiet.weekOrder(calendar: sundayFirst), [6, 0, 1, 2, 3, 4, 5])
        var mondayFirst = Calendar(identifier: .gregorian)
        mondayFirst.firstWeekday = 2
        XCTAssertEqual(PulseQuiet.weekOrder(calendar: mondayFirst), [0, 1, 2, 3, 4, 5, 6])
        // The plugin's Monday 0 is Calendar's weekday symbol 1 (Sunday is 0), and back.
        XCTAssertEqual((0..<7).map(PulseQuiet.calendarIndex(pluginDay:)), [1, 2, 3, 4, 5, 6, 0])
        XCTAssertEqual((0..<7).map { PulseQuiet.pluginDay(calendarIndex: PulseQuiet.calendarIndex(pluginDay: $0)) },
                       Array(0..<7))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let tuesday = Date(timeIntervalSince1970: 1_793_095_200)  // 2026-10-27 10:00 UTC
        XCTAssertEqual(PulseQuiet.dayText(tuesday, calendar: utc), "2026-10-27")
        // A vacation ends from tomorrow to a year ahead, a week away when switched on.
        let days = PulseQuiet.returnDays(now: tuesday, calendar: utc)
        XCTAssertEqual(PulseQuiet.dayText(days.lowerBound, calendar: utc), "2026-10-28")
        XCTAssertEqual(PulseQuiet.dayText(days.upperBound, calendar: utc), "2027-10-27")
        XCTAssertEqual(PulseQuiet.dayText(PulseQuiet.defaultReturn(now: tuesday, calendar: utc), calendar: utc), "2026-11-03")
        // The wire day is Gregorian whatever the phone's calendar, or a Japanese-calendar phone would send its era year.
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = utc.timeZone
        XCTAssertEqual(PulseQuiet.dayText(tuesday, calendar: japanese), "2026-10-27")
        XCTAssertEqual(PulseQuiet.dayText(PulseQuiet.defaultReturn(now: tuesday, calendar: japanese), calendar: japanese),
                       "2026-11-03")
        // Days in the plugin's time zone: 11:00 UTC on Tuesday is already Wednesday at UTC+14.
        let kiritimati = PulseQuiet.calendar(zone: "Pacific/Kiritimati", utc)
        XCTAssertEqual(PulseQuiet.dayText(tuesday.addingTimeInterval(3_600), calendar: kiritimati), "2026-10-28")
        XCTAssertEqual(PulseQuiet.dayText(PulseQuiet.returnDays(now: tuesday.addingTimeInterval(3_600),
                                                                calendar: kiritimati).lowerBound, calendar: kiritimati),
                       "2026-10-29")
        // The phone's calendar, in the phone's zone while the plugin hasn't said one it knows.
        XCTAssertEqual(PulseQuiet.calendar(zone: "Asia/Tokyo", japanese).identifier, .japanese)
        XCTAssertEqual(PulseQuiet.calendar(zone: "").timeZone, TimeZone.current)
        XCTAssertEqual(PulseQuiet.calendar(zone: "Nowhere/Atall").timeZone, TimeZone.current)
    }

    func testThePulseScreenSaysWhenPulseIsBack() {
        // The copy is English here, whatever the test host's language.
        UserDefaults.standard.set("en", forKey: AppLanguageStore.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AppLanguageStore.defaultsKey) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let tuesday = Date(timeIntervalSince1970: 1_793_095_200)  // 2026-10-27 10:00 UTC
        let midnight = utc.startOfDay(for: tuesday)
        let day = { (count: Double) in midnight.addingTimeInterval(count * 86_400) }
        XCTAssertEqual(PulseQuiet.backText(day(1), now: tuesday, calendar: utc), "Back tomorrow")
        XCTAssertEqual(PulseQuiet.backText(tuesday.addingTimeInterval(3_600), now: tuesday, calendar: utc), "Back later today")
        let weekday = PulseQuiet.backText(day(6), now: tuesday, calendar: utc)
        XCTAssertTrue(weekday.hasPrefix("Back on "))
        XCTAssertFalse(weekday.contains("%@"))
        let date = PulseQuiet.backText(day(12), now: tuesday, calendar: utc)
        XCTAssertEqual(date, "Back on Sunday, November 8")
        // A vacation can end next year: the date says which.
        let last = PulseQuiet.returnDays(now: tuesday, calendar: utc).upperBound
        XCTAssertEqual(PulseQuiet.backText(last, now: tuesday, calendar: utc), "Back on Wednesday, October 27, 2027")
    }

    func testQuietForTodayIsOfferedForAHostOnceItsPluginTakesIt() {
        let gateways: Set<String> = ["gw-default", "gw-work"]
        let known: Set<String> = ["gw-default", "gw-work", "gw-other"]
        var plugin = NotifierPluginStatus()
        // Not answered yet: nothing changes.
        XCTAssertEqual(PulseQuiet.sharedGateways(["gw-other"], gateways: gateways, plugin: plugin, known: known), ["gw-other"])
        plugin.state = .reported(version: "0.80.2", capabilities: [PulseClient.capability, PulseClient.quietCapability])
        XCTAssertEqual(PulseQuiet.sharedGateways(["gw-other"], gateways: gateways, plugin: plugin, known: known),
                       ["gw-other", "gw-default", "gw-work"])
        // Before the host said which gateways are its own: nothing changes.
        XCTAssertEqual(PulseQuiet.sharedGateways(["gw-other"], gateways: [], plugin: plugin, known: known), ["gw-other"])
        // A plugin from before quiet times takes its host's gateways out, and only those.
        plugin.state = .reported(version: "0.78.3", capabilities: [PulseClient.capability])
        XCTAssertEqual(PulseQuiet.sharedGateways(["gw-other", "gw-default", "gw-work"], gateways: gateways, plugin: plugin,
                                                 known: known),
                       ["gw-other"])
        // A pairing no saved dashboard has any more (forgotten, or paired again) loses the button, answered or not.
        XCTAssertEqual(PulseQuiet.sharedGateways(["gw-other", "gw-gone"], gateways: [], plugin: NotifierPluginStatus(),
                                                 known: known),
                       ["gw-other"])
    }

    func testStateDecodesTheNudgeLevelAndBudgets() throws {
        let state = try XCTUnwrap(PulseState(json: json("""
        {"enabled": true, "followups": true, "nudge": "eager", "followup_daily_tokens": 300000,
         "followup_tokens_today": 4200, "followup_daily_tokens_set": false, "daily_tokens": 500000}
        """)))
        XCTAssertEqual(state.nudge, "eager")
        XCTAssertTrue(state.followups)
        XCTAssertEqual(state.followupDailyTokens, 300_000)
        XCTAssertEqual(state.followupTokensToday, 4_200)
        XCTAssertFalse(state.followupDailyTokensSet)
        // An older plugin, or a level this build doesn't know, reads as the default.
        XCTAssertEqual(try XCTUnwrap(PulseState(json: json(#"{"enabled": true}"#))).nudge, PulseNudge.defaultLevel)
        XCTAssertEqual(try XCTUnwrap(PulseState(json: json(#"{"enabled": true, "nudge": "loud"}"#))).nudge, "balanced")
        // A budget set off the presets is offered too, in order.
        XCTAssertEqual(PulseNudge.budgets([100, 300], current: 200), [100, 200, 300])
        XCTAssertEqual(PulseNudge.budgets([100, 300], current: 0), [100, 300])
    }

    func testStateDecodesThePluginsPayload() throws {
        let state = try XCTUnwrap(PulseState(json: json("""
        {"ok": true, "enabled": true, "running": false, "stale_build": true,
         "home_chat": {"id": "20261021_080000_abc", "title": "Pulse", "pinned": false},
         "home_problem": "pin the \\"Pulse\\" chat so pruning never removes it", "home_title": "Pulse",
         "checks": {"sent": 4, "failed": 1},
         "recent": [{"at": 1761033600.25, "kind": "report", "state": "sent", "detail": "3 items"},
                    {"at": 1761030000, "kind": "probe", "state": "quiet", "detail": ""}],
         "daily_report": true, "report_times": ["08:00", "18:30", "bad"], "time_zone": "Europe/Paris",
         "time_zone_set": "", "next_report_at": 1761066000, "report_profiles": "all",
         "other_profiles": ["work"], "memory": true, "memory_counts": {"commitment": 2, "fact": 5},
         "memory_chunks": 12, "memory_tokens": 34000, "daily_tokens": 200000, "tokens_today": 1500,
         "backfill": {"state": "reading", "from": 1758441600, "to": 1761033600, "days": 30,
                      "narrow": false, "unreadable": ["work"]},
         "backfill_days": 30, "ratings": {"commitment": {"yes": 3, "no": 1}}, "inbox_deadlines": false,
         "look_first": false, "where": true, "where_ready": false, "private_pushes": true,
         "spots": false}
        """)))

        XCTAssertTrue(state.enabled)
        XCTAssertFalse(state.running)
        XCTAssertTrue(state.staleBuild)
        XCTAssertEqual(state.homeChat, PulseHomeChat(id: "20261021_080000_abc", title: "Pulse", pinned: false))
        XCTAssertEqual(state.homeProblem, "pin the \"Pulse\" chat so pruning never removes it")
        XCTAssertEqual(state.checks, ["sent": 4, "failed": 1])
        XCTAssertEqual(state.recent.map(\.kind), ["report", "probe"])
        XCTAssertEqual(state.recent.first?.at, Date(timeIntervalSince1970: 1_761_033_600.25))
        XCTAssertEqual(Set(state.recent.map(\.id)).count, state.recent.count)
        XCTAssertTrue(state.dailyReport)
        // A time that isn't "HH:MM" is left out.
        XCTAssertEqual(state.reportTimes, ["08:00", "18:30"])
        XCTAssertEqual(state.timeZone, "Europe/Paris")
        XCTAssertEqual(state.timeZoneSet, "")
        XCTAssertEqual(state.nextReportAt, Date(timeIntervalSince1970: 1_761_066_000))
        XCTAssertEqual(state.reportProfiles, "all")
        XCTAssertEqual(state.otherProfiles, ["work"])
        XCTAssertTrue(state.offersProfileChoice)
        XCTAssertTrue(state.memory)
        XCTAssertEqual(state.inboxDeadlines, false)
        XCTAssertEqual(state.lookFirst, false)
        XCTAssertEqual(state.whereYouAre, true)
        XCTAssertFalse(state.whereReady)
        XCTAssertEqual(state.privatePushes, true)
        XCTAssertEqual(state.walkingPast, false)
        XCTAssertEqual(state.memoryCounts, ["commitment": 2, "fact": 5])
        XCTAssertEqual(state.memoryTokens, 34_000)
        XCTAssertEqual(state.dailyTokens, 200_000)
        XCTAssertEqual(state.tokensToday, 1_500)
        XCTAssertEqual(state.backfill.phase, .reading)
        XCTAssertEqual(state.backfill.days, 30)
        XCTAssertEqual(state.backfill.unreadable, ["work"])
        XCTAssertFalse(state.backfill.canStart)
        XCTAssertEqual(state.backfillDays, 30)
        XCTAssertEqual(state.ratings["commitment"], PulseRating(yes: 3, no: 1))
    }

    func testAStateWithoutAHomeChatOrBackfill() throws {
        let state = try XCTUnwrap(PulseState(json: json("""
        {"ok": true, "enabled": false, "running": false, "stale_build": false, "home_chat": null,
         "home_problem": "no chat is titled \\"Pulse\\"; create one and pin it", "home_title": "Pulse",
         "checks": {}, "recent": [], "daily_report": false, "report_times": ["08:00"], "time_zone": "UTC",
         "time_zone_set": "", "next_report_at": null, "report_profiles": "this", "other_profiles": [],
         "memory": false, "memory_counts": {}, "memory_chunks": 0, "memory_tokens": 0,
         "daily_tokens": 200000, "tokens_today": 0, "backfill": {"state": "none"}, "backfill_days": 90,
         "ratings": {}}
        """)))
        XCTAssertFalse(state.enabled)
        XCTAssertNil(state.homeChat)
        XCTAssertNil(state.nextReportAt)
        XCTAssertEqual(state.backfill.phase, .none)
        XCTAssertTrue(state.backfill.canStart)
        XCTAssertEqual(state.backfillDays, 90)
        // Narrowed to this profile: the choice stays, so it can be widened.
        XCTAssertTrue(state.offersProfileChoice)
        // A plugin from before 0.90.0 keeps no deadlines from the Shortcuts inbox,
        // one from before 0.96.0 has Pulse look nothing up, one from before
        // 0.100.0 never reads where the user is, one from before 0.104.0
        // hides no private reminders, and one from before 0.111.0 watches no
        // shops.
        XCTAssertNil(state.inboxDeadlines)
        XCTAssertNil(state.lookFirst)
        XCTAssertNil(state.whereYouAre)
        XCTAssertFalse(state.whereReady)
        XCTAssertNil(state.privatePushes)
        XCTAssertNil(state.walkingPast)
    }

    func testStateReadsPulsesModel() throws {
        let picked = try XCTUnwrap(PulseState(json: json("""
        {"enabled": true, "model": {"provider": "openrouter", "model": "google/gemini-flash"}}
        """)))
        XCTAssertEqual(picked.model, PulseModel(provider: "openrouter", model: "google/gemini-flash"))
        XCTAssertEqual(picked.model?.setting as? [String: String],
                       ["provider": "openrouter", "model": "google/gemini-flash"])
        XCTAssertNil(try XCTUnwrap(PulseState(json: json(#"{"enabled": true, "model": null}"#))).model)
        XCTAssertNil(try XCTUnwrap(PulseState(json: json(#"{"enabled": true}"#))).model)
    }

    func testABodyThatIsntPulsesStateIsRefused() throws {
        XCTAssertNil(PulseState(json: try json(#"{"ok": true}"#)))
        // A JSON number is not a flag.
        XCTAssertNil(PulseState(json: try json(#"{"enabled": 1}"#)))
        XCTAssertThrowsError(try PulseClient.state(from: ["ok": true]))
        // A number no Int holds is no number, not a crash.
        XCTAssertNil(PulseJSON.int(NSNumber(value: Double.infinity)))
        XCTAssertNil(PulseJSON.int(NSNumber(value: 1e300)))
        XCTAssertNil(PulseJSON.date(NSNumber(value: Double.infinity)))
        XCTAssertEqual(PulseJSON.int(NSNumber(value: 42.9)), 42)
    }

    func testEstimateAndMemoryItemsDecode() throws {
        let estimate = try XCTUnwrap(PulseBackfillEstimate(json: json("""
        {"days": 30, "from": 1758441600, "to": 1761033600, "chats": 42, "chars": 900000, "chunks": 60,
         "tokens": 250000, "daily_tokens": 200000, "days_needed": 2, "unreadable": []}
        """)))
        XCTAssertEqual(estimate.days, 30)
        XCTAssertEqual(estimate.chats, 42)
        XCTAssertEqual(estimate.tokens, 250_000)
        XCTAssertEqual(estimate.daysNeeded, 2)

        let response = try json("""
        {"ok": true, "items": [
          {"id": 7, "kind": "commitment", "text": "Send Sam the deck", "evidence": "I'll send it Friday",
           "explicit": true, "due": "Friday", "due_at": 1761292800, "mentioned_at": 1761033600,
           "profile": "default", "chat_id": "abc"},
          {"id": 8, "kind": "fact", "text": "Sam's birthday is 3 March.", "evidence": "Sam's birthday is 3 March",
           "explicit": true, "due": "", "due_at": null, "every_year": "03-03", "occasion": "birthday"},
          {"id": 9, "kind": "fact", "text": "Dad was born on 29 February.", "evidence": "born on 29 February",
           "every_year": "1956-02-29", "occasion": "birthday"},
          {"id": 10, "kind": "fact", "text": "x", "evidence": "y", "every_year": "02-30"},
          {"id": 11, "kind": "deadline", "text": "Netflix free trial ends", "evidence": "Your free trial ends on 21 October",
           "explicit": true, "due": "2026-10-21", "due_at": 1761004800, "mentioned_at": 1760346000, "profile": "",
           "chat_id": "", "from_inbox": true, "sender": "Netflix", "logged_at": 1760346000},
          {"id": 12, "kind": "deadline", "text": "Electricity bill due", "evidence": "Your bill is due on 30 October",
           "due": "2026-10-30", "mentioned_at": 1760346000, "from_inbox": true, "sender": " ", "logged_at": 1760346000},
          {"id": "bad"}]}
        """)
        let items = (response["items"] as? [Any] ?? []).compactMap(PulseMemoryItem.init(json:))
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.first?.id, 7)
        XCTAssertEqual(items.first?.due, "Friday")
        XCTAssertEqual(items.first?.explicit, true)
        // A fact about a yearly date (0.88.0) says its day; the rest, and a day that isn't one, say nothing.
        let british = Locale(identifier: "en_GB")
        XCTAssertEqual(items.map { $0.everyYearText(locale: british) }, [
            nil, AppLocalization.string("Every year on \("3 March")"),
            AppLocalization.string("Every year on \("29 February")"), nil, nil, nil
        ])
        XCTAssertEqual(PulseMemoryKind.sorted(["fact", "zzz", "commitment"]), ["commitment", "fact", "zzz"])
        // A deadline from the Shortcuts inbox (0.90.0) says who it's from and when it was logged, not a chat.
        let deadline = items[4]
        XCTAssertTrue(deadline.fromInbox)
        XCTAssertEqual(deadline.sender, "Netflix")
        XCTAssertEqual(deadline.loggedAt, Date(timeIntervalSince1970: 1_760_346_000))
        let logged = Date(timeIntervalSince1970: 1_760_346_000)
            .formatted(.relative(presentation: .named).locale(AppLocalization.formattingLocale))
        XCTAssertEqual(deadline.loggedText(), AppLocalization.string("From \("Netflix"), logged \(logged)"))
        XCTAssertEqual(items[5].loggedText(), AppLocalization.string("Logged on your phone \(logged)"))
        XCTAssertFalse(items[0].fromInbox)
        XCTAssertNil(items[0].loggedText())
        XCTAssertEqual(PulseMemoryKind.title("deadline"), AppLocalization.string("Deadlines"))
        XCTAssertEqual(PulseMemoryKind.sorted(["deadline", "zzz", "watch"]), ["watch", "deadline", "zzz"])
    }

    func testAMemorySaidForAPlaceSaysWhereItComesUp() throws {
        let response = try json("""
        {"ok": true, "items": [
          {"id": 1, "kind": "commitment", "text": "Pick up batteries", "evidence": "I'll grab batteries at Costco",
           "place": {"words": "Costco", "on": "arrive", "saved": "Costco"}},
          {"id": 2, "kind": "promise", "text": "Remind the user to call Mum", "evidence": "remind me when I leave work",
           "place": {"words": "work", "on": "leave", "saved": "Office"}},
          {"id": 3, "kind": "commitment", "text": "Return the drill", "evidence": "at Dan's",
           "place": {"words": "Dan's", "on": "arrive", "saved": null}},
          {"id": 4, "kind": "commitment", "text": "Send Sam the deck", "evidence": "Friday", "place": null},
          {"id": 5, "kind": "commitment", "text": "x", "evidence": "y", "place": {"words": " ", "on": "arrive"}}]}
        """)
        let items = (response["items"] as? [Any] ?? []).compactMap(PulseMemoryItem.init(json:))
        XCTAssertEqual(items.map(\.place?.leaving), [false, true, false, nil, nil])
        XCTAssertEqual(items[0].place?.text, AppLocalization.string("When you get to \("Costco")"))
        XCTAssertEqual(items[1].place?.text, AppLocalization.string("When you leave \("work")"))
        // The saved place it matches, unless the words are its name, or that none matches yet.
        XCTAssertNil(items[0].place?.savedText)
        XCTAssertEqual(items[1].place?.savedText, AppLocalization.string("Saved place: \("Office")"))
        XCTAssertEqual(items[2].place?.savedText, AppLocalization.string("No saved place has that name yet."))
        XCTAssertNil(PulseMemoryPlace(json: ["words": "costco", "on": "arrive", "saved": "Costco"])?.savedText)
        let spaced = PulseMemoryPlace(json: ["words": " Costco ", "on": "arrive", "saved": "Costco Wholesale "])
        XCTAssertEqual(spaced?.words, "Costco")
        XCTAssertEqual(spaced?.saved, "Costco Wholesale")
    }

    func testRefusalCodesSurviveTheDashboardError() throws {
        // The plugin's 409 detail is an object; the bridge keeps it as JSON.
        let detail = try XCTUnwrap(DashboardTicketBridgeError.structuredDetail(["code": "reading", "from": 1_758_441_600] as [String: Any]))
        let refusal = try XCTUnwrap(PulseRefusal(error: DashboardTicketBridgeError.http(status: 409, detail: detail)))
        XCTAssertEqual(refusal.code, "reading")
        XCTAssertEqual(refusal.message, PulseRefusal(code: "reading").message)
        // Elsewhere a coded refusal reads as the plain failure, never as JSON.
        XCTAssertEqual(DashboardTicketBridgeError.describe(status: 409, detail: detail),
                       AppLocalization.string("Dashboard request failed (409)."))

        XCTAssertEqual(PulseRefusal(error: DashboardTicketBridgeError.http(
            status: 400, detail: #"{"code":"invalid","field":"report_times"}"#))?.code, "invalid")
        // A plain detail, or another status, is no refusal.
        XCTAssertNil(DashboardTicketBridgeError.structuredDetail("Session not found"))
        XCTAssertNil(DashboardTicketBridgeError.structuredDetail(["field": "x"]))
        XCTAssertNil(PulseRefusal(error: DashboardTicketBridgeError.http(status: 409, detail: "session_busy")))
        XCTAssertNil(PulseRefusal(error: DashboardTicketBridgeError.http(status: 500, detail: #"{"code":"pulse_off"}"#)))

        // Every code the plugin sends has its own sentence, a suggestion's too (0.98.0).
        let codes = ["reading", "paused", "already_read", "memory_off", "pulse_off", "no_home_chat",
                     "unreadable", "not_running", "nothing_to_cancel", "changed", "invalid",
                     "already_added", "dismissed", "expired", "not_found", "not_added", "already_undone",
                     "unknown_event"]
        let fallback = PulseRefusal(code: "something_new").message
        for code in codes {
            XCTAssertNotEqual(PulseRefusal(code: code).message, fallback, code)
        }
        XCTAssertEqual(Set(codes.map { PulseRefusal(code: $0).message }).count, codes.count)
        // Undo before the phone said what it added: the same for a reminder.
        XCTAssertEqual(PulseRefusal(code: "unknown_reminder").message, PulseRefusal(code: "unknown_event").message)
        // The phone's side refusing Add says why, in its own words, unless the app words the code.
        let phone = try XCTUnwrap(DashboardTicketBridgeError.structuredDetail(
            ["code": "read_only", "note": "That calendar is read-only"] as [String: Any]))
        let refused = try XCTUnwrap(PulseRefusal(error: DashboardTicketBridgeError.http(status: 409, detail: phone)))
        XCTAssertEqual(refused, PulseRefusal(code: "read_only", note: "That calendar is read-only"))
        XCTAssertEqual(refused.message, "That calendar is read-only")
        XCTAssertEqual(PulseRefusal(code: "expired", note: "ignored").message, PulseRefusal(code: "expired").message)
    }

    func testReportTimes() throws {
        XCTAssertEqual(PulseReportTime.minutes("08:30"), 510)
        XCTAssertNil(PulseReportTime.minutes("8:30"))
        XCTAssertNil(PulseReportTime.minutes("24:00"))
        XCTAssertEqual(PulseReportTime.normalized(["18:00", "08:00", "18:00"]), ["08:00", "18:00"])
        XCTAssertEqual(PulseReportTime.next(after: ["08:00"]), "09:00")
        XCTAssertEqual(PulseReportTime.next(after: []), "12:00")
        XCTAssertEqual(PulseReportTime.next(after: ["23:30"]), "00:30")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let date = PulseReportTime.date("07:45", calendar: calendar)
        XCTAssertEqual(PulseReportTime.text(from: date, calendar: calendar), "07:45")
    }
}
