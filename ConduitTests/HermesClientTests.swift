import XCTest
@testable import Conduit

@MainActor
final class HermesClientTests: XCTestCase {

    // MARK: - rpc() guard

    func testRPCGuardRejectsBeforeHandshake() async throws {
        // The handshake is held open (we never call transport.open), so the
        // socket is installed but `isConnected` is still false. `rpc()`'s
        // `isConnected` requirement must reject the call — the pre-fix
        // `closeCode == .invalid` check alone would have passed.
        let transport = FakeTransport()
        let socket = FakeSocket()
        let reachedResume = Gate()
        socket.onResume = { reachedResume.signal() }
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)

        let connectTask = Task { try? await client.connect() }
        try await reachedResume.wait("connect() to resume the socket (handshake pending)")  // connect() has installed + resumed the socket and is now suspended in the handshake

        do {
            try await client.healthCheck()
            XCTFail("Expected healthCheck to throw before the handshake completes")
        } catch HermesError.notConnected {
            // expected
        } catch {
            XCTFail("Expected .notConnected, got \(error)")
        }

        client.disconnect()  // resumes the suspended handshake so connect() unwinds
        try await awaitCompletion(of: connectTask, "connect() to unwind after disconnect()")
    }

    // MARK: - receive-failure teardown

    func testReceiveFailureOnOwningSocketTearsDown() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        let receivePending = Gate()
        socket.onReceivePending = { receivePending.signal() }
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        var didDisconnect = false
        client.onDisconnected = { didDisconnect = true }

        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")
        XCTAssertTrue(client.isConnected)
        try await receivePending.wait("the receive loop to suspend in socket.receive()")  // the receive loop is now suspended in socket.receive()

        socket.failReceive(URLError(.networkConnectionLost))
        await flushMainActor()       // let the catch run

        XCTAssertFalse(client.isConnected)
        XCTAssertTrue(didDisconnect)
        client.disconnect()
    }

    func testSupersededReceiveLoopDoesNotClobberNewConnection() async throws {
        let transport = FakeTransport()
        let socketA = FakeSocket()
        let aReceivePending = Gate()
        socketA.onReceivePending = { aReceivePending.signal() }
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)
        var disconnectCount = 0
        client.onDisconnected = { disconnectCount += 1 }

        let connectA = Task { try? await client.connect() }
        transport.open(socketA)
        try await awaitCompletion(of: connectA, "connect A to complete after the handshake")
        XCTAssertTrue(client.isConnected)
        try await aReceivePending.wait("socket A's receive loop to suspend in socket.receive()")  // A's receive loop is suspended in socket.receive()

        // Same-instance reconnect (the latent scenario this PR hardens):
        // connect() tears down socketA → A's receive() errors → A's late catch
        // must be a no-op, not clobber the new connection.
        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        try await awaitCompletion(of: connectB, "connect B to complete after the handshake")
        await flushMainActor()  // let A's superseded catch run

        XCTAssertTrue(socketA.cancelled, "Reconnect should cancel the superseded socket")
        XCTAssertTrue(client.isConnected, "A superseded loop must not mark the new connection disconnected")
        XCTAssertEqual(disconnectCount, 0, "A superseded loop must not fire onDisconnected")
        client.disconnect()
    }

    func testSupersededLoopDropsStaleFrame() async throws {
        // The success path of receiveLoop is identity-guarded too: a frame
        // delivered to a superseded socket must not reach handleMessage.
        let transport = FakeTransport()
        let socketA = FakeSocket()
        socketA.cancelErrorsReceive = false  // keep A's receive suspended so a stale frame can arrive after supersession
        let aReceivePending = Gate()
        socketA.onReceivePending = { aReceivePending.signal() }
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)
        var eventCount = 0
        client.onEvent = { _ in eventCount += 1 }

        let connectA = Task { try? await client.connect() }
        transport.open(socketA)
        try await awaitCompletion(of: connectA, "connect A to complete after the handshake")
        try await aReceivePending.wait("socket A's receive loop to suspend in socket.receive()")

        // Reconnect to B, then deliver a frame to the old socket A. The guard
        // must drop it (onEvent not fired for A's stale frame).
        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        try await awaitCompletion(of: connectB, "connect B to complete after the handshake")

        socketA.deliver(someEventJSON())
        await flushMainActor()

        XCTAssertEqual(eventCount, 0, "A stale frame on a superseded socket must be dropped")
        client.disconnect()
    }

    // MARK: - connect() teardown of the prior connection

    func testConnectInvalidatesPriorTransport() async throws {
        let transport = FakeTransport()
        let socketA = FakeSocket()
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)

        let connectA = Task { try? await client.connect() }
        transport.open(socketA)
        try await awaitCompletion(of: connectA, "connect A to complete after the handshake")
        XCTAssertFalse(transport.invalidated)

        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        try await awaitCompletion(of: connectB, "connect B to complete after the handshake")

        XCTAssertTrue(transport.invalidated, "Reconnect must invalidate the prior transport/session")
        XCTAssertEqual(transport.socketsMade.count, 2)
        client.disconnect()
    }

    func testConcurrentConnectSupersedesPriorWithoutHanging() async throws {
        // A second connect() while the first is still mid-handshake must resume
        // the first's open continuation (via the teardown, mirroring disconnect),
        // so the first connect() throws instead of hanging forever.
        let transport = FakeTransport()
        let socketA = FakeSocket()
        let aResumed = Gate()
        socketA.onResume = { aResumed.signal() }
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)

        let connectA = Task { try? await client.connect() }
        try await aResumed.wait("connect A to resume its socket (handshake pending)")  // connectA has installed A and is suspended in the handshake (A is never opened)

        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        try await awaitCompletion(of: connectB, "connect B to complete after the handshake")

        // If the continuation were leaked this would time out (boundedly) and
        // fail the test instead of hanging the run.
        try await awaitCompletion(of: connectA, "superseded connect A to unwind after connect B")
        XCTAssertTrue(client.isConnected)
        client.disconnect()
    }

    // MARK: - session.resume transport bound (issue #106)

    func testProductionTransportRaisesWebSocketMessageLimit() {
        // URLSessionWebSocketTask's platform default receive limit closes the
        // socket with close code 1009 as soon as a single message exceeds it,
        // which is how resuming large sessions used to disconnect Conduit in
        // a loop. The production transport must install the explicit bounded
        // 4 MiB limit on the real socket.
        let transport = URLSessionWebSocketTransport()
        defer { transport.invalidate() }
        let request = URLRequest(url: URL(string: "wss://gateway.example/api/ws")!)
        let socket = transport.makeSocket(
            request: request,
            onOpen: { _ in },
            onCloseBeforeOpen: { _ in }
        )

        let task = socket as? URLSessionWebSocketTask
        XCTAssertNotNil(task, "The production transport must produce a URLSessionWebSocketTask")
        XCTAssertEqual(task?.maximumMessageSize, URLSessionWebSocketTransport.maximumMessageSize)
        XCTAssertEqual(URLSessionWebSocketTransport.maximumMessageSize, 4 * 1024 * 1024)
        XCTAssertNotEqual(
            URLSessionWebSocketTransport.maximumMessageSize,
            1_048_576,
            "The limit must not remain at the platform default"
        )
    }

    func testLegacyResumeUsesDedicatedTimeoutBudget() {
        // The legacy full-transcript resume carries the largest ordinary
        // payload in the app, so it gets the bounded-but-generous 60 s
        // budget; the compact resume rides the ordinary 30 s request
        // timeout (issue #106 follow-up).
        XCTAssertEqual(HermesClient.resumeTimeout(omitMessages: true), HermesClient.requestTimeout)
        XCTAssertEqual(HermesClient.requestTimeout, 30)
        XCTAssertEqual(HermesClient.resumeTimeout(omitMessages: false), HermesClient.legacyResumeTimeout)
        XCTAssertEqual(HermesClient.legacyResumeTimeout, 60)
        XCTAssertGreaterThan(HermesClient.legacyResumeTimeout, HermesClient.requestTimeout)
    }

    func testOpenSessionRequestsCompactResumeWithoutTranscriptPayload() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSession("sess-large") }
        try await sent.wait("the session.resume request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "session.resume")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "sess-large")
        XCTAssertEqual(
            params["omit_messages"] as? Bool,
            true,
            "The compact resume must ask the gateway to omit the persisted transcript"
        )
        XCTAssertEqual(params["cols"] as? Int, 96)
        XCTAssertEqual(params["source"] as? String, "desktop")

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "session_id": "sess-large",
                "messages": [Any](),
                "info": ["running": false]
            ]
        ]
        socket.deliver(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!)

        let result = try await awaitResult(of: openTask, "the compact session.resume response")
        XCTAssertTrue(result.messages.isEmpty, "The compact response must carry no transcript")
        XCTAssertEqual(result.sessionId, "sess-large")
        client.disconnect()
    }

    func testOpenSessionLegacyCarriesTranscriptInResponse() async throws {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        try await awaitCompletion(of: connectTask, "connect() to complete after the handshake")

        let sent = Gate()
        socket.onSend = { sent.signal() }
        let openTask = Task<SessionResumeResult, Error> { try await client.openSessionLegacy("sess-full") }
        try await sent.wait("the legacy session.resume request to be sent")

        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_id"] as? String, "sess-full")
        XCTAssertNil(params["omit_messages"], "The legacy resume must not suppress the transcript")

        let id = try XCTUnwrap(request["id"] as? Int)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "session_id": "sess-full",
                "messages": [
                    ["role": "user", "content": "Hello", "timestamp": "2026-09-01T10:00:00Z"],
                    ["role": "assistant", "content": "Hi there", "timestamp": "2026-09-01T10:00:05Z"]
                ],
                "info": ["running": false]
            ]
        ]
        socket.deliver(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!)

        let result = try await awaitResult(of: openTask, "the legacy session.resume response")
        XCTAssertEqual(result.messages.map({ $0.role }), [.user, .assistant])
        XCTAssertEqual(result.messages.first?.content, "Hello")
        XCTAssertEqual(result.messages.first?.timestamp, "2026-09-01T10:00:00Z")
        client.disconnect()
    }

    // MARK: - Helpers

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    /// Bounded wait for a spawned throwing task, returning its result. The
    /// Task-side counterpart of `Gate.wait`: a wedged phase fails the
    /// test naming `phase` instead of suspending forever.
    private func awaitResult<T>(
        of task: Task<T, Error>,
        _ phase: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> T {
        let finished = Gate()
        let box = ResultBox<T>()
        let watcher = Task<Void, Never>.detached(priority: .userInitiated) {
            do {
                box.value = .success(try await task.value)
            } catch {
                box.value = .failure(error)
            }
            finished.signal()
        }
        defer { watcher.cancel() }
        try await finished.wait(phase, timeout: timeout, file: file, line: line)
        guard let stored = box.value else {
            XCTFail("Expected a result for \(phase)", file: file, line: line)
            throw TestSyncTimedOut(phase: phase)
        }
        return try stored.get()
    }

    private func makeClient(transport: FakeTransport) -> HermesClient {
        HermesClient(
            connection: HermesConnection(baseUrl: "https://test.example", ticket: "ticket"),
            transportFactory: { transport }
        )
    }

    private func flushMainActor() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// Bounded wait for a spawned task to finish — the task-side counterpart
    /// of `Gate.wait`. A `connect()` that never unwinds fails the test naming
    /// `phase` instead of suspending forever on `task.value`. If the deadline
    /// fires, the watcher is left leaked on `task.value` by design: checked
    /// continuations ignore cancellation, and the test process is on its way
    /// to a failure report anyway.
    private func awaitCompletion<T>(
        of task: Task<T, Never>,
        _ phase: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let finished = Gate()
        let watcher = Task<Void, Never>.detached(priority: .userInitiated) {
            _ = await task.value
            finished.signal()
        }
        defer { watcher.cancel() }
        try await finished.wait(phase, timeout: timeout, file: file, line: line)
    }

    /// A gateway stream-event frame (`message.start`) that StreamEventParser
    /// accepts, so `deliver` genuinely exercises the receive success path —
    /// without the identity guard this would fire `onEvent`.
    private func someEventJSON() -> String {
        """
        {"method":"event","params":{"type":"message.start","session_id":"sess-1"}}
        """
    }
}

