//
//  BotPictureRecheckTests.swift
//  Conduit
//
//  Opening the profile picker downloaded every bot's picture again, one
//  after another, each time (issue 1967). It now asks for them all again
//  only once they're `botPictureRecheckInterval` old; a pull on the Bots
//  list always does.
//

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
