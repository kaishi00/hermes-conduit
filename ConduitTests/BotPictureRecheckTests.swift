//
//  BotPictureRecheckTests.swift
//  Conduit
//
//  Opening the profile picker downloaded every bot's picture again, one
//  after another, each time (issue 1967). It now asks for them all again
//  only once they're `botPictureRecheckInterval` old; a pull on the Bots
//  list always does.
//

import UIKit
import XCTest
@testable import Conduit

@MainActor
final class BotPictureRecheckTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BotPictureRecheckTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testOpeningTheProfilesSheetRereadsPicturesOnlyOnceTheyAreOld() async {
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let start = appState.botAvatarGeneration

        // The first open has never read them: every picture is asked for.
        await appState.refreshBotRosterAndStalePictures()
        XCTAssertEqual(appState.botAvatarGeneration, start &+ 1)
        let readAt = try? XCTUnwrap(appState.botAvatarsReloadedAt)

        // Opened again soon after: the roster only.
        await appState.refreshBotRosterAndStalePictures(now: (readAt ?? Date()).addingTimeInterval(60))
        XCTAssertEqual(appState.botAvatarGeneration, start &+ 1)

        // Once they're old, every picture again.
        await appState.refreshBotRosterAndStalePictures(
            now: (readAt ?? Date()).addingTimeInterval(AppState.botPictureRecheckInterval + 1)
        )
        XCTAssertEqual(appState.botAvatarGeneration, start &+ 2)
    }

    func testAPullOnTheBotsListAlwaysRereadsPictures() async {
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let start = appState.botAvatarGeneration
        await appState.reloadBotRoster()
        await appState.reloadBotRoster()
        XCTAssertEqual(appState.botAvatarGeneration, start &+ 2)
    }

    /// A dashboard switch downloaded every bot's picture again over the
    /// chat's socket, ahead of the chat's resume (3 to 6 s on Gridania). A
    /// picture fetched within the recheck interval, and since the last pull,
    /// is shown from the phone's copy instead.
    func testAPictureFetchedRecentlyAndSinceThePullIsFresh() {
        let fetchedAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(AppState.botPictureIsFresh(fetchedAt: fetchedAt, reloadedAt: nil, now: fetchedAt.addingTimeInterval(60)))
        XCTAssertFalse(AppState.botPictureIsFresh(
            fetchedAt: fetchedAt, reloadedAt: nil,
            now: fetchedAt.addingTimeInterval(AppState.botPictureRecheckInterval + 1)
        ), "old enough to ask again")
        XCTAssertFalse(AppState.botPictureIsFresh(
            fetchedAt: fetchedAt, reloadedAt: fetchedAt.addingTimeInterval(1),
            now: fetchedAt.addingTimeInterval(60)
        ), "a pull since asks for every picture again")
        XCTAssertTrue(AppState.botPictureIsFresh(
            fetchedAt: fetchedAt, reloadedAt: fetchedAt.addingTimeInterval(-1),
            now: fetchedAt.addingTimeInterval(60)
        ), "fetched after the pull")
    }

    /// A pull asks again for its own dashboard's pictures only: another
    /// dashboard's phone copies stay fresh for its next switch back.
    func testAPullOnOneDashboardLeavesAnothersPicturesFresh() async {
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let first = UUID(), second = UUID()
        appState.savedDashboardRegistry.activeDashboardID = first
        await appState.reloadBotRoster()
        XCTAssertNotNil(appState.botPicturesPulledAt[first])
        appState.savedDashboardRegistry.activeDashboardID = second
        XCTAssertNil(appState.botPicturesPulledAt[second], "the other dashboard's pull says nothing here")
    }

    /// The skip itself: a picture this dashboard sent a moment ago, kept on
    /// the phone, is shown with no download, and a pull on another
    /// dashboard in between doesn't change that. A pull on its own
    /// dashboard asks for it again.
    func testASwitchBackShowsAFreshPictureWithoutDownloadingIt() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotPictureRecheckTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let avatarsRoot = scratch.appendingPathComponent("profile-avatars", isDirectory: true)
        let store = ProfileAppearanceStore(defaults: defaults, avatarsRoot: avatarsRoot, legacyAvatarDirectories: [avatarsRoot])
        let appState = AppState(defaults: defaults, loadSavedConnection: false, profileAppearanceStore: store)
        let first = UUID(), second = UUID()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        _ = try appState.profileAppearanceStore.saveMirroredAvatar(png, for: "raiden", dashboardID: second)
        let raiden = BotProfile(name: "raiden", botTitle: nil, displayName: "Raiden", profileDescription: "", model: nil,
                                provider: nil, hasAvatar: true, isPinned: false, isHiddenByMeta: false,
                                appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil)

        appState.savedDashboardRegistry.activeDashboardID = second
        XCTAssertNotNil(appState.profileAvatarURLs["raiden"], "the switch loads that dashboard's copy")
        appState.botPictureFetchedAt[AppState.botPictureKey("raiden", dashboardID: second)] = Date()

        appState.savedDashboardRegistry.activeDashboardID = first
        await appState.reloadBotRoster()
        appState.savedDashboardRegistry.activeDashboardID = second
        XCTAssertTrue(appState.hasFreshBotPicture("raiden"), "a pull on the other dashboard leaves it fresh")
        // No client here: anything but the skip would have to download, and
        // can't, so it would answer false.
        let shown = await appState.loadBotAvatarIfNeeded(raiden)
        XCTAssertTrue(shown, "shown from the phone's copy")
        XCTAssertEqual(appState.botAvatarFetchedGeneration["raiden"], appState.botAvatarGeneration)

        await appState.reloadBotRoster()
        XCTAssertFalse(appState.hasFreshBotPicture("raiden"), "a pull here asks for it again")
        let shownAfterPull = await appState.loadBotAvatarIfNeeded(raiden)
        XCTAssertFalse(shownAfterPull, "it has to be downloaded now")
    }

    func testAPictureWithNoCopyOnThePhoneIsNeverFresh() {
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        XCTAssertFalse(appState.hasFreshBotPicture("furina"))
    }

    /// Pictures wait while the connection opens its chat, and not past the
    /// limit.
    func testPictureDownloadsWaitWhileTheChatOpensUpToTheLimit() async {
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.turnState = .synchronizing
        XCTAssertTrue(appState.isOpeningChat)
        let started = Date()
        await appState.waitWhileOpeningChat(limit: 0.3)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        appState.turnState = .idle
        XCTAssertFalse(appState.isOpeningChat)
    }
}
