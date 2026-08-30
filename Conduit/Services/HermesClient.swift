//
//  HermesClient.swift
//  Conduit
//
//  JSON-RPC over WebSocket client for the Hermes gateway.
//
//  ARCHITECTURE NOTE:
//  This client is deliberately thin — it only handles WebSocket transport
//  and JSON-RPC request/response correlation. ALL session state, busy state,
//  and reconnection logic lives in AppState.swift's syncSession().
//
//  The client reports stream events via onEvent callback and disconnects
//  via onDisconnected callback. AppState decides what to do with them.
//
//  LESSONS FROM RN BUILDS 17-30:
//  - `session.resume.running` and `session.info.running` are authoritative
//    turn state. Missing `running` means the gateway is too old for safe chat
//    controls.
//  - Use resumed.messages from session.resume RPC, including any in-flight
//    transcript state, rather than deriving liveness from message roles.
//    Since the compact resume (issue #106) the default openSession suppresses
//    that transcript (omit_messages) and AppState hydrates the persisted rows
//    over REST; openSessionLegacy is the variant whose response still carries
//    the messages.
//  - Do NOT merge gateway RPC session.list into the UI list — it reads from
//    the main DB containing ALL profiles. Use profile-scoped endpoint only.
//

import Foundation
import Combine
import os

// MARK: - JSON-RPC Types

private struct JsonRpcRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

private struct JsonRpcResponse: Decodable {
    let id: Int?
    let result: AnyCodable?
    let error: RpcError?
    let method: String?
    let params: AnyCodable?
}

struct RpcError: Decodable, Error, LocalizedError {
    let code: Int?
    let message: String

    var errorDescription: String? { message }
}

// Type-erased Codable for dynamic JSON
enum AnyCodable: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let v):
            try container.encode(v)
        case .number(let v):
            try container.encode(v)
        case .string(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .object(let v):
            try container.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Renders any AnyCodable type as a display string, not just raw strings.
    /// Tool input/output from the gateway often arrives as JSON objects/arrays.
    var descriptiveStringValue: String? {
        switch self {
        case .string(let s): return s
        case .null: return nil
        case .bool(let b): return String(b)
        case .number(let n): return String(n)
        case .array, .object:
            // Serialize complex types to pretty JSON
            if let data = try? JSONEncoder().encode(self),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return nil
        }
    }

    var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [AnyCodable]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: AnyCodable]? {
        if case .object(let o) = self { return o }
        return nil
    }

    // Deep conversion to native Swift types
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        }
    }
}

// MARK: - Stream Events

enum StreamEvent {
    case messageStart(sessionId: String)
    case messageDelta(sessionId: String, text: String)
    case reasoningDelta(sessionId: String, text: String)
    case messageComplete(sessionId: String, messageId: String?, content: String?, reasoning: String?)
    case messageError(sessionId: String, message: String)
    case messageInterrupted(sessionId: String)
    case sessionBusy(sessionId: String, busy: Bool)
    case sessionInfo(sessionId: String, snapshot: SessionRuntimeSnapshot)
    case sessionTitle(runtimeSessionId: String, storedSessionId: String, title: String)
    case toolStart(sessionId: String, toolName: String, toolInput: String?)
    case toolComplete(sessionId: String, toolName: String, toolOutput: String?)
    case reviewSummary(sessionId: String, activity: ReviewActivity)
    case clarify(sessionId: String, requestId: String, question: String, choices: [(label: String, value: String)])
    case approval(sessionId: String, activity: ApprovalActivity)
    case contextUpdate(sessionId: String, percent: Double, used: Int, max: Int)
    case cwdUpdate(sessionId: String, cwd: String)
    case modelUpdate(sessionId: String, model: String, provider: String)
    case agentCount(sessionId: String, count: Int)
    case delegateAgent(sessionId: String, activity: DelegateAgentActivity)
    case unparsed(payload: [String: Any])
}

/// Runtime fields returned by `session.resume` and `session.info`.
/// `running` is optional only so the client can identify an outdated gateway
/// and refuse to offer unreliable stop/steer controls.
struct SessionRuntimeSnapshot {
    let running: Bool?
    let status: String?
    let model: String?
    let provider: String?
    let cwd: String?
    let contextPercent: Double?
    let contextUsed: Int?
    let contextMax: Int?
    let activeAgents: Int?
    let reasoningEffort: String?
    let fast: Bool?
    /// Per-session approval bypass. This overrides the profile default while
    /// the conversation is active without changing `approvals.mode` itself.
    let yolo: Bool?
    let approvalsMode: String?
    let inflight: AnyCodable?
    let queued: AnyCodable?

    /// `session.resume` may include an in-flight or queued projection that is
    /// newer than the persisted database transcript. Keep that projection for
    /// a live turn; the REST transcript is otherwise the richer history view.
    var hasLiveProjection: Bool {
        [inflight, queued].contains { value in
            guard let value else { return false }
            // Mirror JavaScript's `Boolean(resumed.inflight || resumed.queued)`
            // check in Desktop. In particular, `queued: false` must not hide
            // the durable timestamped transcript.
            switch value {
            case .null:
                return false
            case .bool(let flag):
                return flag
            case .number(let number):
                return number != 0 && !number.isNaN
            case .string(let text):
                return !text.isEmpty
            case .array, .object:
                return true
            }
        }
    }

    /// The in-flight projection holds text that has not reached state.db yet.
    /// A resumed live turn needs this prefix before it accepts new token deltas.
    var inflightAssistantText: String {
        guard let object = inflight?.objectValue else { return "" }
        return ["assistant", "text", "content"]
            .compactMap { object[$0]?.stringValue }
            .first { !$0.isEmpty } ?? ""
    }

    init(
        object: [String: AnyCodable],
        inflight: AnyCodable? = nil,
        queued: AnyCodable? = nil
    ) {
        running = object["running"]?.boolValue
        status = object["status"]?.stringValue
        model = object["model"]?.stringValue
        provider = object["provider"]?.stringValue
        cwd = object["cwd"]?.stringValue
        contextPercent = object["context_percent"]?.doubleValue
        contextUsed = object["context_used"]?.intValue
        contextMax = object["context_max"]?.intValue
        activeAgents = object["active_agents"]?.intValue ?? object["active_subagents"]?.intValue
        reasoningEffort = object["reasoning_effort"]?.stringValue
            ?? object["reasoning"]?.stringValue
        fast = object["fast"]?.boolValue
            ?? object["fast_mode"]?.boolValue
        yolo = object["yolo"]?.boolValue
        approvalsMode = object["approvals_mode"]?.stringValue
            ?? object["approval_mode"]?.stringValue
            ?? object["approvals"]?.objectValue?["mode"]?.stringValue
        self.inflight = inflight
        self.queued = queued
    }
}

struct SessionResumeResult {
    let sessionId: String
    let messages: [ChatMessage]
    let snapshot: SessionRuntimeSnapshot
}

struct SessionBranchMessage {
    let role: MessageRole
    let content: String
}

/// Result of the newer active-turn correction RPC. `queued` is still a
/// successful delivery: Hermes accepted the correction while the agent was
/// in its short turn-build window and will run it next.
enum SessionRedirectOutcome: Equatable {
    case redirected
    case queued
    case rejected

    init(gatewayStatus: String?) {
        switch gatewayStatus?.lowercased() {
        case "redirected": self = .redirected
        case "queued": self = .queued
        default: self = .rejected
        }
    }
}

// MARK: - Pending Request

private struct PendingRequest {
    let continuation: CheckedContinuation<AnyCodable, Error>
    let timer: Timer?
}

// MARK: - WebSocket seam

/// The slice of `URLSessionWebSocketTask` that `HermesClient` depends on, so
/// the client can be driven against a fake transport in tests without a real
/// network. `AnyObject`-bound so the `===` identity checks (which tell a
/// superseded receive loop apart from the current socket) keep working on the
/// existential type.
protocol HermesWebSocket: AnyObject {
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: HermesWebSocket {}

/// Produces sockets for a `HermesClient` and owns the underlying session.
/// `makeSocket` wires the handshake callbacks (`onOpen` / `onCloseBeforeOpen`,
/// mirroring `URLSessionWebSocketDelegate`); `invalidate` tears the session
/// down. The production impl is a faithful extraction of the client's former
/// inline `URLSession` logic; tests supply a fake. All methods are invoked from
/// `HermesClient` on the MainActor; the protocol is left nonisolated so the
/// `URLSessionWebSocketTransport` default doesn't force closure-isolation hoops.
protocol HermesWebSocketTransport: AnyObject {
    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket

    func invalidate()
}

/// Production transport: one `URLSession` per socket, delegate-driven
/// handshake. Behaviour is identical to the client's pre-seam connect().
final class URLSessionWebSocketTransport: HermesWebSocketTransport {
    /// Explicit incoming-message bound for the production socket. URLSession's
    /// own default (1 MiB) closes the connection with close code 1009 as soon
    /// as a single WebSocket message exceeds it, which is how resuming a large
    /// session — one huge `session.resume` frame — used to kill Conduit's
    /// connection in a reconnect loop (issue #106). 4 MiB comfortably covers
    /// legitimate control payloads while staying bounded; the compact resume
    /// keeps transcript-sized payloads off the socket entirely.
    static let maximumMessageSize = 4 * 1024 * 1024

    private var session: URLSession?
    private var delegate: WebSocketOpenDelegate?

    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket {
        let delegate = WebSocketOpenDelegate()
        delegate.onOpen = onOpen
        delegate.onCloseBeforeOpen = onCloseBeforeOpen
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session
        self.delegate = delegate
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        return task
    }

