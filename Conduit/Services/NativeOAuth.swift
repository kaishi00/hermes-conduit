//
//  NativeOAuth.swift
//  Conduit
//
//  Hermes brokered OAuth for native iOS clients: SFSafariViewController,
//  loopback callback, PKCE, Keychain tokens, refresh, and bearer REST.
//

import CryptoKit
import Foundation
import Network
import OSLog
import SafariServices
import Security
import SwiftUI
import UIKit

struct NativeOAuthTokenSet: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval
    let provider: String
    let userID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case provider
        case userID = "user_id"
    }

    func needsRefresh(now: Date = Date(), skewSeconds: TimeInterval = 60) -> Bool {
        expiresAt <= 0 || now.timeIntervalSince1970 >= expiresAt - skewSeconds
    }
}

struct NativeOAuthLoginResult {
    let tokens: NativeOAuthTokenSet
    let ticket: String
    /// Snapshot replaced when the authorization code was redeemed. Repair
    /// activation uses it to roll back atomically if the new socket cannot
    /// become authoritative.
    let previousTokens: NativeOAuthTokenSet?

    init(tokens: NativeOAuthTokenSet, ticket: String, previousTokens: NativeOAuthTokenSet? = nil) {
        self.tokens = tokens
        self.ticket = ticket
        self.previousTokens = previousTokens
    }
}

enum NativeOAuthError: LocalizedError, Equatable {
    case invalidURL
    case randomGenerationFailed
    case listenerFailed
    case callbackMalformed
    case callbackRejected
    case stateMismatch
    case tokenResponseMalformed
    case tokenStorageFailed
    case timedOut
    case requestFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return AppLocalization.string("The dashboard returned an invalid sign-in URL.")
        case .randomGenerationFailed: return AppLocalization.string("Could not prepare a secure sign-in request.")
        case .listenerFailed: return AppLocalization.string("Could not start the secure sign-in callback.")
        case .callbackMalformed: return AppLocalization.string("The dashboard returned an invalid sign-in response.")
        case .callbackRejected: return AppLocalization.string("The identity provider did not complete sign-in.")
        case .stateMismatch: return AppLocalization.string("The sign-in response failed its security check.")
        case .tokenResponseMalformed: return AppLocalization.string("The dashboard returned invalid authentication tokens.")
        case .tokenStorageFailed: return AppLocalization.string("Could not save this dashboard.")
        case .timedOut: return AppLocalization.string("Sign-in timed out. Please try again.")
        case .requestFailed(let status): return AppLocalization.string("Dashboard sign-in failed (HTTP \(String(status))).")
        }
    }
}

enum NativeOAuthHTTPReadError: Error, Equatable {
    case incomplete
    case tooLarge
}

struct NativeOAuthHTTPRequestAccumulator {
    let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int = 64 * 1024) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ chunk: Data) throws -> Bool {
        data.append(chunk)
        guard data.count <= maximumBytes else { throw NativeOAuthHTTPReadError.tooLarge }
        return data.range(of: Data("\r\n\r\n".utf8)) != nil
    }
}

