//
//  NotificationDashboardOwnershipTests.swift
//  Conduit
//
//  Push/relay dashboard ownership (#148 / B3): the collision matrix that
//  keeps a push from dashboard A from ever acting against active dashboard
//  B. Covers the pure ownership resolution, the APNs payload's dashboard_id
//  parsing (valid, absent, and malformed), and the fail-closed integration
//  through AppState.openNotificationTarget.
//

import XCTest
@testable import Conduit

@MainActor
final class NotificationDashboardOwnershipTests: XCTestCase {

    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var backend: InMemoryKeychainBackend!

    override func setUp() {
        super.setUp()
        defaultsSuite = "NotificationDashboardOwnershipTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
    }

    override func tearDown() {
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    // MARK: - Ownership matrix (pure)

    private let dashboardA = UUID()
    private let dashboardB = UUID()

    private func resolve(
        _ target: UUID?,
        malformed: Bool = false,
        active: UUID?,
        saved: [UUID]
    ) -> NotificationDashboardOwnership.Outcome {
        NotificationDashboardOwnership.resolve(
            targetDashboardID: target,
            hasMalformedDashboardID: malformed,
            activeDashboardID: active,
            savedDashboardIDs: saved
        )
    }

    func testPushFromActiveDashboardRoutes() {
        XCTAssertEqual(
            resolve(dashboardA, active: dashboardA, saved: [dashboardA, dashboardB]),
            .route
        )
    }

    func testPushFromKnownOtherDashboardSwitchesFirst() {
        XCTAssertEqual(
            resolve(dashboardB, active: dashboardA, saved: [dashboardA, dashboardB]),
            .switchFirst(dashboardID: dashboardB)
        )
    }

    func testPushFromUnknownDashboardFailsClosed() {
        let unknown = UUID()
        XCTAssertEqual(
            resolve(unknown, active: dashboardA, saved: [dashboardA, dashboardB]),
            .failClosed(.unrecognizedDashboard)
        )
    }

    func testMalformedDashboardIdentityFailsClosed() {
        XCTAssertEqual(
            resolve(nil, malformed: true, active: dashboardA, saved: [dashboardA]),
            .failClosed(.unrecognizedDashboard)
        )
    }

    func testLegacyUnscopedPushRoutesWithAtMostOneSavedDashboard() {
        XCTAssertEqual(resolve(nil, active: dashboardA, saved: [dashboardA]), .route)
        XCTAssertEqual(resolve(nil, active: nil, saved: []), .route)
    }

    func testLegacyUnscopedPushFailsClosedWithMultipleDashboards() {
        XCTAssertEqual(
            resolve(nil, active: dashboardA, saved: [dashboardA, dashboardB]),
            .failClosed(.unscopedPush)
        )
    }

    func testUnscopedPushFailsClosedEvenWhenActiveIsNil() {
        // "Do not guess based on current active dashboard" holds when nothing
        // is active either: several saved dashboards, no ownership evidence.
        XCTAssertEqual(
            resolve(nil, active: nil, saved: [dashboardA, dashboardB]),
            .failClosed(.unscopedPush)
        )
    }

    func testKnownDashboardSwitchesFirstWhenNothingIsActive() {
        XCTAssertEqual(
            resolve(dashboardA, active: nil, saved: [dashboardA, dashboardB]),
            .switchFirst(dashboardID: dashboardA)
        )
    }

    // MARK: - Payload parsing

    private func parsePayload(_ payload: [String: Any]) -> ConduitNotificationTarget? {
        PushNotificationService.parseNotificationTarget(
            from: ["conduit": payload]
        )
    }

    private func routingPayload(dashboardID: Any?) -> [String: Any] {
        var payload: [String: Any] = [
            "session_id": "runtime-1",
            "type": "response.ready",
        ]
        if let dashboardID { payload["dashboard_id"] = dashboardID }
        return payload
    }

    func testPayloadWithValidDashboardIDParsesUUID() throws {
        let target = try XCTUnwrap(parsePayload(routingPayload(dashboardID: dashboardA.uuidString)))
        XCTAssertEqual(target.dashboardID, dashboardA)
        XCTAssertFalse(target.hasMalformedDashboardID)
    }

    func testPayloadWithoutDashboardIDIsUnscoped() throws {
        let target = try XCTUnwrap(parsePayload(routingPayload(dashboardID: nil)))
        XCTAssertNil(target.dashboardID)
        XCTAssertFalse(target.hasMalformedDashboardID)
    }

    func testPayloadWithMalformedDashboardIDIsMarkedUnrecognized() throws {
        let target = try XCTUnwrap(parsePayload(routingPayload(dashboardID: "not-a-uuid")))
        XCTAssertNil(target.dashboardID)
        XCTAssertTrue(target.hasMalformedDashboardID)
    }

    func testDashboardIDReadsFromNestedRoutingStubToo() throws {
        let payload: [String: Any] = [
            "session_id": "runtime-1",
            "dashboard_id": dashboardB.uuidString,
        ]
        let direct = PushNotificationService.parseNotificationTarget(from: ["conduit": payload])
        let nested = PushNotificationService.parseNotificationTarget(from: ["body": ["conduit": payload]])
        XCTAssertEqual(direct?.dashboardID, dashboardB)
        XCTAssertEqual(nested?.dashboardID, dashboardB)
    }

    // MARK: - Fail-closed integration

    private func makeAppState(registry: SavedDashboardRegistry) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    private func decisionTarget(dashboardID: UUID?, malformed: Bool = false) -> ConduitNotificationTarget {
        ConduitNotificationTarget(
            profile: "default",
            sessionId: "runtime-1",
            dashboardID: dashboardID,
            hasMalformedDashboardID: malformed,
            type: "approval.needed",
            decision: .approval(sessionKey: "default", description: "Run?", choices: ["once"])
        )
    }

    func testOpenNotificationTargetFailsClosedForUnknownDashboardWithoutRecording() async {
        let saved = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [saved]))
        appState.messages = []

