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
}
