import XCTest
@testable import Conduit

// MARK: - Reads and the ticket without the page while it runs

@MainActor
extension DashboardTicketBridgeTests {
    /// A held bridge for a saved dashboard with its page able to run, as on
    /// screen. Its page never becomes ready (nothing answers its load), so
    /// a request that waited for the page would fail.
    private func foregroundHeld() -> HeldDashboardRequests {
        let held = HeldDashboardRequests(baseURL: "http://127.0.0.1:1", dashboardID: UUID())
        held.bridge.webViewCanRun = { true }
        addTeardownBlock { @MainActor in
            held.releaseAll()
            held.bridge.invalidate()
        }
        return held
    }

    /// On screen, a read with a session cookie goes out without the page,
    /// so a launch doesn't wait for WebKit and the page's load.
    func testAReadOnScreenWithASessionCookieGoesWithoutThePage() async throws {
        let held = foregroundHeld()
        let read = Task { try await held.bridge.requestJSON(path: "/api/profiles") }
        try await held.waitForRequests(1)
        try await held.answer(["profiles": ["default"]])

        let answer = try await read.value
        XCTAssertEqual(answer["profiles"] as? [String], ["default"])
        XCTAssertEqual(held.sent.map(\.path), ["/api/profiles"])
        XCTAssertFalse(held.bridge.isReady, "answered before the page was ready")
    }

    /// The ticket goes the same way as the socket's upgrade: natively.
    func testATicketOnScreenWithASessionCookieGoesWithoutThePage() async throws {
        let held = foregroundHeld()
        let mint = Task { try await held.bridge.mintTicket() }
        try await held.waitForRequests(1)
        try await held.answer(["ticket": "native-ticket"])

        let ticket = try await mint.value
        XCTAssertEqual(ticket, "native-ticket")
        XCTAssertEqual(held.sent.map(\.method), ["POST"])
        XCTAssertEqual(held.sent.map(\.path), ["/api/auth/ws-ticket"])
    }

    /// A write keeps the page while it runs, so a dashboard switch still
    /// leaves it waiting for its answer.
    func testAWriteOnScreenKeepsThePage() async throws {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            dashboardID: UUID(),
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.webViewCanRun = { true }
        bridge.backgroundIssuedCookies = [try XCTUnwrap(HTTPCookie(properties: [
            .name: "session", .value: "s", .domain: "127.0.0.1", .path: "/",
        ]))]
        var sentWithoutPage: [String] = []
        bridge.loadWithoutPageForTesting = { request in
            sentWithoutPage.append(request.url?.path ?? "")
            throw URLError(.cancelled)
        }
        addTeardownBlock { @MainActor in bridge.invalidate() }

        do {
            _ = try await bridge.requestJSON(path: "/api/sessions/s", method: "DELETE")
            XCTFail("the page never became ready")
        } catch {
            // notReady from the page that can't load
        }
        XCTAssertEqual(sentWithoutPage, [], "a write on screen goes through the page")
        XCTAssertEqual(bridge.writesSent, 2, "counted as it started and as it ended")
    }

