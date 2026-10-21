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

    // MARK: - Update notice

    func testTheNoticeOffersTheInstallForAPluginTheHostDoesntList() {
        var status = NotifierPluginStatus(state: .predatesCapabilities)
        status.hostCopy = .missing
        XCTAssertTrue(status.offersInstall)
        XCTAssertTrue(status.updateAvailable)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .install)
        // Finish setting up offers Install itself: no second call to action.
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: true), .none)

        // The host couldn't say: as missing, which is what installing fixes.
        status.hostCopy = nil
        XCTAssertTrue(status.offersInstall)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .install)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: true), .none)
    }

    func testTheNoticeOffersTheUpdateForAListedPluginOlderThanCapabilities() {
        var status = NotifierPluginStatus(state: .predatesCapabilities)
        status.hostCopy = .old
        XCTAssertFalse(status.offersInstall)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .update)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: true), .update)
    }

    func testANewPluginTheDashboardDoesntServeIsOfferedNoInstallOrUpdate() {
        // Turned off, or installed after the dashboard started: Hermes
        // refuses an install over the copy, and an update doesn't turn it on.
        var status = NotifierPluginStatus(state: .predatesCapabilities)
        status.hostCopy = .notServed
        XCTAssertTrue(status.isNotServed)
        XCTAssertFalse(status.offersInstall)
        XCTAssertFalse(status.updateAvailable)
        XCTAssertFalse(status.restartPending)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .none)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: true), .none)
        XCTAssertEqual(NotifierPluginSummary.detail(status, update: .idle), "Installed but not running")
        // Settings and Notifications still point at the plugin's page.
        XCTAssertTrue(status.needsAttention)

        // Every other copy keeps its offer.
        for copy in [NotifierPluginStatus.HostCopy.missing, .old, nil] {
            status.hostCopy = copy
            XCTAssertFalse(status.isNotServed)
            XCTAssertTrue(status.updateAvailable, "\(String(describing: copy))")
            XCTAssertTrue(status.needsAttention)
            XCTAssertEqual(NotifierPluginSummary.detail(status, update: .idle), "Not installed or out of date")
        }
        XCTAssertFalse(NotifierPluginStatus(state: .unknown, hostCopy: .notServed).isNotServed)
    }

    func testARestartOutcomeStaysWhileTheRoutesDontAnswer() {
        // Conduit's own install that couldn't restart the dashboard leaves
        // the copy unserved until someone does.
        let waiting = NotifierPluginUpdateState.needsDashboardRestart(detail: nil)
        var status = NotifierPluginStatus(state: .predatesCapabilities)
        status.hostCopy = .notServed
        XCTAssertFalse(status.settles(waiting))

        let current = NotifierPluginStatus.recommendedVersion
        let served = NotifierPluginStatus(
            state: .reported(version: current, capabilities: Set(NotifierPluginStatus.usedCapabilities)),
            runtime: NotifierPluginStatus.Runtime(loadedVersion: current, restartNeeded: false, bootID: "b")
        )
        XCTAssertTrue(served.settles(waiting))
        XCTAssertTrue(served.settles(.failed(detail: nil)))
        XCTAssertFalse(served.settles(.idle))
        var stillOld = served
        stillOld.runtime = NotifierPluginStatus.Runtime(loadedVersion: "0.30.0", restartNeeded: true, bootID: "b")
        XCTAssertFalse(stillOld.settles(waiting))
        XCTAssertFalse(stillOld.settles(.failed(detail: nil)))
    }

    func testTheNoticeOffersNothingBeforeTheHostAnswers() {
        let status = NotifierPluginStatus(state: .unknown)
        XCTAssertFalse(status.offersInstall)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .none)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: true), .none)
    }

    func testTheNoticeOffersTheRestartOrTheUpdateForAReportingPlugin() {
        let current = NotifierPluginStatus.recommendedVersion
        let all = Set(NotifierPluginStatus.usedCapabilities)
        // New files on disk, the old process still serving them.
        let restart = NotifierPluginStatus(
            state: .reported(version: current, capabilities: all),
            runtime: NotifierPluginStatus.Runtime(loadedVersion: "0.30.0", restartNeeded: true, bootID: "a")
        )
        XCTAssertEqual(restart.noticeOffer(finishSetupOffersInstall: false), .restart)
        XCTAssertEqual(restart.noticeOffer(finishSetupOffersInstall: true), .restart)

        let old = NotifierPluginStatus(
            state: .reported(version: "0.30.0", capabilities: all),
            runtime: NotifierPluginStatus.Runtime(loadedVersion: "0.30.0", restartNeeded: false, bootID: "a")
        )
        XCTAssertFalse(old.offersInstall)
        XCTAssertEqual(old.noticeOffer(finishSetupOffersInstall: true), .update)

        let upToDate = NotifierPluginStatus(
            state: .reported(version: current, capabilities: all),
            runtime: NotifierPluginStatus.Runtime(loadedVersion: current, restartNeeded: false, bootID: "a")
        )
        XCTAssertEqual(upToDate.noticeOffer(finishSetupOffersInstall: false), .none)
    }

    func testThePluginsCopyIsReadFromHermesPluginList() {
        let read = NotifierPluginStatus.hostCopy(inPluginsHub:)
        let old: [String: Any] = ["plugins": [
            ["name": "disk-cleanup", "source": "bundled"],
            ["name": "conduit_push", "version": "0.3.2", "source": "git", "path": "/home/h/.hermes/plugins/conduit_push"],
        ]]
        XCTAssertEqual(read(old), .old)
        // Cloned under the repository's name, without a version.
        let byFolder: [String: Any] = ["plugins": [["name": "notifier", "source": "user", "path": "/p/hermes-conduit-notifier"]]]
        XCTAssertEqual(read(byFolder), .old)
        let current: [String: Any] = ["plugins": [["name": "conduit_push", "version": "0.46.1", "source": "user", "runtime_status": "disabled"]]]
        XCTAssertEqual(read(current), .notServed)
        let others: [String: Any] = ["plugins": [["name": "disk-cleanup", "source": "bundled"], ["name": "kanban-extra", "source": "git"]]]
        XCTAssertEqual(read(others), .missing)
        XCTAssertEqual(read(["plugins": []]), .missing)
        XCTAssertNil(read(["detail": "Unauthorized"]))
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

    func testTheLatestPluginOnGitHubIsOfferedAboveTheBuildsOwn() {
        let floor = NotifierPluginStatus.recommendedVersion
        var status = NotifierPluginStatus()
        status.state = .reported(version: floor, capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: floor, restartNeeded: false, bootID: nil)
        XCTAssertEqual(status.offeredVersion, floor)
        XCTAssertFalse(status.updateAvailable)

        status.latestVersion = "99.0.0"
        XCTAssertEqual(status.offeredVersion, "99.0.0")
        XCTAssertTrue(status.updateAvailable)

        // An older or unreadable latest never lowers the build's own.
        status.latestVersion = "0.1.0"
        XCTAssertEqual(status.offeredVersion, floor)
        XCTAssertFalse(status.updateAvailable)
        status.latestVersion = "junk"
        XCTAssertEqual(status.offeredVersion, floor)
    }

    func testTheStableChannelOnlyAsksUpToTheStableVersion() {
        let floor = NotifierPluginStatus.recommendedVersion
        var status = NotifierPluginStatus()
        status.state = .reported(version: "1.0.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: "1.0.0", restartNeeded: false, bootID: nil)
        status.latestVersion = "1.2.0"
        status.stableVersion = "1.0.0"
        XCTAssertTrue(status.updateRecommended, "every version on main by default")

        status.followsMain = false
        XCTAssertEqual(status.noticeVersion, "1.0.0")
        XCTAssertFalse(status.updateRecommended)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .none)
        XCTAssertFalse(status.needsAttention)
        // Settings still offers it, and it brings main.
        XCTAssertTrue(status.updateAvailable)
        XCTAssertEqual(status.offeredVersion, "1.2.0")

        status.stableVersion = "1.1.0"
        XCTAssertTrue(status.updateRecommended)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .update)

        // Never below the build's floor, never above what an update brings.
        status.stableVersion = "0.1.0"
        XCTAssertEqual(status.noticeVersion, floor)
        status.stableVersion = nil
        XCTAssertEqual(status.noticeVersion, floor)
        status.stableVersion = "9.0.0"
        XCTAssertEqual(status.noticeVersion, "1.2.0")

        // A missing feature still asks.
        status.stableVersion = "1.0.0"
        status.state = .reported(version: "1.0.0", capabilities: [])
        XCTAssertTrue(status.updateRecommended)
    }

    func testTheNoticeChannelFollowsWhereConduitCameFrom() {
        XCTAssertFalse(NotifierPluginNoticeChannel.automatic.followsMain(installedFrom: .appStore))
        XCTAssertTrue(NotifierPluginNoticeChannel.automatic.followsMain(installedFrom: .testFlight))
        XCTAssertTrue(NotifierPluginNoticeChannel.automatic.followsMain(installedFrom: .xcode))
        XCTAssertTrue(NotifierPluginNoticeChannel.everyVersion.followsMain(installedFrom: .appStore))
        XCTAssertFalse(NotifierPluginNoticeChannel.stableOnly.followsMain(installedFrom: .testFlight))
    }

    func testTheStableVersionIsReadFromChannelsYAML() {
        let read = NotifierPluginLatestVersion.stableVersion(fromChannelsYAML:)
        XCTAssertEqual(read("# comment\nstable: 0.50.1  # raised for 2.1\n"), "0.50.1")
        XCTAssertNil(read("version: 0.50.1\n"))
        XCTAssertNil(read("stable: main\n"))
    }

    func testTheLatestPluginVersionIsReadFromPluginYAML() {
        let read = NotifierPluginLatestVersion.version(fromPluginYAML:)
        XCTAssertEqual(read("name: conduit_push\nmanifest_version: 1\nversion: 0.44.0\n"), "0.44.0")
        XCTAssertEqual(read("version: \"0.44.1\"  # next\n"), "0.44.1")
        XCTAssertEqual(read("  version: 0.44.2\n"), "0.44.2")
        XCTAssertNil(read("manifest_version: 1\n"))
        XCTAssertNil(read("version: main\n"))
    }

    func testTheLatestPluginVersionIsAskedAtMostHourly() async throws {
        let suite = "plugin-latest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var asked = 0
        let fetch: (URL) async throws -> (Data, URLResponse) = { url in
            if url == NotifierPluginLatestVersion.url { asked += 1 }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            let text = url == NotifierPluginLatestVersion.channelsURL ? "stable: 0.48.0\n" : "version: 0.50.0\n"
            return (Data(text.utf8), response)
        }
        let start = Date()
        let first = await NotifierPluginLatestVersion.refresh(defaults: defaults, now: start, fetch: fetch)
        XCTAssertEqual(first, NotifierPluginLatestVersion.Answer(latest: "0.50.0", stable: "0.48.0"))
        XCTAssertEqual(NotifierPluginLatestVersion.cached(in: defaults), "0.50.0")
        XCTAssertEqual(NotifierPluginLatestVersion.cachedStable(in: defaults), "0.48.0")
        let soon = await NotifierPluginLatestVersion.refresh(defaults: defaults, now: start.addingTimeInterval(60), fetch: fetch)
        XCTAssertNil(soon)
        XCTAssertEqual(asked, 1)
        let later = await NotifierPluginLatestVersion.refresh(defaults: defaults, now: start.addingTimeInterval(3_700), fetch: fetch)
        XCTAssertEqual(later?.latest, "0.50.0")
        XCTAssertEqual(asked, 2)

        let missing: (URL) async throws -> (Data, URLResponse) = { url in
            if url == NotifierPluginLatestVersion.url { asked += 1 }
            return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)))
        }
        let failed = await NotifierPluginLatestVersion.refresh(defaults: defaults, now: start.addingTimeInterval(9_000), fetch: missing)
        XCTAssertEqual(failed, NotifierPluginLatestVersion.Answer(latest: nil, stable: nil))
        XCTAssertEqual(NotifierPluginLatestVersion.cached(in: defaults), "0.50.0")
        XCTAssertEqual(NotifierPluginLatestVersion.cachedStable(in: defaults), "0.48.0")
        // A failed ask waits the interval too.
        _ = await NotifierPluginLatestVersion.refresh(defaults: defaults, now: start.addingTimeInterval(9_060), fetch: missing)
        XCTAssertEqual(asked, 3)
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