enum NativeOAuthFlow {
    struct PKCEPair: Equatable {
        let verifier: String
        let challenge: String
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomURLSafe(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NativeOAuthError.randomGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    static func pkceChallenge(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func generatePKCE() throws -> PKCEPair {
        let verifier = try randomURLSafe(byteCount: 32)
        return PKCEPair(verifier: verifier, challenge: pkceChallenge(verifier: verifier))
    }

    static func authorizeURL(
        baseURL: String,
        challenge: String,
        redirectURI: String,
        state: String,
        provider: String? = nil
    ) throws -> URL {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              var components = URLComponents(string: "\(normalized)/auth/native/authorize") else {
            throw NativeOAuthError.invalidURL
        }
        var items = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        if let provider, !provider.isEmpty {
            items.append(URLQueryItem(name: "provider", value: provider))
        }
        components.queryItems = items
        guard let url = components.url else { throw NativeOAuthError.invalidURL }
        return url
    }

    static func callbackCode(
        requestTarget: String,
        expectedState: String,
        expectedPort: UInt16
    ) throws -> String {
        guard var components = URLComponents(string: "http://127.0.0.1:\(expectedPort)\(requestTarget)"),
              components.path == "/callback" else {
            throw NativeOAuthError.callbackMalformed
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { throw NativeOAuthError.callbackMalformed }
            values[item.name] = item.value ?? ""
        }
        guard values["state"] == expectedState else { throw NativeOAuthError.stateMismatch }
        if values["error"]?.isEmpty == false { throw NativeOAuthError.callbackRejected }
        guard let code = values["code"], !code.isEmpty else { throw NativeOAuthError.callbackMalformed }
        components.query = nil
        return code
    }
}

final class NativeOAuthAPIClient {
    let baseURL: String
    let cloudflareAccess: CloudflareAccessCredentials?
    private let session: URLSession
    private let redirectDelegate: SecureRedirectDelegate

    init(
        baseURL: String,
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.cloudflareAccess = cloudflareAccess
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpCookieStorage = nil
        let redirectDelegate = SecureRedirectDelegate(passwordLoginURL: nil)
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(configuration: sessionConfiguration, delegate: redirectDelegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func exchange(code: String, verifier: String) async throws -> NativeOAuthTokenSet {
        try await tokenRequest(path: "/auth/native/token", body: [
            "code": code,
            "code_verifier": verifier,
        ])
    }

    func refresh(_ tokens: NativeOAuthTokenSet) async throws -> NativeOAuthTokenSet {
        try await tokenRequest(path: "/auth/native/refresh", body: [
            "refresh_token": tokens.refreshToken,
            "provider": tokens.provider,
        ])
    }

    func requestJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        accessToken: String,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        var request = try endpointRequest(path: path)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(max(1_000, timeoutMilliseconds)) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DashboardTicketBridgeError.http(status: 0, detail: "No response from the dashboard.")
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > maxResponseBytes {
            throw DashboardTicketBridgeError.oversizedResponse(limit: maxResponseBytes)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxResponseBytes else {
                throw DashboardTicketBridgeError.oversizedResponse(limit: maxResponseBytes)
            }
            data.append(byte)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw DashboardTicketBridgeError.signInRequired
            }
            throw DashboardTicketBridgeError.http(
                status: http.statusCode,
                detail: Self.errorDetail(data) ?? "Dashboard request failed (\(http.statusCode))."
            )
        }
        guard !data.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data)
        if let object = value as? [String: Any] { return object }
        if let array = value as? [Any] { return ["_array": array] }
        return ["value": value]
    }

    func mintTicket(accessToken: String) async throws -> String {
        let response = try await requestJSON(
            path: "/api/auth/ws-ticket",
            method: "POST",
            accessToken: accessToken
        )
        guard let ticket = response["ticket"] as? String, !ticket.isEmpty else {
            throw DashboardTicketBridgeError.requestFailed("Dashboard did not return a WebSocket ticket.")
        }
        return ticket
    }

    private func tokenRequest(path: String, body: [String: String]) async throws -> NativeOAuthTokenSet {
        var request = try endpointRequest(path: path)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeOAuthError.requestFailed(status: 0) }
        let maximumTokenResponseBytes = 64 * 1024
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > maximumTokenResponseBytes {
            throw NativeOAuthError.tokenResponseMalformed
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumTokenResponseBytes else {
                throw NativeOAuthError.tokenResponseMalformed
            }
            data.append(byte)
        }
        guard (200...299).contains(http.statusCode) else {
            throw NativeOAuthError.requestFailed(status: http.statusCode)
        }
        guard let tokens = try? JSONDecoder().decode(NativeOAuthTokenSet.self, from: data),
              !tokens.accessToken.isEmpty else {
            throw NativeOAuthError.tokenResponseMalformed
        }
        return tokens
    }

    private func endpointRequest(path: String) throws -> URLRequest {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              let url = URL(string: "\(normalized)\(path)"),
              ConnectionURLPolicy.originMatches(url, expected: URL(string: normalized)) else {
            throw NativeOAuthError.invalidURL
        }
        return cloudflareAccess?.applying(to: URLRequest(url: url)) ?? URLRequest(url: url)
    }

    private static func errorDetail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["detail"] as? String ?? json["error"] as? String ?? json["message"] as? String
    }
}

@MainActor
final class NativeOAuthSession {
    private let dashboardID: UUID
    private let client: NativeOAuthAPIClient
    private var tokens: NativeOAuthTokenSet
    private var refreshTask: Task<NativeOAuthTokenSet, Error>?
    private var isInvalidated = false

