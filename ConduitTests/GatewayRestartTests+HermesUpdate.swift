import XCTest
@testable import Conduit

/// Update Hermes from Settings > Connection (HermesUpdate.swift), the Skill
/// Hub's update check, and the chat's goal, loop, heartbeat and background
/// process rows. An extension, so no new class to plan.
@MainActor
extension GatewayRestartTests {
    // MARK: - Update Hermes

    func testHermesUpdateCheckReadsWhatTheDashboardSays() throws {
        let check = try XCTUnwrap(HermesUpdateCheck(json: [
            "install_method": "git", "current_version": "0.23.1", "behind": 12,
            "update_available": true, "can_apply": true, "update_command": "hermes update",
            "message": NSNull(), "source_version": "0.24.0",
            "commits": [["sha": "abc1234", "summary": "Faster resumes", "author": "n", "at": 1]]
        ]))
        XCTAssertEqual(check.currentVersion, "0.23.1")
        XCTAssertEqual(check.behind, 12)
        XCTAssertTrue(check.canUpdateHere)
        XCTAssertEqual(check.sourceVersion, "0.24.0")
        XCTAssertEqual(check.commits.map(\.summary), ["Faster resumes"])

        let docker = try XCTUnwrap(HermesUpdateCheck(json: [
            "install_method": "docker", "current_version": "0.23.1", "behind": NSNull(),
            "update_available": false, "can_apply": false, "update_command": "docker pull nousresearch/hermes-agent",
            "message": "Hermes runs in Docker."
        ]))
        XCTAssertFalse(docker.canUpdateHere)
        XCTAssertNil(docker.behind)
        XCTAssertEqual(docker.message, "Hermes runs in Docker.")
        XCTAssertNil(HermesUpdateCheck(json: ["detail": "Not Found"]))
    }

    func testHermesUpdateFollowsTheActionThroughTheRestart() async {
        let host = ScriptedUpdateHost(statuses: [
            .answer(["name": "hermes-update", "running": true, "exit_code": NSNull(), "lines": ["Pulling…"]]),
            .down,
            .down,
            .answer(["name": "hermes-update", "running": false, "exit_code": NSNull(),
                     "lines": ["Restarting", "=== hermes-update completed a1 ==="]])
        ])
        var steps: [HermesUpdateState] = []

        let outcome = await host.updater().run { steps.append($0) }

        XCTAssertEqual(outcome, .updated(version: "0.24.0"), "the check after it names the new version")
        XCTAssertTrue(steps.contains(.updating(.updating, detail: "Pulling…")))
        XCTAssertTrue(steps.contains(.updating(.restarting, detail: "Pulling…")), "the dashboard going quiet is the restart")
        XCTAssertEqual(host.calls.first, "POST /api/hermes/update")
    }

    func testAnInstallTheDashboardCantUpdateSaysHow() async {
        let host = ScriptedUpdateHost(statuses: [], refusal: [
            "ok": false, "name": "hermes-update", "error": "docker",
            "message": "Hermes runs in Docker. Pull the new image.", "update_command": "docker pull nousresearch/hermes-agent"
        ])

        let outcome = await host.updater().run { _ in }

        XCTAssertEqual(outcome, .manual(message: "Hermes runs in Docker. Pull the new image.", command: "docker pull nousresearch/hermes-agent"))
        XCTAssertEqual(host.calls, ["POST /api/hermes/update"], "nothing to follow")
    }

    func testAFailedUpdateShowsItsLastLogLine() async {
        let host = ScriptedUpdateHost(statuses: [
            .answer(["running": true, "exit_code": NSNull(), "lines": ["Installing"]]),
            .answer(["running": false, "exit_code": 1, "lines": ["Installing", "✗ pip install failed", "=== hermes-update finished ==="]])
        ])

        let outcome = await host.updater().run { _ in }

        XCTAssertEqual(outcome, .failed(detail: "✗ pip install failed"))
    }

    func testAnUpdateReadsOnlyItsOwnReceipt() {
        let idle = GatewayRestartActionStatus(running: false)
        XCTAssertEqual(HermesUpdater.verdict(idle, receipt: ["outcome": "partial", "action_id": "a1"], actionID: "a1"), .succeeded,
                       "a partial run committed the update")
        XCTAssertEqual(HermesUpdater.verdict(idle, receipt: ["outcome": "failed", "action_id": "a1"], actionID: "a1"), .failed)
        XCTAssertEqual(HermesUpdater.verdict(idle, receipt: ["outcome": "success", "action_id": "older"], actionID: "a1"), .unknown,
                       "another update's receipt proves nothing about this one")
        XCTAssertEqual(HermesUpdater.verdict(GatewayRestartActionStatus(running: true), receipt: nil, actionID: "a1"), .running)
    }