        let opened = await appState.openNotificationTarget(decisionTarget(dashboardID: UUID()))

        XCTAssertFalse(opened)
        XCTAssertNotNil(appState.errorMessage)
        // The decision card was never recorded into any dashboard's state.
        XCTAssertTrue(appState.messages.isEmpty)
        XCTAssertFalse(appState.isConnected)
    }

    func testOpenNotificationTargetFailsClosedForUnscopedPushWithMultipleDashboards() async {
        let savedA = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let savedB = SavedDashboard(id: dashboardB, label: "VPS", normalizedURL: "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [savedA, savedB]))

        let opened = await appState.openNotificationTarget(decisionTarget(dashboardID: nil))

        XCTAssertFalse(opened)
        XCTAssertNotNil(appState.errorMessage)
        XCTAssertEqual(appState.activeDashboardID, dashboardA, "The active dashboard must not change on a fail-closed push")
    }

    func testOpenNotificationTargetFailsClosedForMalformedDashboardID() async {
        let saved = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [saved]))

        let opened = await appState.openNotificationTarget(decisionTarget(dashboardID: nil, malformed: true))

        XCTAssertFalse(opened)
        XCTAssertNotNil(appState.errorMessage)
    }

    /// #789: a push that can never open here is final, so the route doesn't
    /// retry it and repeat the error.
    func testUnknownDashboardOpenIsFinal() async {
        let saved = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [saved]))

        let outcome = await appState.openNotificationTargetOutcome(decisionTarget(dashboardID: UUID()))

        XCTAssertEqual(outcome, .failed)
    }

    /// #789: a switch that ends on the sign-in screen waits on the user, so
    /// the route doesn't retry it.
    func testSwitchThatNeedsSignInIsFinal() async {
        let savedA = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let savedB = SavedDashboard(id: dashboardB, label: "VPS", normalizedURL: "https://hermes.example.com")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [savedA, savedB]))

        let outcome = await appState.openNotificationTargetOutcome(decisionTarget(dashboardID: dashboardB))

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(appState.showLogin)
        XCTAssertNotNil(appState.errorMessage)
    }

    /// #789: a push for the dashboard on screen that fails only because the
    /// connection isn't up yet is retried once it is.
    func testActiveDashboardOpenWithoutConnectionIsRetried() async {
        let saved = SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [saved]))

        let outcome = await appState.openNotificationTargetOutcome(decisionTarget(dashboardID: dashboardA))

        XCTAssertEqual(outcome, .retry)
        XCTAssertNil(appState.errorMessage)
    }
}