    init?(baseURL: String, dashboardID: UUID, cloudflareAccess: CloudflareAccessCredentials?) {
        guard let tokens = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) else { return nil }
        self.dashboardID = dashboardID
        self.tokens = tokens
        self.client = NativeOAuthAPIClient(baseURL: baseURL, cloudflareAccess: cloudflareAccess)
    }

    init(tokens: NativeOAuthTokenSet, dashboardID: UUID, client: NativeOAuthAPIClient) {
        self.dashboardID = dashboardID
        self.tokens = tokens
        self.client = client
    }

    /// Compares the live grant without exposing it to callers or diagnostics.
    func matchesStoredTokens(_ storedTokens: NativeOAuthTokenSet) -> Bool {
        !isInvalidated && tokens == storedTokens
    }

    func invalidate() {
        isInvalidated = true
        refreshTask?.cancel()
        refreshTask = nil
        client.invalidate()
    }

    func requestJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeoutMilliseconds: Int = 12_000,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) async throws -> [String: Any] {
        guard !isInvalidated else { throw CancellationError() }
        if tokens.needsRefresh() { try await refresh() }
        let rejectedAccessToken = tokens.accessToken
        do {
            let response = try await client.requestJSON(
                path: path,
                method: method,
                body: body,
                accessToken: tokens.accessToken,
                timeoutMilliseconds: timeoutMilliseconds,
                maxResponseBytes: maxResponseBytes
            )
            guard !isInvalidated else { throw CancellationError() }
            return response
        } catch DashboardTicketBridgeError.signInRequired {
            try await refresh(rejectedAccessToken: rejectedAccessToken)
            let normalizedMethod = method.uppercased()
            let replayIsSafe = normalizedMethod == "GET"
                || normalizedMethod == "HEAD"
                || (normalizedMethod == "POST" && path == "/api/auth/ws-ticket")
            guard replayIsSafe else {
                throw DashboardTicketBridgeError.http(
                    status: 401,
                    detail: "Authentication was refreshed; retry this action."
                )
            }
            do {
                let response = try await client.requestJSON(
                    path: path,
                    method: method,
                    body: body,
                    accessToken: tokens.accessToken,
                    timeoutMilliseconds: timeoutMilliseconds,
                    maxResponseBytes: maxResponseBytes
                )
                guard !isInvalidated else { throw CancellationError() }
                return response
            } catch DashboardTicketBridgeError.signInRequired {
                if !isInvalidated {
                    KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
                }
                throw DashboardTicketBridgeError.signInRequired
            } catch let error as URLError where error.code == .cancelled && isInvalidated {
                throw CancellationError()
            }
        } catch let error as URLError where error.code == .cancelled && isInvalidated {
            throw CancellationError()
        }
    }

    func mintTicket() async throws -> String {
        let response = try await requestJSON(path: "/api/auth/ws-ticket", method: "POST")
        guard let ticket = response["ticket"] as? String, !ticket.isEmpty else {
            throw DashboardTicketBridgeError.requestFailed("Dashboard did not return a WebSocket ticket.")
        }
        return ticket
    }

    private func refresh(rejectedAccessToken: String? = nil) async throws {
        guard !isInvalidated else { throw CancellationError() }
        // Another request may already have refreshed the grant after this
        // request left with the rejected token. In that case reuse the newer
        // access token rather than rotating the refresh grant again.
        if let rejectedAccessToken, rejectedAccessToken != tokens.accessToken {
            return
        }
        if let refreshTask {
            // Every waiter observes the same normalized result and persistence
            // boundary, including rejected grants and invalidation.
            _ = try await refreshTask.value
            guard !isInvalidated else { throw CancellationError() }
            return
        }
        guard !tokens.refreshToken.isEmpty else {
            KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
            throw DashboardTicketBridgeError.signInRequired
        }
        let current = tokens
        let task = Task { @MainActor in
            defer { self.refreshTask = nil }
            do {
                let refreshed = try await self.client.refresh(current)
                guard !self.isInvalidated else { throw CancellationError() }
                self.tokens = refreshed
                KeychainHelper.saveNativeOAuthTokens(refreshed, dashboardID: self.dashboardID)
                return refreshed
            } catch NativeOAuthError.requestFailed(let status) where status == 400 || status == 401 {
                guard !self.isInvalidated else { throw CancellationError() }
                KeychainHelper.clearNativeOAuthTokens(dashboardID: self.dashboardID)
                throw DashboardTicketBridgeError.signInRequired
            } catch let error as URLError where error.code == .cancelled && self.isInvalidated {
                throw CancellationError()
            }
        }
        refreshTask = task
        _ = try await task.value
        guard !isInvalidated else { throw CancellationError() }
    }
}

