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
        defer { service.sendRegistrationUpdate = { _ in throw URLError(.cancelled) } }

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
    }

    func testAPushTokenTheRelayRefusesShowsInSettingsUntilItGoes() async throws {
        let stored: [String: Any] = [
            "credential": "credential-1",
            "installationID": "installation-1",
            "relayURL": "https://relay.example.com",
            "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConduitNotificationPreferences())),
        ]
        KeychainHelper.savePushRegistration(try JSONSerialization.data(withJSONObject: stored))
        let service = PushNotificationService(retryDelay: .zero)

        var status = 503
        var attempts = 0
        service.sendRegistrationUpdate = { request in
            attempts += 1
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(#"{"installation":{}}"#.utf8), response)
        }
        defer { service.sendRegistrationUpdate = { _ in throw URLError(.cancelled) } }

        service.didReceiveDeviceToken(Data([0xab, 0xcd]))
        try await waitUntil { service.lastError != nil }
        XCTAssertNil(savedDeviceToken(), "a refused token isn't recorded as accepted")

        // Coming back to the front delivers the same token again, and it goes.
        status = 200
        service.didReceiveDeviceToken(Data([0xab, 0xcd]))
        try await waitUntil { self.savedDeviceToken() == "abcd" && service.lastError == nil }
        XCTAssertEqual(attempts, 2)
    }

    func testAnyUpdateThatDeliversTheCurrentTokenClearsItsError() async throws {
        let stored: [String: Any] = [
            "credential": "credential-1",
            "installationID": "installation-1",
            "relayURL": "https://relay.example.com",
            "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConduitNotificationPreferences())),
        ]
        KeychainHelper.savePushRegistration(try JSONSerialization.data(withJSONObject: stored))
        let service = PushNotificationService(retryDelay: .zero)

        var status = 503
        service.sendRegistrationUpdate = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(#"{"installation":{}}"#.utf8), response)
        }
        defer { service.sendRegistrationUpdate = { _ in throw URLError(.cancelled) } }

        service.didReceiveDeviceToken(Data([0xab, 0xcd]))
        try await waitUntil { service.lastError != nil }

        // A call token change carries the current push token too.
        status = 200
        service.updateVoIPToken("voip-1")
        try await waitUntil { self.savedDeviceToken() == "abcd" && service.lastError == nil }
    }

    func testALaunchThatHasntHeardFromTheRelayKeepsItsLocationToken() async throws {
        // The relay holds the location push token from the last launch.
        let stored: [String: Any] = [
            "credential": "credential-1",
            "installationID": "installation-1",
            "relayURL": "https://relay.example.com",
            "deviceToken": "abcd",
            "locationToken": "10ca",
            "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConduitNotificationPreferences())),
        ]
        KeychainHelper.savePushRegistration(try JSONSerialization.data(withJSONObject: stored))
        let service = PushNotificationService(retryDelay: .zero)

        var bodies: [[String: Any]] = []
        service.sendRegistrationUpdate = { request in
            bodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]))
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"installation":{}}"#.utf8), response)
        }
        defer { service.sendRegistrationUpdate = { _ in throw URLError(.cancelled) } }

        // Before the relay's metadata arrives, background sharing hands over
        // the token and a new push token goes: the location token is left
        // out (kept), never cleared (notifier #287).
        service.updateLocationToken("10ca")
        service.didReceiveDeviceToken(Data([0x12, 0x34]))
        try await waitUntil { self.savedDeviceToken() == "1234" }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies[0].keys.contains("location_token"))
    }

    func testTheLocationTokenChangesOnlyOnceTheRelayIsKnown() {
        typealias Service = PushNotificationService
        XCTAssertEqual(Service.locationTokenChange(registered: "a", current: nil, relaySendsLocates: nil), .keep)
        XCTAssertEqual(Service.locationTokenChange(registered: nil, current: "a", relaySendsLocates: nil), .keep)
        XCTAssertEqual(Service.locationTokenChange(registered: nil, current: "a", relaySendsLocates: true), .set("a"))
        XCTAssertEqual(Service.locationTokenChange(registered: "a", current: "a", relaySendsLocates: true), .keep)
        XCTAssertEqual(Service.locationTokenChange(registered: "a", current: "b", relaySendsLocates: true), .set("b"))
        XCTAssertEqual(Service.locationTokenChange(registered: "a", current: nil, relaySendsLocates: true), .clear)
        XCTAssertEqual(Service.locationTokenChange(registered: "a", current: "a", relaySendsLocates: false), .clear)
        XCTAssertEqual(Service.locationTokenChange(registered: nil, current: "a", relaySendsLocates: false), .keep)
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