// MARK: - Relay gateway discriminator (decision routing)

extension NotificationDashboardOwnershipTests {

    private func payloadFor(
        dashboard: UUID,
        gateway: String,
        requestID: String
    ) -> [String: Any] {
        [
            "session_id": "default",
            "profile": "default",
            "dashboard_id": dashboard.uuidString,
            "gateway_id": gateway,
            "type": "input.needed",
            "decision": [
                "kind": "clarify",
                "request_id": requestID,
                "question": "Which?",
                "choices": ["Red", "Blue"],
            ],
        ]
    }

    func testIdenticalRequestIDsOnTwoDashboardsRetainTheirOwnDiscriminators() throws {
        // One relay, two gateways (GA->dashboard A, GB->dashboard B), both
        // dashboards using profile/session "default" and minting the SAME
        // plugin request id: each pushed card must retain and echo ITS OWN
        // gateway discriminator.
        let service = PushNotificationService()
        let gatewayA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let gatewayB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let requestID = PendingDecisionPayload.relayRequestPrefix + "same-request"

        let pushA = parsePayload(payloadFor(dashboard: dashboardA, gateway: gatewayA, requestID: requestID))
        let pushB = parsePayload(payloadFor(dashboard: dashboardB, gateway: gatewayB, requestID: requestID))
        let targetA = try XCTUnwrap(pushA)
        let targetB = try XCTUnwrap(pushB)

        // Distinct targets (never collapse into one navigation identity)...
        XCTAssertNotEqual(targetA.id, targetB.id)
        XCTAssertEqual(targetA.dashboardID, dashboardA)
        XCTAssertEqual(targetB.dashboardID, dashboardB)
        // ...and each retains its own discriminator for the SAME request id.
        XCTAssertEqual(targetA.relayGatewayID, gatewayA)
        XCTAssertEqual(targetB.relayGatewayID, gatewayB)

        // Receiving A's push retains A's discriminator for the shared id.
        service.receiveNotificationPayload(["conduit": payloadFor(dashboard: dashboardA, gateway: gatewayA, requestID: requestID)])
        XCTAssertEqual(service.relayGatewayID(forRequestID: requestID), gatewayA)
        // Receiving B's push afterwards retargets the retention to B: the
        // most recently RECEIVED push for a request id owns the echo. A's
        // answer came first in the matrix, so ordering is user-driven; the
        // discriminator always matches the card the user last received.
        service.receiveNotificationPayload(["conduit": payloadFor(dashboard: dashboardB, gateway: gatewayB, requestID: requestID)])
        XCTAssertEqual(service.relayGatewayID(forRequestID: requestID), gatewayB)
    }

    func testRespondBodyEchoesDiscriminatorAndQuestionScoping() {
        // Discriminator + batch question scoping land in the wire body...
        let full = PushNotificationService.respondBody(
            requestID: "conduit-push-x",
            answer: "Red",
            questionID: "q0",
            relayGatewayID: "gw-A"
        )
        XCTAssertEqual(full, ["answer": "Red", "question_id": "q0", "gateway_id": "gw-A"])

        // ...and a legacy-shaped answer (no discriminator, no qid) keeps the
        // exact pre-discriminator body.
        let legacy = PushNotificationService.respondBody(
            requestID: "conduit-push-x",
            answer: "Red",
            questionID: nil,
            relayGatewayID: nil
        )
        XCTAssertEqual(legacy, ["answer": "Red"])
    }

