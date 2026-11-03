//
//  SidebarLayoutTests+CronRunHistory.swift
//  Conduit
//
//  A scheduled job's Run history sheet (#1707): the dashboard's per-job
//  route is the answer, an empty one included, and a list of every job's
//  runs only lends a job the runs it can tell are that job's.
//

import XCTest
@testable import Conduit

@MainActor
private final class CronRunsRequester: DashboardJSONRequester {
    var responsesByPath: [String: [String: Any]] = [:]
    var failingPrefix: String?
    var cancelling = false
    private(set) var paths: [String] = []
    /// Reads whose path starts with this wait until `release()`.
    var holdPrefix: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int { held.count }

    func release() {
        holdPrefix = nil
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func requestJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        timeoutMilliseconds: Int,
        maxResponseBytes: Int
    ) async throws -> [String: Any] {
        paths.append(path)
        if let holdPrefix, path.hasPrefix(holdPrefix) {
            await withCheckedContinuation { held.append($0) }
        }
        if cancelling { throw CancellationError() }
        if let failingPrefix, path.hasPrefix(failingPrefix) {
            throw DashboardTicketBridgeError.http(status: 0, detail: "Load failed")
        }
        return responsesByPath.first { path.hasPrefix($0.key) }?.value ?? [:]
    }
}

@MainActor
extension SidebarLayoutTests {
    private func cronRunHistoryState() -> AppState {
        AppState(
            defaults: makeScratchDefaults("CronRunHistory"),
            loadSavedConnection: false,
            chatResumeLifecycleOperations: .live
        )
    }

    func testANeverRunJobsHistoryStaysEmptyWhenTheRouteAnswersNone() async {
        let state = cronRunHistoryState()
        let requester = CronRunsRequester()
        requester.responsesByPath["/api/cron/jobs/aaaaaaaaaaaa/runs"] = [
            "runs": [["id": "cron_aaaaaaaaaaaa_20261103_090000", "title": "Morning brief"]],
        ]
        requester.responsesByPath["/api/cron/jobs/bbbbbbbbbbbb/runs"] = ["runs": []]

        // The gateway's cron.runs lists every job's runs, job A's included.
        var gatewayReads = 0
        let gateway: @MainActor () async throws -> [CronRun]? = {
            gatewayReads += 1
            return [CronRun(id: "cron_aaaaaaaaaaaa_20261103_090000", lastActive: nil, model: nil, preview: nil, profile: nil, startedAt: nil, title: "Morning brief")]
        }

        // Job B never ran, and is the first sheet opened: nothing to clear.
        await state.loadCronRuns(for: CronJob(enabled: true, id: "bbbbbbbbbbbb"), dashboard: requester, gateway: gateway)
        XCTAssertTrue(state.cronRuns.isEmpty, "an empty per-job answer stands")
        XCTAssertTrue(state.cronRunsLoaded)
        XCTAssertEqual(state.cronRunsJobID, "bbbbbbbbbbbb")
        XCTAssertEqual(gatewayReads, 0, "the dashboard's answer needs no cron.runs")

        await state.loadCronRuns(for: CronJob(enabled: true, id: "aaaaaaaaaaaa"), dashboard: requester, gateway: gateway)
        XCTAssertEqual(state.cronRuns.map(\.id), ["cron_aaaaaaaaaaaa_20261103_090000"])

        await state.loadCronRuns(for: CronJob(enabled: true, id: "bbbbbbbbbbbb"), dashboard: requester, gateway: gateway)
        XCTAssertTrue(state.cronRuns.isEmpty)
        XCTAssertTrue(requester.paths.last?.hasPrefix("/api/cron/jobs/bbbbbbbbbbbb/runs") == true)
    }