    func invalidate() {
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }
}

/// URLSession only confirms the WebSocket handshake through its delegate. The
/// client must not issue session RPCs or paint a green indicator before this
/// callback, otherwise a just-opened socket can race its first `session.resume`.
private final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: ((any HermesWebSocket) -> Void)?
    var onCloseBeforeOpen: ((any HermesWebSocket) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onCloseBeforeOpen?(webSocketTask)
    }
}

// MARK: - HermesClient

@MainActor
final class HermesClient: ObservableObject {

    private let logger = Logger(subsystem: "com.milim.conduit", category: "HermesClient")

    // Published state for SwiftUI views
    @Published private(set) var isConnected = false

    // Non-published internal state
    private var socket: (any HermesWebSocket)?
    private var transport: (any HermesWebSocketTransport)?
    private let transportFactory: () -> any HermesWebSocketTransport
    private var requestId = 0
    private var pending = [Int: PendingRequest]()
    private var closedIntentionally = false
    private var receiveTask: Task<Void, Never>?
    private var socketHasOpened = false
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openTimeoutTask: Task<Void, Never>?

    let connection: HermesConnection
    let profile: String?
    let cloudflareAccess: CloudflareAccessCredentials?

    // Callback for stream events (set by AppState)
    var onEvent: ((StreamEvent) -> Void)?
    var onDisconnected: (() -> Void)?

    static let requestTimeout: TimeInterval = 30
    static let promptSubmitTimeout: TimeInterval = 180 // 3 minutes
    static let titleGenerationTimeout: TimeInterval = 90
    /// The legacy full-transcript resume is the RPC most likely to carry the
    /// largest payload over the slowest connections (issue #106 follow-up),
    /// so it gets a bounded-but-generous budget instead of the ordinary
    /// request timeout.
    static let legacyResumeTimeout: TimeInterval = 60

    init(
        connection: HermesConnection,
        profile: String? = nil,
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        transportFactory: @escaping () -> any HermesWebSocketTransport = { URLSessionWebSocketTransport() }
    ) {
        self.connection = connection
        self.profile = profile
        self.cloudflareAccess = cloudflareAccess
        self.transportFactory = transportFactory
    }

    // MARK: - Connection

    func connect() async throws {
        // Tear down any prior connection in full before installing a new one —
        // this mirrors disconnect()'s cleanup. Cancelling the receive task alone
        // is not enough: URLSessionWebSocketTask.receive() does not honor
        // cooperative cancellation, so a superseded loop stays alive until its
        // socket actually errors; cancelling the socket + invalidating the
        // session forces that error, after which the loop's identity guard
        // no-ops its late catch. Resuming the open continuation and failing
        // pending RPCs here also covers the case where the new connect() throws
        // before its own waitForSocketOpen (e.g. invalid URL) — without it the
        // prior connect() would hang forever and its RPCs would wait out their
        // own timers. (AppState makes a fresh HermesClient per reconnect and
        // disconnects the old one first, so this is defense-in-depth against an
        // intra-instance reconnect — which no caller does today.)
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        transport?.invalidate()
        transport = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: HermesError.connectionClosed)
        openContinuation = nil
        isConnected = false
        failAllPendingRequests(with: HermesError.connectionClosed)

        closedIntentionally = false
        socketHasOpened = false
        let url: URL
        do {
            url = try ConnectionURLPolicy.webSocketURL(
                baseURL: connection.baseUrl,
                path: "/api/ws",
                queryItems: [URLQueryItem(name: "ticket", value: connection.ticket)]
            )
        } catch {
            throw HermesError.invalidUrl
        }

        let transport = transportFactory()
        self.transport = transport

        var request = URLRequest(url: url)
        request = cloudflareAccess?.applying(to: request) ?? request
        let socket = transport.makeSocket(
            request: request,
            onOpen: { [weak self] socket in Task { @MainActor in self?.didOpen(socket) } },
            onCloseBeforeOpen: { [weak self] socket in Task { @MainActor in self?.didClose(socket) } }
        )
        self.socket = socket
        socket.resume()
        try await waitForSocketOpen(socket)
        isConnected = true
        logger.notice("WebSocket handshake completed")

