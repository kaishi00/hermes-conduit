//
//  WatchGeminiSocket.swift
//  Conduit Watch
//
//  The sockets the Watch's Gemini Live session runs on (test T2 of
//  designs/apple-watch-voice-direct.md). watchOS allows them only in
//  TN3135's cases: an app streaming audio, or a CallKit call. Two
//  implementations of the shared session's socket: Network framework,
//  which TN3135 names, and the iPhone's own URLSession socket, which a
//  developer report says watchOS refuses even then. Each attempt the
//  session makes takes the other one until one hears from Gemini; the log
//  shows which, and each Network framework path change (one watchOS 26
//  report saw the path drop about 35 s in).
//

import Foundation
import Network

enum WatchSocketAPI: String {
    case network
    case urlSession
}

/// Which socket a call uses, picked on the call screen: both in turn until
/// one works, or one only, to compare them.
enum WatchSocketChoice: String, CaseIterable, Identifiable {
    case alternate
    case network
    case urlSession

    static let key = "watchDirect.socket"
    static var current: WatchSocketChoice {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .alternate
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alternate: return "Both in turn"
        case .network: return "Network framework"
        case .urlSession: return "URLSession"
        }
    }

    var only: WatchSocketAPI? {
        switch self {
        case .alternate: return nil
        case .network: return .network
        case .urlSession: return .urlSession
        }
    }
}

/// Picks each connection's socket and counts what went through them.
@MainActor
final class WatchSocketMeter {
    private(set) var bytesUp = 0
    private(set) var bytesDown = 0
    private(set) var opened = 0
    /// The API whose connection first heard from Gemini; every later
    /// connection uses it.
    private(set) var workingAPI: WatchSocketAPI?
    let choice: WatchSocketChoice
    var onFirstFrame: ((WatchSocketAPI) -> Void)?
    var onWaiting: ((WatchSocketAPI, String) -> Void)?
    /// A Network framework connection's path: "ready" once it opens, then
    /// every path, viability or better-path change, for the ~35 s path
    /// cycling one watchOS 26 report describes.
    var onPathEvent: ((String, [String: Any]) -> Void)?

    init(choice: WatchSocketChoice = .alternate) {
        self.choice = choice
    }

    func makeSocket(_ url: URL) -> GeminiLiveSocket {
        let api = choice.only ?? workingAPI ?? (opened % 2 == 0 ? .network : .urlSession)
        opened += 1
        let inner: GeminiLiveSocket
        switch api {
        case .network:
            let socket = NetworkGeminiLiveSocket(url: url)
            socket.onWaiting = { [weak self] reason in self?.onWaiting?(.network, reason) }
            socket.onPathEvent = { [weak self] kind, fields in self?.onPathEvent?(kind, fields) }
            inner = socket
        case .urlSession:
            inner = URLSessionGeminiLiveSocket(url: url)
        }
        return WatchMeteredSocket(api: api, inner: inner, meter: self)
    }

    fileprivate func sent(_ bytes: Int) {
        bytesUp += bytes
    }

    fileprivate func received(_ bytes: Int, api: WatchSocketAPI, first: Bool) {
        bytesDown += bytes
        guard first else { return }
        if workingAPI == nil { workingAPI = api }
        onFirstFrame?(api)
    }
}

@MainActor
private final class WatchMeteredSocket: GeminiLiveSocket {
    let api: WatchSocketAPI
    private let inner: GeminiLiveSocket
    private let meter: WatchSocketMeter
    private var heardFromServer = false

    init(api: WatchSocketAPI, inner: GeminiLiveSocket, meter: WatchSocketMeter) {
        self.api = api
        self.inner = inner
        self.meter = meter
    }

    func send(_ text: String) async throws {
        try await inner.send(text)
        meter.sent(text.utf8.count)
    }

    func receive() async throws -> Data {
        let data = try await inner.receive()
        let first = !heardFromServer
        heardFromServer = true
        meter.received(data.count, api: api, first: first)
        return data
    }

    func close() {
        inner.close()
    }

    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        await inner.serverClose(within: timeout)
    }
}

// MARK: - Network framework

@MainActor
final class NetworkGeminiLiveSocket: GeminiLiveSocket {
    /// TN3135: without the grant a connection waits with ENETDOWN instead
    /// of failing. After this long the attempt fails, so the
    /// session tries again, with the other API.
    static let waitLimit: TimeInterval = 10

    var onWaiting: ((String) -> Void)?
    var onPathEvent: ((String, [String: Any]) -> Void)?

    private struct Message {
        let data: Data?
        let metadata: NWProtocolWebSocket.Metadata?
        let isComplete: Bool
    }

    private let connection: NWConnection
    private var isOpen = false
    private var closedError: Error?
    private var openWaiters: [WatchResumeOnce<Void>] = []
    private var pendingReceive: WatchResumeOnce<Message>?
    private var recordedClose: GeminiLiveServerClose?
    private var waitTimer: Timer?