    func testApprovalDecisionsNeverRetainARelayDiscriminator() {
        // Approvals answer through the gateway's approval.respond directly;
        // a relay discriminator must never be recorded for them.
        let service = PushNotificationService()
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "default",
                "gateway_id": "gw-A",
                "type": "approval.needed",
                "decision": [
                    "kind": "approval",
                    "session_key": "default",
                    "description": "Run?",
                    "choices": ["once"],
                ],
            ]
        ])
        XCTAssertNil(service.relayGatewayID(forRequestID: "anything"))
    }
}

// MARK: - The active dashboard's own relay gateways

/// A push whose relay gateway the active dashboard's host reported belongs
/// to that dashboard, even when its pairing was bound to another saved
/// entry (or one since removed). Switching away tore down the working
/// connection and left the other entry asking to sign in, so a Hermes call
/// answered in the background ended at "dashboard check".
extension NotificationDashboardOwnershipTests {

    private func resolve(
        _ target: UUID?,
        gateway: String?,
        known: Set<String>,
        malformed: Bool = false,
        active: UUID?,
        saved: [UUID]
    ) -> NotificationDashboardOwnership.Outcome {
        NotificationDashboardOwnership.resolve(
            targetDashboardID: target,
            hasMalformedDashboardID: malformed,
            activeDashboardID: active,
            savedDashboardIDs: saved,
            targetGatewayID: gateway,
            activeDashboardGatewayIDs: known
        )
    }

    func testPushFromActiveHostsGatewayRoutesWhateverDashboardItWasBoundTo() {
        // Bound to another saved entry for the same host.
        XCTAssertEqual(
            resolve(dashboardB, gateway: "gw-1", known: ["gw-1"], active: dashboardA, saved: [dashboardA, dashboardB]),
            .route
        )
        // Bound to an entry since removed.
        XCTAssertEqual(
            resolve(UUID(), gateway: "gw-1", known: ["gw-1"], active: dashboardA, saved: [dashboardA]),
            .route
        )
        // Paired before dashboard scoping, with two saved.
        XCTAssertEqual(
            resolve(nil, gateway: "gw-1", known: ["gw-1"], active: dashboardA, saved: [dashboardA, dashboardB]),
            .route
        )
    }

    func testPushFromAnotherGatewayKeepsTheOwnershipRule() {
        XCTAssertEqual(
            resolve(dashboardB, gateway: "gw-2", known: ["gw-1"], active: dashboardA, saved: [dashboardA, dashboardB]),
            .switchFirst(dashboardID: dashboardB)
        )
        XCTAssertEqual(
            resolve(dashboardB, gateway: nil, known: ["gw-1"], active: dashboardA, saved: [dashboardA, dashboardB]),
            .switchFirst(dashboardID: dashboardB)
        )
        // A malformed binding still fails closed, and with nothing active
        // there is no host that reported anything.
        XCTAssertEqual(
            resolve(nil, gateway: "gw-1", known: ["gw-1"], malformed: true, active: dashboardA, saved: [dashboardA]),
            .failClosed(.unrecognizedDashboard)
        )
        XCTAssertEqual(
            resolve(dashboardB, gateway: "gw-1", known: ["gw-1"], active: nil, saved: [dashboardA, dashboardB]),
            .switchFirst(dashboardID: dashboardB)
        )
    }