        // Start listening for messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func waitForSocketOpen(_ socket: any HermesWebSocket) async throws {
        // The prior continuation (if any) is already resumed by connect()'s
        // teardown before we reach here, so just install this one.
        try await withCheckedThrowingContinuation { continuation in
            openContinuation = continuation
            openTimeoutTask?.cancel()
            openTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.failSocketOpen(socket, error: HermesError.timeout("WebSocket connection"))
            }
        }
    }

    private func didOpen(_ socket: any HermesWebSocket) {
        guard self.socket === socket, !socketHasOpened else { return }
        socketHasOpened = true
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume()
        openContinuation = nil
    }

    private func didClose(_ socket: any HermesWebSocket) {
        guard self.socket === socket, !socketHasOpened else { return }
        failSocketOpen(socket, error: HermesError.connectionClosed)
    }

    private func failSocketOpen(_ socket: any HermesWebSocket, error: Error) {
        guard self.socket === socket else { return }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        socket.cancel(with: .goingAway, reason: nil)
        self.socket = nil
        transport?.invalidate()
        transport = nil
        isConnected = false
        openContinuation?.resume(throwing: error)
        openContinuation = nil
    }

    private func receiveLoop() async {
        guard let socket = socket else { return }

        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                // A reconnect replaces `self.socket`; if this loop has been
                // superseded, drop the frame rather than dispatch it —
                // `handleMessage` has no identity check of its own and could
                // otherwise fire `onEvent`/resolve pending RPCs for the new
                // connection. Same guard the catch uses below.
                guard self.socket === socket else { break }
                switch message {
                case .data(let data):
                    handleMessage(data: data)
                case .string(let text):
                    handleMessage(data: Data(text.utf8))
                @unknown default:
                    break
                }
            } catch {
                // Socket closed or errored
                logger.error("WebSocket receive failed: \(error.localizedDescription, privacy: .public)")
                // Only tear down if this loop still owns the current socket.
                // A reconnect replaces `self.socket` and spawns a new loop; an
                // unguarded late catch from the superseded loop would mark the
                // healthy new connection disconnected and fail its in-flight
                // RPCs. didOpen/didClose/failSocketOpen guard the same way.
                guard self.socket === socket else { break }
                isConnected = false
                // No response can ever arrive on a dead socket; failing the
                // in-flight requests here keeps awaiting UI from hanging for
                // the remainder of each request's timeout.
                failAllPendingRequests(with: HermesError.connectionClosed)
                // Drop the dead socket: its `closeCode` stays `.invalid` after
                // a receive error, so leaving it installed would let `rpc`
                // re-issue against it and hang until its own timeout.
                self.socket = nil
                if !closedIntentionally {
                    onDisconnected?()
                }
                break
            }
        }
    }

    private func handleMessage(data: Data) {
        guard let json = try? JSONDecoder().decode(JsonRpcResponse.self, from: data) else {
            logger.error("Dropped undecodable inbound WebSocket frame (\(data.count) bytes)")
            return
        }

        // Handle RPC response (has id)
        if let id = json.id {
            guard let pending = pending.removeValue(forKey: id) else {
                logger.debug("Received unmatched RPC response id \(id)")
                return
            }
            logger.notice("Received RPC response id \(id)")
            pending.timer?.invalidate()
            if let error = json.error {
                pending.continuation.resume(throwing: error)
            } else {
                pending.continuation.resume(returning: json.result ?? .null)
            }
            return
        }

        // Handle stream event notification
        if json.method == "event", let params = json.params {
            handleStreamEvent(params: params)
        } else {
            logger.debug("Received non-event WebSocket notification without an RPC id")
        }
    }

    private func handleStreamEvent(params: AnyCodable) {
        if let event = StreamEventParser.parse(params: params) {
            onEvent?(event)
        }
    }

    func disconnect() {
        closedIntentionally = true
        receiveTask?.cancel()
        receiveTask = nil
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: HermesError.connectionClosed)
        openContinuation = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        transport?.invalidate()
        transport = nil
        isConnected = false
        failAllPendingRequests(with: HermesError.connectionClosed)
    }

    private func failAllPendingRequests(with error: Error) {
        for (_, request) in pending {
            request.timer?.invalidate()
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    // MARK: - RPC

    private func rpc(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = requestTimeout) async throws -> AnyCodable {
        // Require both a live socket and a completed handshake. A receive
        // error leaves the socket installed with `closeCode == .invalid`, so
        // closeCode alone would let an RPC ride a dead socket to its timeout.
        guard let socket, socket.closeCode == .invalid, isConnected else {
            throw HermesError.notConnected
        }

        let id = incrementRequestId()
        let scopedParams = scopeParams(params)
        let encodedParams = scopedParams?.mapValues { AnyCodable.from($0) }

        let request = JsonRpcRequest(id: id, method: method, params: encodedParams)
        let body = try JSONEncoder().encode(request)
        logger.notice("Sending RPC id \(id) method \(method, privacy: .public)")

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // Timeout
                let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        if let pending = self?.pending.removeValue(forKey: id) {
                            pending.continuation.resume(throwing: HermesError.timeout(method))
                        }
                    }
                }

                pending[id] = PendingRequest(continuation: continuation, timer: timer)

                // Hermes' established React Native client uses WebSocket text
                // frames (`socket.send(JSON.stringify(...))`). The gateway accepts
                // the connection but does not dispatch binary JSON-RPC frames.
                let text = String(decoding: body, as: UTF8.self)
                socket.send(.string(text)) { [weak self] error in
                    if let error {
                        self?.logger.error("RPC send failed for \(method, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        Task { @MainActor in
                            if let pending = self?.pending.removeValue(forKey: id) {
                                pending.timer?.invalidate()
                                pending.continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id: id)
            }
        })
    }

    private func cancelPendingRequest(id: Int) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timer?.invalidate()
        pending.continuation.resume(throwing: CancellationError())
    }

    private func incrementRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func scopeParams(_ params: [String: Any]?) -> [String: Any]? {
        var params = params ?? [:]
        if let profile, profile != "default" {
            params["profile"] = profile
        }
        return params.isEmpty ? nil : params
    }

    // MARK: - API Methods

    /// Matches the React Native transport: the default profile uses no
    /// parameters, while every other profile carries its gateway context even
    /// though `session.list` itself has no explicit arguments.
    func sessions() async throws -> [SessionSummary] {
        let result = try await rpc("session.list", params: nil)
        return MessageNormalizer.normalizeSessions(result, profile: profile)
    }

    /// Projects are a newer, optional gateway capability. Unlike the ordinary
    /// session catalog, membership comes from Hermes' server-side project tree
    /// so every Hermes client sees the same organization.
    func projects() async throws -> [ProjectSummary] {
        let result = try await rpc("projects.tree", params: ["preview_limit": 3])
        return MessageNormalizer.normalizeProjects(result, profile: profile)
    }

    func projectSessions(_ projectId: String) async throws -> ProjectSessionDetail? {
        let result = try await rpc("projects.project_sessions", params: ["project_id": projectId])
        return MessageNormalizer.normalizeProjectSessions(result, profile: profile)
    }

    func createProject(name: String, folders: [String]) async throws -> ProjectSummary? {
        let result = try await rpc("projects.create", params: [
            "name": name,
            "folders": folders,
            "primary_path": folders.first ?? "",
            "use": true
        ])
        guard let project = result.objectValue?["project"] else { return nil }
        return MessageNormalizer.normalizeProject(project, profile: profile)
    }

    func healthCheck() async throws {
        _ = try await rpc("session.list", params: nil, timeout: 8)
    }

    /// Resumes a session with the compact projection: `omit_messages` asks
    /// the gateway to suppress the persisted transcript copy in the response
    /// (`messages: []`) because the caller hydrates it through the
    /// authenticated REST history route, exactly like Hermes Desktop. Older
    /// gateways read `session.resume` params loosely and simply ignore the
    /// unknown flag, degrading to the historical full response. AppState owns
    /// the REST hydration and falls back to `openSessionLegacy` when no
    /// usable history source exists.
    func openSession(_ sessionId: String) async throws -> SessionResumeResult {
        try await resumeSession(sessionId, omitMessages: true)
    }

    /// Resume variant that carries the persisted transcript inside the RPC
    /// response. Used when compact resume cannot be hydrated (missing bridge,
    /// a gateway without the history endpoint, or history rows that resolved
    /// to a foreign session). Its response is the largest ordinary payload in
    /// the app, so it uses the dedicated `legacyResumeTimeout`.
    func openSessionLegacy(_ sessionId: String) async throws -> SessionResumeResult {
        try await resumeSession(sessionId, omitMessages: false)
    }

    /// Compact responses are tiny, so they ride the ordinary request budget;
    /// the legacy transcript response gets the generous bounded budget.
    static func resumeTimeout(omitMessages: Bool) -> TimeInterval {
        omitMessages ? requestTimeout : legacyResumeTimeout
    }

    private func resumeSession(_ sessionId: String, omitMessages: Bool) async throws -> SessionResumeResult {
        var params: [String: Any] = [
            "session_id": sessionId,
            "cols": 96,
            "source": "desktop"
        ]
        if omitMessages {
            params["omit_messages"] = true
        }
        let result = try await rpc(
            "session.resume",
            params: params,
            timeout: Self.resumeTimeout(omitMessages: omitMessages)
        )
        let object = result.objectValue ?? [:]
        let resolvedId = object["session_id"]?.stringValue ?? sessionId
        let messages = MessageNormalizer.normalizeMessages(
            object["messages"]?.arrayValue ?? []
        )
        var snapshotObject = object["info"]?.objectValue ?? [:]
        // The resume response owns the liveness fields. Keep `info` for the
        // rest of the runtime metadata, but let top-level values win.
        for key in ["running", "status"] {
            if let value = object[key] {
                snapshotObject[key] = value
            }
        }
        return SessionResumeResult(
            sessionId: resolvedId,
            messages: messages,
            snapshot: SessionRuntimeSnapshot(
                object: snapshotObject,
                inflight: object["inflight"],
                queued: object["queued"]
            )
        )
    }

    func busyInputMode() async throws -> BusyInputMode {
        let result = try await rpc("config.set", params: ["key": "busy", "value": "status"])
        let value = result.objectValue?["value"]?.stringValue?.lowercased()
        return BusyInputMode.fromGatewayValue(value)
    }

    func setBusyInputMode(_ mode: BusyInputMode) async throws {
        _ = try await rpc("config.set", params: ["key": "busy", "value": mode.rawValue])
    }

    func createSession(model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil, fast: Bool? = nil, cwd: String? = nil) async throws -> (sessionId: String, storedSessionId: String?, profile: String?) {
        var params: [String: Any] = [
            "cols": 96,
            "source": "desktop"
        ]
        // Keep this explicit instead of relying solely on the generic RPC
        // scope. Hermes Desktop does the same: a global gateway can otherwise
        // create an unscoped session in its launch/default profile.
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        if let model {
            params["model"] = model
            if let provider { params["provider"] = provider }
        }
        if let reasoningEffort { params["reasoning_effort"] = reasoningEffort }
        if let fast, fast { params["fast"] = true }
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { params["cwd"] = cwd }
        let result = try await rpc("session.create", params: params)
        let object = result.objectValue ?? [:]
        let sid = object["session_id"]?.stringValue ?? ""
        let stored = object["stored_session_id"]?.stringValue
        let profile = object["profile"]?.stringValue ?? object["profile_id"]?.stringValue
        return (sid, stored, profile)
    }

    /// Creates a historical fork rather than a blank conversation. Hermes
    /// preserves the supplied prefix, then lets the new session continue from
    /// the selected assistant response.
    func branchSession(
        parentSessionId: String,
        messages: [SessionBranchMessage],
        title: String,
        cwd: String?
    ) async throws -> (sessionId: String, storedSessionId: String?, profile: String?) {
        var params: [String: Any] = [
            "cols": 96,
            "source": "desktop",
            "parent_session_id": parentSessionId,
            "title": title,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["profile"] = profile
        }
        if let cwd, !cwd.isEmpty { params["cwd"] = cwd }
        let result = try await rpc("session.create", params: params)
        let object = result.objectValue ?? [:]
        let sessionId = object["session_id"]?.stringValue ?? ""
        guard !sessionId.isEmpty else { throw HermesError.invalidResponse }
        return (
            sessionId,
            object["stored_session_id"]?.stringValue,
            object["profile"]?.stringValue ?? object["profile_id"]?.stringValue
        )
    }

    func setSessionTitle(_ sessionId: String, title: String) async throws {
        _ = try await rpc("session.title", params: [
            "session_id": sessionId,
            "title": title
        ])
    }

    /// Reads the gateway's current title without guessing from the local
    /// catalog. This is particularly important for profile-scoped sessions,
    /// whose title can be updated asynchronously by Hermes.
    func sessionTitle(_ sessionId: String) async throws -> String? {
        let result = try await rpc("session.title", params: ["session_id": sessionId])
        let title = result.objectValue?["title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false) ? title : nil
    }

    /// Hermes' one-shot endpoint uses the configured title-capable model but
    /// does not add a message to the conversation history.
    func generateSessionTitle(
        _ sessionId: String,
        userMessage: String,
        assistantMessage: String,
        language: String? = nil
    ) async throws -> String? {
        let requestedLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let languageInstruction = requestedLanguage.isEmpty
            ? "Write the title in the same language the user is writing in."
            : "Write the title in \(requestedLanguage)."
        let userSnippet = String(userMessage.prefix(500))
        let assistantSnippet = String(assistantMessage.prefix(500))
        let result = try await rpc("llm.oneshot", params: [
            "session_id": sessionId,
            "task": "title_generation",
            "instructions": "Generate a short, descriptive title (3-7 words) for a conversation that starts with the following exchange. The title should capture the main topic or intent. \(languageInstruction) Return ONLY the title text, nothing else. No quotes, no punctuation at the end, no prefixes.",
            "input": "User: \(userSnippet)\n\nAssistant: \(assistantSnippet)",
            "max_tokens": 500,
            "temperature": 0.3
        ], timeout: Self.titleGenerationTimeout)
        return result.objectValue?["text"]?.stringValue
    }

    func sendPrompt(_ sessionId: String, text: String) async throws {
        _ = try await rpc("prompt.submit", params: [
            "session_id": sessionId,
            "text": text
        ], timeout: Self.promptSubmitTimeout)
    }

    func steer(_ sessionId: String, text: String) async throws {
        let result = try await rpc("session.steer", params: [
            "session_id": sessionId,
            "text": text
        ])
        if result.objectValue?["status"]?.stringValue == "rejected" {
            throw HermesError.steerRejected
        }
    }

    func redirect(_ sessionId: String, text: String) async throws -> SessionRedirectOutcome {
        let result = try await rpc("session.redirect", params: [
            "session_id": sessionId,
            "text": text
        ])
        return SessionRedirectOutcome(gatewayStatus: result.objectValue?["status"]?.stringValue)
    }

    func cancel(_ sessionId: String) async throws {
        _ = try await rpc("session.interrupt", params: [
            "session_id": sessionId
        ])
    }

    func respondToClarification(requestId: String, answer: String) async throws {
        _ = try await rpc("clarify.respond", params: [
            "request_id": requestId,
            "answer": answer
        ])
    }

    func respondToApproval(sessionId: String, choice: String) async throws {
        _ = try await rpc("approval.respond", params: [
            "choice": choice,
            "session_id": sessionId
        ])
    }

    func modelOptions(sessionId: String? = nil) async throws -> (model: String?, provider: String?, providers: [ProviderInfo]?) {
        var params: [String: Any] = ["explicit_only": true]
        if let sessionId { params["session_id"] = sessionId }
        let result = try await rpc("model.options", params: params)
        let obj = result.objectValue ?? [:]
        let model = obj["model"]?.stringValue
        let provider = obj["provider"]?.stringValue
        let providers = (obj["providers"]?.arrayValue ?? []).compactMap { ProviderInfo(from: $0) }
        return (model, provider, providers)
    }

    func setModel(_ sessionId: String, model: String, provider: String) async throws {
        _ = try await rpc("config.set", params: [
            "key": "model",
            "session_id": sessionId,
            "value": "\(model) --provider \(provider) --session"
        ])
    }

    func setReasoning(_ sessionId: String, effort: String) async throws {
        _ = try await rpc("config.set", params: [
            "key": "reasoning",
            "session_id": sessionId,
            "value": effort
        ])
    }

    func setFast(_ sessionId: String, enabled: Bool) async throws {
        _ = try await rpc("config.set", params: [
            "key": "fast",
            "session_id": sessionId,
            "value": enabled ? "fast" : "normal"
        ])
    }

    /// Session-only approval bypass, matching Desktop and the TUI's Shift+Tab.
    /// The persistent profile default is managed separately through Settings.
    func setSessionYolo(_ sessionId: String, enabled: Bool) async throws {
        _ = try await rpc("config.set", params: [
            "key": "yolo",
            "session_id": sessionId,
            "value": enabled ? "1" : "0"
        ])
    }

    func contextBreakdown(_ sessionId: String) async throws -> ContextBreakdown {
        let result = try await rpc("session.context_breakdown", params: [
            "session_id": sessionId
        ])
        return ContextBreakdown(from: result)
    }

    // MARK: - Slash Commands

    func commandsCatalog(sessionId: String? = nil) async throws -> AnyCodable {
        var params: [String: Any] = [:]
        if let sessionId { params["session_id"] = sessionId }
        return try await rpc("commands.catalog", params: params.isEmpty ? nil : params)
    }

    func executeSlash(sessionId: String, command: String) async throws -> AnyCodable {
        // Strip leading slashes so callers can pass "/clear" or "clear"
        let cleaned = command.replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        return try await rpc("slash.exec", params: [
            "session_id": sessionId,
            "command": cleaned
        ])
    }

    func dispatchCommand(sessionId: String, name: String, arg: String) async throws -> AnyCodable {
        return try await rpc("command.dispatch", params: [
            "session_id": sessionId,
            "name": name,
            "arg": arg
        ])
    }

    // MARK: - Attachments

    func attachImage(_ sessionId: String, base64: String, filename: String) async throws -> String? {
        let result = try await rpc("image.attach_bytes", params: [
            "session_id": sessionId,
            "content_base64": base64,
            "filename": filename
        ])
        return result.objectValue?["path"]?.stringValue
    }

    func attachPdf(_ sessionId: String, base64: String, filename: String) async throws {
        _ = try await rpc("pdf.attach", params: [
            "session_id": sessionId,
            "content_base64": base64,
            "filename": filename
        ], timeout: 120)
    }

    func attachFile(_ sessionId: String, dataUrl: String, name: String, path: String = "") async throws {
        _ = try await rpc("file.attach", params: [
            "session_id": sessionId,
            "data_url": dataUrl,
            "name": name,
            "path": path
        ], timeout: 120)
    }

    // MARK: - Cron

    func listCronJobs() async throws -> [CronJob] {
        let result = try await rpc("cron.list")
        let arr = result.objectValue?["jobs"]?.arrayValue ?? result.arrayValue ?? []
        return arr.compactMap { try? JSONDecoder().decode(CronJob.self, from: JSONSerialization.data(withJSONObject: $0.anyValue)) }
    }

    func cronRuns() async throws -> [CronRun] {
        let result = try await rpc("cron.runs")
        let arr = result.objectValue?["runs"]?.arrayValue ?? result.arrayValue ?? []
        return arr.compactMap { try? JSONDecoder().decode(CronRun.self, from: JSONSerialization.data(withJSONObject: $0.anyValue)) }
    }

    // delegateAgentActivity moved to StreamEventParser
}