    /// A native ticket refused as signed out goes on to the page, whose
    /// reload and retries decide: a store's cookie may be older than the
    /// page's, so one native 401 doesn't end the session.
    func testATicketRefusedNativelyGoesOnToThePage() async throws {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            dashboardID: UUID(),
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.webViewCanRun = { true }
        bridge.backgroundIssuedCookies = [try XCTUnwrap(HTTPCookie(properties: [
            .name: "session", .value: "old", .domain: "127.0.0.1", .path: "/",
        ]))]
        var sentWithoutPage = 0
        bridge.loadWithoutPageForTesting = { request in
            sentWithoutPage += 1
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
            return (Data(#"{"detail":"Unauthorized"}"#.utf8), response)
        }
        addTeardownBlock { @MainActor in bridge.invalidate() }

        do {
            _ = try await bridge.mintTicket()
            XCTFail("nothing answers the page")
        } catch DashboardTicketBridgeError.signInRequired {
            XCTFail("one native 401 ended the session without the page's say")
        } catch {
            // the page, which can't load here, has the last word
        }
        XCTAssertEqual(sentWithoutPage, 1)
    }

    /// A write is counted as it starts and as it ends, so a read sent while
    /// it was out doesn't match a fence taken after it.
    func testAWriteIsCountedWhenItStartsAndEnds() async throws {
        let held = HeldDashboardRequests(baseURL: "http://127.0.0.1:1", dashboardID: UUID())
        addTeardownBlock { @MainActor in held.releaseAll() }
        let write = Task { try await held.bridge.requestJSON(path: "/api/sessions/s", method: "PATCH", body: ["title": "t"]) }
        try await held.waitForRequests(1)
        XCTAssertEqual(held.bridge.writesSent, 1)
        XCTAssertEqual(held.bridge.writesOut, 1)
        try await held.answer([String: Any]())
        _ = try await write.value
        XCTAssertEqual(held.bridge.writesSent, 2)
        XCTAssertEqual(held.bridge.writesOut, 0)
    }

    /// A bridge built before its dashboard is saved shares the default
    /// stores, so it keeps the page for reads too.
    func testAnUnsavedDashboardsReadKeepsThePage() async throws {
        let bridge = DashboardTicketBridge(
            baseURL: "http://127.0.0.1:1",
            readinessPollAttempts: 2,
            readinessPollInterval: .milliseconds(10)
        )
        bridge.webViewCanRun = { true }
        bridge.backgroundIssuedCookies = [try XCTUnwrap(HTTPCookie(properties: [
            .name: "session", .value: "s", .domain: "127.0.0.1", .path: "/",
        ]))]
        var sentWithoutPage = 0
        bridge.loadWithoutPageForTesting = { _ in
            sentWithoutPage += 1
            throw URLError(.cancelled)
        }
        addTeardownBlock { @MainActor in bridge.invalidate() }

        _ = try? await bridge.requestJSON(path: "/api/status")
        XCTAssertFalse(bridge.readsWithoutThePageFirst)
        XCTAssertEqual(sentWithoutPage, 0)
    }
}

// MARK: - Reads sent as a connection starts

@MainActor
extension DashboardTicketBridgeTests {
    private func fence(_ writes: Int = 0, catalog: UInt64 = 0, display: Int = 0) -> StartupReads.Fence {
        StartupReads.Fence(writes: writes, catalog: catalog, display: display)
    }

    /// The step takes the early answer, once: the read went out once.
    func testAStartupReadIsTakenOnce() async throws {
        let held = HeldDashboardRequests(baseURL: "http://127.0.0.1:1", dashboardID: UUID())
        addTeardownBlock { @MainActor in held.releaseAll() }
        let reads = StartupReads()
        reads.send(["/api/profiles"], through: held.bridge, fence: fence())
        try await held.waitForRequests(1)
        try await held.answer(["profiles": ["default", "work"]])

        let first = try await reads.read("/api/profiles", through: held.bridge, fence: fence())
        XCTAssertEqual(first["profiles"] as? [String], ["default", "work"])
        XCTAssertTrue(reads.waitingPaths.isEmpty)

        let second = Task { try await reads.read("/api/profiles", through: held.bridge, fence: fence()) }
        try await held.waitForRequests(2)
        try await held.answer(["profiles": ["default"]])
        let again = try await second.value
        XCTAssertEqual(again["profiles"] as? [String], ["default"], "a second read is a read of its own")
    }

    /// An early answer read before a change, through another bridge, or
    /// too long ago isn't used.
    func testAStartupReadIsntUsedAfterAChange() {
        let held = HeldDashboardRequests(baseURL: "http://127.0.0.1:1", dashboardID: UUID())
        let other = HeldDashboardRequests(baseURL: "http://127.0.0.1:1", dashboardID: UUID())
        addTeardownBlock { @MainActor in
            held.releaseAll()
            other.releaseAll()
        }
        let reads = StartupReads()
        let sentAt = Date()

        reads.send(["/a"], through: held.bridge, fence: fence(), now: sentAt)
        XCTAssertNil(reads.take("/a", through: held.bridge, fence: fence(1), now: sentAt), "a write since")

        reads.send(["/b"], through: held.bridge, fence: fence(), now: sentAt)
        XCTAssertNil(reads.take("/b", through: held.bridge, fence: fence(catalog: 1), now: sentAt), "a chat list change since")
        reads.clear()

        reads.send(["/c"], through: held.bridge, fence: fence(), now: sentAt)
        XCTAssertNil(reads.take("/c", through: held.bridge, fence: fence(display: 1), now: sentAt), "a display save since")
        reads.clear()

        reads.send(["/d"], through: held.bridge, fence: fence(), now: sentAt)
        XCTAssertNil(reads.take("/d", through: other.bridge, fence: fence(), now: sentAt), "another bridge")
        reads.clear()

        reads.send(["/e"], through: held.bridge, fence: fence(), now: sentAt)
        XCTAssertNil(
            reads.take("/e", through: held.bridge, fence: fence(), now: sentAt.addingTimeInterval(StartupReads.lifetime)),
            "too old"
        )
        reads.clear()

        reads.send(["/g"], through: held.bridge, fence: { _ in StartupReads.Fence(writes: 0, catalog: 0, display: 0, listings: 0) }, now: sentAt)
        XCTAssertNil(
            reads.take("/g", through: held.bridge, fence: StartupReads.Fence(writes: 0, catalog: 0, display: 0, listings: 1), now: sentAt),
            "a newer chat list committed since"
        )
        reads.clear()

        let writeOut = StartupReads.Fence(writes: 1, catalog: 0, display: 0, writesOut: 1)
        reads.send(["/h"], through: held.bridge, fence: writeOut, now: sentAt)
        XCTAssertNil(reads.take("/h", through: held.bridge, fence: writeOut, now: sentAt), "a write was out when it was sent")
        reads.clear()

        reads.send(["/f"], through: held.bridge, fence: fence(), now: sentAt)
        XCTAssertNotNil(reads.take("/f", through: held.bridge, fence: fence(), now: sentAt.addingTimeInterval(1)))
    }

    /// The connect right after a ticket mint doesn't send the same reads
    /// again.
    func testTheSameStartupReadsArentSentTwice() async throws {
        let held = HeldDashboardRequests(baseURL: "http://127.0.0.1:1", dashboardID: UUID())
        addTeardownBlock { @MainActor in held.releaseAll() }
        let reads = StartupReads()
        let sentAt = Date()
        reads.send(["/api/profiles"], through: held.bridge, fence: fence(), now: sentAt)
        reads.send(["/api/profiles"], through: held.bridge, fence: fence(), now: sentAt.addingTimeInterval(1))
        try await held.waitForRequests(1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(held.sent.count, 1)
        XCTAssertEqual(reads.waitingPaths, ["/api/profiles"])
    }

    /// An early read that couldn't go out without the page (no session
    /// cookie yet) is sent again by its step.
    func testAStartupReadWithNoCookieIsSentAgainByItsStep() async throws {
        let bridge = DashboardTicketBridge(baseURL: "https://no-session-\(UUID().uuidString.lowercased()).invalid", dashboardID: UUID())
        bridge.webViewCanRun = { false }
        addTeardownBlock { @MainActor in bridge.invalidate() }
        let reads = StartupReads()
        reads.send(["/api/status"], through: bridge, fence: fence())

        do {
            _ = try await reads.read("/api/status", through: bridge, fence: fence())
            XCTFail("no cookie: the step's own read is refused too")
        } catch DashboardTicketBridgeError.notReady {
            // the step's own read, sent again, met the same missing cookie
        }
        XCTAssertTrue(reads.waitingPaths.isEmpty)
    }
}