    func testOpenFromActiveHostsGatewayStaysOnTheActiveDashboard() async {
        let savedA = SavedDashboard(id: dashboardA, label: "VPS", normalizedURL: "https://vps.tailnet.ts.net")
        let savedB = SavedDashboard(id: dashboardB, label: "VPS (old)", normalizedURL: "http://100.64.0.7:9119")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [savedA, savedB]))
        appState.recordRelayGatewayID("gw-1", for: dashboardA, profile: "default")
        let target = ConduitNotificationTarget(
            profile: "default",
            sessionId: "runtime-1",
            dashboardID: dashboardB,
            relayGatewayID: "gw-1",
            type: "call.requested"
        )

        let outcome = await appState.openNotificationTargetOutcome(target)

        // Routed here: only the connection isn't up in this test. A switch
        // to the other entry would end `.failed` on its sign-in, with an
        // error (testSwitchThatNeedsSignInIsFinal).
        XCTAssertEqual(outcome, .retry)
        XCTAssertEqual(appState.activeDashboardID, dashboardA)
        XCTAssertNil(appState.errorMessage)
    }

    func testPulseQuietForTodayIsOwnedAsATapOnThePushIs() {
        let savedA = SavedDashboard(id: dashboardA, label: "VPS", normalizedURL: "https://vps.tailnet.ts.net")
        let savedB = SavedDashboard(id: dashboardB, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [savedA, savedB]))
        appState.recordRelayGatewayID("gw-1", for: dashboardA, profile: "default")
        appState.recordRelayGatewayID("gw-2", for: dashboardB, profile: "default")
        // The host in use, by its gateway, whatever dashboard the pairing was bound to.
        XCTAssertEqual(appState.pulseQuietOwnership(PulseQuietTarget(dashboardID: dashboardB.uuidString, gatewayID: "gw-1")),
                       .route)
        // Another saved dashboard's push switches to it first, which only a tap with Conduit open does.
        XCTAssertEqual(appState.pulseQuietOwnership(PulseQuietTarget(dashboardID: dashboardB.uuidString, gatewayID: "gw-2")),
                       .switchFirst(dashboardID: dashboardB))
        // A dashboard no longer saved, or a push Conduit couldn't place with two saved: nothing goes quiet.
        XCTAssertEqual(appState.pulseQuietOwnership(PulseQuietTarget(dashboardID: UUID().uuidString, gatewayID: "gw-9")),
                       .failClosed(.unrecognizedDashboard))
        XCTAssertEqual(appState.pulseQuietOwnership(nil), .failClosed(.unscopedPush))
        // The gateways a saved dashboard still pairs through: the extension offers the button for no other.
        XCTAssertEqual(appState.knownRelayGatewayIDs, ["gw-1", "gw-2"])
        appState.removeDashboard(dashboardB)
        XCTAssertEqual(appState.knownRelayGatewayIDs, ["gw-1"])
    }

    func testPulseQuietForTodayRetryDuringACallStaysAndSaysWhy() async {
        let savedA = SavedDashboard(id: dashboardA, label: "VPS", normalizedURL: "https://vps.tailnet.ts.net")
        let savedB = SavedDashboard(id: dashboardB, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [savedA, savedB]))
        appState.recordRelayGatewayID("gw-1", for: dashboardA, profile: "default")
        appState.recordRelayGatewayID("gw-2", for: dashboardB, profile: "default")
        appState.showVoiceSheet = true

        // Another saved dashboard's push, retried with Conduit open: a call keeps
        // Conduit where it is, as a tap on the push does, and says so.
        let quieted = await appState.quietPulseForToday(PulseQuietTarget(dashboardID: dashboardB.uuidString, gatewayID: "gw-2"),
                                                        switching: true, wait: .zero)

        XCTAssertFalse(quieted)
        XCTAssertEqual(appState.activeDashboardID, dashboardA)
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("End the call to quiet Pulse in another workspace."))
        XCTAssertTrue(appState.isVoiceCallInProgress)
    }

    func testRelayGatewayIDsAreKeptPerDashboardAndForgottenWithIt() {
        let savedA = SavedDashboard(id: dashboardA, label: "VPS", normalizedURL: "https://vps.tailnet.ts.net")
        let savedB = SavedDashboard(id: dashboardB, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [savedA, savedB]))

        appState.recordRelayGatewayID("gw-1", for: dashboardA, profile: "default")
        appState.recordRelayGatewayID("gw-1", for: dashboardA, profile: "default")
        appState.recordRelayGatewayID(" gw-2 ", for: dashboardA, profile: "work")
        appState.recordRelayGatewayID("", for: dashboardA, profile: "default")
        appState.recordRelayGatewayID("gw-3", for: dashboardB, profile: "default")

        XCTAssertEqual(appState.activeDashboardRelayGatewayIDs, ["gw-1", "gw-2"])
        XCTAssertEqual(appState.relayGatewayIDs(of: dashboardB), ["gw-3"])

        // A profile paired again (or a new host at the address) replaces
        // its old gateway rather than adding to it.
        appState.recordRelayGatewayID("gw-4", for: dashboardA, profile: "default")
        XCTAssertEqual(appState.activeDashboardRelayGatewayIDs, ["gw-4", "gw-2"])

        // A profile the host no longer pairs with this iPhone drops its id.
        appState.forgetRelayGatewayID(for: dashboardA, profile: "work")
        XCTAssertEqual(appState.activeDashboardRelayGatewayIDs, ["gw-4"])

        appState.removeDashboard(dashboardB)
        XCTAssertTrue(appState.relayGatewayIDs(of: dashboardB).isEmpty)
        XCTAssertEqual(appState.relayGatewayIDs(of: dashboardA), ["gw-4"])
    }

    func testSettingsListsTheActiveHostsPairingAsThisDashboards() {
        let pairing = RelayMetaInfo.Gateway(
            id: "gw-1", name: "VPS", pluginVersion: "0.53.1", pluginCapabilities: [],
            lastEventAt: nil, dashboardID: dashboardB.uuidString
        )
        let pairings = NotificationDashboardPairings(
            gateways: [pairing],
            activeDashboardID: dashboardA,
            savedDashboardIDs: [dashboardA, dashboardB],
            activeDashboardGatewayIDs: ["gw-1"]
        )
        XCTAssertEqual(pairings.thisDashboard.map(\.id), ["gw-1"])
        XCTAssertEqual(pairings.otherDashboardsCount, 0)
    }
}

