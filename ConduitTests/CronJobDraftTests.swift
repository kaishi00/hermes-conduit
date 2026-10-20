//
//  CronJobDraftTests.swift
//  Conduit
//
//  The scheduled-job editor's form (#819): a job's schedule read into the
//  editor's shapes and written back as Hermes reads it, an edit sending only
//  what changed, and the blueprint catalog as the server serves it.
//

import XCTest
@testable import Conduit

extension CronScheduleTextTests {
    private func draft(_ schedule: CronSchedule) -> CronScheduleDraft {
        CronScheduleDraft(schedule: schedule, display: nil)
    }

    // MARK: Schedule shapes

    func testATimeOfDayScheduleRoundTrips() {
        let weekdays = draft(CronSchedule(expr: "0 8 * * 1-5", kind: "cron"))
        XCTAssertEqual(weekdays.mode, .time)
        XCTAssertEqual(weekdays.hour, 8)
        XCTAssertEqual(weekdays.minute, 0)
        XCTAssertEqual(weekdays.days, CronScheduleDraft.weekdays)
        XCTAssertEqual(weekdays.scheduleString, "0 8 * * 1-5")

        let daily = draft(CronSchedule(expr: "30 7 * * *", kind: "cron"))
        XCTAssertEqual(daily.days, CronScheduleDraft.everyDay)
        XCTAssertEqual(daily.scheduleString, "30 7 * * *")

        var chosen = daily
        chosen.days = [3, 1]
        XCTAssertEqual(chosen.scheduleString, "30 7 * * 1,3")
        chosen.days = []
        XCTAssertNil(chosen.scheduleString, "no day picked is not a schedule")
    }

    func testIntervalsPickTheLargestWholeUnit() {
        XCTAssertEqual(draft(CronSchedule(kind: "interval", minutes: 120)).scheduleString, "every 2h")
        XCTAssertEqual(draft(CronSchedule(kind: "interval", minutes: 90)).scheduleString, "every 90m")
        XCTAssertEqual(draft(CronSchedule(kind: "interval", minutes: 2_880)).scheduleString, "every 2d")

        var schedule = CronScheduleDraft()
        schedule.mode = .interval
        schedule.intervalValue = 2
        schedule.intervalUnit = .hours
        let preview = schedule.previewSchedule.flatMap { CronScheduleText.describe($0, zoneLabel: nil, locale: Locale(identifier: "en_US")) }
        XCTAssertEqual(preview, "Every 2 hours")
    }

    func testAOneShotKeepsItsInstant() throws {
        let once = draft(CronSchedule(kind: "once", runAt: "2026-10-21T09:00:00+00:00"))
        XCTAssertEqual(once.mode, .once)
        let sent = try XCTUnwrap(once.scheduleString)
        XCTAssertTrue(sent.contains("T"), "Hermes reads a timestamp by its T")
        XCTAssertEqual(CronScheduleText.parseDate(sent), CronScheduleText.parseDate("2026-10-21T09:00:00Z"))
    }

    func testOtherSchedulesStayAsTyped() {
        let monthly = draft(CronSchedule(expr: "0 9 1 * *", kind: "cron"))
        XCTAssertEqual(monthly.mode, .custom)
        XCTAssertEqual(monthly.scheduleString, "0 9 1 * *")

        let olderHermes = CronScheduleDraft(schedule: nil, display: "15 6 * * 0,6")
        XCTAssertEqual(olderHermes.mode, .time)
        XCTAssertEqual(olderHermes.days, CronScheduleDraft.weekends)

        var typed = CronScheduleDraft()
        typed.mode = .custom
        typed.custom = "  "
        XCTAssertNil(typed.scheduleString)
        typed.custom = " every monday 9am "
        XCTAssertEqual(typed.scheduleString, "every monday 9am")
    }

    // MARK: Create and edit

    func testANewJobNeedsAPromptAndASchedule() throws {
        var form = CronJobDraft()
        XCTAssertNil(form.createBody)
        form.prompt = "  Summarize my inbox "
        form.name = " Inbox "
        let body = try XCTUnwrap(form.createBody)
        XCTAssertEqual(body["prompt"] as? String, "Summarize my inbox")
        XCTAssertEqual(body["name"] as? String, "Inbox")
        XCTAssertEqual(body["schedule"] as? String, "0 8 * * *")
        XCTAssertEqual(body["deliver"] as? String, "local")
    }