    init(url: URL) {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        // Model audio frames are larger than the default limit.
        options.maximumMessageSize = 16 * 1024 * 1024
        let parameters = NWParameters.tls
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            WatchVoiceMain.async { self?.stateChanged(state) }
        }
        connection.pathUpdateHandler = { [weak self] path in
            WatchVoiceMain.async { self?.pathEvent("path", Self.describe(path)) }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            WatchVoiceMain.async { self?.pathEvent("viability", ["viable": viable]) }
        }
        connection.betterPathUpdateHandler = { [weak self] available in
            WatchVoiceMain.async { self?.pathEvent("betterPath", ["available": available]) }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    deinit {
        connection.cancel()
    }

    func send(_ text: String) async throws {
        try await waitUntilOpen()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> Data {
        try await waitUntilOpen()
        while true {
            let message = try await nextMessage()
            let opcode = message.metadata?.opcode
            if opcode == .close {
                let reason = message.data.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                recordedClose = GeminiLiveServerClose(code: message.metadata.map { Self.number($0.closeCode) } ?? 0, reason: reason)
                fail(NetworkGeminiLiveSocketError.closed)
                throw NetworkGeminiLiveSocketError.closed
            }
            if opcode == .ping || opcode == .pong { continue }
            if let data = message.data, !data.isEmpty { return data }
            // Nothing more will come.
            if opcode == nil, message.isComplete {
                fail(NetworkGeminiLiveSocketError.closed)
                throw NetworkGeminiLiveSocketError.closed
            }
        }
    }

    func close() {
        fail(NetworkGeminiLiveSocketError.closed)
    }

    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while recordedClose == nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return recordedClose
    }

    private func waitUntilOpen() async throws {
        if let closedError { throw closedError }
        if isOpen { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openWaiters.append(WatchResumeOnce(continuation))
        }
    }

    private func nextMessage() async throws -> Message {
        if let closedError { throw closedError }
        let connection = connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Message, Error>) in
            let pending = WatchResumeOnce(continuation)
            pendingReceive = pending
            connection.receiveMessage { data, context, isComplete, error in
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                WatchVoiceMain.async {
                    if let error {
                        pending.resume(.failure(error))
                    } else {
                        pending.resume(.success(Message(data: data, metadata: metadata, isComplete: isComplete)))
                    }
                }
            }
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        guard closedError == nil else { return }
        switch state {
        case .ready:
            waitTimer?.invalidate()
            waitTimer = nil
            isOpen = true
            onPathEvent?("ready", Self.describe(connection.currentPath))
            let waiters = openWaiters
            openWaiters = []
            waiters.forEach { $0.resume(.success(())) }
        case .waiting(let error):
            onWaiting?("\(error)")
            guard waitTimer == nil else { return }
            waitTimer = WatchVoiceMain.timer(every: Self.waitLimit, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.fail(error) }
            }
        case .failed(let error):
            fail(error)
        case .cancelled:
            fail(NetworkGeminiLiveSocketError.closed)
        default:
            break
        }
    }

    private func pathEvent(_ kind: String, _ fields: [String: Any]) {
        guard closedError == nil, isOpen else { return }
        onPathEvent?(kind, fields)
    }

    private func fail(_ error: Error) {
        guard closedError == nil else { return }
        closedError = error
        isOpen = false
        waitTimer?.invalidate()
        waitTimer = nil
        let waiters = openWaiters
        openWaiters = []
        waiters.forEach { $0.resume(.failure(error)) }
        pendingReceive?.resume(.failure(error))
        pendingReceive = nil
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
        connection.betterPathUpdateHandler = nil
        connection.cancel()
    }

    private static func number(_ code: NWProtocolWebSocket.CloseCode) -> Int {
        switch code {
        case .protocolCode(let defined): return Int(defined.rawValue)
        case .applicationCode(let value): return Int(value)
        case .privateCode(let value): return Int(value)
        @unknown default: return 0
        }
    }

    /// Which way the traffic goes: on a Watch without cellular, through
    /// the iPhone ("other") or Wi-Fi.
    static func describe(_ path: NWPath?) -> [String: Any] {
        guard let path else { return [:] }
        let types: [(NWInterface.InterfaceType, String)] = [(.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.other, "other"), (.loopback, "loopback")]
        return [
            "status": "\(path.status)",
            "uses": types.filter { path.usesInterfaceType($0.0) }.map(\.1),
            "interfaces": path.availableInterfaces.map { "\($0.name):\($0.type)" },
            "expensive": path.isExpensive,
            "constrained": path.isConstrained,
        ]
    }
}

enum NetworkGeminiLiveSocketError: LocalizedError {
    case closed

    var errorDescription: String? {
        switch self {
        case .closed: return "The connection to Gemini closed."
        }
    }
}

/// A continuation resumed once, by whichever of its callers comes first:
/// the network's answer, a timeout or a close.
@MainActor
final class WatchResumeOnce<Value> {
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
