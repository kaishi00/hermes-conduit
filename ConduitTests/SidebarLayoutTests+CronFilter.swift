//
//  SidebarLayoutTests+CronFilter.swift
//  Conduit
//
//  Coverage for the Cron tab's Active / Inactive / All filter (#392): what
//  each filter keeps, the active-first order, search within a filter, and
//  the empty-state wording.
//

import XCTest
@testable import Conduit

extension SidebarLayoutTests {
    private func cronJob(
        _ id: String,
        name: String? = nil,
        enabled: Bool,
        prompt: String? = nil,
        schedule: String? = nil,
        deliver: String? = nil,
        state: String? = nil
    ) -> CronJob {
        CronJob(deliver: deliver, enabled: enabled, id: id, name: name ?? id, prompt: prompt, scheduleDisplay: schedule, state: state)
    }

    private var mixedCronJobs: [CronJob] {
        [
            cronJob("1", name: "weekly report", enabled: false),
            cronJob("2", name: "Backup", enabled: true),
            cronJob("3", name: "archive", enabled: false),
            cronJob("4", name: "Digest", enabled: true),
            cronJob("5", name: "cleanup", enabled: true)
        ]
    }

    func testCronAllListsActiveJobsFirstThenByName() {
        let result = CronJobFilter.visibleJobs(mixedCronJobs, filter: .all, query: "")

        XCTAssertEqual(result.map(\.id), ["2", "5", "4", "3", "1"])
    }

    func testCronActiveAndInactiveKeepOnlyTheirJobs() {
        let active = CronJobFilter.visibleJobs(mixedCronJobs, filter: .active, query: "")
        XCTAssertEqual(active.map(\.id), ["2", "5", "4"])

        let inactive = CronJobFilter.visibleJobs(mixedCronJobs, filter: .inactive, query: "")
        XCTAssertEqual(inactive.map(\.id), ["3", "1"])
    }

    func testCronFinishedOneShotJobsCountAsInactive() {
        let jobs = [
            cronJob("once", name: "Reminder", enabled: true, state: "completed"),
            cronJob("daily", name: "Digest", enabled: true, state: "scheduled"),
            cronJob("off", name: "Archive", enabled: false, state: "completed")
        ]

        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .active, query: "").map(\.id), ["daily"])
        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .inactive, query: "").map(\.id), ["off", "once"])
        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .all, query: "").map(\.id), ["daily", "off", "once"])
    }

    func testCronRowBadgeSaysFinishedActiveOrPaused() {
        // "completed" is the Hermes wire value for a one-shot job that ran.
        XCTAssertEqual(cronJob("a", enabled: true, state: "completed").statusLabel, AppLocalization.string("Finished"))
        XCTAssertEqual(cronJob("b", enabled: false, state: "completed").statusLabel, AppLocalization.string("Finished"))
        XCTAssertEqual(cronJob("c", enabled: true, state: "scheduled").statusLabel, AppLocalization.string("Active"))
        XCTAssertEqual(cronJob("d", enabled: true).statusLabel, AppLocalization.string("Active"))
        XCTAssertEqual(cronJob("e", enabled: false, state: "paused").statusLabel, AppLocalization.string("Paused"))
    }

    func testCronJobsWithTheSameNameKeepAStableOrder() {
        let jobs = [
            cronJob("b", name: "Sync", enabled: true),
            cronJob("a", name: "sync", enabled: true)
        ]

        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .all, query: "").map(\.id), ["a", "b"])
    }

    func testCronSearchNarrowsWithinTheChosenFilter() {
        let jobs = [
            cronJob("1", name: "Morning brief", enabled: true, prompt: "Summarize the news"),
            cronJob("2", name: "Evening brief", enabled: false),
            cronJob("3", name: "Backup", enabled: true, schedule: "Every day at 03:00"),
            cronJob("4", name: "Ping", enabled: true, deliver: "telegram")
        ]

        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .all, query: "  brief ").map(\.id), ["1", "2"])
        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .active, query: "brief").map(\.id), ["1"])
        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .inactive, query: "brief").map(\.id), ["2"])
        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .all, query: "news").map(\.id), ["1"])
        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .all, query: "03:00").map(\.id), ["3"])
        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .all, query: "TELEGRAM").map(\.id), ["4"])
        XCTAssertEqual(CronJobFilter.visibleJobs(jobs, filter: .all, query: "   ").count, 4)
    }

    func testCronEmptyStateNamesWhatIsMissing() {
        XCTAssertEqual(
            CronJobFilter.emptyState(filter: .active, hasJobs: false, isSearching: false).title,
            AppLocalization.string("No Scheduled Jobs")
        )
        XCTAssertEqual(
            CronJobFilter.emptyState(filter: .active, hasJobs: true, isSearching: true).title,
            AppLocalization.string("No Matching Jobs")
        )
        XCTAssertEqual(
            CronJobFilter.emptyState(filter: .active, hasJobs: true, isSearching: true).description,
            AppLocalization.string("Try a different search or filter.")
        )
        XCTAssertEqual(
            CronJobFilter.emptyState(filter: .all, hasJobs: true, isSearching: true).description,
            AppLocalization.string("Try a different search.")
        )
        XCTAssertEqual(
            CronJobFilter.emptyState(filter: .active, hasJobs: true, isSearching: false).title,
            AppLocalization.string("No Active Jobs")
        )
        XCTAssertEqual(
            CronJobFilter.emptyState(filter: .inactive, hasJobs: true, isSearching: false).title,
            AppLocalization.string("No Inactive Jobs")
        )
    }

    func testCronFilterStoredValuesStayStable() {
        // The choice is remembered in AppStorage by raw value.
        XCTAssertEqual(CronJobFilter.allCases.map(\.rawValue), ["active", "inactive", "all"])
    }
}
