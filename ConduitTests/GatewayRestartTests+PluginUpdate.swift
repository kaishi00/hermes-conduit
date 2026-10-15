import XCTest
@testable import Conduit

/// The one-tap Conduit plugin update (NotifierPluginUpdate.swift) and the
/// plugin's running-version report. An extension, so no new class to plan.
@MainActor
extension GatewayRestartTests {
    // MARK: - Status

    func testPluginVersionsCompareNumerically() {
        XCTAssertTrue(NotifierPluginStatus.isOlder("0.9.1", than: "0.10.0"))
        XCTAssertTrue(NotifierPluginStatus.isOlder("0.23.0", than: "0.24.0"))
        XCTAssertFalse(NotifierPluginStatus.isOlder("0.24.0", than: "0.24.0"))
        XCTAssertFalse(NotifierPluginStatus.isOlder("0.24", than: "0.24.0"))
        XCTAssertFalse(NotifierPluginStatus.isOlder("1.0.0-beta", than: "0.24.0"))
        XCTAssertTrue(NotifierPluginStatus.isOlder(nil, than: "0.24.0"))
        XCTAssertTrue(NotifierPluginStatus.isOlder("junk", than: "0.24.0"))
    }

    func testAnOlderPluginOffersTheUpdateEvenWithEveryFeature() {
        var status = NotifierPluginStatus()
        status.state = .reported(version: "0.23.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        XCTAssertFalse(status.needsUpdate)
        XCTAssertTrue(status.updateAvailable)
        XCTAssertFalse(status.restartPending)
        XCTAssertEqual(status.runningVersion, "0.23.0")
    }

    func testAMissingPluginOffersTheUpdate() {
        var status = NotifierPluginStatus()
        status.state = .predatesCapabilities
        XCTAssertTrue(status.updateAvailable)
        status.state = .unknown
        XCTAssertFalse(status.updateAvailable)
    }

    func testANewPluginOnDiskServedByOldCodeNeedsOnlyARestart() {
        // A pre-0.24 dashboard process reads the version from disk and has
        // no running-version report.
        var status = NotifierPluginStatus()
        status.state = .reported(version: NotifierPluginStatus.recommendedVersion, capabilities: ["session-takeover"])
        XCTAssertTrue(status.restartPending)
        XCTAssertFalse(status.updateAvailable)
        XCTAssertNil(status.runningVersion)

        let response: [String: Any] = [
            "ok": true, "version": NotifierPluginStatus.recommendedVersion, "loaded_version": "0.24.0", "restart_needed": true, "boot_id": "a1",
            "capabilities": NotifierPluginStatus.usedCapabilities,
        ]
        status.state = NotifierPluginStatus.state(from: response)
        status.runtime = NotifierPluginStatus.runtime(from: response)
        XCTAssertEqual(status.runtime, NotifierPluginStatus.Runtime(loadedVersion: "0.24.0", restartNeeded: true, bootID: "a1"))
        XCTAssertTrue(status.restartPending)
        XCTAssertFalse(status.updateAvailable)
        XCTAssertEqual(status.runningVersion, "0.24.0")
    }

    func testAnOlderPluginReportsNoRuntime() {
        XCTAssertNil(NotifierPluginStatus.runtime(from: ["ok": true, "version": "0.23.0", "capabilities": []]))
    }

    func testProfilePairingOwner() {
        XCTAssertEqual(PushNotificationService.profilePairing(status: ["paired": false], installationID: "i1"), .unpaired)
        XCTAssertEqual(PushNotificationService.profilePairing(status: ["paired": true, "installation_id": "i1"], installationID: "i1"), .thisDevice)
        XCTAssertEqual(PushNotificationService.profilePairing(status: ["paired": true, "installation_id": "i2"], installationID: "i1"), .otherDevice)
    }

    // MARK: - Updater

    func testUpdateRestartsTheGatewayThenTheDashboard() async {
        let host = PluginHost()
        host.capabilities = [
            Self.capabilities(loaded: "0.24.0", disk: "0.25.0", boot: "old"),
            Self.capabilities(loaded: "0.25.0", disk: "0.25.0", boot: "new"),
        ]
        var steps: [NotifierPluginUpdateState] = []
        let outcome = await host.updater().run { steps.append($0) }
        XCTAssertEqual(outcome, .updated(version: "0.25.0"))
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("POST") }, [
            "POST \(NotifierPluginUpdater.updatePath)",
            "POST \(GatewayRestarter.restartPath)",
            "POST \(NotifierPluginUpdater.selfRestartPath)",
        ])
        XCTAssertEqual(steps.first, .updating(.downloading))
        XCTAssertTrue(steps.contains(.updating(.restartingDashboard)))
    }

    func testAMissingPluginIsInstalled() async {
        let host = PluginHost()
        host.updateError = DashboardTicketBridgeError.http(status: 400, detail: "Plugin 'conduit_push' was not found under /home/h/.hermes/plugins.")
        host.capabilities = [Self.capabilities(loaded: "0.25.0", disk: "0.25.0", boot: "b")]
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, .updated(version: "0.25.0"))
        XCTAssertTrue(host.calls.contains("POST \(NotifierPluginUpdater.installPath)"))
        XCTAssertEqual(host.installBody?["identifier"] as? String, NotifierPluginStatus.repository)
        XCTAssertEqual(host.installBody?["enable"] as? Bool, true)
        // A first install is mounted as it lands: no dashboard restart.
        XCTAssertFalse(host.calls.contains("POST \(NotifierPluginUpdater.selfRestartPath)"))
    }

    func testAPluginHermesDidNotCloneIsReinstalledFromItsSource() async {
        let host = PluginHost()
        host.updateError = DashboardTicketBridgeError.http(status: 400, detail: "Plugin 'conduit_push' has no owned Git checkout; reinstall from its source.")
        host.capabilities = [
            Self.capabilities(loaded: "0.24.0", disk: "0.30.0", boot: "old"),
            Self.capabilities(loaded: "0.30.0", disk: "0.30.0", boot: "new"),
        ]
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, .updated(version: "0.30.0"))
        XCTAssertEqual(host.installBody?["identifier"] as? String, NotifierPluginStatus.repository)
        XCTAssertEqual(host.installBody?["force"] as? Bool, true)
    }

    func testAFirstInstallIsNotForced() async {
        let host = PluginHost()
        host.updateError = DashboardTicketBridgeError.http(status: 400, detail: "Plugin 'conduit_push' was not found under /home/h/.hermes/plugins.")
        host.capabilities = [Self.capabilities(loaded: "0.30.0", disk: "0.30.0", boot: "b")]
        _ = await host.updater().run { _ in }
        XCTAssertNil(host.installBody?["force"])
    }

    func testTheDashboardRestartSigningOutSignsInAgain() async {
        let host = PluginHost()
        host.restartSignsOut = true
        host.signInAgainWorks = true
        host.capabilities = [
            Self.capabilities(loaded: "0.24.0", disk: "0.25.0", boot: "old"),
            Self.capabilities(loaded: "0.25.0", disk: "0.25.0", boot: "new"),
        ]
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, .updated(version: "0.25.0"))
        XCTAssertEqual(host.signInsAgain, 1)
    }

    func testARefusedSignInEndsTheUpdateWithTheSignInError() async {
        let host = PluginHost()
        host.restartSignsOut = true
        host.signInAgainWorks = false
        host.capabilities = [Self.capabilities(loaded: "0.24.0", disk: "0.25.0", boot: "old")]
        let start = host.clock
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, NotifierPluginUpdater.outcome(forRequestError: DashboardTicketBridgeError.signInRequired))
        XCTAssertEqual(host.signInsAgain, 1)
        // Says so at once instead of waiting out the comeback limit.
        XCTAssertLessThan(host.clock.timeIntervalSince(start), NotifierPluginUpdater.comeBackLimit)
    }

    func testRunningChatsAreWaitedOn() async {
        let host = PluginHost()
        host.capabilities = [
            Self.capabilities(loaded: "0.24.0", disk: "0.25.0", boot: "old"),
            Self.capabilities(loaded: "0.25.0", disk: "0.25.0", boot: "new"),
        ]
        host.selfRestartErrors = [DashboardTicketBridgeError.http(status: 409, detail: "2 chat turns still running on this dashboard")]
        var steps: [NotifierPluginUpdateState] = []
        let outcome = await host.updater().run { steps.append($0) }
        XCTAssertEqual(outcome, .updated(version: "0.25.0"))
        XCTAssertTrue(steps.contains(.updating(.waitingForChats(count: 2))))
        XCTAssertEqual(host.calls.filter { $0 == "POST \(NotifierPluginUpdater.selfRestartPath)" }.count, 2)
    }

    func testAPluginWithoutTheRestartRouteAsksForAManualRestart() async {
        let host = PluginHost()
        // The old plugin still serves: no running-version report.
        host.capabilities = [["ok": true, "version": "0.24.0", "capabilities": ["session-takeover"]]]
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, .needsDashboardRestart(detail: nil))
        XCTAssertFalse(host.calls.contains("POST \(NotifierPluginUpdater.selfRestartPath)"))
    }

    func testADesktopBackendRefusesTheRestart() async {
        let host = PluginHost()
        host.capabilities = [Self.capabilities(loaded: "0.24.0", disk: "0.25.0", boot: "old")]
        host.selfRestartErrors = [DashboardTicketBridgeError.http(status: 501, detail: "Restart Hermes Desktop to finish the update")]
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, .needsDashboardRestart(detail: "Restart Hermes Desktop to finish the update"))
    }

    func testAHermesWithoutPluginRoutesIsUnsupported() async {
        let host = PluginHost()
        host.updateError = DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, .unsupported)
        XCTAssertFalse(host.calls.contains("POST \(GatewayRestarter.restartPath)"))
    }

    func testARefusedUpdateFailsWithHermesWords() async {
        let host = PluginHost()
        host.updateResponse = ["ok": false, "consent_required": true, "error": "The update widens what the plugin can do."]
        let outcome = await host.updater().run { _ in }
        XCTAssertEqual(outcome, .failed(detail: "The update widens what the plugin can do."))
    }

    func testTheUpdateSlotKeepsOnlyItsOwnDashboardsOutcome() {
        var slot = NotifierPluginUpdateSlot()
        let dashboard = UUID()
        let run = slot.start(on: dashboard)
        XCTAssertEqual(slot.state(on: UUID()), .idle)
        slot.finish(.updated(version: "0.25.0"), run: run, activeDashboardID: dashboard)
        XCTAssertEqual(slot.state(on: dashboard), .updated(version: "0.25.0"))
        let next = slot.start(on: dashboard)
        slot.finish(.updated(version: "0.26.0"), run: next, activeDashboardID: UUID())
        XCTAssertEqual(slot.state(on: dashboard), .idle)
    }

    func testProgressCountsStepsAndTimesTheRun() {
        XCTAssertEqual(NotifierPluginUpdateStep.downloading.number, 1)
        XCTAssertEqual(NotifierPluginUpdateStep.installing.number, 1)
        XCTAssertEqual(NotifierPluginUpdateStep.restartingGateway(nil).number, 2)
        XCTAssertEqual(NotifierPluginUpdateStep.waitingForChats(count: 2).number, 3)
        XCTAssertEqual(NotifierPluginUpdateStep.restartingDashboard.number, NotifierPluginUpdateStep.count)
        var slot = NotifierPluginUpdateSlot()
        XCTAssertNil(slot.startedAt)
        let run = slot.start(on: UUID())
        XCTAssertNotNil(slot.startedAt)
        slot.finish(.idle, run: run, activeDashboardID: nil)
        XCTAssertNil(slot.startedAt)
    }

    func testAFailedUpdateOnAnOldPluginAsksForTheOneTimeManualUpdate() {
        var old = NotifierPluginStatus()
        old.state = .reported(version: "0.23.0", capabilities: ["session-takeover"])
        XCTAssertTrue(old.predatesOneTapUpdate)
        let failed = NotifierPluginUpdateStatusView.row(for: .failed(detail: "not a git repository"), plugin: old)
        XCTAssertEqual(failed?.title, "Update the plugin on the host this once")
        XCTAssertTrue(failed?.detail?.contains("0.23.0") == true)
        XCTAssertTrue(failed?.detail?.contains("not a git repository") == true)
        XCTAssertEqual(NotifierPluginUpdateStatusView.row(for: .unsupported, plugin: old)?.title, "Update the plugin on the host this once")

        // A plugin with one-tap updates keeps the plain error.
        var current = old
        current.runtime = NotifierPluginStatus.Runtime(loadedVersion: "0.24.0", restartNeeded: false, bootID: "b")
        XCTAssertFalse(current.predatesOneTapUpdate)
        XCTAssertEqual(NotifierPluginUpdateStatusView.row(for: .failed(detail: nil), plugin: current)?.title, "Couldn't update the Conduit plugin")
        XCTAssertFalse(NotifierPluginStatus().predatesOneTapUpdate)

        // New files on disk served by the old process: only a restart is left.
        var restartOnly = NotifierPluginStatus()
        restartOnly.state = .reported(version: "0.29.0", capabilities: ["session-takeover"])
        XCTAssertFalse(restartOnly.predatesOneTapUpdate)
        var missing = NotifierPluginStatus()
        missing.state = .predatesCapabilities
        XCTAssertTrue(missing.predatesOneTapUpdate)
        XCTAssertTrue(NotifierPluginUpdateStatusView.row(for: .unsupported, plugin: missing)?.detail?.contains("missing") == true)
    }

    private static func capabilities(loaded: String, disk: String, boot: String) -> [String: Any] {
        [
            "ok": true, "version": disk, "loaded_version": loaded, "restart_needed": loaded != disk, "boot_id": boot,
            "capabilities": NotifierPluginStatus.usedCapabilities + ["pairing", NotifierPluginUpdater.selfRestartCapability],
        ]
    }
}

