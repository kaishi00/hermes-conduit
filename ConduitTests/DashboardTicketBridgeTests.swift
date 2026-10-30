import XCTest
@testable import Conduit

@MainActor
final class DashboardTicketBridgeTests: XCTestCase {

    func testInvalidatingPendingRequestsResumesThemWithNotReady() async {
        let requests = DashboardTicketBridgePendingRequests()
        let bridge = DashboardTicketBridge(
            baseURL: "https://example.com",
            pendingRequests: requests
        )
        let requestRegistered = expectation(description: "pending request registered")
        let resultTask = Task { @MainActor in
            do {
                _ = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<[String: Any], Error>) in
                    requests.insert(continuation, for: 1)
                    requestRegistered.fulfill()
                }
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }

        // A cap, not a timing: it returns as soon as the request registers.
        // Creating the bridge's web view can stall the main actor past 1s.
        await fulfillment(of: [requestRegistered], timeout: 10.0)
        bridge.invalidate()

        switch await resultTask.value {
        case .success:
            XCTFail("Invalidation must resume pending requests with an error")
        case .failure(let error as DashboardTicketBridgeError):
            if case .notReady = error {
                // expected
            } else {
                XCTFail("Expected .notReady, got \(error)")
            }
        case .failure(let error):
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }
        XCTAssertEqual(requests.count, 0)
    }

    /// A bridge whose dashboard page load keeps failing (e.g. launch during
    /// a network outage) must keep re-attempting the page load while minting
    /// and, on exhaustion, surface `.notReady` — never a misleading
    /// `.signInRequired`, which would sign the user out of a valid session.
    /// The failed landing is simulated (WKWebView's failure callbacks are
    /// not deterministically drivable in the unit test host) and persists
    /// across reloads, modeling a dashboard that stays unreachable.
    func testColdBridgeMintTicketRetriesReloadAndSurfacesNotReady() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1", // nothing listens: load cannot succeed
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.simulateLandingForTesting(.loadFailure)

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw on a cold bridge")
        } catch DashboardTicketBridgeError.notReady {
            // expected
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }

        // Every attempt must re-attempt the terminally failed page load; the
        // original wedge (no reload at all) would leave this at zero.
        XCTAssertEqual(bridge.reloadCount, 3)
    }

    /// A page whose load failed while the socket stayed open (a request that
    /// stalled across a Wi-Fi change) must be reloaded by the next dashboard
    /// request, not only by a ticket mint: an open socket mints none, so
    /// history and status reads were refused in a fraction of a second until
    /// the app quit (#1412).
    func testRequestOnAFailedPageReloadsIt() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.webViewCanRun = { true }
        bridge.webViewWebContentProcessDidTerminate(bridge.webView)
        XCTAssertTrue(bridge.isLoadFailed)

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions")
            XCTFail("Expected requestJSON to throw while the reloaded page loads")
        } catch DashboardTicketBridgeError.notReady {
            // expected: nothing listens, so the fresh load can't finish
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }

        XCTAssertEqual(bridge.reloadCount, 1, "The request must reload the failed page")
    }

    /// Requests that meet the same failed page together reload it once: the
    /// first reload clears the failure before any of them waits.
    func testConcurrentRequestsOnAFailedPageReloadItOnce() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.webViewCanRun = { true }
        // Let the initial load settle first: it starts after the bridge's
        // cookie restore, and starting it clears the failure modeled below.
        for _ in 0..<80 where !bridge.isLoadFailed {
            try? await Task.sleep(for: .milliseconds(25))
        }
        bridge.webViewWebContentProcessDidTerminate(bridge.webView)

        let first = Task { @MainActor in _ = try? await bridge.requestJSON(path: "/api/sessions") }
        let second = Task { @MainActor in _ = try? await bridge.requestJSON(path: "/api/status") }
        await first.value
        await second.value

        // A fresh load that fails inside the poll window can be reloaded by
        // a later request, never by these two together.
        XCTAssertEqual(bridge.reloadCount, 1)
    }

    /// A load still in flight is polled, never restarted by a request: on a
    /// degraded link it may be about to finish.
    func testRequestLeavesALoadInFlightAlone() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.webViewCanRun = { true }
        XCTAssertFalse(bridge.isLoadFailed)

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions")
            XCTFail("Expected requestJSON to throw before the page is ready")
        } catch {
            // notReady, or the initial load's own failure on hosts where it
            // lands inside the poll window
        }

        XCTAssertEqual(bridge.reloadCount, 0)
    }

    /// A bridge parked on the dashboard's login page must route minting to
    /// the signInRequired recovery: each retry reloads the page (the cookie-
    /// race recovery round 4 accidentally disabled) rather than blind-
    /// re-POSTing, exhaustion surfaces `.signInRequired` (never a misleading
    /// `.notReady`), and no ticket is ever minted against a logged-out
    /// session. The simulation persists across reloads, modeling a session
    /// that is genuinely gone.
    func testMintTicketReloadsForSimulatedLoginLanding() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.simulateLandingForTesting(.loginPage)

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against a login-parked bridge")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected on exhaustion
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.signInRequired, got \(error)")
        }

        // Both retries must reload the page; the round-4 regression would
        // leave this at zero.
        XCTAssertEqual(bridge.reloadCount, 2)
    }

    /// iOS reclaims the bridge's web content process under memory pressure —
    /// typically while the app is suspended overnight. The termination
    /// callback must mark the bridge cold-but-reloadable so the next mint
    /// revives the page instead of awaiting a JavaScript response that can
    /// never arrive (the overnight stuck-reconnecting wedge).
    func testWebContentTerminationMarksBridgeReloadableAndMintRetries() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )

        bridge.webViewWebContentProcessDidTerminate(bridge.webView)
        XCTAssertTrue(bridge.isLoadFailed, "Termination must make the bridge reloadable")

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against a terminated web process")
        } catch DashboardTicketBridgeError.notReady {
            // expected
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }

        // The .notReady recovery must reload the dead page.
        XCTAssertGreaterThanOrEqual(bridge.reloadCount, 1)
    }

    /// A requestJSON awaiting a JavaScript response when the content process
    /// dies must be resumed with .notReady — not left pending forever.
    func testWebContentTerminationResumesPendingRequestAsNotReady() async {
        let requests = DashboardTicketBridgePendingRequests()
        let bridge = DashboardTicketBridge(
            baseURL: "https://example.com",
            pendingRequests: requests
        )
        let requestRegistered = expectation(description: "pending request registered")
        let resultTask = Task { @MainActor in
            do {
                _ = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<[String: Any], Error>) in
                    requests.insert(continuation, for: 99)
                    requestRegistered.fulfill()
                }
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }

        // A cap, not a timing: it returns as soon as the request registers.
        // Creating the bridge's web view can stall the main actor past 1s.
        await fulfillment(of: [requestRegistered], timeout: 10.0)
        bridge.webViewWebContentProcessDidTerminate(bridge.webView)

        switch await resultTask.value {
        case .success:
            XCTFail("Termination must resume pending requests with an error")
        case .failure(let error as DashboardTicketBridgeError):
            if case .notReady = error {
                // expected
            } else {
                XCTFail("Expected .notReady, got \(error)")
            }
        case .failure(let error):
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }
        XCTAssertEqual(requests.count, 0)
    }

    /// When a request's Swift-side deadline expires (the JavaScript response
    /// was silently dropped — stalled web view), the bridge must mark the
    /// view cold-but-reloadable so mintTicket's retry RELOADS it instead of
    /// re-evaluating JavaScript against the same dead view forever.
    ///
    /// Drives requestJSON directly: mintTicket's request timeout is not
    /// injectable (~12s deadline), and settling the initial page load first
    /// makes the run deterministic on both test-host flavors — where WKWebView
    /// navigation callbacks fire, the initial load's failure must land before
    /// the simulated ready state (a later didFailProvisionalNavigation would
    /// otherwise reject the pending request with a connection error instead
    /// of letting the deadline expire).
    func testExpiredRequestDeadlineMarksWebViewStalled() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10),
            requestDeadlineGraceMilliseconds: 50
        )

        // Let the initial /api/status load settle (fail or hang) before
        // modeling the overnight state: the bridge believes it is ready,
        // but its web view cannot deliver responses.
        for _ in 0..<80 where !bridge.isLoadFailed {
            try? await Task.sleep(for: .milliseconds(25))
        }
        bridge.simulateLandingForTesting(.ready)

        do {
            _ = try await bridge.requestJSON(path: "/api/auth/ws-ticket", timeoutMilliseconds: 1_000)
            XCTFail("Expected requestJSON to throw against a stalled web view")
        } catch DashboardTicketBridgeError.notReady {
            XCTAssertTrue(bridge.isLoadFailed, "Deadline expiry must mark the view reloadable")
        } catch {
            // Hosts that deliver an immediate evaluateJavaScript error
            // surface it here; the deadline belt is not exercised there.
            // Recorded so CI logs show which arm ran (the fallback arm is
            // expected to stay silent/unused on this CI's host flavor).
            print("deadline test took immediate-error arm: \(error)")
        }
    }

    /// An invalidated bridge must report plain unreadiness even if its last
    /// landing was the login page — a stale login verdict would surface
    /// .signInRequired (with its session-erasing recovery) from a bridge
    /// that no longer exists for use.
    func testInvalidateClearsLoginLanding() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.simulateLandingForTesting(.loginPage)
        bridge.invalidate()

        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against an invalidated bridge")
        } catch DashboardTicketBridgeError.notReady {
            // expected — not .signInRequired
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }
        XCTAssertEqual(bridge.reloadCount, 0, "An invalidated bridge must not reload")
    }

    /// A login-parked bridge has a settled page: its readiness polls must
    /// exit immediately (the .signInRequired recovery fires right away)
    /// instead of sleeping out the full window on every attempt.
    func testLoginParkedBridgeDoesNotBurnPollWindow() async {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 30,
            readinessPollInterval: .milliseconds(100)
        )
        bridge.simulateLandingForTesting(.loginPage)

        let started = Date()
        do {
            _ = try await bridge.mintTicket()
            XCTFail("Expected mintTicket to throw against a login-parked bridge")
        } catch DashboardTicketBridgeError.signInRequired {
            // expected on exhaustion
        } catch {
            XCTFail("Expected DashboardTicketBridgeError.signInRequired, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        // Without the fast exit, three attempts would poll ~3s each plus
        // sleeps (~9.7s). With it, the run is three ~350ms sleeps (~1.1s).
        // The bound leaves room for a loaded CI runner and still catches the
        // slow path.
        XCTAssertLessThan(elapsed, 6.0, "Login-parked minting must skip the readiness poll window")
        XCTAssertEqual(bridge.reloadCount, 2, "Both signInRequired retries must reload")
    }
}

