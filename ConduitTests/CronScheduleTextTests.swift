//
//  CronScheduleTextTests.swift
//  Conduit
//
//  The Scheduled list's wording: common cron patterns in plain words, the
//  profile's zone named when it isn't this iPhone's, and a next run that
//  says "Monday 8:00 AM" rather than "in 1 day" for one 47 hours away.
//

import XCTest
@testable import Conduit

final class CronScheduleTextTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let toronto = TimeZone(identifier: "America/Toronto")!

    /// iOS puts a narrow no-break space before AM/PM.
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func describe(_ expression: String, locale: Locale? = nil) -> String? {
        plain(CronScheduleText.describe(expression: expression, locale: locale ?? english))
    }

    // MARK: Cron expressions

    func testATimeOfDayOnCommonDays() {
        XCTAssertEqual(describe("0 8 * * 1-5"), "Weekdays at 8:00 AM")
        XCTAssertEqual(describe("30 7 * * *"), "Daily at 7:30 AM")
        XCTAssertEqual(describe("0 9 * * 0,6"), "Weekends at 9:00 AM")
        XCTAssertEqual(describe("0 9 * * 6,7"), "Weekends at 9:00 AM")
        XCTAssertEqual(describe("0 9 * * 0-6"), "Daily at 9:00 AM")
        XCTAssertEqual(describe("45 17 * * 1"), "Every Monday at 5:45 PM")
        XCTAssertEqual(describe("0 9 * * 4,1"), "Every Monday and Thursday at 9:00 AM")
        XCTAssertEqual(describe("0 9 * * 1,3,5"), "Every Monday, Wednesday, and Friday at 9:00 AM")
        XCTAssertEqual(describe("0 8 1 * *"), "Monthly on day 1 at 8:00 AM")
    }

    func testRepeatingSchedules() {
        XCTAssertEqual(describe("* * * * *"), "Every minute")
        XCTAssertEqual(describe("*/1 * * * *"), "Every minute")
        XCTAssertEqual(describe("*/15 * * * *"), "Every 15 minutes")
        XCTAssertEqual(describe("0 * * * *"), "Every hour")
        XCTAssertEqual(describe("15 * * * *"), "Every hour at :15")
        XCTAssertEqual(describe("0 */2 * * *"), "Every 2 hours")
        XCTAssertEqual(describe("0 */1 * * *"), "Every hour")
    }

    func testPatternsItDoesNotCoverStayUndescribed() {
        for expression in ["0 8,20 * * *", "0 8 * 1 *", "*/7 * * * *", "0 8 1-7 * 1", "0 8 * * MON", "0 8 * *", "0 8 * * * 2027", "15 */2 * * *", "61 8 * * *"] {
            XCTAssertNil(describe(expression), expression)
        }
    }

    func testTimesFollowTheLocale() {
        XCTAssertEqual(describe("0 8 * * 1-5", locale: Locale(identifier: "fr_FR")), "Weekdays at 08:00")
    }

    // MARK: Jobs

    private func job(_ schedule: CronSchedule?, display: String? = nil) -> CronJob {
        CronJob(enabled: true, id: "job", schedule: schedule, scheduleDisplay: display)
    }

    func testAJobsCronScheduleNamesTheProfileZoneWhenGiven() {
        let job = job(CronSchedule(display: "0 8 * * 1-5", expr: "0 8 * * 1-5", kind: "cron"), display: "0 8 * * 1-5")
        XCTAssertEqual(plain(CronScheduleText.describe(job, zoneLabel: "America/Toronto", locale: english)), "Weekdays at 8:00 AM (America/Toronto)")
        XCTAssertEqual(plain(CronScheduleText.describe(job, zoneLabel: nil, locale: english)), "Weekdays at 8:00 AM")
    }

    func testIntervalSchedulesNeedNoZone() {
        let every = { (minutes: Int) in
            CronScheduleText.describe(self.job(CronSchedule(display: "every \(minutes)m", kind: "interval", minutes: minutes)), zoneLabel: "America/Toronto", locale: self.english)
        }
        XCTAssertEqual(every(30), "Every 30 minutes")
        XCTAssertEqual(every(60), "Every hour")
        XCTAssertEqual(every(120), "Every 2 hours")
        XCTAssertEqual(every(1_440), "Every day")
        XCTAssertEqual(every(2_880), "Every 2 days")
        XCTAssertEqual(every(90), "Every 90 minutes")
    }

    func testAOneShotJobShowsItsTimeOnThisIPhonesClock() {
        let job = job(CronSchedule(display: "once at 2026-10-20 08:00", kind: "once", runAt: "2026-10-20T08:00:00-04:00"))
        let text = plain(CronScheduleText.describe(job, zoneLabel: "America/Toronto", locale: english))
        XCTAssertEqual(text?.hasPrefix("Once, "), true, text ?? "nil")
        XCTAssertEqual(text?.contains("America/Toronto"), false)
    }

    func testAnOlderHermesThatSendsOnlyTheDisplayIsStillDescribed() {
        XCTAssertEqual(plain(CronScheduleText.describe(job(nil, display: "0 8 * * *"), zoneLabel: nil, locale: english)), "Daily at 8:00 AM")
    }

    func testAnythingElseKeepsHermesWording() {
        XCTAssertEqual(CronScheduleText.describe(job(CronSchedule(display: "0 8,20 * * *", expr: "0 8,20 * * *", kind: "cron")), zoneLabel: nil, locale: english), "0 8,20 * * *")
        XCTAssertEqual(CronScheduleText.describe(job(nil, display: "when the moon is full"), zoneLabel: nil, locale: english), "when the moon is full")
        XCTAssertNil(CronScheduleText.describe(job(nil), zoneLabel: nil, locale: english))
    }

    func testScheduleDecodesEveryKindAndToleratesOddFields() throws {
        let interval = try JSONDecoder().decode(CronSchedule.self, from: Data(#"{"kind":"interval","minutes":30,"display":"every 30m"}"#.utf8))
        XCTAssertEqual(interval.minutes, 30)
        let once = try JSONDecoder().decode(CronSchedule.self, from: Data(#"{"kind":"once","run_at":"2026-10-20T08:00:00-04:00"}"#.utf8))
        XCTAssertEqual(once.runAt, "2026-10-20T08:00:00-04:00")
        let odd = try JSONDecoder().decode(CronSchedule.self, from: Data(#"{"kind":"cron","expr":"0 8 * * *","minutes":"soon"}"#.utf8))
        XCTAssertEqual(odd.expr, "0 8 * * *")
        XCTAssertNil(odd.minutes)
    }

    // MARK: Next run

    private func date(_ iso: String) -> Date {
        CronScheduleText.parseDate(iso)!
    }

    private func runText(_ run: String, now: String) -> String? {
        plain(CronScheduleText.runTimeText(date(run), now: date(now), locale: english, timeZone: toronto))
    }

    /// The reported bug: Saturday 08:52 to Monday 08:00 is 47 hours, which
    /// RelativeDateTimeFormatter called "in 1 day".
    func testARunTwoDaysAwayNamesItsDay() {
        XCTAssertEqual(runText("2026-10-19T08:00:00-04:00", now: "2026-10-17T08:52:00-04:00"), "Monday 8:00 AM")
    }

    func testNearRunsReadAsRoundedRelativeTimes() {
        XCTAssertEqual(runText("2026-10-17T09:17:00-04:00", now: "2026-10-17T08:52:00-04:00"), "in 25 minutes")
        XCTAssertEqual(runText("2026-10-17T12:42:00-04:00", now: "2026-10-17T08:52:00-04:00"), "in 4 hours")
        XCTAssertEqual(runText("2026-10-18T03:52:00-04:00", now: "2026-10-17T08:52:00-04:00"), "in 19 hours")
        XCTAssertEqual(runText("2026-10-17T08:52:20-04:00", now: "2026-10-17T08:52:00-04:00"), "in 1 minute")
    }

    /// Pinned `now`, locale and zone: passes at any real hour (the day
    /// words are relative to `now`, never to the real clock).
    func testTomorrowAndLaterRunsReadAsADayAndTime() {
        XCTAssertEqual(runText("2026-10-18T07:00:00-04:00", now: "2026-10-17T08:00:00-04:00"), "tomorrow at 7:00 AM")
        XCTAssertEqual(runText("2026-10-23T08:00:00-04:00", now: "2026-10-17T08:00:00-04:00"), "Friday 8:00 AM")
        // A week or more away: the date and time, the year only when it
        // isn't this one. (The joining words vary between iOS versions.)
        let later = runText("2026-10-26T08:00:00-04:00", now: "2026-10-17T08:00:00-04:00") ?? ""
        XCTAssertTrue(later.hasPrefix("Oct 26") && later.hasSuffix("8:00 AM") && !later.contains("2026"), later)
        let nextYear = runText("2027-01-04T08:00:00-05:00", now: "2026-10-17T08:00:00-04:00") ?? ""
        XCTAssertTrue(nextYear.hasPrefix("Jan 4, 2027") && nextYear.hasSuffix("8:00 AM"), nextYear)
    }

    /// A run later today but 20 hours or more away says "today", never a
    /// bare weekday that reads like next week's.
    func testALateRunTodayReadsAsToday() {
        XCTAssertEqual(runText("2026-10-17T23:00:00-04:00", now: "2026-10-17T00:30:00-04:00"), "today at 11:00 PM")
    }

    func testAnOverdueRunSaysHowLongAgo() {
        XCTAssertEqual(runText("2026-10-17T08:40:00-04:00", now: "2026-10-17T08:52:00-04:00"), "12 minutes ago")
        // Days overdue read in days, not hours.
        XCTAssertEqual(runText("2026-10-14T08:52:00-04:00", now: "2026-10-17T08:52:00-04:00"), "3 days ago")
    }

    func testRunTimesParseHermesFormats() {
        let expected = date("2026-10-19T12:00:00Z")
        XCTAssertEqual(CronScheduleText.parseDate("2026-10-19T08:00:00-04:00"), expected)
        XCTAssertEqual(CronScheduleText.parseDate("2026-10-19T08:00:00.123456-04:00")?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(CronScheduleText.parseDate(String(expected.timeIntervalSince1970)), expected)
        XCTAssertEqual(CronScheduleText.parseDate(String(expected.timeIntervalSince1970 * 1000)), expected)
        XCTAssertNil(CronScheduleText.parseDate("next tuesday"))
    }

    /// #997: Python's naive isoformat reads in the given zone, and an epoch
    /// that isn't a real run time is no date rather than a crash later.
    func testRunTimesWithoutAnOffsetOrOutOfRange() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let expected = date("2026-10-19T12:00:00Z")
        XCTAssertEqual(CronScheduleText.parseDate("2026-10-19T08:00:00", timeZone: newYork), expected)
        XCTAssertEqual(CronScheduleText.parseDate("2026-10-19T08:00:00.123456", timeZone: newYork)?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 1)
        for bad in ["-1e30", "1e30", "-5", "nan", "inf", "-inf"] {
            XCTAssertNil(CronScheduleText.parseDate(bad), bad)
        }
    }

    func testARunTooFarOffForADayCountReadsAsADate() {
        // Days past Int's range: the day count used to trap.
        let ancient = Date(timeIntervalSince1970: -1e30)
        XCTAssertEqual(
            CronScheduleText.runTimeText(ancient, now: date("2026-10-17T08:52:00-04:00"), locale: english, timeZone: toronto),
            CronScheduleText.absoluteDateText(ancient, locale: english, timeZone: toronto)
        )
    }
}