final class NativeOAuthLoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.milim.conduit.native-oauth-loopback")
    private let expectedState: String
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var port: UInt16?
    private var terminalResult: Result<String, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    /// Every accepted local connection is queue-confined here until its
    /// response owns cancellation. Finishing the login cancels any client
    /// withholding the end of its headers, which also releases its read Task.
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start(timeout: TimeInterval = 5 * 60) async throws -> UInt16 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.terminalResult {
                        switch result {
                        case .failure(let error): continuation.resume(throwing: error)
                        case .success: continuation.resume(throwing: NativeOAuthError.listenerFailed)
                        }
                        return
                    }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        self.startContinuation = continuation
                        listener.stateUpdateHandler = { [weak self] state in self?.handle(state: state) }
                        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection: connection) }
                        listener.start(queue: self.queue)
                        let timeoutItem = DispatchWorkItem { [weak self] in self?.finish(.failure(NativeOAuthError.timedOut)) }
                        self.timeoutWorkItem = timeoutItem
                        self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
                    } catch {
                        continuation.resume(throwing: NativeOAuthError.listenerFailed)
                    }
                }
            }
        }, onCancel: { self.stop() })
    }

    func waitForCallback() async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.terminalResult {
                        continuation.resume(with: result)
                    } else {
                        self.callbackContinuation = continuation
                    }
                }
            }
        }, onCancel: { self.stop() })
    }

    func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

#if DEBUG
    func debugActiveConnectionCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.activeConnections.count) }
        }
    }
#endif

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            guard let rawPort = listener?.port?.rawValue else {
                finish(.failure(NativeOAuthError.listenerFailed))
                return
            }
            port = rawPort
            startContinuation?.resume(returning: rawPort)
            startContinuation = nil
        case .failed:
            if let continuation = startContinuation {
                continuation.resume(throwing: NativeOAuthError.listenerFailed)
                startContinuation = nil
            }
            finish(.failure(NativeOAuthError.listenerFailed))
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        guard terminalResult == nil else {
            connection.cancel()
            return
        }
        activeConnections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await self.readRequest(from: connection)
                self.queue.async { self.processRequest(request, on: connection) }
            } catch NativeOAuthHTTPReadError.tooLarge {
                self.queue.async {
                    self.sendResponse(on: connection, status: "431 Request Header Fields Too Large", message: "The sign-in response was too large.")
                }
            } catch {
                self.queue.async {
                    self.sendResponse(on: connection, status: "400 Bad Request", message: "The sign-in response was incomplete.")
                }
            }
        }
    }

    private func readRequest(from connection: NWConnection) async throws -> Data {
        var accumulator = NativeOAuthHTTPRequestAccumulator()
        while true {
            let (chunk, isComplete) = try await receiveChunk(from: connection)
            if let chunk, try accumulator.append(chunk) { return accumulator.data }
            if isComplete { throw NativeOAuthHTTPReadError.incomplete }
        }
    }

    private func receiveChunk(from connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func processRequest(_ request: Data, on connection: NWConnection) {
        guard let requestText = String(data: request, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first else {
            sendResponse(on: connection, status: "400 Bad Request", message: "The sign-in response was invalid.")
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET" else {
            sendResponse(on: connection, status: "405 Method Not Allowed", message: "Only GET callbacks are accepted.")
            return
        }
        guard let port else {
            sendResponse(on: connection, status: "503 Service Unavailable", message: "The sign-in callback is not ready.")
            finish(.failure(NativeOAuthError.listenerFailed))
            return
        }
        do {
            let code = try NativeOAuthFlow.callbackCode(
                requestTarget: String(parts[1]),
                expectedState: expectedState,
                expectedPort: port
            )
            sendResponse(on: connection, status: "200 OK", message: "✓ Signed in to Hermes. You can close this window and return to Conduit.")
            finish(.success(code))
        } catch NativeOAuthError.callbackRejected {
            sendResponse(on: connection, status: "400 Bad Request", message: "Sign-in was not completed. You can return to Conduit.")
            finish(.failure(NativeOAuthError.callbackRejected))
        } catch NativeOAuthError.stateMismatch {
            // A different local process must not be able to terminate the
            // pending login without knowing the high-entropy state value.
            sendResponse(on: connection, status: "400 Bad Request", message: "The sign-in response failed its security check.")
        } catch {
            // Ignore malformed probes and keep listening for the real browser
            // callback until cancellation or the bounded timeout.
            sendResponse(on: connection, status: "400 Bad Request", message: "The sign-in response was invalid.")
        }
    }

    private func sendResponse(on connection: NWConnection, status: String, message: String) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = "<!doctype html><meta charset=\"utf-8\"><title>Hermes sign-in</title><body style=\"font:15px system-ui;margin:3rem;text-align:center\"><p>\(escaped)</p>"
        let body = Data(html.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<String, Error>) {
        guard terminalResult == nil else { return }
        terminalResult = result
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.cancel()
        listener = nil
        for connection in activeConnections.values { connection.cancel() }
        activeConnections.removeAll()
        if let continuation = startContinuation {
            startContinuation = nil
            switch result {
            case .failure(let error): continuation.resume(throwing: error)
            case .success: continuation.resume(throwing: NativeOAuthError.listenerFailed)
            }
        }
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: result)
        }
    }
}