// MARK: - Test doubles

/// Single-use gate that survives a `signal()` arriving before `wait()` (the
/// flag is sticky). `wait` is bounded: XCTest has no per-test timeout for
/// async tests, so a missed signal would suspend the test forever and wedge
/// xcodebuild until the CI job-level kill. A missed signal must instead fail
/// the test naming the phase it was waiting for.
///
/// NSLock rather than MainActor confinement because the deadline timer runs
/// detached from any actor; whoever takes the continuation under the lock
/// resumes it exactly once, which makes the signal/timeout race safe.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    /// Resumed with `true` when the deadline wins the race.
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal() {
        lock.lock()
        signalled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: false)
    }

    func wait(
        _ phase: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let timedOut = await withCheckedContinuation { continuation in
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            self.continuation = continuation
            lock.unlock()

            // Detached so the deadline fires even if the actor the awaited
            // work runs on never gets scheduled again.
            Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.fireDeadline()
            }
        }
        if timedOut {
            XCTFail("Timed out after \(timeout)s waiting for \(phase)", file: file, line: line)
            throw TestSyncTimedOut(phase: phase)
        }
    }

    /// Deadline half of the signal/timeout race. Whoever takes the
    /// continuation under the lock resumes it; the loser sees nil, making the
    /// race exactly-once. Synchronous (no awaits) so the NSLock critical
    /// sections stay out of async contexts.
    private func fireDeadline() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let signalled = self.signalled
        lock.unlock()
        if !signalled {
            continuation?.resume(returning: true)
        }
    }
}

