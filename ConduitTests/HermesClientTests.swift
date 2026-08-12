import XCTest
@testable import Conduit

@MainActor
final class HermesClientTests: XCTestCase {

    // MARK: - rpc() guard

    func testRPCGuardRejectsBeforeHandshake() async {
        // The handshake is held open, so the socket is installed but
        // `isConnected` is still false. `rpc()`'s `isConnected` requirement
        // must reject the call — the pre-fix `closeCode == .invalid` check alone
        // would have passed (the fake socket reports `.invalid`).
        let transport = FakeTransport()
        let handshakeGate = Gate()
        let socket = FakeSocket()
        socket.onResume = { handshakeGate.signal() }
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)

        let connectTask = Task { try? await client.connect() }
        await handshakeGate.wait()  // connect() has reached socket.resume() and is now suspended in the handshake

        do {
            try await client.healthCheck()
            XCTFail("Expected healthCheck to throw before the handshake completes")
        } catch HermesError.notConnected {
            // expected
        } catch {
            XCTFail("Expected .notConnected, got \(error)")
        }

        client.disconnect()  // resumes the suspended handshake so connect() unwinds
        _ = await connectTask.value
    }

    // MARK: - receive-failure teardown

    func testReceiveFailureOnOwningSocketTearsDown() async {
        let transport = FakeTransport()
        let socket = FakeSocket()
        transport.nextSocket = { socket }
        let client = makeClient(transport: transport)
        var didDisconnect = false
        client.onDisconnected = { didDisconnect = true }

        let connectTask = Task { try? await client.connect() }
        transport.open(socket)
        _ = await connectTask.value
        XCTAssertTrue(client.isConnected)

        // The receive loop is suspended in socket.receive(); fail it on the
        // socket this loop still owns. The catch must tear down.
        socket.failReceive(URLError(.networkConnectionLost))
        await flushMainActor()

        XCTAssertFalse(client.isConnected)
        XCTAssertTrue(didDisconnect)
    }

    func testSupersededReceiveLoopDoesNotClobberNewConnection() async {
        let transport = FakeTransport()
        let socketA = FakeSocket()
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)
        var disconnectCount = 0
        client.onDisconnected = { disconnectCount += 1 }

        let connectA = Task { try? await client.connect() }
        transport.open(socketA)
        _ = await connectA.value
        XCTAssertTrue(client.isConnected)

        // Same-instance reconnect (the latent scenario this PR hardens):
        // connect() tears down socketA → A's receive() errors → A's late catch
        // must be a no-op, not clobber the new connection.
        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        _ = await connectB.value
        await flushMainActor()  // let A's superseded catch run

        XCTAssertTrue(socketA.cancelled, "Reconnect should cancel the superseded socket")
        XCTAssertTrue(client.isConnected, "A superseded loop must not mark the new connection disconnected")
        XCTAssertEqual(disconnectCount, 0, "A superseded loop must not fire onDisconnected")
    }

    // MARK: - connect() teardown of the prior connection

    func testConnectInvalidatesPriorTransport() async {
        let transport = FakeTransport()
        let socketA = FakeSocket()
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)

        let connectA = Task { try? await client.connect() }
        transport.open(socketA)
        _ = await connectA.value
        XCTAssertFalse(transport.invalidated)

        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        _ = await connectB.value

        XCTAssertTrue(transport.invalidated, "Reconnect must invalidate the prior transport/session")
        XCTAssertEqual(transport.socketsMade.count, 2)
    }

    func testConcurrentConnectSupersedesPriorWithoutHanging() async {
        // A second connect() while the first is still mid-handshake must resume
        // the first's open continuation (so the first connect() throws instead
        // of hanging forever), rather than overwriting and leaking it.
        let transport = FakeTransport()
        let socketA = FakeSocket()
        transport.nextSocket = { socketA }
        let client = makeClient(transport: transport)

        let connectA = Task { try? await client.connect() }
        await flushMainActor()  // let connectA reach and suspend in the handshake (A is never opened)

        let socketB = FakeSocket()
        transport.nextSocket = { socketB }
        let connectB = Task { try? await client.connect() }
        transport.open(socketB)
        _ = await connectB.value

        // If the continuation were leaked this await would hang and the test would time out.
        _ = await connectA.value
        XCTAssertTrue(client.isConnected)
    }

    // MARK: - Helpers

    private func makeClient(transport: FakeTransport) -> HermesClient {
        HermesClient(
            connection: HermesConnection(baseUrl: "https://test.example", ticket: "ticket"),
            transportFactory: { transport }
        )
    }

    private func flushMainActor() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

// MARK: - Test doubles

/// Single-use continuation gate: `wait()` suspends until `signal()` fires.
/// All access happens on the MainActor (tests + the connect path), so no locking.
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }
}

/// Controllable HermesWebSocket. receive() suspends until the test delivers a
/// message or fails it; cancel() mimics URLSession by erroring the in-flight
/// receive (real cancellation surfaces as a receive error).
private final class FakeSocket: HermesWebSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var cancelled = false
    private(set) var resumed = false
    var onResume: (() -> Void)?

    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    func resume() {
        resumed = true
        onResume?()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
        failReceive(URLError(.networkConnectionLost))
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        completionHandler(nil)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { receiveContinuation = $0 }
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

/// Records invalidate() and lets the test drive the handshake per socket.
/// Accessed only from the MainActor (the test + the connect path).
private final class FakeTransport: HermesWebSocketTransport {
    private(set) var invalidated = false
    private(set) var socketsMade: [FakeSocket] = []
    var nextSocket: (() -> FakeSocket)?
    private var openCallbacks: [(FakeSocket) -> Void] = []

    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket {
        let socket = nextSocket?() ?? FakeSocket()
        socketsMade.append(socket)
        openCallbacks.append { _ in onOpen(socket) }
        return socket
    }

    func invalidate() {
        invalidated = true
    }

    /// Fire the handshake-open callback for a socket this transport produced.
    func open(_ socket: FakeSocket) {
        guard let index = socketsMade.firstIndex(where: { $0 === socket }) else { return }
        openCallbacks[index](socket)
    }
}