/// A scripted dashboard for the plugin updater.
@MainActor
private final class PluginHost {
    var calls: [String] = []
    var clock = Date(timeIntervalSince1970: 0)
    var updateError: Error?
    var updateResponse: [String: Any] = ["ok": true, "name": "conduit_push", "output": "Updated", "unchanged": false]
    var installBody: [String: Any]?
    var selfRestartErrors: [Error] = []
    /// Answers to the capabilities route in order; the last one repeats.
    var capabilities: [[String: Any]] = []
    /// The dashboard restart signs everyone out, like a host without a
    /// fixed sign-in secret.
    var restartSignsOut = false
    /// Whether signing in again with the saved password works; nil leaves
    /// the updater without a way to sign in again.
    var signInAgainWorks: Bool?
    var signInsAgain = 0
    private var signedIn = true
    private var gatewayPolls = 0

    func updater() -> NotifierPluginUpdater {
        var updater = NotifierPluginUpdater(request: { [unowned self] path, method, body in
            try self.respond(path: path, method: method, body: body)
        })
        if let works = signInAgainWorks {
            updater.renewSignIn = { [unowned self] in
                self.signInsAgain += 1
                if works { self.signedIn = true }
                return works
            }
        }
        updater.sleep = { [unowned self] _ in self.clock += 2 }
        updater.now = { [unowned self] in self.clock }
        return updater
    }