/// Thrown by the bounded wait helpers after the failure has been recorded;
/// aborts the test method so a wedged phase does not cascade into misleading
/// downstream assertion failures.
private struct TestSyncTimedOut: Error {
    let phase: String
}

/// Controllable HermesWebSocket. `receive()` suspends until the test delivers a
/// message or fails it; `cancel()` mimics URLSession by recording the close
/// code and erroring the in-flight receive (real cancellation surfaces as a
/// receive error).
private final class FakeSocket: HermesWebSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var cancelled = false
    private(set) var resumed = false
    var onResume: (() -> Void)?
    var onReceivePending: (() -> Void)?
    private(set) var sentTexts: [String] = []
    /// Signalled after each outbound text frame so tests can await the
    /// JSON-RPC request before answering it.
    var onSend: (() -> Void)?

    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    func resume() {
        resumed = true
        onResume?()
    }

    /// Whether `cancel()` errors the in-flight `receive()` (true mirrors
    /// URLSession). Tests that need a frame to arrive on a cancelled socket
    /// set this false.
    var cancelErrorsReceive = true

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        cancelled = true
        if cancelErrorsReceive { failReceive(URLError(.networkConnectionLost)) }
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        if case .string(let text) = message {
            sentTexts.append(text)
            onSend?()
        }
        completionHandler(nil)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
            onReceivePending?()
        }
    }

    // Test hooks
    func deliver(_ text: String) {
        receiveContinuation?.resume(returning: .string(text))
        receiveContinuation = nil
    }

    func failReceive(_ error: Error) {
        receiveContinuation?.resume(throwing: error)
        receiveContinuation = nil
    }
}

