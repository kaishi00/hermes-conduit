import XCTest
@testable import Conduit

/// A bot's Conduit plugin (issue 2803): New Bot turns it on, Edit Bot offers
/// Turn On. An extension of BotModeTests: the unit suite is at its class cap.
extension BotModeTests {
    func testNewBotTurnsThePluginOnWhereTheDashboardsPluginCan() {
        let serves = NotifierPluginStatus.State.reported(version: "0.180.0", capabilities: [BotPlugin.capability])
        XCTAssertEqual(BotPlugin.newBotStep(plugin: serves, startsFresh: true), .turnOn)
        // A clone may come from a profile without it: asked as well.
        XCTAssertEqual(BotPlugin.newBotStep(plugin: serves, startsFresh: false), .turnOn)

        // An older plugin can't: only a fresh bot, which nothing else turns
        // it on for, is told to update.
        let older = NotifierPluginStatus.State.reported(version: "0.179.2", capabilities: ["session-usage"])
        XCTAssertEqual(BotPlugin.newBotStep(plugin: older, startsFresh: true), .askForUpdate)
        XCTAssertEqual(BotPlugin.newBotStep(plugin: older, startsFresh: false), .nothing)

        // Not reported yet, or too old to report (or not installed): nothing here.
        XCTAssertEqual(BotPlugin.newBotStep(plugin: .unknown, startsFresh: true), .nothing)
        XCTAssertEqual(BotPlugin.newBotStep(plugin: .predatesCapabilities, startsFresh: true), .nothing)
    }

    func testEditBotOffersTurnOnOnlyForABotWithThePluginOffThatTheDashboardCanHelp() {
        let off = BotPlugin.State(response: ["profile": "furina", "on": false, "allowed": false, "linked": false,
                                             "can_turn_on": true])
        XCTAssertEqual(off, BotPlugin.State(on: false, canTurnOn: true))
        XCTAssertTrue(off.offersTurnOn)
        XCTAssertFalse(BotPlugin.State(response: ["on": true, "can_turn_on": true]).offersTurnOn)
        // A dashboard running a profile's own copy can't share it.
        XCTAssertFalse(BotPlugin.State(response: ["on": false, "can_turn_on": false]).offersTurnOn)
        // A malformed answer offers nothing.
        XCTAssertFalse(BotPlugin.State(response: [:]).offersTurnOn)
    }

    func testTheBotPluginRouteNamesTheBotAndNoProfile() {
        XCTAssertEqual(BotPlugin.route(profile: "furina"), "/api/plugins/conduit_push/profiles/plugin?name=furina")
        XCTAssertEqual(BotPlugin.route(profile: "a&b"), "/api/plugins/conduit_push/profiles/plugin?name=a%26b")
    }
}