    func testAnEditSendsOnlyWhatChanged() {
        let job = CronJob(
            deliver: "telegram",
            enabled: true,
            id: "abc",
            name: "Brief",
            prompt: "Morning brief",
            schedule: CronSchedule(expr: "0 8 * * 1-5", kind: "cron")
        )
        let original = CronJobDraft(job: job)
        var edited = original
        XCTAssertTrue(edited.updates(from: original).isEmpty)

        edited.name = "Brief "
        XCTAssertTrue(edited.updates(from: original).isEmpty, "unchanged once trimmed")

        edited.schedule.hour = 9
        edited.deliver = "local"
        let updates = edited.updates(from: original)
        XCTAssertEqual(Set(updates.keys), ["schedule", "deliver"])
        XCTAssertEqual(updates["schedule"] as? String, "0 9 * * 1-5")
    }

    func testAScriptJobCanSaveWithoutAPrompt() {
        let job = CronJob(enabled: true, id: "s", noAgent: true, schedule: CronSchedule(kind: "interval", minutes: 30))
        XCTAssertTrue(CronJobDraft(job: job).canSave)
        XCTAssertFalse(CronJobDraft(job: CronJob(enabled: true, id: "p", schedule: CronSchedule(kind: "interval", minutes: 30))).canSave)
    }

    // MARK: Server catalogs

    func testBlueprintsDecodeAsTheServerSendsThem() throws {
        let raw: [String: Any] = [
            "key": "custom-reminder",
            "title": "Custom reminder",
            "description": "A nudge at a time you pick.",
            "category": "productivity",
            "scheduleHuman": "everyday at 14:00",
            "fields": [
                ["name": "what", "type": "text", "label": "Remind me to…", "default": "stretch", "options": [], "optional": false, "help": ""],
                ["name": "time", "type": "time", "label": "What time?", "default": "14:00", "options": []],
                ["name": "recurrence", "type": "weekdays", "label": "Repeat on", "default": "everyday", "options": ["everyday", "weekdays", "weekends"]],
                ["name": "count", "type": "enum", "label": "How many?", "default": 3, "options": [1, 3, 5], "optional": true],
                ["name": "future", "type": "slider", "label": "Unknown kind"]
            ]
        ]
        let blueprint = try XCTUnwrap(CronBlueprint(raw))
        XCTAssertEqual(blueprint.fields.map(\.name), ["what", "time", "recurrence", "count"], "a field kind Conduit can't show is left out")
        XCTAssertEqual(blueprint.fields[3].options, ["1", "3", "5"])
        XCTAssertEqual(blueprint.defaultValues["count"], "3")

        var values = blueprint.defaultValues
        values["what"] = "  "
        values["count"] = ""
        let sent = CronBlueprint.instantiateValues(values, fields: blueprint.fields)
        XCTAssertEqual(sent, ["time": "14:00", "recurrence": "everyday"], "blanks stay unset so Hermes names what's missing")

        XCTAssertNil(CronBlueprint(["title": "No key"]))
        XCTAssertEqual(CronBlueprint.clock("07:05")?.hour, 7)
        XCTAssertNil(CronBlueprint.clock("25:00"))
        XCTAssertEqual(CronBlueprint.clockText(hour: 7, minute: 5), "07:05")
    }

    func testBlueprintKeepsTheFirstOfARepeatedFieldName() throws {
        let raw: [String: Any] = [
            "key": "double-time",
            "title": "Double time",
            "fields": [
                ["name": "time", "type": "time", "label": "What time?", "default": "08:00", "options": []],
                ["name": "time", "type": "time", "label": "Or this time?", "default": "09:00", "options": []]
            ]
        ]
        let blueprint = try XCTUnwrap(CronBlueprint(raw))
        XCTAssertEqual(blueprint.fields.map(\.name), ["time"])
        XCTAssertEqual(blueprint.defaultValues, ["time": "08:00"], "the first one wins, and reading defaults doesn't trap")
    }

    func testDeliveryChoicesKeepTheJobsOwnTarget() {
        let targets = [
            CronDeliveryTarget(["id": "local", "name": "Local (save only)", "home_target_set": true]),
            CronDeliveryTarget(["id": "telegram", "name": "Telegram", "home_target_set": false])
        ].compactMap { $0 }
        XCTAssertEqual(targets.map(\.homeTargetSet), [true, false])
        XCTAssertEqual(CronDeliveryTarget.choices(targets, keeping: "telegram").map(\.id), ["local", "telegram"])
        XCTAssertEqual(CronDeliveryTarget.choices(targets, keeping: "discord:123").map(\.id), ["local", "telegram", "discord:123"])
        XCTAssertEqual(CronDeliveryTarget.choices([], keeping: "local").map(\.id), ["local"])
    }
}