private let nativeOAuthLogger = Logger(subsystem: "com.milim.relay", category: "native-oauth")

@MainActor
final class NativeOAuthLoginModel: ObservableObject {
    @Published private(set) var authorizeURL: URL?
    private var server: NativeOAuthLoopbackServer?

    func run(
        baseURL: String,
        cloudflareAccess: CloudflareAccessCredentials?,
        provider: String?,
        dashboardID: UUID
    ) async throws -> NativeOAuthLoginResult {
        // A previous exchange may already have succeeded while its first
        // ticket mint failed transiently. Reuse that durable grant before
        // opening Safari and only reauthorize after confirmed rejection.
        if let existing = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID),
           let existingSession = NativeOAuthSession(
            baseURL: baseURL,
            dashboardID: dashboardID,
            cloudflareAccess: cloudflareAccess
           ) {
            do {
                let ticket = try await existingSession.mintTicket()
                let current = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) ?? existing
                return NativeOAuthLoginResult(
                    tokens: current,
                    ticket: ticket,
                    // Ticket minting may have rotated the refresh token. Any
                    // later activation rollback must retain this newest usable
                    // generation, not restore the rejected predecessor.
                    previousTokens: current
                )
            } catch DashboardTicketBridgeError.signInRequired {
                // The session cleared the rejected grant. Continue into a new
                // external-browser authorization below.
            }
        }
        let pkce = try NativeOAuthFlow.generatePKCE()
        let state = try NativeOAuthFlow.randomURLSafe(byteCount: 24)
        let server = NativeOAuthLoopbackServer(expectedState: state)
        self.server = server
        defer {
            server.stop()
            self.server = nil
        }
        let port = try await server.start()
        nativeOAuthLogger.notice("OAuth stage: listener ready")
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        authorizeURL = try NativeOAuthFlow.authorizeURL(
            baseURL: baseURL,
            challenge: pkce.challenge,
            redirectURI: redirectURI,
            state: state,
            provider: provider
        )
        let code = try await server.waitForCallback()
        nativeOAuthLogger.notice("OAuth stage: callback validated")
        let client = NativeOAuthAPIClient(baseURL: baseURL, cloudflareAccess: cloudflareAccess)
        let previousTokens = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID)
        let tokens = try await client.exchange(code: code, verifier: pkce.verifier)
        nativeOAuthLogger.notice("OAuth stage: token exchange succeeded")
        KeychainHelper.saveNativeOAuthTokens(tokens, dashboardID: dashboardID)
        guard KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) == tokens else {
            if let previousTokens {
                KeychainHelper.saveNativeOAuthTokens(previousTokens, dashboardID: dashboardID)
            } else {
                KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
            }
            throw NativeOAuthError.tokenStorageFailed
        }
        let session = NativeOAuthSession(tokens: tokens, dashboardID: dashboardID, client: client)
        let ticket = try await session.mintTicket()
        nativeOAuthLogger.notice("OAuth stage: ticket minted")
        let current = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) ?? tokens
        return NativeOAuthLoginResult(tokens: current, ticket: ticket, previousTokens: previousTokens)
    }

    func cancel() {
        server?.stop()
    }
}