extension NotificationDashboardOwnershipTests {
    func testRelayGatewayIDsAreForgottenWhenTheDashboardMoves() {
        var moving = SavedDashboard(id: dashboardA, label: "VPS", normalizedURL: "https://vps.tailnet.ts.net")
        moving.pendingURL = "https://other.tailnet.ts.net"
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [moving]))
        appState.recordRelayGatewayID("gw-1", for: dashboardA, profile: "default")

        appState.settlePendingDashboardMove(dashboardA)

        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: dashboardA)?.normalizedURL, "https://other.tailnet.ts.net")
        XCTAssertTrue(appState.relayGatewayIDs(of: dashboardA).isEmpty)
    }
}

extension NotificationDashboardOwnershipTests {
    func testRelayGatewayIDsAreForgottenOnSignOut() {
        let savedA = SavedDashboard(id: dashboardA, label: "VPS", normalizedURL: "https://vps.tailnet.ts.net")
        let savedB = SavedDashboard(id: dashboardB, label: "Mac", normalizedURL: "https://mac.tailnet.ts.net")
        let appState = makeAppState(registry: SavedDashboardRegistry(activeDashboardID: dashboardA, dashboards: [savedA, savedB]))
        appState.recordRelayGatewayID("gw-1", for: dashboardA, profile: "default")
        appState.recordRelayGatewayID("gw-2", for: dashboardB, profile: "default")

        appState.signOutDashboard(dashboardB)

        XCTAssertTrue(appState.relayGatewayIDs(of: dashboardB).isEmpty)
        XCTAssertEqual(appState.relayGatewayIDs(of: dashboardA), ["gw-1"])
    }
}
