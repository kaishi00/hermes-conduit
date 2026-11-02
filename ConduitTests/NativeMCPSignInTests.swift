import Foundation
import XCTest
@testable import Conduit

@MainActor
final class NativeMCPSignInTests: XCTestCase {
    private func started(redirect: String = "http://127.0.0.1:45678/callback") -> AnyCodable {
        var url = URLComponents(string: "https://provider.example/authorize")!
        url.queryItems = [URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "state", value: "expected")]
        return AnyCodable(["session_id": "flow", "auth_url": url.url!.absoluteString])
    }

    private func loopback(stopped: @escaping () -> Void = {}) -> NativeMCPSignIn.Loopback {
        NativeMCPSignIn.Loopback(
            start: { 45678 }, expect: { XCTAssertEqual($0, "expected") },
            callback: { "code=test-code&state=expected&iss=https%3A%2F%2Fprovider.example" }, stop: stopped
        )
    }

    func testConnectorsAndBotsRelayThePhoneRedirectOnTheCapturedProfileAndServer() async {
        var actions: [String] = []
        var opened = false
        var stopped = false
        let outcome = await NativeMCPSignIn.run(
            profile: "chosen-profile", name: "chosen-server", rpc: { action, params in
                actions.append(action)
                XCTAssertEqual(params["profile"] as? String, "chosen-profile")
                XCTAssertEqual(params["name"] as? String, "chosen-server")
                switch action {
                case "start":
                    XCTAssertEqual(params["client_redirect_uri"] as? String, "http://127.0.0.1:45678/callback")
                    return self.started()
                case "callback":
                    XCTAssertTrue(opened)
                    XCTAssertEqual(params["session_id"] as? String, "flow")
                    XCTAssertEqual(params["state"] as? String, "expected")
                    XCTAssertEqual(params["code"] as? String, "test-code")
                    XCTAssertEqual(params["iss"] as? String, "https://provider.example")
                    return AnyCodable(["ok": true])
                case "poll": return AnyCodable(["status": "approved"])
                default: XCTFail("Approved flow must not be cancelled"); return AnyCodable([:])
                }
            }, isCurrent: { true }, open: { _ in opened = true }, loopback: loopback(stopped: { stopped = true })
        )
        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(actions, ["start", "callback", "poll"])
        XCTAssertTrue(stopped)
    }

    func testHostRedirectIsNeverOpenedAndItsFlowIsCancelled() async {
        let cancelled = expectation(description: "flow cancelled on original transport")
        var stopped = false
        let outcome = await NativeMCPSignIn.run(
            profile: "original", name: "server", rpc: { action, params in
                if action == "start" { return self.started(redirect: "https://dashboard.example/callback") }
                XCTAssertEqual(action, "cancel")
                XCTAssertEqual(params["profile"] as? String, "original")
                XCTAssertEqual(params["session_id"] as? String, "flow")
                cancelled.fulfill()
                return AnyCodable(["ok": true])
            }, isCurrent: { true }, open: { _ in XCTFail("Wrong redirect must not open") },
            loopback: loopback(stopped: { stopped = true })
        )
        if case .failed = outcome {} else { XCTFail("Expected unsupported redirect failure") }
        XCTAssertTrue(stopped)
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testSwitchDuringAnyRPCDropsItsLateAnswerAndUsesOriginalTransportForCleanup() async {
        for switchedAt in ["start", "callback", "poll"] {
            let cancelled = expectation(description: "cancel after \(switchedAt)")
            var current = true
            var actions: [String] = []
            let outcome = await NativeMCPSignIn.run(
                profile: "original", name: "server", rpc: { action, params in
                    actions.append(action)
                    XCTAssertEqual(params["profile"] as? String, "original")
                    if action == "cancel" { cancelled.fulfill(); return AnyCodable(["ok": true]) }
                    if action == switchedAt { current = false }
                    if action == "start" { return self.started() }
                    return AnyCodable(["ok": true, "status": "approved"])
                }, isCurrent: { current }, open: { _ in
                    XCTAssertNotEqual(switchedAt, "start", "A late start must not open Safari")
                }, loopback: loopback()
            )
            XCTAssertEqual(outcome, .cancelled)
            await fulfillment(of: [cancelled], timeout: 2)
            XCTAssertEqual(actions.last, "cancel")
            if switchedAt == "start" { XCTAssertFalse(actions.contains("callback")) }
            if switchedAt == "callback" { XCTAssertFalse(actions.contains("poll")) }
        }
    }

    func testCancellationDuringStartReconcilesTheAcceptedHandle() async {
        let starting = expectation(description: "start accepted")
        let cancelled = expectation(description: "late handle cancelled")
        var reply: CheckedContinuation<Void, Never>?
        var stopped = false
        let task = Task {
            await NativeMCPSignIn.run(profile: "original", name: "server", rpc: { action, params in
                if action == "cancel" {
                    XCTAssertEqual(params["session_id"] as? String, "flow")
                    cancelled.fulfill()
                    return AnyCodable(["ok": true])
                }
                XCTAssertEqual(action, "start")
                await withCheckedContinuation { reply = $0; starting.fulfill() }
                // Mirrors the real RPC's cancellation check: the independently
                // owned start must survive the UI task's cancellation.
                try Task.checkCancellation()
                return self.started()
            }, isCurrent: { true }, open: { _ in XCTFail("Cancelled start must not open") },
               loopback: loopback(stopped: { stopped = true }))
        }
        await fulfillment(of: [starting], timeout: 2)
        task.cancel()
        reply?.resume()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(stopped)
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testTimeoutAndProviderFailureBothReleaseTheListenerAndFlow() async {
        for timesOut in [true, false] {
            let cancelled = expectation(description: "failed flow cancelled")
            var stopped = false
            let outcome = await NativeMCPSignIn.run(profile: "original", name: "server", rpc: { action, _ in
                switch action {
                case "start": return self.started()
                case "callback": return AnyCodable(["ok": false, "error_message": "Access denied"])
                case "cancel": cancelled.fulfill(); return AnyCodable(["ok": true])
                default: XCTFail("Failed callback must not poll"); return AnyCodable([:])
                }
            }, isCurrent: { true }, open: { _ in }, loopback: NativeMCPSignIn.Loopback(
                start: { 45678 }, expect: { _ in }, callback: {
                    if timesOut { throw NativeOAuthError.timedOut }
                    return "error=access_denied&state=expected"
                }, stop: { stopped = true }
            ))
            if case .failed = outcome {} else { XCTFail("Expected failure") }
            XCTAssertTrue(stopped)
            await fulfillment(of: [cancelled], timeout: 2)
        }
    }

    /// A failed poll is tried again and a success resets the count; three
    /// in a row end the sign-in and cancel Hermes' flow.
    func testAPollThatFailsIsRetriedUntilThreeFailInARow() async {
        for failuresBeforeAnswer in [1, 3] {
            var polls = 0
            let cancelled = failuresBeforeAnswer < BotMcpSetup.pollFailureLimit ? nil : expectation(description: "flow cancelled")
            let outcome = await NativeMCPSignIn.run(profile: "original", name: "server", rpc: { action, _ in
                switch action {
                case "start": return self.started()
                case "callback": return AnyCodable(["ok": true])
                case "poll":
                    polls += 1
                    if polls <= failuresBeforeAnswer { throw URLError(.timedOut) }
                    return AnyCodable(["status": "approved"])
                case "cancel": cancelled?.fulfill(); return AnyCodable(["ok": true])
                default: XCTFail("Unexpected \(action)"); return AnyCodable([:])
                }
            }, isCurrent: { true }, open: { _ in }, loopback: loopback())
            if failuresBeforeAnswer < BotMcpSetup.pollFailureLimit {
                if case .signedIn = outcome {} else { XCTFail("One failed poll is retried, got \(outcome)") }
                XCTAssertEqual(polls, 2)
            } else {
                if case .failed = outcome {} else { XCTFail("Three failed polls end it, got \(outcome)") }
                XCTAssertEqual(polls, 3, "no poll after the third failure")
                if let cancelled { await fulfillment(of: [cancelled], timeout: 2) }
            }
        }
    }

    func testRealPhoneListenerRejectsWrongStateThenRelaysTheValidCallback() async {
        let browserReturned = expectation(description: "browser callback returned")
        var browserTask: Task<Void, Never>?
        let outcome = await NativeMCPSignIn.run(profile: "original", name: "server", rpc: { action, params in
            switch action {
            case "start":
                return self.started(redirect: params["client_redirect_uri"] as! String)
            case "callback":
                XCTAssertEqual(params["code"] as? String, "test-code")
                XCTAssertEqual(params["state"] as? String, "expected")
                return AnyCodable(["ok": true])
            case "poll": return AnyCodable(["status": "approved"])
            default: XCTFail("Unexpected cancel"); return AnyCodable([:])
            }
        }, isCurrent: { true }, open: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = items.first { $0.name == "redirect_uri" }!.value!
            browserTask = Task {
                defer { browserReturned.fulfill() }
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                do {
                    let wrong = URL(string: redirect + "?code=bad&state=wrong")!
                    let (_, rejected) = try await session.data(from: wrong)
                    XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
                    let valid = URL(string: redirect + "?code=test-code&state=expected")!
                    let (_, accepted) = try await session.data(from: valid)
                    XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
                } catch { XCTFail("Local callback failed: \(error)") }
            }
        })
        XCTAssertEqual(outcome, .signedIn)
        await fulfillment(of: [browserReturned], timeout: 2)
        await browserTask?.value
    }

    func testCancellationWhileWaitingStopsListenerAndCancelsOnlyItsFlow() async {
        let waiting = expectation(description: "waiting for callback")
        let cancelled = expectation(description: "backend flow cancelled")
        var stopped = false
        let task = Task {
            await NativeMCPSignIn.run(profile: "original", name: "server", rpc: { action, _ in
                if action == "cancel" { cancelled.fulfill(); return AnyCodable(["ok": true]) }
                XCTAssertEqual(action, "start")
                return self.started()
            }, isCurrent: { true }, open: { _ in }, loopback: NativeMCPSignIn.Loopback(
                start: { 45678 }, expect: { _ in }, callback: {
                    waiting.fulfill()
                    try await Task.sleep(for: .seconds(30))
                    return ""
                }, stop: { stopped = true }
            ))
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(stopped)
        await fulfillment(of: [cancelled], timeout: 2)
    }
}