struct NativeOAuthSignInSheet: View {
    let baseURL: String
    let cloudflareAccess: CloudflareAccessCredentials?
    let provider: String?
    let dashboardID: UUID
    let onSuccess: (NativeOAuthLoginResult) -> Void
    let onError: (Error) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = NativeOAuthLoginModel()

    var body: some View {
        // Keep one representable alive while authorizeURL changes and Safari
        // covers this sheet. Visibility changes are not OAuth cancellation.
        SafariAuthenticationView(
            url: model.authorizeURL,
            operation: {
                try await model.run(
                    baseURL: baseURL,
                    cloudflareAccess: cloudflareAccess,
                    provider: provider,
                    dashboardID: dashboardID
                )
            },
            onSuccess: { result in
                onSuccess(result)
                dismiss()
            },
            onError: { error in
                onError(error)
                dismiss()
            },
            onCancel: { dismiss() }
        )
        .ignoresSafeArea()
    }
}

/// Owns the operation until the representable is actually dismantled, not
/// merely covered by Safari or its password UI.
@MainActor
final class NativeOAuthPresentationTask {
    private var task: Task<Void, Never>?
    private var started = false
    private var cancelled = false

    func start(
        operation: @escaping @MainActor () async throws -> NativeOAuthLoginResult,
        onSuccess: @escaping @MainActor (NativeOAuthLoginResult) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard !started, !cancelled else { return }
        started = true
        task = Task { [weak self] in
            do {
                let result = try await operation()
                guard !Task.isCancelled, self?.cancelled == false else { return }
                onSuccess(result)
            } catch is CancellationError {
                nativeOAuthLogger.notice("OAuth stage: cancelled")
            } catch {
                guard !Task.isCancelled, self?.cancelled == false else { return }
                onError(error)
            }
            self?.task = nil
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

private struct SafariAuthenticationView: UIViewControllerRepresentable {
    let url: URL?
    let operation: @MainActor () async throws -> NativeOAuthLoginResult
    let onSuccess: @MainActor (NativeOAuthLoginResult) -> Void
    let onError: @MainActor (Error) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> NativeOAuthPresentationTask {
        NativeOAuthPresentationTask()
    }

    func makeUIViewController(context: Context) -> SafariPresenterViewController {
        let controller = SafariPresenterViewController(onCancel: {
            nativeOAuthLogger.notice("OAuth stage: user cancelled browser")
            context.coordinator.cancel()
            onCancel()
        })
        context.coordinator.start(operation: operation, onSuccess: onSuccess, onError: onError)
        return controller
    }

    func updateUIViewController(_ controller: SafariPresenterViewController, context: Context) {
        controller.setAuthorizeURL(url)
    }

    static func dismantleUIViewController(
        _ controller: SafariPresenterViewController,
        coordinator: NativeOAuthPresentationTask
    ) {
        nativeOAuthLogger.notice("OAuth stage: sign-in view removed")
        coordinator.cancel()
    }

    final class SafariPresenterViewController: UIViewController, SFSafariViewControllerDelegate {
        private var url: URL?
        private let onCancel: () -> Void
        private var safariViewController: SFSafariViewController?

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            spinner.startAnimating()
        }

        func setAuthorizeURL(_ url: URL?) {
            self.url = url
            presentSafariIfReady()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentSafariIfReady()
        }

        private func presentSafariIfReady() {
            guard let url, viewIfLoaded?.window != nil,
                  safariViewController == nil, presentedViewController == nil else { return }
            let configuration = SFSafariViewController.Configuration()
            configuration.entersReaderIfAvailable = false
            configuration.barCollapsingEnabled = false
            let safari = SFSafariViewController(url: url, configuration: configuration)
            safari.delegate = self
            safari.modalPresentationStyle = .fullScreen
            safariViewController = safari
            present(safari, animated: true) {
                nativeOAuthLogger.notice("OAuth stage: Safari presented")
            }
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onCancel()
        }
    }
}
