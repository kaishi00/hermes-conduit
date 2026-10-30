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
        status.archivedVersion = nil
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

    func testNeverAsksOnlyToFinishARestart() {
        var status = NotifierPluginStatus()
        status.state = .reported(version: "9.0.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: "9.0.0", restartNeeded: false, bootID: nil)
        status.latestVersion = "9.2.0"
        status.stableVersion = "9.1.0"
        status.followsMain = NotifierPluginNoticeChannel.never.followsMain
        status.asksToUpdate = NotifierPluginNoticeChannel.never.asksToUpdate
        // Newer and stable versions ask nothing anywhere.
        XCTAssertFalse(status.updateRecommended)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .none)
        XCTAssertFalse(status.needsAttention)
        XCTAssertEqual(FinishSetupStatus.plugin(status, updating: false), .done)
        XCTAssertEqual(FinishSetupStatus.pluginDoneNote(status), .newerVersionWaits)
        // Settings still offers the latest.
        XCTAssertTrue(status.updateAvailable)
        XCTAssertEqual(status.offeredVersion, "9.2.0")

        // Neither does a missing feature; Settings shows it.
        status.state = .reported(version: "9.0.0", capabilities: [])
        XCTAssertTrue(status.needsUpdate)
        XCTAssertFalse(status.updateRecommended)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .none)
        XCTAssertTrue(status.updateAvailable)
        XCTAssertEqual(FinishSetupStatus.pluginDoneNote(status), .featuresWait)

        // Nor a plugin below this build's floor.
        status.state = .reported(version: "0.1.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: "0.1.0", restartNeeded: false, bootID: nil)
        XCTAssertFalse(status.updateRecommended)
        XCTAssertTrue(status.updateAvailable)
        XCTAssertEqual(status.noticeDismissalVersion, status.noticeVersion)

        // An update waiting for its restart is still finished from the
        // notice, and "Not now" on it belongs to the version on disk, so
        // the next update's restart asks again.
        status.state = .reported(version: "9.2.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: "9.0.0", restartNeeded: true, bootID: nil)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .restart)
        XCTAssertTrue(status.needsAttention)
        XCTAssertEqual(status.noticeDismissalVersion, "9.2.0")
        status.state = .reported(version: "9.3.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        XCTAssertEqual(status.noticeDismissalVersion, "9.3.0")

        // A plugin too old to report anything isn't asked about either.
        status.state = .predatesCapabilities
        status.runtime = nil
        status.hostCopy = .old
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .none)
        XCTAssertFalse(status.needsAttention)

        // Installing isn't updating: a missing plugin is still offered.
        status.hostCopy = .missing
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .install)
        XCTAssertTrue(status.needsAttention)
    }

    func testNotNowKeepsOtherDashboardsDismissals() throws {
        let suite = "GatewayRestartTests.dismissals.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let other = "\(UUID().uuidString)|0.48.0"
        let this = appState.activeDashboardID?.uuidString ?? ""
        appState.dismissedPluginUpdates = [other, "\(this)|0.1.0"]
        appState.dismissNotifierPluginUpdateNotice()
        // This dashboard's older one goes; the other dashboard's stays.
        let version = appState.notifierPlugin.noticeDismissalVersion
        XCTAssertEqual(appState.dismissedPluginUpdates, [other, "\(this)|\(version)"])
    }

    func testNeverShowsOnlyARestartUntilNotNow() throws {
        let suite = "GatewayRestartTests.neverNotice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.setNotifierPluginNoticeChannel(.never)
        XCTAssertFalse(appState.notifierPlugin.asksToUpdate)
        // Running what's on disk: nothing asks.
        appState.applyNotifierPluginReport(Self.capabilities(loaded: "0.63.0", disk: "0.63.0", boot: "a"))
        XCTAssertFalse(appState.showsNotifierPluginUpdateNotice)
        // An update on disk waits for its restart: the notice asks, until Not now.
        appState.applyNotifierPluginReport(Self.capabilities(loaded: "0.63.0", disk: "0.64.0", boot: "a"))
        XCTAssertTrue(appState.showsNotifierPluginUpdateNotice)
        appState.dismissNotifierPluginUpdateNotice()
        XCTAssertFalse(appState.showsNotifierPluginUpdateNotice)
        // The next update's restart asks again.
        appState.applyNotifierPluginReport(Self.capabilities(loaded: "0.63.0", disk: "0.65.0", boot: "a"))
        XCTAssertTrue(appState.showsNotifierPluginUpdateNotice)
    }

    func testTheSavedNoticeChoiceHoldsFromLaunch() throws {
        let suite = "GatewayRestartTests.noticeChannel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(NotifierPluginNoticeChannel.never.rawValue, forKey: NotifierPluginNoticeChannel.key)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        // Before any refresh has read where Conduit came from.
        XCTAssertEqual(appState.notifierPluginNoticeChannel, .never)
        XCTAssertFalse(appState.notifierPlugin.asksToUpdate)
        XCTAssertFalse(appState.notifierPlugin.followsMain)
    }

    func testOtherNoticeChoicesKeepTheirFinishSetupText() {
        var status = NotifierPluginStatus()
        status.state = .reported(version: "9.1.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: "9.1.0", restartNeeded: false, bootID: nil)
        status.latestVersion = "9.2.0"
        status.stableVersion = "9.1.0"
        status.archivedVersion = nil
        status.followsMain = false
        // Stable versions only: a newer plugin on main waits unasked, and
        // the row still reads as up to date, as before Never.
        XCTAssertTrue(status.updateAvailable)
        XCTAssertEqual(FinishSetupStatus.plugin(status, updating: false), .done)
        XCTAssertEqual(FinishSetupStatus.pluginDoneNote(status), .upToDate)
        XCTAssertEqual(status.noticeDismissalVersion, status.noticeVersion)

        // A restart's "Not now" belongs to the version on disk here too, so
        // a later update's restart asks again.
        status.state = .reported(version: "9.2.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: "9.1.0", restartNeeded: true, bootID: nil)
        XCTAssertEqual(status.noticeOffer(finishSetupOffersInstall: false), .restart)
        XCTAssertEqual(status.noticeDismissalVersion, "9.2.0")
        status.state = .reported(version: "9.3.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        XCTAssertEqual(status.noticeDismissalVersion, "9.3.0")
    }

    func testAnAppStoreBuildAsksUpToThePluginItWasArchivedWith() {
        var status = NotifierPluginStatus()
        status.state = .reported(version: "1.0.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: "1.0.0", restartNeeded: false, bootID: nil)
        status.latestVersion = "1.3.0"
        status.followsMain = false
        status.archivedVersion = "1.1.0"
        status.stableVersion = "0.51.6"
        // An old stable line doesn't hold back what the build was cut with.
        XCTAssertEqual(status.noticeVersion, "1.1.0")
        XCTAssertTrue(status.updateRecommended)

        // channels.yaml can raise it between builds.
        status.stableVersion = "1.2.0"
        XCTAssertEqual(status.noticeVersion, "1.2.0")

        // GitHub out of reach: the archived version still stands.
        status.stableVersion = nil
        status.latestVersion = nil
        XCTAssertEqual(status.offeredVersion, "1.1.0")
        XCTAssertEqual(status.noticeVersion, "1.1.0")
        XCTAssertTrue(status.updateRecommended)

        // Up to date with the archive: no notice.
        status.stableVersion = nil
        status.state = .reported(version: "1.1.0", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.runtime = NotifierPluginStatus.Runtime(loadedVersion: "1.1.0", restartNeeded: false, bootID: nil)
        XCTAssertFalse(status.updateRecommended)
    }

    func testStableVersionsOnlyIsTheDefault() throws {
        let suite = "GatewayRestartTests.defaultChannel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NotifierPluginNoticeChannel.load(from: defaults), .stableOnly)
        // Automatic, which asked TestFlight builds for every version, is gone:
        // whoever had it saved hears about stable versions now.
        defaults.set("automatic", forKey: NotifierPluginNoticeChannel.key)
        XCTAssertEqual(NotifierPluginNoticeChannel.load(from: defaults), .stableOnly)
        defaults.set(NotifierPluginNoticeChannel.everyVersion.rawValue, forKey: NotifierPluginNoticeChannel.key)
        XCTAssertEqual(NotifierPluginNoticeChannel.load(from: defaults), .everyVersion)
    }

    func testOnlyEveryNewVersionFollowsMain() {
        XCTAssertTrue(NotifierPluginNoticeChannel.everyVersion.followsMain)
        XCTAssertFalse(NotifierPluginNoticeChannel.stableOnly.followsMain)
        XCTAssertFalse(NotifierPluginNoticeChannel.never.followsMain)
        XCTAssertFalse(NotifierPluginNoticeChannel.never.asksToUpdate)
        XCTAssertTrue(NotifierPluginNoticeChannel.stableOnly.asksToUpdate)
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

    /// A failure the plugin's report contradicts reads as done: the gateway
    /// restart can take the dashboard, and the job it ran, down with it.
    func testASettledOutcomeBecomesTheUpdateButARunningOneStays() {
        let dashboard = UUID()
        var slot = NotifierPluginUpdateSlot()
        let run = slot.start(on: dashboard)
        slot.settle(as: .updated(version: "0.69.0"))
        XCTAssertEqual(slot.state(on: dashboard), .updating(.downloading))
        slot.finish(.failed(detail: "The plugin is updated, but the gateway didn't restart."), run: run, activeDashboardID: dashboard)
        slot.settle(as: .updated(version: "0.69.0"))
        XCTAssertEqual(slot.state(on: dashboard), .updated(version: "0.69.0"))
        slot.dismiss()
        slot.settle(as: .updated(version: "0.69.0"))
        XCTAssertEqual(slot.state(on: dashboard), .idle)
    }

    func testProgressCountsStepsAndTimesTheRun() {
        XCTAssertEqual(NotifierPluginUpdateStep.downloading.number, 1)
        XCTAssertEqual(NotifierPluginUpdateStep.installing.number, 1)
        XCTAssertEqual(NotifierPluginUpdateStep.restartingGateway(nil).number, 2)
        XCTAssertEqual(NotifierPluginUpdateStep.waitingForChats(count: 2).number, 3)
        XCTAssertEqual(NotifierPluginUpdateStep.restartingDashboard.number, 3)
        // Reconnecting after the host finished is the last step.
        XCTAssertEqual(NotifierPluginUpdateStep.reconnecting.number, NotifierPluginUpdateStep.count)
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
    /// The host-run update (plugin 0.63+): the job answers in order, the
    /// last one repeating, or the error the start answers with.
    var selfUpdateJobs: [[String: Any]] = []
    var selfUpdateStartError: Error?
    var selfUpdatePaths: [String] = []
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
        if path.hasPrefix(NotifierPluginUpdater.selfUpdatePath) {
            selfUpdatePaths.append(path)
            if method == "POST", let selfUpdateStartError { throw selfUpdateStartError }
            guard let first = selfUpdateJobs.first else { throw DashboardTicketBridgeError.http(status: 404, detail: "Not Found") }
            if selfUpdateJobs.count > 1 { selfUpdateJobs.removeFirst() }
            return ["ok": true, "job": first]
        }
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

/// What each plugin version brings (NotifierPluginChangelog.swift) and the
/// update the host runs on its own (plugin 0.63+).
@MainActor
extension GatewayRestartTests {
    private static let changelog = """
    # Conduit plugin changelog

    - `## <version> (<YYYY-MM-DD>)`: the version.
      ### Fixes is not a heading here.

    ## 0.63.0 (2026-10-23)

    ### New and improved
    - The host runs the whole update,
      and notifies.

    ## 0.62.0 (2026-10-22)

    ### Security
    - Room turns stay out of memory.

    ## 0.61.3 (2026-10-22)

    ### Fixes
    - Pulse reads keys in scope.

    ### New and improved
    - Something new.
    """

    func testTheChangelogIsReadWithWrappedLines() throws {
        let log = try XCTUnwrap(NotifierPluginChangelog(markdown: Self.changelog))
        XCTAssertEqual(log.entries.map(\.version), ["0.63.0", "0.62.0", "0.61.3"])
        XCTAssertEqual(log.entries[0].changes.map(\.text), ["The host runs the whole update, and notifies."])
        XCTAssertEqual(log.entries[2].changes.map(\.kind), [.fixes, .new])
        let day = try XCTUnwrap(log.released("0.62.0"))
        XCTAssertEqual(day, Date(timeIntervalSince1970: 1_792_627_200))
        XCTAssertNil(NotifierPluginChangelog(markdown: "version: 0.50.0\n"))
    }

    func testAnUpdateShowsSecurityFixesFirstFromAfterTheInstalledVersion() throws {
        let log = try XCTUnwrap(NotifierPluginChangelog(markdown: Self.changelog))
        let changes = log.updateChanges(after: "0.61.3", through: "0.63.0")
        XCTAssertEqual(changes.map(\.version), ["0.62.0", "0.63.0"])
        XCTAssertEqual(changes.first?.kind, .security)
        XCTAssertEqual(log.updateChanges(after: nil, through: "0.62.0").map(\.kind), [.security, .fixes, .new])
        XCTAssertTrue(log.updateChanges(after: "0.63.0", through: "0.63.0").isEmpty)

        var status = NotifierPluginStatus()
        status.state = .reported(version: "0.61.3", capabilities: Set(NotifierPluginStatus.usedCapabilities))
        status.latestVersion = "0.63.0"
        let notes = try XCTUnwrap(NotifierPluginReleaseNotes(changelog: log, status: status))
        XCTAssertEqual(notes.version, "0.63.0")
        XCTAssertTrue(notes.hasSecurityFixes)
        XCTAssertNotNil(notes.released)
        XCTAssertNil(NotifierPluginReleaseNotes(changelog: nil, status: status))
    }

    func testTheHostRunsTheUpdateAndConduitFollowsIt() async {
        let host = PluginHost()
        host.selfUpdateJobs = [
            ["id": "j1", "step": "downloading"],
            ["id": "j1", "step": "waiting_for_chats", "running_chats": 2],
            ["id": "j1", "step": "restarting_dashboard"],
            ["id": "j1", "step": "done", "loaded_version": "0.63.0"],
        ]
        host.capabilities = [Self.capabilities(loaded: "0.63.0", disk: "0.63.0", boot: "new")]
        var updater = host.updater()
        updater.onHost = true
        updater.profile = "coder"
        var reports: [[String: Any]] = []
        updater.report = { reports.append($0) }
        var steps: [NotifierPluginUpdateState] = []
        let outcome = await updater.run { steps.append($0) }
        XCTAssertEqual(outcome, .updated(version: "0.63.0"))
        XCTAssertTrue(steps.contains(.updating(.waitingForChats(count: 2))))
        XCTAssertTrue(steps.contains(.updating(.restartingDashboard)))
        // Nothing run from here: the host did it.
        XCTAssertFalse(host.calls.contains("POST \(NotifierPluginUpdater.updatePath)"))
        XCTAssertFalse(host.calls.contains("POST \(GatewayRestarter.restartPath)"))
        XCTAssertTrue(host.selfUpdatePaths.allSatisfy { $0.contains("profile=coder") })
        XCTAssertGreaterThan(host.selfUpdatePaths.count, 1)
        XCTAssertEqual(reports.count, 1)
    }

    func testAHostThatCantRunTheUpdateLeavesTheStepsToConduit() async {
        let host = PluginHost()
        host.selfUpdateStartError = DashboardTicketBridgeError.http(status: 501, detail: "This Hermes can't run the plugin update on its own")
        host.capabilities = [
            Self.capabilities(loaded: "0.62.0", disk: "0.63.0", boot: "old"),
            Self.capabilities(loaded: "0.63.0", disk: "0.63.0", boot: "new"),
        ]
        var updater = host.updater()
        updater.onHost = true
        let outcome = await updater.run { _ in }
        XCTAssertEqual(outcome, .updated(version: "0.63.0"))
        XCTAssertTrue(host.calls.contains("POST \(NotifierPluginUpdater.updatePath)"))
    }

    func testAHostThatCantPullThisPluginLeavesTheReinstallToConduit() async {
        let host = PluginHost()
        host.selfUpdateJobs = [["id": "j1", "step": "failed", "failed_step": "downloading",
                                "detail": "Plugin 'conduit_push' has no owned Git checkout; reinstall from its source."]]
        host.updateError = DashboardTicketBridgeError.http(status: 400, detail: "Plugin 'conduit_push' has no owned Git checkout; reinstall from its source.")
        host.capabilities = [
            Self.capabilities(loaded: "0.62.0", disk: "0.63.0", boot: "old"),
            Self.capabilities(loaded: "0.63.0", disk: "0.63.0", boot: "new"),
        ]
        var updater = host.updater()
        updater.onHost = true
        let outcome = await updater.run { _ in }
        XCTAssertEqual(outcome, .updated(version: "0.63.0"))
        XCTAssertTrue(host.calls.contains("POST \(NotifierPluginUpdater.installPath)"))
    }

    func testConduitStopsFollowingALongHostUpdateWithoutCallingItFailed() async {
        let host = PluginHost()
        host.selfUpdateJobs = [["id": "j1", "step": "waiting_for_chats", "running_chats": 1]]
        var updater = host.updater()
        updater.onHost = true
        updater.sleep = { [unowned host] _ in host.clock += 120 }
        let outcome = await updater.run { _ in }
        XCTAssertEqual(outcome, .runningOnHost)
    }

    func testAStartWhoseAnswerIsLostFollowsTheJobInsteadOfUpdatingTwice() async {
        let host = PluginHost()
        host.selfUpdateStartError = URLError(.timedOut)
        host.selfUpdateJobs = [
            ["id": "j1", "step": "restarting_gateway"],
            ["id": "j1", "step": "done", "loaded_version": "0.63.0"],
        ]
        host.capabilities = [Self.capabilities(loaded: "0.63.0", disk: "0.63.0", boot: "new")]
        var updater = host.updater()
        updater.onHost = true
        let outcome = await updater.run { _ in }
        XCTAssertEqual(outcome, .updated(version: "0.63.0"))
        XCTAssertFalse(host.calls.contains("POST \(NotifierPluginUpdater.updatePath)"))
    }

    /// #299: the new plugin's report replaces the status at once, and a
    /// status read already asked of the old plugin lands under it.
    func testTheUpdatedPluginsReportWinsOverAStatusReadInFlight() {
        let suite = "PluginUpdate.AppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        // A read of the old plugin starts.
        appState.notifierPluginStatusGeneration += 1
        let inFlight = appState.notifierPluginStatusGeneration
        appState.applyNotifierPluginReport(Self.capabilities(loaded: "0.63.0", disk: "0.63.0", boot: "new"))
        XCTAssertEqual(appState.notifierPlugin.runningVersion, "0.63.0")
        XCTAssertFalse(appState.notifierPlugin.restartPending)
        // refreshNotifierPluginStatus drops an answer whose generation isn't newer.
        XCTAssertLessThanOrEqual(inFlight, appState.notifierPluginStatusAcceptedGeneration)
    }

    func testAHostJobThatFailsAfterThePullDoesntRunTheStepsAgain() async {
        let host = PluginHost()
        host.selfUpdateJobs = [["id": "j1", "step": "failed", "failed_step": "restarting_gateway",
                                "detail": "Gateway restart: unit not found"]]
        host.capabilities = [Self.capabilities(loaded: "0.62.0", disk: "0.63.0", boot: "old")]
        var updater = host.updater()
        updater.onHost = true
        let outcome = await updater.run { _ in }
        XCTAssertEqual(outcome, .failed(detail: "Gateway restart: unit not found"))
        XCTAssertFalse(host.calls.contains("POST \(NotifierPluginUpdater.updatePath)"))
        XCTAssertFalse(host.calls.contains("POST \(NotifierPluginUpdater.installPath)"))
    }

    func testHostJobOutcomes() {
        XCTAssertNil(NotifierPluginUpdater.hostOutcome(["step": "restarting_gateway"]))
        XCTAssertEqual(NotifierPluginUpdater.hostStep(["step": "restarting_gateway"]), .restartingGateway(nil))
        XCTAssertEqual(NotifierPluginUpdater.hostOutcome(["step": "failed", "detail": "no"]), .failed(detail: "no"))
        XCTAssertEqual(NotifierPluginUpdater.hostOutcome(["step": "failed", "code": "restart_needed", "detail": "Restart it"]),
                       .needsDashboardRestart(detail: "Restart it"))
        XCTAssertEqual(NotifierPluginUpdater.hostOutcome(["step": "done", "version": "0.63.0"]), .updated(version: "0.63.0"))
    }
}
