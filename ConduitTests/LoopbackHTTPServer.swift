//
//  LoopbackHTTPServer.swift
//  Conduit
//
//  A real HTTP/1.1 server on an OS-assigned loopback port, for tests that
//  must exercise the real URLSession stack (redirect delegate, cookies,
//  headers) rather than a URLProtocol stub. 127.0.0.1 and localhost are
//  different origins, which is how cross-origin cases are built.
//

import CryptoKit
import Foundation
import Network

struct LoopbackHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct LoopbackHTTPResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data
    /// A 101 upgrade: the head goes out without a body or `Connection:
    /// close`, and the connection stays open until the server stops.
    var keepsConnectionOpen = false

    /// A genuine WebSocket upgrade answer to `request`: 101 with the
    /// `Sec-WebSocket-Accept` RFC 6455 derives from the client's key, so a
    /// real `URLSessionWebSocketTask` completes its handshake.
    static func webSocketUpgrade(for request: LoopbackHTTPRequest) -> LoopbackHTTPResponse {
        let key = request.headers["sec-websocket-key"] ?? ""
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return LoopbackHTTPResponse(
            status: 101,
            headers: [
                ("Upgrade", "websocket"),
                ("Connection", "Upgrade"),
                ("Sec-WebSocket-Accept", Data(digest).base64EncodedString()),
            ],
            body: Data(),
            keepsConnectionOpen: true
        )
    }

    static func redirect(status: Int = 302, to location: String) -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(status: status, headers: [("Location", location)], body: Data())
    }

    static func status(_ status: Int) -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(status: status, headers: [], body: Data())
    }

    static func json(
        status: Int,
        headers: [(String, String)] = [],
        body: String
    ) -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json")] + headers,
            body: Data(body.utf8)
        )
    }
}

final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (LoopbackHTTPRequest) -> LoopbackHTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "conduit.native-auth.loopback",
        attributes: .concurrent
    )
    private let handler: Handler
    private let lock = NSLock()
    private var requests: [LoopbackHTTPRequest] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private init(listener: NWListener, handler: @escaping Handler) {
        self.listener = listener
        self.handler = handler
    }

    static func start(handler: @escaping Handler) throws -> LoopbackHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let server = LoopbackHTTPServer(listener: listener, handler: handler)
        try server.startAndWaitUntilReady()
        return server
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let activeConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in activeConnections {
            connection.cancel()
        }
    }

    func lastRequest(path: String) -> LoopbackHTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last(where: { $0.path == path })
    }

    /// Every request received so far, in arrival order.
    var receivedRequests: [LoopbackHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func startAndWaitUntilReady() throws {
        let ready = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                stateLock.lock()
                startError = error
                stateLock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw NSError(
                domain: "LoopbackHTTPServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out starting loopback HTTP server"]
            )
        }
        stateLock.lock()
        let error = startError
        stateLock.unlock()
        if let error {
            listener.cancel()
            throw error
        }
        guard port != 0 else {
            listener.cancel()
            throw NSError(
                domain: "LoopbackHTTPServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Loopback HTTP server did not receive a port"]
            )
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if let request = Self.parseRequest(from: accumulated) {
                lock.lock()
                requests.append(request)
                lock.unlock()
                send(handler(request), on: connection)
                return
            }
            if error != nil || isComplete {
                remove(connection)
                connection.cancel()
                return
            }
            receive(on: connection, buffer: accumulated)
        }
    }

    private func send(_ response: LoopbackHTTPResponse, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 101: reason = "Switching Protocols"
        case 200: reason = "OK"
        case 301: reason = "Moved Permanently"
        case 302: reason = "Found"
        case 307: reason = "Temporary Redirect"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        default: reason = "Response"
        }
        var header = "HTTP/1.1 \(response.status) \(reason)\r\n"
        for (name, value) in response.headers {
            header += "\(name): \(value)\r\n"
        }
        if response.keepsConnectionOpen {
            header += "\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            return
        }
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.remove(connection)
            connection.cancel()
        })
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private static func parseRequest(from data: Data) -> LoopbackHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return LoopbackHTTPRequest(
            method: parts[0],
            path: parts[1],
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}