/// Records `invalidate()` and completes the handshake deterministically.
/// `open(_:)` is safe to call before `makeSocket` has registered the socket
/// (e.g. right after spawning `Task { connect() }`): the request is buffered
/// and fired once the socket exists, so the handshake never races the scheduler.
private final class FakeTransport: HermesWebSocketTransport {
    private(set) var invalidated = false
    private(set) var socketsMade: [FakeSocket] = []
    var nextSocket: (() -> FakeSocket)?
    private var openCallbacks: [ObjectIdentifier: () -> Void] = [:]
    private var earlyOpenRequests = Set<ObjectIdentifier>()

    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket {
        let socket = nextSocket?() ?? FakeSocket()
        socketsMade.append(socket)
        let key = ObjectIdentifier(socket)
        openCallbacks[key] = { onOpen(socket) }
        if earlyOpenRequests.remove(key) != nil, let callback = openCallbacks.removeValue(forKey: key) {
            callback()
        }
        return socket
    }

    func invalidate() {
        invalidated = true
    }

    /// Fire the handshake-open callback for a socket this transport has or will
    /// produce. Buffering makes this independent of Task scheduling order.
    func open(_ socket: FakeSocket) {
        let key = ObjectIdentifier(socket)
        if let callback = openCallbacks.removeValue(forKey: key) {
            callback()
        } else {
            earlyOpenRequests.insert(key)
        }
    }
}
