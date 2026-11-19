import XCTest
@testable import Conduit

/// A bot's Conduit plugin (issue 2803): New Bot turns it on, Edit Bot offers
/// Turn On. An extension of BotModeTests: the unit suite is at its class cap.
extension BotModeTests {
    func testNewBotTurnsThePluginOnWhereTheDashboardsPluginCan() {
        let serves = NotifierPluginStatus(state: .reported(version: "0.181.0", capabilities: [BotPlugin.capability]))
        XCTAssertEqual(BotPlugin.newBotStep(plugin: serves, startsFresh: true), .turnOn)
        // A clone may come from a profile without it: asked as well.
        XCTAssertEqual(BotPlugin.newBotStep(plugin: serves, startsFresh: false), .turnOn)

        // An older plugin can't: only a fresh bot, which nothing else turns
        // it on for, is told to update.
        let older = NotifierPluginStatus(state: .reported(version: "0.179.2", capabilities: ["session-usage"]))
        XCTAssertEqual(BotPlugin.newBotStep(plugin: older, startsFresh: true), .askForUpdate)
        XCTAssertEqual(BotPlugin.newBotStep(plugin: older, startsFresh: false), .nothing)

        // Too old to report what it serves (or not installed) is older too.
        let tooOld = NotifierPluginStatus(state: .predatesCapabilities)
        XCTAssertEqual(BotPlugin.newBotStep(plugin: tooOld, startsFresh: true), .askForUpdate)
        XCTAssertEqual(BotPlugin.newBotStep(plugin: tooOld, startsFresh: false), .nothing)

        // Not reported yet: nothing here (the caller waits for the read).
        XCTAssertEqual(BotPlugin.newBotStep(plugin: NotifierPluginStatus(state: .unknown), startsFresh: true), .nothing)
    }

    func testNewBotNeverAsksForAnUpdateThatCantHelp() {
        // A host that keeps the plugin itself is asked by nobody to update.
        var managed = NotifierPluginStatus(state: .predatesCapabilities)
        managed.managedBy = "Hermes Cloud"
        XCTAssertEqual(BotPlugin.newBotStep(plugin: managed, startsFresh: true), .nothing)
        var managedOlder = NotifierPluginStatus(state: .reported(version: "0.179.2", capabilities: []))
        managedOlder.managedBy = ""
        XCTAssertEqual(BotPlugin.newBotStep(plugin: managedOlder, startsFresh: true), .nothing)

        // A new enough copy this dashboard doesn't run needs turning on
        // there, not an update.
        var notServed = NotifierPluginStatus(state: .predatesCapabilities)
        notServed.hostCopy = .notServed
        XCTAssertTrue(notServed.isNotServed)
        XCTAssertEqual(BotPlugin.newBotStep(plugin: notServed, startsFresh: true), .nothing)

        // An old copy on the host is still told to update.
        var oldCopy = NotifierPluginStatus(state: .predatesCapabilities)
        oldCopy.hostCopy = .old
        XCTAssertEqual(BotPlugin.newBotStep(plugin: oldCopy, startsFresh: true), .askForUpdate)
    }

    func testABotLeftWithThePluginAsMadeWarnsOnlyWhenItStartedFresh() {
        // Every path that leaves the plugin as it was made (Hermes changed
        // before or during the step, the dashboard's plugin never reported)
        // shares this one decision: a fresh bot is told where to turn it on,
        // a clone, which may have it already, stays quiet.
        let fresh = BotPlugin.leftAsMadeWarning(startsFresh: true)
        XCTAssertEqual(fresh, AppLocalization.string(
            "The Conduit plugin wasn't turned on for this bot. Edit the bot to turn it on.",
            table: .bots
        ))
        XCTAssertNil(BotPlugin.leftAsMadeWarning(startsFresh: false))
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