// MARK: - Supporting Types

struct ProviderInfo: Equatable {
    let name: String
    let models: [ModelInfo]
}

struct ModelInfo: Equatable {
    let id: String
    let label: String?
    let reasoningCapable: Bool
}

extension ProviderInfo {
    init?(from codable: AnyCodable) {
        let object = codable.objectValue ?? [:]
        guard let name = object["slug"]?.stringValue ?? object["id"]?.stringValue ?? object["name"]?.stringValue,
              !name.isEmpty else { return nil }
        self.name = name
        self.models = (object["models"]?.arrayValue ?? []).compactMap { model in
            if let id = model.stringValue, !id.isEmpty {
                return ModelInfo(id: id, label: nil, reasoningCapable: false)
            }
            let item = model.objectValue ?? [:]
            guard let id = item["id"]?.stringValue ?? item["model"]?.stringValue ?? item["name"]?.stringValue,
                  !id.isEmpty else { return nil }
            return ModelInfo(
                id: id,
                label: item["label"]?.stringValue,
                reasoningCapable: item["reasoning"]?.boolValue ?? false
            )
        }
    }

}

struct ContextBreakdown {
    var categories: [(id: String, label: String, tokens: Int, color: String)]
    var contextMax: Int
    var contextPercent: Double
    var contextUsed: Int
    var estimatedTotal: Int
    var model: String?

    init(from codable: AnyCodable) {
        let obj = codable.objectValue ?? [:]
        self.categories = (obj["categories"]?.arrayValue ?? []).compactMap { cat in
            guard let id = cat.objectValue?["id"]?.stringValue,
                  let label = cat.objectValue?["label"]?.stringValue else { return nil }
            return (
                id: id,
                label: label,
                tokens: cat.objectValue?["tokens"]?.intValue ?? 0,
                color: cat.objectValue?["color"]?.stringValue ?? "amber"
            )
        }
        self.contextMax = obj["context_max"]?.intValue ?? 0
        self.contextPercent = obj["context_percent"]?.doubleValue ?? 0
        self.contextUsed = obj["context_used"]?.intValue ?? 0
        self.estimatedTotal = obj["estimated_total"]?.intValue ?? 0
        self.model = obj["model"]?.stringValue
    }

    /// Hermes versions have reported `context_percent` both as a 0...1
    /// fraction and a 0...100 percentage. Prefer the actual token totals when
    /// available so the composer ring has one stable representation.
    var resolvedUsed: Int {
        if contextUsed > 0 { return contextUsed }
        if estimatedTotal > 0 { return estimatedTotal }
        return categories.reduce(0) { $0 + $1.tokens }
    }

    var resolvedPercent: Double {
        // Match the desktop client's live gauge. Token arithmetic is useful
        // only for older gateways that omit the explicit usage value; several
        // context engines count categories differently from the active window.
        if contextPercent > 0 { return normalizedPercent(contextPercent) }
        if contextMax > 0, resolvedUsed > 0 {
            return min(max((Double(resolvedUsed) / Double(contextMax)) * 100, 0), 100)
        }
        return 0
    }
}

private func normalizedPercent(_ value: Double) -> Double {
    let percent = (0...1).contains(value) ? value * 100 : value
    return min(max(percent, 0), 100)
}

// Alias for backward compatibility
extension ContextBreakdown {
    var contextCount: Int {
        get { contextUsed }
        set { contextUsed = newValue }
    }
}

enum HermesError: Error, LocalizedError {
    case invalidUrl
    case invalidResponse
    case notConnected
    case connectionClosed
    case timeout(String)
    case steerRejected

    var errorDescription: String? {
        switch self {
        case .invalidUrl: return "Invalid gateway URL."
        case .invalidResponse: return "Hermes returned an incomplete response."
        case .notConnected: return "Hermes is not connected."
        case .connectionClosed: return "Hermes connection closed."
        case .timeout(let method): return "Request timed out: \(method)"
        case .steerRejected: return "Hermes could not steer the active response."
        }
    }
}

// MARK: - AnyCodable.from helper

extension AnyCodable {
    static func from(_ value: Any) -> AnyCodable {
        if value is NSNull { return .null }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? Int { return .number(Double(v)) }
        if let v = value as? Double { return .number(v) }
        if let v = value as? String { return .string(v) }
        if let v = value as? [Any] { return .array(v.map { AnyCodable.from($0) }) }
        if let v = value as? [String: Any] { return .object(v.mapValues { AnyCodable.from($0) }) }
        return .null
    }
}

// MARK: - Message Normalization