// MARK: - #378: requests while the phone app is in the background

@MainActor
extension DashboardTicketBridgeTests {
    func testRequestsWithoutThePageGoWhereThePagesFetchWould() {
        XCTAssertEqual(
            DashboardTicketBridge.pageRequestURL(path: "/api/auth/ws-ticket", baseURL: "https://example.com")?.absoluteString,
            "https://example.com/api/auth/ws-ticket"
        )
        XCTAssertEqual(
            DashboardTicketBridge.pageRequestURL(path: "/api/plugins/conduit_push/gpt-live/session", baseURL: "https://example.com:8443/")?.absoluteString,
            "https://example.com:8443/api/plugins/conduit_push/gpt-live/session",
            "an absolute path resolves against the page's origin, as fetch does"
        )
        XCTAssertNil(
            DashboardTicketBridge.pageRequestURL(path: "https://elsewhere.example/api/status", baseURL: "https://example.com"),
            "never another origin"
        )
    }

    func testABackgroundRequestWithNoCookiesIsNotReadyRatherThanSignedOut() async {
        let bridge = DashboardTicketBridge(baseURL: "https://no-session-\(UUID().uuidString.lowercased()).invalid")
        bridge.webViewCanRun = { false }
        defer { bridge.invalidate() }

        do {
            _ = try await bridge.requestJSON(path: "/api/status")
            XCTFail("a request with no cookies to send must not go out")
        } catch DashboardTicketBridgeError.notReady {
            // Nothing proves the sign-in expired.
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

// MARK: - Answers that land after a dashboard switch

@MainActor
extension DashboardTicketBridgeTests {
    /// The page answered, and the switch invalidated the bridge before the
    /// caller ran: the caller hears that the old dashboard accepted it,
    /// never its answer, which it would apply to the dashboard now showing.
    func testAPageAnswerThatLandsAfterInvalidationIsAnsweredAfterSwitch() async throws {
        let requests = DashboardTicketBridgePendingRequests()
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            pendingRequests: requests,
            readinessPollAttempts: 0,
            readinessPollInterval: .milliseconds(1)
        )
        bridge.webViewCanRun = { true }
        // Let the initial load settle first, as in
        // testExpiredRequestDeadlineMarksWebViewStalled, so its failure
        // can't reject the request this test answers.
        for _ in 0..<80 where !bridge.isLoadFailed {
            try? await Task.sleep(for: .milliseconds(25))
        }
        bridge.simulateLandingForTesting(.ready)

        let result = Task { try await bridge.requestJSON(path: "/api/sessions") }
        var answer: DashboardTicketBridgePendingRequests.Continuation?
        for _ in 0..<1_000 where answer == nil {
            await Task.yield()
            answer = requests.removeValue(for: 1)
        }
        try XCTUnwrap(answer).resume(returning: ["sessions": []])
        bridge.invalidate()

        do {
            _ = try await result.value
            XCTFail("an answer for an invalidated bridge must not reach its caller")
        } catch DashboardTicketBridgeError.answeredAfterSwitch {
            // expected
        }
    }

    /// A change the page sent before a switch keeps waiting for its answer:
    /// the caller learns the old dashboard accepted it. A read waiting at
    /// the switch hears unreadiness at once.
    func testAPageWriteWaitingAtASwitchHearsItsAnswer() async throws {
        let requests = DashboardTicketBridgePendingRequests()
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            pendingRequests: requests,
            readinessPollAttempts: 0,
            readinessPollInterval: .milliseconds(1)
        )
        bridge.webViewCanRun = { true }
        for _ in 0..<80 where !bridge.isLoadFailed {
            try? await Task.sleep(for: .milliseconds(25))
        }
        bridge.simulateLandingForTesting(.ready)

        let write = Task { try await bridge.requestJSON(path: "/api/sessions/s", method: "DELETE") }
        for _ in 0..<1_000 where requests.count < 1 { await Task.yield() }
        let read = Task { try await bridge.requestJSON(path: "/api/sessions") }
        for _ in 0..<1_000 where requests.count < 2 { await Task.yield() }
        XCTAssertEqual(requests.count, 2)
        bridge.invalidate()

        do {
            _ = try await read.value
            XCTFail("a read waiting at a switch must not wait for the old dashboard")
        } catch DashboardTicketBridgeError.notReady {
            // expected
        }
        XCTAssertEqual(requests.count, 1, "the change is still waiting for its answer")
        try XCTUnwrap(requests.removeValue(for: 1)).resume(returning: [:])
        do {
            _ = try await write.value
            XCTFail("an answer for an invalidated bridge must not reach its caller")
        } catch DashboardTicketBridgeError.answeredAfterSwitch {
            // expected
        }
    }

    /// invalidate() doesn't cancel a request sent without the page, so its
    /// answer can come back up to its deadline after a switch.
    func testAnAnswerWithoutThePageThatLandsAfterInvalidationIsAnsweredAfterSwitch() async throws {
        let held = HeldDashboardRequests(baseURL: "https://late-\(UUID().uuidString.lowercased()).invalid")
        let result = Task { try await held.bridge.requestJSON(path: "/api/sessions") }
        try await held.waitForRequests(1)
        held.bridge.invalidate()
        try await held.answer(["sessions": []])

        do {
            _ = try await result.value
            XCTFail("an answer for an invalidated bridge must not reach its caller")
        } catch DashboardTicketBridgeError.answeredAfterSwitch {
            // expected
        }
    }

    /// A refusal that lands after a switch says nothing happened there: the
    /// caller hears plain unreadiness, as for a request that never went out.
    func testARefusalWithoutThePageThatLandsAfterInvalidationIsNotReady() async throws {
        let held = HeldDashboardRequests(baseURL: "https://late-\(UUID().uuidString.lowercased()).invalid")
        let result = Task { try await held.bridge.requestJSON(path: "/api/sessions/s", method: "DELETE") }
        try await held.waitForRequests(1)
        held.bridge.invalidate()
        try await held.answer(["detail": "Session not found"], status: 404)

        do {
            _ = try await result.value
            XCTFail("an answer for an invalidated bridge must not reach its caller")
        } catch DashboardTicketBridgeError.notReady {
            // expected
        }
    }
}

@MainActor
extension DashboardTicketBridgeTests {
    func testBackgroundRequestsSendTheCookieThatExpiresLast() throws {
        func cookie(_ value: String, expires: TimeInterval?) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: "session", .value: value, .domain: "example.com", .path: "/",
            ]
            if let expires { properties[.expires] = Date(timeIntervalSinceNow: expires) }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let resignedIn = try cookie("new", expires: 7_200)
        let stalePage = try cookie("old", expires: 600)
        let chosen = DashboardTicketBridge.freshestCookies([resignedIn, stalePage])
        XCTAssertEqual(chosen.map(\.value), ["new"], "a copy that expires sooner never replaces a fresher sign-in")