    func testAnOlderReadThatLandsLastIsDropped() async {
        let state = cronRunHistoryState()
        let requester = CronRunsRequester()
        requester.responsesByPath["/api/cron/jobs/aaaaaaaaaaaa/runs"] = [
            "runs": [["id": "cron_aaaaaaaaaaaa_20261103_090000"]],
        ]
        requester.responsesByPath["/api/cron/jobs/bbbbbbbbbbbb/runs"] = ["runs": []]
        requester.holdPrefix = "/api/cron/jobs/aaaaaaaaaaaa/runs"

        let slow = Task { await state.loadCronRuns(for: CronJob(enabled: true, id: "aaaaaaaaaaaa"), dashboard: requester, gateway: nil) }
        while requester.heldCount == 0 { await Task.yield() }
        // The sheet moved on to job B before job A's read came back.
        await state.loadCronRuns(for: CronJob(enabled: true, id: "bbbbbbbbbbbb"), dashboard: requester, gateway: nil)
        requester.release()
        await slow.value

        XCTAssertEqual(state.cronRunsJobID, "bbbbbbbbbbbb")
        XCTAssertTrue(state.cronRuns.isEmpty)
    }

    func testAnOlderReadOfTheSameJobThatLandsLastIsDropped() async {
        let state = cronRunHistoryState()
        let requester = CronRunsRequester()
        let older: [String: Any] = ["runs": [["id": "cron_aaaaaaaaaaaa_20261103_090000"]]]
        let newer: [String: Any] = ["runs": [["id": "cron_aaaaaaaaaaaa_20261104_090000"]]]
        let job = CronJob(enabled: true, id: "aaaaaaaaaaaa")
        requester.responsesByPath["/api/cron/jobs/aaaaaaaaaaaa/runs"] = older
        requester.holdPrefix = "/api/cron/jobs/aaaaaaaaaaaa/runs"

        let slow = Task { await state.loadCronRuns(for: job, dashboard: requester, gateway: nil) }
        while requester.heldCount == 0 { await Task.yield() }
        // Run now reads again while the sheet's first read is out.
        requester.holdPrefix = nil
        requester.responsesByPath["/api/cron/jobs/aaaaaaaaaaaa/runs"] = newer
        await state.loadCronRuns(for: job, dashboard: requester, gateway: nil)
        requester.responsesByPath["/api/cron/jobs/aaaaaaaaaaaa/runs"] = older
        requester.release()
        await slow.value

        XCTAssertEqual(state.cronRuns.map(\.id), ["cron_aaaaaaaaaaaa_20261104_090000"])
    }

    func testAFailedReadIsNotANeverRunJob() async {
        let state = cronRunHistoryState()
        let requester = CronRunsRequester()
        requester.failingPrefix = "/api/cron/jobs/aaaaaaaaaaaa/runs"

        await state.loadCronRuns(for: CronJob(enabled: true, id: "aaaaaaaaaaaa"), dashboard: requester, gateway: nil)
        XCTAssertFalse(state.cronRunsLoaded, "no answer, so the sheet can't say the job hasn't run")
        XCTAssertNotNil(state.cronRunsFailure)

        // Offline: nothing to ask is no answer either.
        await state.loadCronRuns(for: CronJob(enabled: true, id: "bbbbbbbbbbbb"), dashboard: nil, gateway: nil)
        XCTAssertFalse(state.cronRunsLoaded)
        XCTAssertNotNil(state.cronRunsFailure)

        // A sheet closed mid-read is no failure.
        requester.cancelling = true
        await state.loadCronRuns(for: CronJob(enabled: true, id: "cccccccccccc"), dashboard: requester, gateway: nil)
        XCTAssertNil(state.cronRunsFailure)
        XCTAssertFalse(state.cronRunsLoaded)
        requester.cancelling = false

        // A later answer clears the failure.
        requester.responsesByPath["/api/cron/jobs/bbbbbbbbbbbb/runs"] = ["runs": []]
        await state.loadCronRuns(for: CronJob(enabled: true, id: "bbbbbbbbbbbb"), dashboard: requester, gateway: nil)
        XCTAssertTrue(state.cronRunsLoaded)
        XCTAssertNil(state.cronRunsFailure)
    }

