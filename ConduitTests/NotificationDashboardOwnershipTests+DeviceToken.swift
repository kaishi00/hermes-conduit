//
//  NotificationDashboardOwnershipTests+DeviceToken.swift
//  Conduit
//
//  Conduit asks for its push token at every launch, and only a token the
//  relay doesn't have yet goes to it (notifier #119). An extension of the
//  ownership tests, which already swap in an in-memory Keychain: the test
//  planner needs no new entry.
//

import XCTest
@testable import Conduit

extension NotificationDashboardOwnershipTests {
    func testOnlyAPushTokenTheRelayDoesNotHaveGoesToIt() async throws {
        // Saved before the relay's token was recorded.
        let stored: [String: Any] = [
            "credential": "credential-1",
            "installationID": "installation-1",
            "relayURL": "https://relay.example.com",
            "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConduitNotificationPreferences())),
        ]
        KeychainHelper.savePushRegistration(try JSONSerialization.data(withJSONObject: stored))
        let service = PushNotificationService(retryDelay: .zero)

        var sent: [String?] = []
        service.sendRegistrationUpdate = { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            sent.append(body["device_token"] as? String)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"installation":{}}"#.utf8), response)
        }

        // The first launch after updating sends the token once.
        service.didReceiveDeviceToken(Data([0xab, 0xcd]))
        try await waitUntil { self.savedDeviceToken() == "abcd" }
        XCTAssertEqual(sent, ["abcd"])

        // The same token at the next launch sends nothing; a new one does.
        service.didReceiveDeviceToken(Data([0xab, 0xcd]))
        service.didReceiveDeviceToken(Data([0x12, 0x34]))
        // What the relay accepted is kept for the next launch.
        try await waitUntil { self.savedDeviceToken() == "1234" }
        XCTAssertEqual(sent, ["abcd", "1234"])
        XCTAssertNil(service.lastError)
    }

    private func savedDeviceToken() -> String? {
        guard let saved = KeychainHelper.loadPushRegistration(),
              let json = try? JSONSerialization.jsonObject(with: saved) as? [String: Any] else { return nil }
        return json["deviceToken"] as? String
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