        let live = try cookie("live", expires: nil)
        XCTAssertEqual(DashboardTicketBridge.freshestCookies([stalePage, live]).map(\.value), ["live"])
        XCTAssertEqual(
            DashboardTicketBridge.freshestCookies([live, resignedIn]).map(\.value), ["live"],
            "a live session cookie is never displaced by a dated copy from a later store"
        )
    }

    func testBackgroundRequestsFollowOnlySameOriginRedirectsWithTheirHeaders() throws {
        var original = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/api/sessions")))
        original.setValue("session=abc", forHTTPHeaderField: "Cookie")
        func proposed(_ url: String) throws -> URLRequest { URLRequest(url: try XCTUnwrap(URL(string: url))) }

        let followed = DashboardBackgroundSession.redirect(from: original, to: try proposed("https://example.com/api/sessions/"))
        XCTAssertEqual(followed?.value(forHTTPHeaderField: "Cookie"), "session=abc", "a trailing-slash redirect keeps the cookies")
        XCTAssertNil(DashboardBackgroundSession.redirect(from: original, to: try proposed("https://example.com/login?next=/api")))
        XCTAssertNil(
            DashboardBackgroundSession.redirect(from: original, to: try proposed("https://elsewhere.example/api/sessions")),
            "cookies never follow a redirect to another origin"
        )
    }

