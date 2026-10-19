//
//  NotificationDashboardOwnershipTests+PreferenceSync.swift
//  Conduit
//
//  Notification preference changes reach the relay one after another, so
//  the copy the relay keeps is always the newest (PushNotificationService).
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
}