    func testWithoutTheDashboardOnlyTheJobsOwnRunsAreKept() async {
        let state = cronRunHistoryState()
        func run(_ id: String, job: String? = nil) -> CronRun {
            CronRun(id: id, lastActive: nil, model: nil, preview: nil, profile: nil, startedAt: nil, title: nil, jobID: job)
        }
        let everyJobsRuns = [
            run("cron_aaaaaaaaaaaa_20261103_090000"),
            run("cron_bbbbbbbbbbbb_20261103_100000"),
            run("local-7f3a", job: "aaaaaaaaaaaa"),
            run("local-9c1d"),
        ]
        await state.loadCronRuns(for: CronJob(enabled: true, id: "aaaaaaaaaaaa"), dashboard: nil, gateway: { everyJobsRuns })
        XCTAssertEqual(state.cronRuns.map(\.id), ["cron_aaaaaaaaaaaa_20261103_090000", "local-7f3a"])

        await state.loadCronRuns(for: CronJob(enabled: true, id: "cccccccccccc"), dashboard: nil, gateway: { everyJobsRuns })
        XCTAssertTrue(state.cronRuns.isEmpty)
        XCTAssertTrue(state.cronRunsLoaded)
    }

    func testRunsOfAnotherProfileAreLeftOut() async {
        let state = cronRunHistoryState()
        let profile = state.activeProfile
        let runs = [
            CronRun(id: "cron_aaaaaaaaaaaa_20261103_090000", lastActive: nil, model: nil, preview: nil, profile: profile, startedAt: nil, title: nil),
            CronRun(id: "cron_aaaaaaaaaaaa_20261103_100000", lastActive: nil, model: nil, preview: nil, profile: "someone-else", startedAt: nil, title: nil),
            CronRun(id: "cron_aaaaaaaaaaaa_20261103_110000", lastActive: nil, model: nil, preview: nil, profile: nil, startedAt: nil, title: nil),
        ]
        await state.loadCronRuns(for: CronJob(enabled: true, id: "aaaaaaaaaaaa"), dashboard: nil, gateway: { runs })
        XCTAssertEqual(state.cronRuns.map(\.id), ["cron_aaaaaaaaaaaa_20261103_090000", "cron_aaaaaaaaaaaa_20261103_110000"])
    }

    func testARunBelongsToTheJobItNamesOrItsSessionIDNames() {
        func run(_ id: String, job: String? = nil) -> CronRun {
            CronRun(id: id, lastActive: nil, model: nil, preview: nil, profile: nil, startedAt: nil, title: nil, jobID: job)
        }
        XCTAssertTrue(run("cron_abc123_20261103_090000").isRun(ofJob: "abc123"))
        XCTAssertFalse(run("cron_abc123_20261103_090000").isRun(ofJob: "def456"))
        // A job whose id is another's plus a suffix doesn't take its runs.
        XCTAssertFalse(run("cron_abc_123_20261103_090000").isRun(ofJob: "abc"))
        XCTAssertFalse(run("cron_abc123_2026110_090000").isRun(ofJob: "abc123"))
        // The job the gateway names wins over the id.
        XCTAssertTrue(run("local-7f3a", job: "abc123").isRun(ofJob: "abc123"))
        XCTAssertFalse(run("cron_abc123_20261103_090000", job: "def456").isRun(ofJob: "abc123"))
        // A run that names no job is no job's.
        XCTAssertFalse(run("local-7f3a").isRun(ofJob: "abc123"))
        XCTAssertFalse(run("cron__20261103_090000").isRun(ofJob: ""))
    }

    func testARunDecodesTheJobItNames() throws {
        let data = Data(#"{"id":"local-7f3a","job_id":"abc123","title":"Brief"}"#.utf8)
        let run = try JSONDecoder().decode(CronRun.self, from: data)
        XCTAssertEqual(run.jobID, "abc123")
        XCTAssertTrue(run.isRun(ofJob: "abc123"))

        let named = try JSONDecoder().decode(CronRun.self, from: Data(#"{"id":"local-7f3a","cron_job_id":"def456"}"#.utf8))
        XCTAssertEqual(named.jobID, "def456")

        // An empty or non-string job_id doesn't hide cron_job_id or the row.
        let empty = try JSONDecoder().decode(CronRun.self, from: Data(#"{"id":"local-7f3a","job_id":"","cron_job_id":"def456"}"#.utf8))
        XCTAssertEqual(empty.jobID, "def456")
        let numeric = try JSONDecoder().decode(CronRun.self, from: Data(#"{"id":"local-7f3a","job_id":42}"#.utf8))
        XCTAssertNil(numeric.jobID)
    }
}
