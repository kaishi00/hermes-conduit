import XCTest
@testable import Conduit

@MainActor
final class GatewayRestartTests: XCTestCase {
    private typealias Gateway = GatewayRestartGatewayStatus
    private typealias Action = GatewayRestartActionStatus

    // MARK: - Monitor

    func testChildExitingZeroWithAServingGatewayIsBack() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running"))
        let gateway = Gateway(running: true, state: "running")
        XCTAssertEqual(monitor.observe(action: Action(running: false, exitCode: 0), gateway: gateway, elapsed: 2), .back(gateway))
    }

    func testChildExitingNonZeroFailsWithItsLastLogLine() {
        var monitor = GatewayRestartMonitor(before: nil)
        let action = Action(running: false, exitCode: 78, lines: [
            "=== gateway-restart started 2026-10-09 23:30:00 ===",
            "✗ Profile coder is served by the default gateway",
            "",
            "=== gateway-restart completed 2026-10-09 23:30:01 ===",
        ])
        XCTAssertEqual(
            monitor.observe(action: action, gateway: Gateway(running: true, state: "running"), elapsed: 1),
            .failed(detail: "✗ Profile coder is served by the default gateway")
        )
    }

    func testOldGatewayStillUpIsStoppingOrDraining() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running", pid: 10))
        XCTAssertEqual(
            monitor.observe(action: Action(running: true), gateway: Gateway(running: true, state: "running", pid: 10), elapsed: 2),
            .waiting(.stopping)
        )
        XCTAssertEqual(
            monitor.observe(action: Action(running: true), gateway: Gateway(running: true, state: "draining", pid: 10), elapsed: 4),
            .waiting(.draining)
        )
    }

    func testGatewayComingBackAfterGoingDownIsBackWhileTheChildStillRuns() {
        // With no service manager the restart child becomes the gateway and
        // never exits.
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running"))
        XCTAssertEqual(monitor.observe(action: Action(running: true), gateway: Gateway(running: false, state: "stopped"), elapsed: 2), .waiting(.starting))
        XCTAssertEqual(monitor.observe(action: Action(running: true), gateway: Gateway(running: true, state: "starting"), elapsed: 4), .waiting(.starting))
        let back = Gateway(running: true, state: "running")
        XCTAssertEqual(monitor.observe(action: Action(running: true), gateway: back, elapsed: 6), .back(back))
    }

    func testNewProcessIsBack() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running", pid: 10))
        let back = Gateway(running: true, state: "running", pid: 11)
        XCTAssertEqual(monitor.observe(action: Action(running: true), gateway: back, elapsed: 2), .back(back))
    }

    func testServingGatewayCountsAsBackOnceTheGraceRunsOut() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running"))
        let gateway = Gateway(running: true, state: "running")
        XCTAssertEqual(
            monitor.observe(action: Action(running: true), gateway: gateway, elapsed: GatewayRestartMonitor.runningChildGrace - 1),
            .waiting(.stopping)
        )
        XCTAssertEqual(
            monitor.observe(action: Action(running: true), gateway: gateway, elapsed: GatewayRestartMonitor.runningChildGrace),
            .back(gateway)
        )
    }

    func testDrainingGatewayIsNeverBack() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running"))
        XCTAssertEqual(
            monitor.observe(action: Action(running: true), gateway: Gateway(running: true, state: "draining"), elapsed: 120),
            .waiting(.draining)
        )
    }

    func testStoppedGatewayIsBackAsSoonAsItServes() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: false, state: "stopped"))
        let back = Gateway(running: true, state: "degraded")
        XCTAssertEqual(monitor.observe(action: Action(running: true), gateway: back, elapsed: 2), .back(back))
    }

    func testGatewayThatDoesNotComeBackAfterTheChildIsNotBackYet() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running"))
        let down = Gateway(running: false, state: "stopped")
        XCTAssertEqual(monitor.observe(action: Action(running: false, exitCode: 0), gateway: down, elapsed: 5), .waiting(.starting))
        XCTAssertEqual(
            monitor.observe(action: Action(running: false, exitCode: 0), gateway: down, elapsed: 5 + GatewayRestartMonitor.comeBackWindow - 1),
            .waiting(.starting)
        )
        XCTAssertEqual(
            monitor.observe(action: Action(running: false, exitCode: 0), gateway: down, elapsed: 5 + GatewayRestartMonitor.comeBackWindow),
            .notBackYet
        )
    }

    func testGatewayThatFailedToStartSaysSo() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running"))
        let failed = Gateway(running: false, state: "startup_failed")
        XCTAssertEqual(monitor.observe(action: Action(running: false, exitCode: 0), gateway: failed, elapsed: 3), .waiting(.starting))
        XCTAssertEqual(
            monitor.observe(action: Action(running: false, exitCode: 0), gateway: failed, elapsed: 3 + GatewayRestartMonitor.comeBackWindow),
            .failedToStart
        )
    }

    func testWatchingStopsAtTheLimit() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running"))
        XCTAssertEqual(
            monitor.observe(action: Action(running: true), gateway: Gateway(running: true, state: "draining"), elapsed: GatewayRestartMonitor.watchLimit),
            .notBackYet
        )
    }

    func testMissedReadsKeepWaiting() {
        var monitor = GatewayRestartMonitor(before: Gateway(running: true, state: "running"))
        XCTAssertEqual(monitor.observe(action: nil, gateway: nil, elapsed: 40), .waiting(.stopping))
    }

    // MARK: - Parsing

    func testGatewayStatusParsesTheStatusRoute() throws {
        let status = try XCTUnwrap(Gateway(json: [
            "gateway_running": true,
            "gateway_state": "running",
            "gateway_pid": 4242,
            "gateway_shared_with": ["writer", "default", "coder", "writer", " "],
        ]))
        XCTAssertEqual(status, Gateway(running: true, state: "running", pid: 4242, sharedProfiles: ["default", "coder", "writer"]))
        XCTAssertNil(Gateway(json: ["version": "0.12.0"]))
    }

    func testOneProfileIsNotAShare() {
        XCTAssertEqual(Gateway.sharedProfiles(from: ["default"]), [])
        XCTAssertEqual(Gateway.sharedProfiles(from: nil), [])
        XCTAssertEqual(Gateway.sharedProfiles(from: NSNull()), [])
    }

    func testActionStatusParsesTheActionRoute() throws {
        let action = try XCTUnwrap(Action(json: ["name": "gateway-restart", "running": false, "exit_code": 0, "pid": 7, "lines": ["a", "b"]]))
        XCTAssertEqual(action, Action(running: false, exitCode: 0, lines: ["a", "b"]))
        XCTAssertEqual(Action(json: ["running": true, "exit_code": NSNull()]), Action(running: true))
        XCTAssertNil(Action(json: ["detail": "Unknown action"]))
    }

    func testLatestLineIsBounded() {
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(Action(running: true, lines: [long]).latestLine, String(repeating: "x", count: 240) + "…")
        XCTAssertNil(Action(running: true, lines: ["", "=== gateway-restart started ==="]).latestLine)
    }

    // MARK: - Restarter

    func testRestartRunsUntilTheGatewayIsBack() async {
        let dashboard = ScriptedDashboard(
            statuses: [
                ["gateway_running": true, "gateway_state": "running"],
                ["gateway_running": true, "gateway_state": "draining"],
                ["gateway_running": true, "gateway_state": "running", "gateway_shared_with": ["default", "coder"]],
            ],
            actions: [
                ["running": true, "lines": ["⏳ User service restarting gracefully (PID 10)"]],
                ["running": false, "exit_code": 0, "lines": ["✓ User service restarted"]],
            ]
        )
        var steps: [GatewayRestartState] = []
        let outcome = await dashboard.restarter().run { steps.append($0) }

        XCTAssertEqual(outcome, .restarted(sharedProfiles: ["default", "coder"]))
        XCTAssertEqual(steps, [
            .requesting,
            .restarting(.stopping, detail: nil),
            .restarting(.draining, detail: "⏳ User service restarting gracefully (PID 10)"),
        ])
        XCTAssertEqual(dashboard.calls.first, "GET /api/status")
        XCTAssertEqual(dashboard.calls.dropFirst().first, "POST /api/gateway/restart")
    }

    func testDashboardWithoutTheActionLogIsWatchedThroughStatus() async {
        let dashboard = ScriptedDashboard(
            statuses: [
                ["gateway_running": true, "gateway_state": "running"],
                ["gateway_running": false, "gateway_state": "stopped"],
                ["gateway_running": true, "gateway_state": "running"],
            ],
            actions: [],
            actionError: DashboardTicketBridgeError.http(status: 404, detail: "Unknown action: gateway-restart")
        )
        let outcome = await dashboard.restarter().run { _ in }

        XCTAssertEqual(outcome, .restarted(sharedProfiles: []))
        XCTAssertEqual(dashboard.calls.filter { $0.contains("/api/actions/") }.count, 1, "a missing action log is asked for once")
    }

    func testRestartRouteMissingIsUnsupported() async {
        let dashboard = ScriptedDashboard(
            statuses: [["gateway_running": true]],
            actions: [],
            restartError: DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
        )
        let outcome = await dashboard.restarter().run { _ in }
        XCTAssertEqual(outcome, .unsupported)
        XCTAssertFalse(dashboard.calls.contains { $0.contains("/api/actions/") })
    }

    func testRestartRefusedFailsWithHermesWords() async {
        let error = DashboardTicketBridgeError.http(status: 409, detail: "Profile coder is served by the shared gateway.")
        let dashboard = ScriptedDashboard(statuses: [], actions: [], restartError: error)
        let outcome = await dashboard.restarter().run { _ in }
        XCTAssertEqual(outcome, .failed(detail: UserFacingError.message(for: error)))
    }

    func testFailedChildEndsTheRestart() async {
        let dashboard = ScriptedDashboard(
            statuses: [["gateway_running": true, "gateway_state": "running"]],
            actions: [["running": false, "exit_code": 1, "lines": ["✗ systemctl restart failed"]]]
        )
        let outcome = await dashboard.restarter().run { _ in }
        XCTAssertEqual(outcome, .failed(detail: "✗ systemctl restart failed"))
    }
}

