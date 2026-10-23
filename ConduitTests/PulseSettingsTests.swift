//
//  PulseSettingsTests.swift
//  Conduit
//
//  Settings > Pulse (beta) reads the notifier plugin's Pulse routes:
//  the state payload as the plugin's pulse_control.state() writes it, a
//  backfill estimate, memory items, the refusal codes its 409s carry and
//  the report times the page edits.
//

import XCTest
@testable import Conduit

@MainActor
final class PulseSettingsTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
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
         "backfill_days": 30, "ratings": {"commitment": {"yes": 3, "no": 1}}}
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
          {"id": "bad"}]}
        """)
        let items = (response["items"] as? [Any] ?? []).compactMap(PulseMemoryItem.init(json:))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, 7)
        XCTAssertEqual(items.first?.due, "Friday")
        XCTAssertEqual(items.first?.explicit, true)
        XCTAssertEqual(PulseMemoryKind.sorted(["fact", "zzz", "commitment"]), ["commitment", "fact", "zzz"])
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

        // Every code the plugin sends has its own sentence.
        let codes = ["reading", "paused", "already_read", "memory_off", "pulse_off", "no_home_chat",
                     "unreadable", "not_running", "nothing_to_cancel", "changed", "invalid"]
        let fallback = PulseRefusal(code: "something_new").message
        for code in codes {
            XCTAssertNotEqual(PulseRefusal(code: code).message, fallback, code)
        }
        XCTAssertEqual(Set(codes.map { PulseRefusal(code: $0).message }).count, codes.count)
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