/// Hermes' persisted display-projection contract. Some model-facing records —
/// model switches, personality pivots, auto-continuations, background-agent
/// completions, internal wake notices — are persisted as `role=user` rows so
/// strict OpenAI-compatible providers accept them mid-history, while
/// `display_kind` tells clients they are not human-authored messages and
/// `display_content` overrides the physical `content` with the text that
/// should actually be visible. The recognized values mirror Hermes Desktop's
/// transcript hydration; an unrecognized value is deliberately given no
/// display semantics so a future kind can never delete or reinterpret an
/// ordinary visible row.
private enum HermesDisplayKind: String {
    case hidden
    case modelSwitch = "model_switch"
    case personalitySwitch = "personality_switch"
    case autoContinue = "auto_continue"
    case asyncDelegationComplete = "async_delegation_complete"
    case internalNotification = "internal_notification"
}

enum MessageNormalizer {

    static func normalizeProjects(_ payload: AnyCodable, profile: String?) -> [ProjectSummary] {
        let records = payload.objectValue?["projects"]?.arrayValue ?? payload.arrayValue ?? []
        return records.compactMap { normalizeProject($0, profile: profile) }
    }

    static func normalizeProject(_ item: AnyCodable, profile: String?) -> ProjectSummary? {
        let object = item.objectValue ?? [:]
        let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { return nil }
        let title = firstNonEmptyString([
            object["label"], object["name"], object["title"]
        ]) ?? "Untitled project"
        let previews = object["preview_sessions"]?.arrayValue
            ?? object["previewSessions"]?.arrayValue
            ?? []
        let folderPath = object["folders"]?.arrayValue?
            .compactMap { $0.objectValue?["path"]?.stringValue }
            .first
        let count = object["session_count"]?.intValue
            ?? object["sessionCount"]?.intValue
            ?? object["session_count"]?.stringValue.flatMap(Int.init)
            ?? previews.count
        return ProjectSummary(
            id: id,
            title: title,
            primaryPath: firstNonEmptyString([object["path"], object["primary_path"], object["primaryPath"]]) ?? folderPath,
            icon: object["icon"]?.stringValue,
            colorHex: object["color"]?.stringValue,
            isHome: object["isNoProject"]?.boolValue ?? object["is_no_project"]?.boolValue ?? false,
            sessionCount: count,
            previewSessions: normalizeSessions(.array(previews), profile: profile)
        )
    }

