//
//  NotificationDashboardOwnershipTests+PreferenceSync.swift
//  Conduit
//
//  Notification preference changes reach the relay one after another, so
//  the copy the relay keeps is always the newest (PushNotificationService),
//  and a relay that takes room invites gets their switch (Linked Rooms).
//  An extension of the ownership tests, which already swap in an in-memory
//  Keychain: the test planner needs no new entry.
//

import XCTest
@testable import Conduit

extension NotificationDashboardOwnershipTests {
    func testQuickPreferenceTogglesLeaveTheRelayWithTheNewestPreferences() async throws {
        let stored: [String: Any] = [
            "credential": "credential-1",
            "installationID": "installation-1",
            "relayURL": "https://relay.example.com",
            "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConduitNotificationPreferences())),
        ]
        KeychainHelper.savePushRegistration(try JSONSerialization.data(withJSONObject: stored))
        let service = PushNotificationService(retryDelay: .zero)
        XCTAssertTrue(service.isEnabled)

        // The relay keeps whichever update it handles last; each one waits
        // until the test lets the relay answer.
        var relay: ConduitNotificationPreferences?
        var inFlight = 0
        var overlapped = false
        var held: [CheckedContinuation<Void, Never>] = []
        service.sendRegistrationUpdate = { request in
            inFlight += 1
            overlapped = overlapped || inFlight > 1
            defer { inFlight -= 1 }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let sent = try JSONDecoder().decode(
                ConduitNotificationPreferences.self,
                from: JSONSerialization.data(withJSONObject: body["preferences"] ?? [:])
            )
            await withCheckedContinuation { held.append($0) }
            relay = sent
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"installation":{}}"#.utf8), response)
        }

        // Two switches flipped in quick succession, as the Settings toggles do.
        let first = Task { await service.setPreference(\.decisionCards, enabled: false) }
        while held.isEmpty { await Task.yield() }
        let second = Task { await service.setPreference(\.responseReady, enabled: false) }
        for _ in 0..<50 { await Task.yield() }
        var done = false
        Task {
            await first.value
            await second.value
            done = true
        }
        // The relay answers the newest request it holds first.
        while !done {
            if !held.isEmpty { held.removeLast().resume() }
            await Task.yield()
        }

        XCTAssertFalse(overlapped, "one update reaches the relay at a time")
        XCTAssertEqual(relay?.decisionCards, false)
        XCTAssertEqual(relay?.responseReady, false, "the relay ends on the newest preferences")
        XCTAssertEqual(relay, service.preferences)
        XCTAssertNil(service.lastError)
    }

    /// Invites to rooms from people you've linked (Linked Rooms): on here,
    /// while the relay keeps them off until a Conduit that shows them turns
    /// them on (relay 0.21).
    func testRoomInvitePreferenceIsOnByDefault() throws {
        XCTAssertTrue(ConduitNotificationPreferences().roomInvite)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ConduitNotificationPreferences())) as? [String: Any])
        XCTAssertEqual(encoded["room_invite"] as? Bool, true, "it goes to the relay with the rest")
        // Stored by a build before it: on.
        let older = try JSONDecoder().decode(ConduitNotificationPreferences.self, from: Data(#"{"enabled":true,"response_ready":false}"#.utf8))
        XCTAssertTrue(older.roomInvite)
        XCTAssertFalse(older.responseReady)
        let off = try JSONDecoder().decode(ConduitNotificationPreferences.self, from: Data(#"{"room_invite":false}"#.utf8))
        XCTAssertFalse(off.roomInvite)
    }

    /// A phone registered before Conduit showed invites has none at the
    /// relay, which counts as off: once the relay takes invites, an update
    /// goes until the relay's answer keeps the key.
    func testAnUpdateGoesOnceTheRelayTakesInvitesUntilItKeepsTheKey() async throws {
        let takes = ["decisions", "room-invites"]
        XCTAssertTrue(PushNotificationService.resendsRoomInvite(relayCapabilities: takes, relayKeepsRoomInvite: nil),
                      "registered before this build")
        XCTAssertTrue(PushNotificationService.resendsRoomInvite(relayCapabilities: takes, relayKeepsRoomInvite: false))
        XCTAssertFalse(PushNotificationService.resendsRoomInvite(relayCapabilities: takes, relayKeepsRoomInvite: true))
        // A relay before 0.21 drops the key and doesn't take invites:
        // nothing goes again until it's updated.
        XCTAssertFalse(PushNotificationService.resendsRoomInvite(relayCapabilities: ["decisions"], relayKeepsRoomInvite: false))
        XCTAssertFalse(PushNotificationService.resendsRoomInvite(relayCapabilities: nil, relayKeepsRoomInvite: nil),
                       "the relay not heard from yet")

        func keeps(_ json: String) -> Bool { PushNotificationService.relayKeepsRoomInvite(Data(json.utf8)) }
        XCTAssertTrue(keeps(#"{"installation":{"preferences":{"room_invite":true}}}"#))
        XCTAssertTrue(keeps(#"{"installation":{"preferences":{"room_invite":false}}}"#), "kept, whichever way it's set")
        XCTAssertFalse(keeps(#"{"installation":{"preferences":{"response_ready":true}}}"#))
        XCTAssertFalse(keeps(#"{"installation":{}}"#))
        XCTAssertFalse(keeps("not json"))

        // The registration remembers what the relay's answer kept.
        let stored: [String: Any] = [
            "credential": "credential-1",
            "installationID": "installation-1",
            "relayURL": "https://relay.example.com",
            "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConduitNotificationPreferences())),
        ]
        KeychainHelper.savePushRegistration(try JSONSerialization.data(withJSONObject: stored))
        let service = PushNotificationService(retryDelay: .zero)
        var sent: [String: Any]?
        service.sendRegistrationUpdate = { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            sent = body["preferences"] as? [String: Any]
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"installation":{"preferences":{"room_invite":true}}}"#.utf8), response)
        }
        await service.setPreference(\.decisionCards, enabled: false)
        XCTAssertEqual(sent?["room_invite"] as? Bool, true)
        XCTAssertNil(service.lastError)
        let saved = try XCTUnwrap(KeychainHelper.loadPushRegistration())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(json["relayKeepsRoomInvite"] as? Bool, true)
    }
}
