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
