//
//  WatchGeminiSocket.swift
//  Conduit Watch
//
//  The socket the Watch's Gemini Live session runs on
//  (designs/apple-watch-voice-direct.md). watchOS allows it only in
//  TN3135's cases; the call's play-and-record audio session is the one it
//  uses. URLSession, set up as AIProxySwift's Watch realtime session is:
//  the device runs found that Network framework connections were refused
//  before they got a route, while URLSession connected every time. Every
//  delegate callback is logged, so a refusal shows how it happened.
//

import Foundation
import Network

enum WatchSocketAPI: String {
    case urlSession
}

/// Makes each connection's socket and counts what went through them.
@MainActor
final class WatchSocketMeter {
    private(set) var bytesUp = 0
    private(set) var bytesDown = 0
    private(set) var opened = 0
    /// Frames received, and when the last one came (system uptime).
    private(set) var framesDown = 0
    private(set) var lastFrameAt: TimeInterval?
    /// The newest socket's state, as its last event gave it.
    private(set) var socketState = "none"
    var onFirstFrame: ((WatchSocketAPI) -> Void)?
    /// Every socket's delegate callbacks, with the socket's number in the
    /// call.
    var onSocketEvent: ((WatchSocketAPI, Int, String, [String: Any]) -> Void)?

    func makeSocket(_ url: URL) -> GeminiLiveSocket {
        opened += 1
        let number = opened
        socketState = "opening"
        let socket = WatchURLSessionGeminiLiveSocket(url: url)
        socket.onEvent = { [weak self] kind, fields in
            self?.socketEvent(.urlSession, number, kind, state: WatchURLSessionGeminiLiveSocket.state(after: kind, fields), fields)
        }
        onSocketEvent?(.urlSession, number, "created", [:])
        return WatchMeteredSocket(api: .urlSession, inner: socket, meter: self)
    }

    private func socketEvent(_ api: WatchSocketAPI, _ number: Int, _ kind: String, state: String?, _ fields: [String: Any]) {
        // An older connection (a GoAway handoff's) doesn't speak for the
        // newest.
        if number == opened, let state { socketState = state }
        onSocketEvent?(api, number, kind, fields)
    }

    fileprivate func sent(_ bytes: Int) {
        bytesUp += bytes
    }

    fileprivate func received(_ bytes: Int, api: WatchSocketAPI, first: Bool) {
        bytesDown += bytes
        framesDown += 1
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        guard first else { return }
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

/// A network path as the call's log records it.
enum WatchNetworkPath {
    static func describe(_ path: NWPath?) -> [String: Any] {
        guard let path else { return [:] }
        let types: [(NWInterface.InterfaceType, String)] = [(.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.other, "other"), (.loopback, "loopback")]
        var fields: [String: Any] = [
            "status": "\(path.status)",
            "uses": types.filter { path.usesInterfaceType($0.0) }.map(\.1),
            "interfaces": path.availableInterfaces.map { "\($0.name):\($0.type)" },
            "expensive": path.isExpensive,
            "constrained": path.isConstrained,
        ]
        if path.status != .satisfied { fields["unsatisfiedReason"] = "\(path.unsatisfiedReason)" }
        return fields
    }
}

// MARK: - URLSession

/// The URLSession socket, set up as AIProxySwift's realtime session is on
/// the Watch (the one open-source Watch app found that opens a WebSocket
/// there): an ephemeral session, the request marked as audio streaming.
/// Otherwise the iPhone's socket (Shared/GeminiLive), with every delegate
/// callback reported: when it opened, how it closed, the error it failed
/// with (and the path the system gave as the reason), and the
/// connection's metrics.
@MainActor
final class WatchURLSessionGeminiLiveSocket: GeminiLiveSocket {
    var onEvent: ((String, [String: Any]) -> Void)?

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate = WatchURLSessionSocketDelegate()

    init(url: URL) {
        var request = URLRequest(url: url)
        request.networkServiceType = .avStreaming
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        // Model audio frames are larger than URLSession's 1 MB default.
        task.maximumMessageSize = 16 * 1024 * 1024
        // Set before the task starts, and never again.
        delegate.onEvent = { [weak self] kind, fields in
            WatchVoiceMain.async { self?.onEvent?(kind, fields) }
        }
        task.resume()
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// The state an event leaves the socket in, for the timeline; nil when
    /// it doesn't change it (metrics).
    static func state(after kind: String, _ fields: [String: Any]) -> String? {
        switch kind {
        case "open": return "open"
        case "waiting": return "waiting"
        case "close": return "closed \(fields["code"] ?? "")"
        case "complete":
            guard let code = fields["code"] else { return "completed" }
            return "failed \(code)"
        default: return nil
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if let recorded = delegate.serverClose { return recorded }
            if task.closeCode != .invalid {
                let text = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return GeminiLiveServerClose(code: task.closeCode.rawValue, reason: text)
            }
            if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
                return GeminiLiveServerClose(code: http.statusCode, reason: "", isHTTPStatus: true)
            }
            guard ContinuousClock.now < deadline else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
        }
        return nil
    }
}

private final class WatchURLSessionSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: GeminiLiveServerClose?
    var onEvent: ((String, [String: Any]) -> Void)?

    var serverClose: GeminiLiveServerClose? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol negotiated: String?) {
        onEvent?("open", [:])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        recorded = GeminiLiveServerClose(code: closeCode.rawValue, reason: text)
        lock.unlock()
        onEvent?("close", ["code": closeCode.rawValue, "reason": String(text.prefix(160))])
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        onEvent?("waiting", [:])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var fields: [String: Any] = [:]
        if let error = error as NSError? {
            fields["domain"] = error.domain
            fields["code"] = error.code
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                fields["underlying"] = "\(underlying.domain) \(underlying.code)"
            }
            // URLSession puts the refused path in its errors (undocumented
            // key): "unsatisfied (…)" says why.
            if let path = error.userInfo["_NSURLErrorNWPathKey"] {
                fields["path"] = String("\(path)".prefix(240))
            }
        }
        if let http = task.response as? HTTPURLResponse { fields["http"] = http.statusCode }
        onEvent?("complete", fields)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        onEvent?("metrics", [
            "protocol": last.networkProtocolName ?? "",
            "cellular": last.isCellular,
            "expensive": last.isExpensive,
            "constrained": last.isConstrained,
            "multipath": last.isMultipath,
            "local": last.localAddress ?? "",
            "remote": last.remoteAddress ?? "",
            "reused": last.isReusedConnection,
            "transactions": metrics.transactionMetrics.count,
        ])
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