    func testABackgroundResponseOverTheLimitIsNeverHeldWhole() async throws {
        let limit = 1_024
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/api/sessions")))
        let body = Data(repeating: 0x20, count: limit * 4)

        // A length over the limit is refused before the body is read.
        let announced = try await DashboardTicketBridge.load(
            request, deadline: .seconds(10), maxResponseBytes: limit,
            session: downloadSession(status: 200, body: body, headers: ["Content-Length": String(body.count)])
        )
        XCTAssertTrue(announced.oversized)
        XCTAssertTrue(announced.data.isEmpty, "nothing of an announced oversized body is held")

        // Without a length, the read stops once the limit is passed.
        let streamed = try await DashboardTicketBridge.load(
            request, deadline: .seconds(10), maxResponseBytes: limit,
            session: downloadSession(status: 200, body: body)
        )
        XCTAssertTrue(streamed.oversized)
        XCTAssertLessThanOrEqual(streamed.data.count, limit, "the body past the limit is never held")

        let small = Data(#"{"ok":true}"#.utf8)
        let fits = try await DashboardTicketBridge.load(
            request, deadline: .seconds(10), maxResponseBytes: limit,
            session: downloadSession(status: 200, body: small)
        )
        XCTAssertFalse(fits.oversized)
        XCTAssertEqual(fits.data, small)
    }

    // MARK: - File downloads (#569)

    private func downloadSession(status: Int, body: Data, headers: [String: String] = [:]) -> URLSession {
        DashboardDownloadURLProtocolStub.response = (status, body, headers)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashboardDownloadURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func downloadRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardDownloadTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testDownloadWritesTheBodyToDiskInChunks() async throws {
        // Several chunks plus a partial one.
        let body = Data((0..<(2 * 1024 * 1024 + 4_321)).map { UInt8(truncatingIfNeeded: $0) })
        let session = downloadSession(status: 200, body: body, headers: ["Content-Type": "video/mp4"])
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/api/fs/download?path=/tmp/reel.mp4")))

        let download = try await DashboardTicketBridge.download(
            request, filename: "/tmp/out/reel.mp4", into: try downloadRoot(), maxBytes: 4 * 1024 * 1024, session: session
        )

        XCTAssertEqual(download.file.lastPathComponent, "reel.mp4")
        XCTAssertEqual(download.mimeType, "video/mp4")
        XCTAssertEqual(try Data(contentsOf: download.file), body)
    }

    func testDownloadOverTheLimitIsOversizedAndLeavesNothingBehind() async throws {
        let session = downloadSession(status: 200, body: Data(repeating: 1, count: 600_000))
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/api/fs/download?path=/tmp/a.mov")))
        let root = try downloadRoot()

        do {
            _ = try await DashboardTicketBridge.download(request, filename: "a.mov", into: root, maxBytes: 500_000, session: session)
            XCTFail("a file over the limit is refused")
        } catch DashboardTicketBridgeError.oversizedResponse(let limit) {
            XCTAssertEqual(limit, 500_000)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "a refused download removes its directory")
    }

    func testDownloadReportsSignInAndHTTPFailures() async throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/api/fs/download?path=/tmp/a.mp3")))
        let root = try downloadRoot()

        do {
            _ = try await DashboardTicketBridge.download(
                request, filename: "a.mp3", into: root, maxBytes: 1_000,
                session: downloadSession(status: 401, body: Data("{}".utf8))
            )
            XCTFail("401 needs a sign-in")
        } catch DashboardTicketBridgeError.signInRequired {}

        // Hermes refuses a sensitive or unreadable file with 403 to a caller
        // who is signed in: a failure with Hermes' reason, not a sign-in.
        do {
            _ = try await DashboardTicketBridge.download(
                request, filename: "a.mp3", into: root, maxBytes: 1_000,
                session: downloadSession(status: 403, body: Data(#"{"detail":"Access to sensitive files is not allowed"}"#.utf8))
            )
            XCTFail("a refused file is not a file")
        } catch DashboardTicketBridgeError.http(let status, let detail) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(detail, "Access to sensitive files is not allowed")
        }

        do {
            _ = try await DashboardTicketBridge.download(
                request, filename: "a.mp3", into: root, maxBytes: 1_000,
                session: downloadSession(status: 404, body: Data(#"{"detail":"Not Found"}"#.utf8))
            )
            XCTFail("an older Hermes without the route is a failure the data URL can fall back from")
        } catch DashboardTicketBridgeError.http(let status, _) {
            XCTAssertEqual(status, 404)
        }
    }

    /// The background session returns only redirects to sign-in or another
    /// origin; each is judged by the shared sign-in decision, not by a
    /// "/login" substring (#791).
    func testADownloadRedirectedToAnAuthProxysSignInIsSignIn() async throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/api/fs/download?path=/tmp/a.mp3")))
        let root = try downloadRoot()
        for location in [
            "https://auth.example.org/oauth2/start?rd=%2Fapi%2Ffs%2Fdownload",
            "/oauth2/sign_in?rd=%2Fapi%2Ffs%2Fdownload",
            "/signin",
        ] {
            do {
                _ = try await DashboardTicketBridge.download(
                    request, filename: "a.mp3", into: root, maxBytes: 1_000,
                    session: downloadSession(status: 302, body: Data(), headers: ["Location": location])
                )
                XCTFail("A redirect to \(location) needs a sign-in")
            } catch DashboardTicketBridgeError.signInRequired {}
        }

        do {
            _ = try await DashboardTicketBridge.download(
                request, filename: "a.mp3", into: root, maxBytes: 1_000,
                session: downloadSession(status: 302, body: Data(), headers: ["Location": "/docs/login-guide"])
            )
            XCTFail("An unfollowed redirect to an ordinary page is not a file")
        } catch DashboardTicketBridgeError.http(let status, _) {
            XCTAssertEqual(status, 302)
        }
    }
}

private final class DashboardDownloadURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data, headers: [String: String]) = (200, Data(), [:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body, headers) = Self.response
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension DashboardTicketBridgeTests {
    /// The page's answers are parsed off the main thread; only an object the
    /// page sent as an answer counts as one.
    func testOnlyThePagesAnswersParseAsAnswers() {
        let payload = DashboardTicketBridge.dashboardResponsePayload(
            #"{"type":"dashboard-response","id":3,"ok":true,"body":{"a":1}}"#
        )
        XCTAssertEqual(payload?["id"] as? Int, 3)
        XCTAssertNil(DashboardTicketBridge.dashboardResponsePayload("not json"))
        XCTAssertNil(DashboardTicketBridge.dashboardResponsePayload("[1, 2]"))
        XCTAssertNil(DashboardTicketBridge.dashboardResponsePayload(#"{"type":"other","id":3}"#))
    }

    /// An answer the page sends is parsed off the main thread and resumes
    /// its request back on it; one whose request already ended (its
    /// deadline, a reload) resumes nothing, nor does a message that isn't
    /// an answer.
    func testAReceivedAnswerResumesOnlyARequestStillWaiting() async throws {
        let requests = DashboardTicketBridgePendingRequests()
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            pendingRequests: requests,
            readinessPollAttempts: 0,
            readinessPollInterval: .milliseconds(1)
        )
        bridge.webViewCanRun = { true }
        // The initial load settles first, as in
        // testAPageAnswerThatLandsAfterInvalidationIsAnsweredAfterSwitch, so
        // its failure can't reject the requests this test answers.
        for _ in 0..<80 where !bridge.isLoadFailed {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let dashboard = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        let registered = expectation(description: "requests registered")
        registered.expectedFulfillmentCount = 2
        let ended = Task { @MainActor () -> Bool in
            do {
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                    requests.insert(continuation, for: 1)
                    registered.fulfill()
                }
                return true
            } catch {
                return false
            }
        }
        let waiting = Task { @MainActor () -> Int? in
            let body = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                requests.insert(continuation, for: 2)
                registered.fulfill()
            }
            return body?["a"] as? Int
        }
        await fulfillment(of: [registered], timeout: 10.0)
        // Request 1's deadline ended it before its answer was parsed.
        requests.removeValue(for: 1)?.resume(throwing: DashboardTicketBridgeError.notReady)

        await bridge.receive(#"{"type":"dashboard-response","id":1,"ok":true,"body":{"late":true}}"#, expectedURL: dashboard).value
        await bridge.receive(#"{"type":"other","id":2,"ok":true,"body":{"a":2}}"#, expectedURL: dashboard).value
        XCTAssertEqual(requests.count, 1, "Not an answer: request 2 still waits")
        await bridge.receive(#"{"type":"dashboard-response","id":2,"ok":true,"body":{"a":1}}"#, expectedURL: dashboard).value

        let endedHeardTheAnswer = await ended.value
        XCTAssertFalse(endedHeardTheAnswer, "It heard its deadline, not the late answer")
        let answered = await waiting.value
        XCTAssertEqual(answered, 1)
        XCTAssertEqual(requests.count, 0)
    }
}