/// A dashboard that answers the restart's requests from scripts. A script
/// that runs out repeats its last answer.
@MainActor
private final class ScriptedDashboard {
    private var statuses: [[String: Any]]
    private var actions: [[String: Any]]
    private let actionError: Error?
    private let restartError: Error?
    private(set) var calls: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    init(statuses: [[String: Any]], actions: [[String: Any]], actionError: Error? = nil, restartError: Error? = nil) {
        self.statuses = statuses
        self.actions = actions
        self.actionError = actionError
        self.restartError = restartError
    }

    func restarter() -> GatewayRestarter {
        var restarter = GatewayRestarter(request: { [unowned self] path, method in try self.respond(path: path, method: method) })
        restarter.sleep = { [unowned self] _ in self.clock += 1.5 }
        restarter.now = { [unowned self] in self.clock }
        return restarter
    }

    private func respond(path: String, method: String) throws -> [String: Any] {
        calls.append("\(method) \(path.split(separator: "?").first.map(String.init) ?? path)")
        switch path {
        case GatewayRestarter.restartPath:
            if let restartError { throw restartError }
            return ["ok": true, "pid": 99, "name": "gateway-restart"]
        case GatewayRestarter.statusPath:
            return try next(&statuses)
        case GatewayRestarter.actionStatusPath:
            if let actionError { throw actionError }
            return try next(&actions)
        default:
            XCTFail("unexpected request \(method) \(path)")
            throw DashboardTicketBridgeError.http(status: 404, detail: "")
        }
    }

    private func next(_ script: inout [[String: Any]]) throws -> [String: Any] {
        guard let first = script.first else { throw DashboardTicketBridgeError.http(status: 0, detail: "No response from the dashboard.") }
        if script.count > 1 { script.removeFirst() }
        return first
    }
}
