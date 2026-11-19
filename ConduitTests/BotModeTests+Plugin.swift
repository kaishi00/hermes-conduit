import XCTest
@testable import Conduit

/// A bot's Conduit plugin (issue 2803): New Bot turns it on, Edit Bot offers
/// Turn On. An extension of BotModeTests: the unit suite is at its class cap.
extension BotModeTests {
    func testNewBotTurnsThePluginOnWhereTheDashboardsPluginCan() {
        let serves = NotifierPluginStatus.State.reported(version: "0.181.0", capabilities: [BotPlugin.capability])
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
        XCTAssertEqual(off?.offersTurnOn, true)
        XCTAssertEqual(BotPlugin.State(response: ["on": true, "can_turn_on": true])?.offersTurnOn, false)
        // A dashboard running a profile's own copy can't share it.
        XCTAssertEqual(BotPlugin.State(response: ["on": false, "can_turn_on": false])?.offersTurnOn, false)
        // An answer that doesn't say whether it's on is no answer.
        XCTAssertNil(BotPlugin.State(response: [:]))
        XCTAssertNil(BotPlugin.State(response: ["can_turn_on": true]))
    }

    func testTheBotPluginRouteNamesTheBotAndNoProfile() {
        XCTAssertEqual(BotPlugin.route(profile: "furina"), "/api/plugins/conduit_push/profiles/plugin?name=furina")
        XCTAssertEqual(BotPlugin.route(profile: "a&b"), "/api/plugins/conduit_push/profiles/plugin?name=a%26b")
    }

    func testNewBotTellsTheHostStepsWhereTheDashboardCantTurnItOn() {
        XCTAssertEqual(BotPlugin.stateStep(BotPlugin.State(on: false, canTurnOn: false)), .hostSteps)
        XCTAssertEqual(BotPlugin.stateStep(BotPlugin.State(on: true, canTurnOn: false)), .leave)
        XCTAssertEqual(BotPlugin.stateStep(BotPlugin.State(on: true, canTurnOn: true)), .leave)
        XCTAssertEqual(BotPlugin.stateStep(BotPlugin.State(on: false, canTurnOn: true)), .turnOn)
        // A read that failed is tried by turning it on.
        XCTAssertEqual(BotPlugin.stateStep(nil), .turnOn)
        XCTAssertEqual(
            DashboardTicketBridgeError.pluginOffOnHost(plugin: "conduit_push", profile: "furina"),
            "Hermes has the conduit_push plugin turned off for the “furina” profile. On the Hermes host, add conduit_push to plugins.enabled in that profile's config.yaml (and take it out of plugins.disabled), then restart Hermes."
        )
    }
}