    private func respond(path: String, method: String, body: [String: Any]?) throws -> [String: Any] {
        calls.append("\(method) \(path.split(separator: "?").first.map(String.init) ?? path)")
        guard signedIn else { throw DashboardTicketBridgeError.signInRequired }
        switch path {
        case NotifierPluginUpdater.updatePath:
            if let updateError { throw updateError }
            return updateResponse
        case NotifierPluginUpdater.installPath:
            installBody = body
            return ["ok": true, "name": "conduit_push"]
        case GatewayRestarter.restartPath:
            return ["ok": true, "pid": 99, "name": "gateway-restart"]
        case GatewayRestarter.actionStatusPath:
            return ["running": false, "exit_code": 0, "lines": []]
        case GatewayRestarter.statusPath:
            gatewayPolls += 1
            return ["gateway_running": true, "gateway_state": "running"]
        case NotifierPluginUpdater.selfRestartPath:
            if !selfRestartErrors.isEmpty { throw selfRestartErrors.removeFirst() }
            if restartSignsOut { signedIn = false }
            return ["ok": true, "restarting": true]
        case NotifierPluginStatus.path:
            guard let first = capabilities.first else {
                throw DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
            }
            if capabilities.count > 1 { capabilities.removeFirst() }
            return first
        default:
            XCTFail("unexpected request \(method) \(path)")
            throw DashboardTicketBridgeError.http(status: 404, detail: "")
        }
    }
}
