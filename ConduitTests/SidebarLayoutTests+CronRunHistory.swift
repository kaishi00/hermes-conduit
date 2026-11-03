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

        await state.loadCronRuns(for: CronJob(enabled: true, id: "aaaaaaaaaaaa"), dashboard: requester)
        XCTAssertEqual(state.cronRuns.map(\.id), ["cron_aaaaaaaaaaaa_20261103_090000"])

        // Job B never ran: its sheet says so, never job A's runs.
        await state.loadCronRuns(for: CronJob(enabled: true, id: "bbbbbbbbbbbb"), dashboard: requester)
        XCTAssertTrue(state.cronRuns.isEmpty)
        XCTAssertEqual(state.cronRunsJobID, "bbbbbbbbbbbb")
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

        let slow = Task { await state.loadCronRuns(for: CronJob(enabled: true, id: "aaaaaaaaaaaa"), dashboard: requester) }
        while requester.heldCount == 0 { await Task.yield() }
        // The sheet moved on to job B before job A's read came back.
        await state.loadCronRuns(for: CronJob(enabled: true, id: "bbbbbbbbbbbb"), dashboard: requester)
        requester.release()
        await slow.value

        XCTAssertEqual(state.cronRunsJobID, "bbbbbbbbbbbb")
        XCTAssertTrue(state.cronRuns.isEmpty)
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
    }
}