    func testADashboardWithoutTheUpdateRouteCantUpdate() async {
        let host = ScriptedUpdateHost(statuses: [], postError: DashboardTicketBridgeError.http(status: 404, detail: "Not Found"))
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, .unsupported)
    }

    // MARK: - Skill Hub update check

    func testHubSkillUpdateRowsKeepTheirName() {
        let rows: [Any] = [
            ["name": "pdf-tools", "identifier": "skills-sh/acme/pdf-tools", "source": "skills.sh"],
            ["identifier": "github/acme/notes", "source": "github"],
            ["source": "github"]
        ]
        let updates = rows.compactMap(HubSkillUpdate.init)
        XCTAssertEqual(updates.map(\.name), ["pdf-tools", "github/acme/notes"], "a row with neither name nor identifier is dropped")
    }

    // MARK: - Goal, loop, heartbeat and background process rows

    func testSessionControlUpdateCarriesTheWholeSnapshot() throws {
        let params = AnyCodable.from([
            "type": "session.control.update",
            "session_id": "s1",
            "payload": ["control": [
                "goal": ["title": "Ship it", "status": "paused", "turns_used": 3, "max_turns": 20,
                         "subgoals": ["tests pass", " "], "paused_reason": "waiting on you"],
                "loop": ["prompt": "check CI", "status": "active", "mode": "interval", "interval_seconds": 300,
                         "current_delay": 300, "times": 0, "until": "", "max_ticks": 10, "ticks_fired": 2,
                         "created_at": 1, "last_fired_at": 2, "next_due_at": 3, "awaiting_response": false,
                         "deferred_by_goal": true],
                "heartbeat": ["prompt": "anything new?", "status": "active", "interval_seconds": 1800,
                              "created_at": 1, "last_fired_at": 2, "fire_count": 4],
                "revision": "abc", "updated_at": 2
            ] as [String: Any]]
        ] as [String: Any])
        guard case .sessionControl(let session, let snapshot) = StreamEventParser.parse(params: params) else {
            return XCTFail("expected a session control update")
        }
        XCTAssertEqual(session, "s1")
        XCTAssertEqual(snapshot.goal?.title, "Ship it")
        XCTAssertEqual(snapshot.goal?.isPaused, true)
        XCTAssertEqual(snapshot.goal?.subgoals, ["tests pass"], "a blank criterion isn't shown")
        XCTAssertEqual(snapshot.loop?.maxTicks, 10)
        XCTAssertEqual(snapshot.loop?.deferredByGoal, true)
        XCTAssertEqual(snapshot.heartbeat?.intervalSeconds, 1800)
        XCTAssertEqual(snapshot.revision, "abc")
    }

    func testFinishedLoopsAndClearedGoalsLeaveTheDock() throws {
        let snapshot = try XCTUnwrap(SessionControlSnapshot(.object([
            "goal": .object(["title": .string("Old"), "status": .string("cleared")]),
            "loop": .object(["prompt": .string("done loop"), "status": .string("done")]),
            "heartbeat": .null,
            "revision": .string("")
        ])))
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertNil(SessionControlSnapshot(.object(["error": .string("nope")])))
    }

    func testDockActionsUseHermesNames() {
        XCTAssertEqual(SessionControlAction.loopStop.name, "loop.stop")
        XCTAssertEqual(SessionControlAction.heartbeatResume.name, "heartbeat.resume")
        XCTAssertEqual(SessionControlAction.subgoalRemove(index: 2).args?["index"] as? Int, 2)
        XCTAssertTrue(SessionControlAction.goalClear.ends)
        XCTAssertFalse(SessionControlAction.goalPause.ends)
    }

    func testBackgroundProcessRowReadsHermesProcessRegistry() throws {
        let process = try XCTUnwrap(BackgroundProcess([
            "session_id": .string("proc_7"), "command": .string("npm run dev"), "cwd": .string("/srv/app"),
            "pid": .number(4242), "status": .string("running"), "uptime_seconds": .number(65),
            "output_preview": .string("old"), "output_tail": .string("a\nb\n\nc\nd\ne\n")
        ]))
        XCTAssertEqual(process.id, "proc_7")
        XCTAssertEqual(process.pid, 4242)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(process.output, "b\nc\nd\ne", "the newest four lines, blanks left out")
        XCTAssertNil(BackgroundProcess(["command": .string("no id")]))
    }
}

/// A dashboard that answers Update Hermes from a script of action-status
/// answers. `.down` is the dashboard restarting; a script that runs out
/// repeats its last answer.
@MainActor
private final class ScriptedUpdateHost {
    enum Status {
        case answer([String: Any])
        case down
    }

    private var statuses: [Status]
    private let refusal: [String: Any]?
    private let postError: Error?
    private(set) var calls: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    init(statuses: [Status], refusal: [String: Any]? = nil, postError: Error? = nil) {
        self.statuses = statuses
        self.refusal = refusal
        self.postError = postError
    }

    func updater() -> HermesUpdater {
        var updater = HermesUpdater(request: { [unowned self] path, method in try self.respond(path: path, method: method) })
        updater.sleep = { [unowned self] _ in self.clock += 1.5 }
        updater.now = { [unowned self] in self.clock }
        return updater
    }

    private func respond(path: String, method: String) throws -> [String: Any] {
        calls.append("\(method) \(path.split(separator: "?").first.map(String.init) ?? path)")
        if path == HermesUpdater.updatePath {
            if let postError { throw postError }
            return refusal ?? ["ok": true, "pid": 7, "name": "hermes-update", "action_id": "a1"]
        }
        if path.hasPrefix(HermesUpdater.checkPath) {
            return ["install_method": "git", "current_version": "0.24.0", "behind": 0, "update_available": false, "can_apply": true]
        }
        if path == HermesUpdater.statusPath("hermes-update") {
            guard let first = statuses.first else { throw DashboardTicketBridgeError.http(status: 0, detail: "No response from the dashboard.") }
            if statuses.count > 1 { statuses.removeFirst() }
            switch first {
            case .answer(let json): return json
            case .down: throw URLError(.cannotConnectToHost)
            }
        }
        XCTFail("unexpected request \(method) \(path)")
        throw DashboardTicketBridgeError.http(status: 404, detail: "")
    }
}