    static func normalizeProjectSessions(_ payload: AnyCodable, profile: String?) -> ProjectSessionDetail? {
        guard let project = payload.objectValue?["project"]?.objectValue else { return nil }
        let id = project["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else { return nil }
        let title = firstNonEmptyString([project["label"], project["name"], project["title"]]) ?? "Project"
        let repos = project["repos"]?.arrayValue ?? []
        let multipleRepos = repos.count > 1
        var lanes: [ProjectSessionLane] = []

        for repo in repos {
            let repoObject = repo.objectValue ?? [:]
            let repoLabel = firstNonEmptyString([repoObject["label"], repoObject["path"]]) ?? "Workspace"
            for group in repoObject["groups"]?.arrayValue ?? [] {
                let groupObject = group.objectValue ?? [:]
                let groupID = groupObject["id"]?.stringValue ?? UUID().uuidString
                let groupLabel = firstNonEmptyString([groupObject["label"], groupObject["path"]]) ?? "Sessions"
                let sessions = normalizeSessions(.array(groupObject["sessions"]?.arrayValue ?? []), profile: profile)
                guard !sessions.isEmpty else { continue }
                lanes.append(ProjectSessionLane(
                    id: groupID,
                    title: multipleRepos ? "\(repoLabel) · \(groupLabel)" : groupLabel,
                    sessions: sessions
                ))
            }
        }

        if lanes.isEmpty {
            let previews = project["preview_sessions"]?.arrayValue ?? project["previewSessions"]?.arrayValue ?? []
            let sessions = normalizeSessions(.array(previews), profile: profile)
            if !sessions.isEmpty {
                lanes = [ProjectSessionLane(id: "\(id)-recent", title: "Recent", sessions: sessions)]
            }
        }
        return ProjectSessionDetail(id: id, title: title, lanes: lanes)
    }

    static func normalizeSessions(_ payload: AnyCodable, profile: String?) -> [SessionSummary] {
        let records: [AnyCodable]
        if let arr = payload.arrayValue {
            records = arr
        } else if let sessions = payload.objectValue?["sessions"]?.arrayValue {
            records = sessions
        } else {
            records = []
        }

        return records.enumerated().map { index, item in
            let obj = item.objectValue ?? [:]
            let runtimeSessionId = obj["session_id"]?.stringValue
            let id = runtimeSessionId ?? obj["id"]?.stringValue ?? String(index)
            let explicitStoredSessionId = ["stored_session_id", "storedSessionId"]
                .compactMap { obj[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let storedSessionId = explicitStoredSessionId ?? {
                // The legacy catalog shape exposes the durable ID as `id`
                // alongside a separate runtime `session_id`. A lone `id` is
                // ambiguous, so do not label it as a verified stored ID.
                guard runtimeSessionId != nil else { return nil }
                return obj["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }()

            // Collect alternate IDs
            let altKeys = ["session_id", "id", "stored_session_id", "runtime_session_id", "session_key"]
            let altIds = Set(altKeys.compactMap { obj[$0]?.stringValue }.filter { $0 != id && !$0.isEmpty })

            let explicitProfile = [
                "profile", "profile_name", "profileName", "profile_id", "profileId"
            ]
                .compactMap { obj[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let messageCount = ["message_count", "messageCount"].compactMap { key -> Int? in
                if let count = obj[key]?.intValue {
                    return count
                }
                if let count = obj[key]?.stringValue {
                    return Int(count)
                }
                return nil
            }.first

            return SessionSummary(
                id: id,
                storedSessionId: storedSessionId,
                alternateIds: Array(altIds),
                title: obj["title"]?.stringValue ?? obj["preview"]?.stringValue ?? "Untitled conversation",
                model: obj["model"]?.stringValue ?? "Hermes",
                updatedLabel: sessionUpdatedLabel(in: obj),
                profile: explicitProfile ?? profile,
                source: classifySource(obj),
                isActive: false,
                isArchived: obj["archived"]?.boolValue ?? false,
                messageCount: messageCount,
                lineageRootId: obj["_lineage_root_id"]?.stringValue
            )
        }
    }

    private static func sessionUpdatedLabel(in object: [String: AnyCodable]) -> String {
        let keys = [
            "last_active", "lastActive", "updated_at", "updatedAt", "updated",
            "last_message_at", "lastMessageAt", "latest_message_at", "latestMessageAt",
            "modified_at", "modifiedAt", "created_at", "createdAt", "timestamp", "time"
        ]

        for key in keys {
            guard let value = object[key], value != .null else { continue }
            switch value {
            case .number(let timestamp):
                return formattedSessionTimestamp(timestamp)
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let timestamp = Double(trimmed) {
                    return formattedSessionTimestamp(timestamp)
                }
                return trimmed
            default:
                continue
            }
        }
        return "recently"
    }

    private static func formattedSessionTimestamp(_ timestamp: Double) -> String {
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        let date = Date(timeIntervalSince1970: seconds)
        guard date.timeIntervalSince1970 > 0 else { return String(timestamp) }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func classifySource(_ obj: [String: AnyCodable]) -> SessionSource {
        // CRITICAL: classify BEFORE the chat whitelist (build 18 fix).
        // discord/telegram/webhook/api are NOT in the chat whitelist, so if we
        // test them against it, everything falls through to 'other'.

        let directSources = ["source", "origin", "platform"].compactMap { obj[$0]?.stringValue?.lowercased() }.filter { !$0.isEmpty }
        let handoffSource = (obj["handoff_platform"]?.stringValue ?? "").lowercased()

        // Check for cron metadata
        let hasCronMeta = ["cron_job_id", "cron_run_id", "scheduled_job_id", "schedule_id"].contains { obj[$0] != nil && obj[$0] != .null }
        let sessionId = (obj["session_id"]?.stringValue ?? obj["id"]?.stringValue ?? "").lowercased()
        let hasCronSessionId = sessionId.range(of: #"^(?:session[_:-])?cron[_:-]"#, options: .regularExpression) != nil
        let allReported = directSources + (handoffSource.isEmpty ? [] : [handoffSource])
        if hasCronMeta || hasCronSessionId || allReported.contains(where: {
            $0 == "cron" || $0 == "scheduled" || $0 == "scheduler" || $0.hasPrefix("cron:") || $0.hasPrefix("cron_") || $0.hasPrefix("scheduled:")
        }) {
            return .cron
        }

        // Classify external sources (RETURN IMMEDIATELY — do not fall through)
        func classify(_ source: String) -> SessionSource? {
            switch source {
            case "discord": return .discord
            case "telegram": return .telegram
            case "webhook": return .webhook
            case "api", "api-server", "api_server", "server": return .api
            default: return nil
            }
        }

        if let classified = directSources.compactMap(classify).first ?? classify(handoffSource) {
            return classified
        }

        let fallback = directSources.first ?? handoffSource
        let chatSources = ["", "desktop", "gateway", "tui", "chat", "web", "dashboard", "mobile", "cli", "local", "default", "unknown"]
        if chatSources.contains(fallback) { return .chat }
        return .other
    }

    static func normalizeMessages(_ payload: [AnyCodable]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var callsById = [String: ChatMessage]()

        for (index, item) in payload.enumerated() {
            let envelope = item.objectValue ?? [:]
            // Session history can wrap the actual persisted message in a
            // `message`, `payload`, or (when it is itself a message) `data`
            // object. Do not merge an arbitrary `data` field from a stored
            // tool result: those fields are often the tool's own payload.
            let dataMessage = envelope["data"]?.objectValue.flatMap { data -> [String: AnyCodable]? in
                (data["role"] != nil || data["type"] != nil) ? data : nil
            }
            let nested = envelope["message"]?.objectValue
                ?? envelope["payload"]?.objectValue
                ?? dataMessage
                ?? [:]
            let obj = envelope.merging(nested) { _, nestedValue in nestedValue }

            // Hermes' display projection is resolved before any content work.
            // A hidden row is pure model-facing scaffolding (compaction
            // handoffs, interrupted-turn checkpoints) that can be
            // multi-megabyte, so it is dropped before Markdown, compaction
            // scans, reasoning extraction, or tool interpretation — and
            // regardless of its physical role.
            let displayKind = HermesDisplayKind(
                rawValue: (obj["display_kind"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if displayKind == .hidden { continue }

            let rawRole = (obj["role"]?.stringValue ?? obj["type"]?.stringValue ?? "").lowercased()
            let isToolResult = rawRole == "tool" || rawRole.contains("tool_result") || rawRole.contains("tool-result")
            var role: MessageRole
            switch rawRole {
            case "user": role = .user
            case "system": role = .system
            case "reasoning", "thinking": role = .reasoning
            default: role = isToolResult ? .tool : .assistant
            }
            // The persisted `/messages` endpoint exposes SQLite message IDs as
            // numbers, whereas `session.resume` often has no stable message
            // identifier at all. Preserve either form so both sources retain
            // a deterministic row identity.
            let id = obj["id"]?.stringValue
                ?? obj["id"]?.descriptiveStringValue
                ?? obj["message_id"]?.stringValue
                ?? obj["message_id"]?.descriptiveStringValue
                ?? String(index)

            // `display_content` replaces the physical payload for
            // conversational rows. Tool results keep their legacy handling:
            // upstream only ever projects conversational rows, and a tool
            // output that merely contains display-like fields must not be
            // rewritten. The `??` keeps the physical carrier un-extracted
            // whenever a projection exists.
            let projectedContent = isToolResult ? nil : projectedDisplayContent(in: obj)
            let extractedContent = isToolResult
                ? extractToolOutput(obj)
                : projectedContent ?? extractContent(obj["content"] ?? obj["text"] ?? .null)
            // Compaction bookkeeping is removed before role/system/runtime
            // normalization so no summary text — standalone or merged onto a
            // real prompt — can reach a ChatMessage and the renderer.
            //
            // With an explicit display projection the physical carrier is
            // never scanned and the projected text is never re-judged: the
            // legacy delimiter search, the `_compressed_summary` flag, and
            // the summary-prefix guard cannot discard authentic
            // `display_content` (ordering matters here — the compatibility
            // filters are only for rows lacking display metadata).
            let rawContent: String?
            if let projected = projectedContent {
                rawContent = projected
            } else {
                rawContent = visibleContentRemovingCompaction(
                    from: obj,
                    content: extractedContent,
                    isToolResult: isToolResult
                )
            }
            guard let rawContent else {
                continue
            }
            let modelChange = modelChangeActivity(fromText: rawContent)
            let systemNotice = systemNoticeText(fromText: rawContent)
            // A known synthetic display kind never renders as a human turn,
            // even when its persisted role is `user` and its text matches no
            // legacy marker. Unknown kinds keep ordinary normalization.
            if modelChange != nil || systemNotice != nil || (displayKind != nil && !isToolResult) {
                role = .system
            }
            let userContent: (content: String, rawContent: String?, attachments: [Attachment]?) = role == .user
                ? splitUserImageReferences(rawContent, messageId: id)
                : (content: rawContent, rawContent: nil, attachments: nil)
            let content: String
            if let displayKind, !isToolResult {
                // `displayKind` is non-nil here only for the known synthetic
                // timeline kinds: hidden rows were already dropped and
                // unknown values fail raw-value decoding above.
                content = timelineNoticeContent(
                    for: displayKind,
                    projected: projectedContent,
                    metadata: obj["display_metadata"],
                    modelChange: modelChange,
                    systemNotice: systemNotice,
                    rawVisible: rawContent
                )
            } else {
                content = modelChange.map {
                    "[Model has been changed to \($0.provider)/\($0.model)]"
                } ?? systemNotice ?? userContent.content
            }

            let reasoning = role == .assistant ? extractContent(obj["reasoning"] ?? obj["reasoning_content"] ?? .null) : nil
            // This deliberately follows Desktop's persisted-transcript parser:
            // only an assistant row with an actual array of tool calls creates
            // call cards. Treating an object-shaped `tool_calls` field as an
            // invocation turns incidental metadata into a duplicate "Tool"
            // card, often at the end of a later assistant reply.
            let tools = role == .assistant ? extractToolCalls(obj) : []

            if isToolResult {
                let callId = firstNonEmptyString([
                    obj["tool_call_id"], obj["call_id"], obj["tool_use_id"]
                ]) ?? ""
                let name = extractToolName(obj)
                // An ID is authoritative. Desktop falls back to tool name only
                // for legacy rows which genuinely have no call ID; using a
                // name fallback after an ID mismatch can attach an old call's
                // result to every later response.
                let match: ChatMessage?
                if !callId.isEmpty {
                    match = callsById[callId]
                } else if let name, !name.isEmpty {
                    match = messages.reversed().first { candidate in
                        guard let tool = candidate.tool else { return false }
                        return tool.name == name && (tool.output?.isEmpty != false)
                    }
                } else {
                    match = nil
                }
                if let match {
                    var updated = match
                    updated.tool?.output = content.isEmpty ? (match.tool?.output ?? "") : content
                    updated.tool?.status = .complete
                    if let idx = messages.firstIndex(where: { $0.id == match.id }) {
                        messages[idx] = updated
                        if !callId.isEmpty { callsById[callId] = updated }
                    }
                } else if let name = name as String?, !name.isEmpty {
                    // `session.resume` exposes a compact tool row with a
                    // context preview but deliberately omits its raw output.
                    // Preserve that as input instead of mislabeling it as an
                    // output after a reload.
                    let preview = content.isEmpty ? extractToolContext(obj) : nil
                    let m = ChatMessage(
                        id: id, role: .tool, content: "", timestamp: extractTimestamp(obj),
                        author: extractAuthor(obj), reasoning: nil,
                        tool: ToolActivity(
                            id: callId.isEmpty ? nil : callId,
                            name: name,
                            input: preview,
                            output: content.isEmpty ? nil : content,
                            status: .complete
                        )
                    )
                    messages.append(m)
                }
                continue
            }

            if let reasoning, !reasoning.isEmpty, !isDuplicateReasoning(reasoning, content) {
                messages.append(ChatMessage(
                    id: "\(id)-reasoning",
                    role: .reasoning,
                    content: reasoning,
                    timestamp: extractTimestamp(obj),
                    author: extractAuthor(obj)
                ))
            }

            // Timeline-projected rows are never self-improvement reviews, and
            // skipping detection also keeps their physical carrier
            // un-extracted.
            let review = role == .system && displayKind == nil
                ? reviewActivity(from: obj, eventSessionId: nil)
                : nil
            let base = ChatMessage(
                id: id,
                role: role,
                content: content,
                rawContent: modelChange == nil && systemNotice == nil ? userContent.rawContent : rawContent,
                timestamp: extractTimestamp(obj),
                author: extractAuthor(obj),
                reasoning: nil,
                review: review,
                attachments: userContent.attachments,
                displayKind: displayKind?.rawValue
            )

            // External session history occasionally includes a role-less
            // metadata envelope after the last real message. It normalizes to
            // `.assistant` with no text or tool calls; rendering that record
            // creates a phantom agent header with only its timestamp/actions.
            // Keep intentionally empty user rows (they can carry a locally
            // cached image attachment) and tool-only assistant rows, but omit
            // an assistant row that has no visible content of its own.
            if !content.isEmpty || (role != .assistant && tools.isEmpty) {
                messages.append(base)
            }

            for (toolIndex, tool) in tools.enumerated() {
                let callRow = ChatMessage(
                    id: "\(id)-tool-\(toolIndex)", role: .tool, content: "",
                    timestamp: base.timestamp, author: base.author, tool: tool
                )
                messages.append(callRow)
                if let toolId = tool.id { callsById[toolId] = callRow }
            }
        }

        return collapseDuplicateInterruptCorrections(in: messages)
    }

    /// `display_content` is the authoritative visible payload whenever the
    /// field exists — including an explicit empty string, JSON null, or an
    /// odd scalar, all of which resolve to authoritative empty text rather
    /// than a fallback. Field presence is the authority boundary: once the
    /// field exists, the physical carrier must never resurface, because a
    /// malformed projection falling back to physical content could expose
    /// model-facing internal rows. Nil return therefore means exactly
    /// "field absent".
    private static func projectedDisplayContent(in obj: [String: AnyCodable]) -> String? {
        guard let value = obj["display_content"] else { return nil }
        return extractContent(value)
    }

    /// `display_metadata` may arrive as a JSON object (current servers) or as
    /// unparsed JSON text (older backends). Anything malformed degrades to
    /// nil so a bad sidecar can never fail session normalization.
    private static func displayMetadataObject(_ value: AnyCodable?) -> [String: AnyCodable]? {
        guard let value else { return nil }
        if let object = value.objectValue { return object }
        guard let text = value.stringValue,
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            return nil
        }
        return object.mapValues { AnyCodable.from($0) }
    }

    /// Upstream persists `task_count` on `async_delegation_complete` rows so
    /// clients can phrase the completion notice. The count goes through
    /// `doubleValue` + `Int(exactly:)` so non-representable numbers (1e100,
    /// NaN, fractional) degrade to the generic notice instead of trapping
    /// normalization — malformed metadata must never fail hydration.
    private static func delegationCompleteNotice(metadata: AnyCodable?) -> String {
        guard let count = displayMetadataObject(metadata)?["task_count"]?.doubleValue,
              let taskCount = Int(exactly: count),
              taskCount > 0 else {
            return "Background agent work finished"
        }
        return taskCount == 1 ? "1 background agent finished" : "\(taskCount) background agents finished"
    }

    /// Final visible text for a row Hermes tags with a known synthetic
    /// display kind. These rows are timeline events — Hermes Desktop renders
    /// canned labels for them — so the physical scaffold text is never shown
    /// unless an explicit `display_content` projection supplies better copy.
    private static func timelineNoticeContent(
        for kind: HermesDisplayKind,
        projected: String?,
        metadata: AnyCodable?,
        modelChange: (model: String, provider: String)?,
        systemNotice: String?,
        rawVisible: String
    ) -> String {
        // `projected` is non-nil only when the `display_content` field
        // exists, and its value — including an explicit empty string — is
        // authoritative: trimming an empty projection back into absence
        // would fall through to canned labels or the physical carrier,
        // which must never resurface.
        switch kind {
        case .hidden:
            // Defense in depth: hidden rows are dropped before content work.
            // Never echo the physical carrier if that invariant ever breaks.
            return "Hidden system event"
        case .modelSwitch:
            // An explicit projection outranks the marker-derived card text;
            // without one, the persisted marker matches Conduit's existing
            // model-change card detection and keeps that presentation. A
            // marker the card regex cannot parse is still model scaffold, so
            // it degrades to the canned label rather than rendering raw.
            if let projected {
                return projected
            }
            if let modelChange {
                return "[Model has been changed to \(modelChange.provider)/\(modelChange.model)]"
            }
            return "Model changed"
        case .personalitySwitch:
            // The physical marker embeds the full persona prompt; surface a
            // canned label instead, like Hermes Desktop does.
            return projected ?? "Personality changed"
        case .autoContinue:
            return projected ?? "Resumed interrupted turn"
        case .asyncDelegationComplete:
            return projected ?? delegationCompleteNotice(metadata: metadata)
        case .internalNotification:
            // The row content is the operational notice itself (wake events,
            // background completions); show it as a system notice. An
            // explicit projection — including an empty one — is authoritative
            // and rendered verbatim; the canned label is only for rows that
            // have no projection at all, and the `[System: …]` strip applies
            // only to that no-projection fallback.
            if let projected {
                return projected
            }
            let visible = systemNotice ?? rawVisible
            return visible.isEmpty ? "System notification" : visible
        }
    }

    static func modelChangeActivity(fromText text: String) -> (model: String, provider: String)? {
        let pattern = #"^\s*\[?System:\s*The active model for this chat has changed to\s+(\S+)\s+via provider\s+(.+?)(?:\.\s+From this point forward\b|\.?\]\s*$|$)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let modelRange = Range(match.range(at: 1), in: text),
              let providerRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        let model = String(text[modelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = String(text[providerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !provider.isEmpty else { return nil }
        return (model, provider)
    }

    /// Hermes persists runtime instructions as transcript messages. They are
    /// not user prompts and should never inherit the outgoing user bubble.
    static func systemNoticeText(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "[System:"
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            var body = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix("]") {
                body.removeLast()
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return body.isEmpty ? nil : body
        }
        if isUserCorrectionInterruptionNotice(trimmed) {
            return "Response interrupted by a user correction."
        }
        return nil
    }

    static func isUserCorrectionInterruptionNotice(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("[This response was interrupted by a user correction.]") == .orderedSame
    }

    /// Hermes persists context-compaction summaries as ordinary transcript
    /// records — usually under a conversational role, and sometimes appended
    /// to a row that still holds the genuine user prompt. They are
    /// model-context bookkeeping, not chat messages, and can be large enough
    /// to stall the Markdown pipeline when mistaken for a visible bubble.
    /// Returns the content that should remain visible, or nil when the whole
    /// record is compaction bookkeeping and must not produce a ChatMessage.
    /// Tool-result rows bypass the filter: compaction artifacts only ride
    /// conversational roles, while a tool's own output may legitimately print
    /// the delimiter text.
    private static func visibleContentRemovingCompaction(
        from obj: [String: AnyCodable],
        content: String,
        isToolResult: Bool
    ) -> String? {
        if isToolResult { return content }

        // Standalone summaries announce themselves within the first bytes.
        // Dropping them here skips the merged-delimiter search, which would
        // otherwise walk a potentially multi-megabyte payload end-to-end.
        if hasCompactionSummaryPrefix(content) { return nil }

        if let range = content.range(of: compactionSummaryDelimiter) {
            // Merged row: the genuine prompt sits before the delimiter behind
            // an optional wrapper header; the summary suffix is never shown.
            // The flag does not preempt this branch — it marks the record as
            // carrying a summary, not as lacking a genuine prompt.
            var visible = String(content[..<range.lowerBound])
            // Strip the wrapper only as a leading header — a copy the user
            // quoted mid-message belongs to their message.
            if visible.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix(priorContextWrapperHeader),
                let wrapperRange = visible.range(of: priorContextWrapperHeader) {
                visible.removeSubrange(wrapperRange)
            }
            let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
            // After a second compaction the retained prefix can itself be an
            // older summary rather than a genuine prompt.
            guard !trimmed.isEmpty, !hasCompactionSummaryPrefix(trimmed) else { return nil }
            return trimmed
        }

        let flaggedAsSummary = obj["_compressed_summary"]?.boolValue == true
            || obj["metadata"]?.objectValue?["_compressed_summary"]?.boolValue == true
        // Flagged with no merged form is pure bookkeeping.
        return flaggedAsSummary ? nil : content
    }

    private static let compactionSummaryDelimiter =
        "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"

    private static let priorContextWrapperHeader =
        "[PRIOR CONTEXT — for reference only; not a new message]"

    /// Hermes emits multiple generations of compaction headers, and the
    /// reload path can drop the `_compressed_summary` flag while keeping the
    /// recognizable text. Match case-insensitively like the other Hermes
    /// bracketed notices, anchored at the start of the content so ordinary
    /// discussion of "context compaction" is never mistaken for a summary.
    /// Classification reads only a bounded head: leading whitespace is
    /// skipped by index and only the next 32 characters are compared, so a
    /// multi-megabyte summary is never copied or tail-scanned to classify it.
    static func hasCompactionSummaryPrefix(_ content: String) -> Bool {
        var headStart = content.startIndex
        while headStart < content.endIndex, content[headStart].isWhitespace {
            headStart = content.index(after: headStart)
        }
        let head = content[headStart...].prefix(32).lowercased()
        return head.hasPrefix("[context compaction")
            || head.hasPrefix("[context summary]:")
            || head.hasPrefix("[recent summary (")
    }

    /// Normalizes the gateway's native clarification event. Current Hermes
    /// sends string choices, while older integrations may send label/value
    /// objects; accepting both keeps the card answerable across gateways.
    static func clarifyActivity(from payload: [String: AnyCodable]) -> ClarifyActivity? {
        let requestIDCandidates = ["request_id", "requestId", "id"]
            .compactMap { payload[$0]?.stringValue }
        let requestId = requestIDCandidates
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let questionCandidates = ["question", "prompt", "text"]
            .compactMap { key in payload[key].map { extractContent($0) } }
        let question = questionCandidates
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requestId.isEmpty, !question.isEmpty else { return nil }

        let rawChoices = payload["choices"]?.arrayValue ?? payload["options"]?.arrayValue ?? []
        let choices = rawChoices.compactMap { choice -> ClarifyChoice? in
            if let text = choice.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return ClarifyChoice(label: text, value: text)
            }
            guard let object = choice.objectValue else { return nil }
            let labelCandidates = ["label", "title", "text", "name", "value"]
                .compactMap { key in object[key].map { extractContent($0) } }
            let label = labelCandidates
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let valueCandidates = ["value", "answer", "id"]
                .compactMap { key in object[key].map { extractContent($0) } }
            let value = valueCandidates
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? label
            guard !label.isEmpty, !value.isEmpty else { return nil }
            return ClarifyChoice(label: label, value: value)
        }
        let uniqueChoices = choices.reduce(into: [ClarifyChoice]()) { result, choice in
            if !result.contains(where: { $0.value == choice.value }) { result.append(choice) }
        }
        return ClarifyActivity(
            requestId: requestId,
            question: question,
            choices: uniqueChoices,
            status: .pending
        )
    }

    /// Normalizes Hermes' session-scoped command approval event. The current
    /// gateway sends `approval.request { command, description, choices }` and
    /// waits for `approval.respond { choice, session_id }` before continuing.
    static func approvalActivity(
        from payload: [String: AnyCodable],
        sessionId: String
    ) -> ApprovalActivity? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }

        let command = ["command", "code", "text"]
            .compactMap { payload[$0]?.stringValue }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = ["description", "message", "prompt"]
            .compactMap { payload[$0]?.stringValue }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Approval required"
        let choices = payload["choices"]?.arrayValue?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniqueChoices = choices.map { values in
            values.reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        }

        return ApprovalActivity(
            sessionId: normalizedSessionId,
            command: command,
            description: description,
            choices: uniqueChoices?.isEmpty == true ? nil : uniqueChoices,
            allowPermanent: payload["allow_permanent"]?.boolValue != false,
            smartDenied: payload["smart_denied"]?.boolValue == true,
            status: .pending
        )
    }

    private static func collapseDuplicateInterruptCorrections(in messages: [ChatMessage]) -> [ChatMessage] {
        var collapsed: [ChatMessage] = []
        for message in messages {
            guard message.role == .user,
                  let interruption = collapsed.last,
                  interruption.role == .system,
                  isUserCorrectionInterruptionNotice(interruption.rawContent ?? interruption.content),
                  let previousUser = collapsed.dropLast().last(where: { $0.role == .user }),
                  previousUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    == message.content.trimmingCharacters(in: .whitespacesAndNewlines) else {
                collapsed.append(message)
                continue
            }

            // Redirect persists the correction in Hermes itself. If it is an
            // exact repeat of the interrupted prompt, one visible bubble is
            // enough; retain the interruption marker and original user row.
        }
        return collapsed
    }

    /// Desktop persists uploaded images as `@image:/gateway/path/file.ext`
    /// tokens in the user prompt. Project those tokens into Conduit's regular
    /// attachment model so resumed cross-client sessions keep their previews.
    /// Retain the original prompt for replay/branch operations.
    private static func splitUserImageReferences(
        _ source: String,
        messageId: String
    ) -> (content: String, rawContent: String?, attachments: [Attachment]?) {
        let pattern = #"@image:(?:"([^"\r\n]+)"|'([^'\r\n]+)'|([^\s]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return (source, nil, nil)
        }

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = expression.matches(in: source, range: fullRange)
        guard !matches.isEmpty else { return (source, nil, nil) }

        var paths: [String] = []
        for match in matches {
            for group in 1..<match.numberOfRanges {
                let range = match.range(at: group)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: source) else { continue }
                let path = String(source[swiftRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { paths.append(path) }
                break
            }
        }
        guard !paths.isEmpty else { return (source, nil, nil) }

        var visibleContent = source
        for match in matches.reversed() {
            guard let range = Range(match.range, in: visibleContent) else { continue }
            visibleContent.removeSubrange(range)
        }
        visibleContent = visibleContent
            .replacingOccurrences(
                of: #"[ \t]+\r?\n"#,
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?:\r?\n){3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let attachments = paths.enumerated().map { index, path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return Attachment(
                id: "\(messageId)-gateway-image-\(index)",
                name: name.isEmpty ? "Attached image" : name,
                uri: path,
                mimeType: imageMimeType(for: path),
                kind: .image
            )
        }
        return (visibleContent, source, attachments)
    }

    private static func imageMimeType(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        default: return nil
        }
    }

    static func reviewActivity(from payload: [String: AnyCodable], eventSessionId: String?) -> ReviewActivity? {
        let text = extractContent(payload["text"] ?? payload["content"] ?? .null)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let activity = reviewActivity(fromText: text) else { return nil }

        var details = activity.details ?? []
        for key in ["details", "transcript", "messages", "output"] {
            guard let value = payload[key], value != .null else { continue }
            if key == "details", let values = value.arrayValue {
                details += values.map(extractContent).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            } else {
                let valueText = extractContent(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !valueText.isEmpty { details.append(valueText) }
            }
        }
        let fullSessionId = ["review_session_id", "reviewSessionId", "child_session_id", "childSessionId", "maintenance_session_id"]
            .compactMap { payload[$0]?.stringValue }
            .first { !$0.isEmpty && $0 != eventSessionId }
        let uniqueDetails = details.reduce(into: [String]()) { result, detail in
            if !result.contains(detail) { result.append(detail) }
        }
        return ReviewActivity(
            summary: activity.summary,
            details: uniqueDetails.isEmpty ? nil : uniqueDetails,
            fullSessionId: fullSessionId
        )
    }

    static func reviewActivity(fromText text: String) -> ReviewActivity? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "💾 Self-improvement review:"
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let parts = body.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let details = parts.filter { part in ["➕", "✏️", "➖"].contains { part.contains($0) } }
        guard !details.isEmpty else { return ReviewActivity(summary: body, details: nil, fullSessionId: nil) }
        let labels = Set(details.compactMap { detail -> String? in
            let lower = detail.lowercased()
            if lower.hasPrefix("user profile") { return "User profile" }
            if lower.hasPrefix("memory") { return "Memory" }
            if lower.hasPrefix("skill") { return "Skill" }
            return nil
        })
        let summary: String
        if labels.count == 1, let label = labels.first { summary = "\(label) updated" }
        else if labels.count > 1 { summary = "Memory and skills updated" }
        else { summary = "Self-improvement updates saved" }
        return ReviewActivity(summary: summary, details: details, fullSessionId: nil)
    }

    private static func extractContent(_ value: AnyCodable) -> String {
        switch value {
        case .null: return ""
        case .string(let s): return s
        case .array(let arr): return arr.map { extractContent($0) }.joined()
        case .object(let obj):
            if let text = obj["text"] { return extractContent(text) }
            if let content = obj["content"] { return extractContent(content) }
            if let data = try? JSONSerialization.data(withJSONObject: obj.mapValues { $0.anyValue }, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return ""
        default: return ""
        }
    }

    private static func extractToolOutput(_ obj: [String: AnyCodable]) -> String {
        let keys = ["result", "output", "tool_result", "response", "data", "stdout", "content", "text"]
        var parts: [String] = []
        for key in keys {
            if let val = obj[key], val != .null {
                let text = extractContent(val)
                if !text.isEmpty { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func extractToolContext(_ obj: [String: AnyCodable]) -> String? {
        guard let context = obj["context"] else { return nil }
        let value = extractContent(context).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func extractToolCalls(_ obj: [String: AnyCodable]) -> [ToolActivity] {
        let calls = obj["tool_calls"]?.arrayValue
            ?? obj["tools"]?.arrayValue
            ?? []
        return calls.map { call in
            let cobj = call.objectValue ?? [:]
            let fn = cobj["function"]?.objectValue ?? cobj
            let input = cobj["input"]?.objectValue ?? [:]
            let output = extractToolOutput(cobj)
            return ToolActivity(
                id: firstNonEmptyString([cobj["id"], cobj["tool_call_id"], cobj["call_id"]]),
                name: firstNonEmptyString([
                    cobj["name"], cobj["tool_name"], fn["name"], input["name"]
                ]) ?? "Tool",
                input: {
                    let raw = fn["arguments"] ?? cobj["input"] ?? cobj["arguments"] ?? cobj["args"] ?? cobj["command"] ?? cobj["code"] ?? .null
                    let s = raw.descriptiveStringValue ?? extractContent(raw)
                    return s.isEmpty ? nil : s
                }(),
                output: output.isEmpty ? nil : output,
                status: .complete
            )
        }
    }

    private static func extractToolName(_ obj: [String: AnyCodable]) -> String? {
        let tool = obj["tool"]?.objectValue ?? [:]
        let function = obj["function"]?.objectValue ?? [:]
        let input = obj["input"]?.objectValue ?? [:]
        return firstNonEmptyString([
            obj["tool_name"], obj["name"], function["name"], tool["name"], input["name"]
        ])
    }

    private static func firstNonEmptyString(_ values: [AnyCodable?]) -> String? {
        for value in values {
            guard let text = value?.stringValue ?? value?.descriptiveStringValue else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func extractAuthor(_ obj: [String: AnyCodable]) -> String? {
        let meta = obj["metadata"]?.objectValue ?? [:]
        let candidates = [obj["profile"], obj["profile_name"], obj["author"], obj["sender"], obj["agent_name"], obj["agent"], meta["profile"], meta["profile_name"], meta["author"]]
        for candidate in candidates {
            if let s = candidate?.stringValue, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        return nil
    }

    private static func extractTimestamp(_ obj: [String: AnyCodable]) -> String {
        let meta = obj["metadata"]?.objectValue ?? obj["meta"]?.objectValue ?? [:]
        let candidates = [
            obj["timestamp"], obj["timestamp_ms"], obj["timestampMs"], obj["created_at"], obj["createdAt"], obj["created"], obj["created_ms"], obj["createdMs"], obj["time"], obj["ts"], obj["date"], obj["datetime"],
            obj["updated_at"], obj["updatedAt"], obj["sent_at"], obj["sentAt"], obj["last_active"], obj["lastActive"],
            meta["timestamp"], meta["timestamp_ms"], meta["timestampMs"], meta["created_at"], meta["createdAt"], meta["created"], meta["created_ms"], meta["createdMs"], meta["time"], meta["ts"], meta["date"], meta["datetime"],
            meta["updated_at"], meta["updatedAt"], meta["sent_at"], meta["sentAt"], meta["last_active"], meta["lastActive"]
        ]
        for candidate in candidates {
            if candidate == nil || candidate == .null { continue }
            if let s = candidate?.stringValue { return s }
            if let n = candidate?.doubleValue { return String(n) }
        }
        return ""
    }

    private static func isDuplicateReasoning(_ reasoning: String, _ content: String) -> Bool {
        let normR = reasoning.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).joined()
        let normC = content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).joined()
        guard !normR.isEmpty, !normC.isEmpty else { return false }
        if normR == normC { return true }
        let shortest = min(normR.count, normC.count)
        return shortest >= 80 && (normR.hasPrefix(normC) || normC.hasPrefix(normR))
    }
}
