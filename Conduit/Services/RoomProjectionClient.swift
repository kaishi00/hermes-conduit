//
//  RoomProjectionClient.swift
//  Conduit
//
//  Read-only client for the Hub ANVIL Room projection (H1 frozen contract,
//  `feat/room-projection-v1-20260915` @ 078ff5a2):
//
//    GET /api/v1/rooms
//    GET /api/v1/rooms/{roomId}
//    GET /api/v1/rooms/{roomId}/events?after=N&limit=M
//
//  Authentication is `Authorization: Bearer <Paseo organization credential>`
//  with the `rooms:read` scope. The credential is stored per saved dashboard
//  (SavedDashboardRegistry identity → KeychainHelper scoped record), never in
//  a generic bearer-token bucket: two dashboards can point at two different
//  Hub deployments without sharing tokens.
//

import Foundation

/// The Hub connection record bound to one saved dashboard. `hubBaseURL` is
/// normalized through the same ConnectionURLPolicy as dashboard addresses —
/// remote hubs must be HTTPS; cleartext is allowed only on loopback/LAN/
/// Tailnet. `token` is the Hub-issued bearer credential.
struct RoomHubCredential: Codable, Equatable {
    let hubBaseURL: String
    let token: String
}

/// Transport seam for the Room client — the same shape as the app's other
/// injected seams: production sends through URLSession, tests substitute a
/// scripted transport (or a URLProtocol-backed session) without the client
/// knowing the difference.
struct RoomTransport {
    let send: (URLRequest) async throws -> (Data, URLResponse)

    init(send: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.send = send
    }

    static func urlSession(_ session: URLSession = .shared) -> RoomTransport {
        RoomTransport { request in
            try await session.data(for: request)
        }
    }
}

enum RoomProjectionError: LocalizedError, Equatable {
    /// The dashboard has no saved Hub credential — the seam is unconfigured
    /// for this dashboard, which is a different failure than a rejected one.
    case missingCredential
    /// The stored/normalized Hub base URL could not produce a request URL.
    case invalidBaseURL
    /// No HTTP response arrived (DNS, TLS, timeout, offline). The projection
    /// is stale, never failed-open.
    case transport(String)
    /// The response exceeded the safe bound before parsing.
    case oversizedResponse(limit: Int)
    /// A 2xx answer carried no decodable Room payload — a contract breach,
    /// never silently nil data.
    case undecodable(status: Int, detail: String)
    /// 401 — bearer missing, malformed, or revoked (`unauthorized`).
    /// Distinct from every 403: this is a credential problem, not a grant
    /// problem.
    case unauthorized(RoomProblem)
    /// 403 `insufficient_scope` — the bearer lacks `rooms:read`.
    case insufficientScope(RoomProblem)
    /// 403 `capability_denied` — the Hub's bound ANVIL subject lacks a
    /// durable room.read grant on this Room.
    case capabilityDenied(RoomProblem)
    /// 404 `room_not_found`.
    case roomNotFound(RoomProblem)
    /// 503 `room_projection_unavailable` — this Hub has no Room read seam.
    case projectionUnavailable(RoomProblem)
    /// 503 `authentication_unavailable` — Hub auth is down; retry later.
    case authenticationUnavailable(RoomProblem)
    /// 503 `infrastructure_unavailable` — Hub storage/auth unavailable.
    case infrastructureUnavailable(RoomProblem)
    /// Any other non-2xx, problem document preserved when decodable.
    case problem(status: Int, problem: RoomProblem?)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return AppLocalization.string("No Room hub credential is saved for this dashboard.")
        case .invalidBaseURL:
            return AppLocalization.string("The Room hub address is invalid.")
        case .transport(let detail):
            return AppLocalization.string("Could not reach the Room hub: \(detail)")
        case .oversizedResponse(let limit):
            return AppLocalization.string("The Room response exceeded \(String(limit)) bytes.")
        case .undecodable(let status, let detail):
            return AppLocalization.string("The Room hub answered HTTP \(String(status)) with an unreadable payload: \(detail)")
        case .unauthorized:
            return AppLocalization.string("The Room hub credential was rejected. Sign in again or replace the saved credential.")
        case .insufficientScope(let problem):
            return problem.detail ?? AppLocalization.string("The Room credential lacks the rooms:read scope.")
        case .capabilityDenied(let problem):
            return problem.detail ?? AppLocalization.string("The hub's ANVIL subject holds no room.read grant on this Room.")
        case .roomNotFound(let problem):
            return problem.detail ?? AppLocalization.string("The Room does not exist.")
        case .projectionUnavailable(let problem):
            return problem.detail ?? AppLocalization.string("This hub does not expose the ANVIL Room projection.")
        case .authenticationUnavailable(let problem):
            return problem.detail ?? AppLocalization.string("Room hub authentication is unavailable. Retry later.")
        case .infrastructureUnavailable(let problem):
            return problem.detail ?? AppLocalization.string("The Room hub is temporarily unavailable.")
        case .problem(let status, let problem):
            return problem?.detail ?? AppLocalization.string("The Room hub answered HTTP \(String(status)).")
        }
    }
}

/// Typed client for the three H1 read operations. It owns request
/// construction and response classification only — replay/cursor state
/// belongs to RoomReplayCoordinator + RoomReplayStore.
struct RoomProjectionClient {
    static let apiPrefix = "/api/v1"

    let credential: RoomHubCredential
    private let baseURL: String
    private let transport: RoomTransport
    private let cloudflareAccess: CloudflareAccessCredentials?
    private let maxResponseBytes: Int
    private let decoder: JSONDecoder

    init(
        credential: RoomHubCredential,
        transport: RoomTransport = .urlSession(),
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) throws {
        let normalized = try ConnectionURLPolicy.normalizedBaseURL(credential.hubBaseURL)
        self.credential = RoomHubCredential(hubBaseURL: normalized, token: credential.token)
        self.baseURL = normalized
        self.transport = transport
        self.cloudflareAccess = cloudflareAccess
        self.maxResponseBytes = maxResponseBytes
        self.decoder = JSONDecoder()
    }

    func listRooms() async throws -> RoomList {
        try await get("\(Self.apiPrefix)/rooms", as: RoomList.self)
    }

    func roomSnapshot(roomID: String) async throws -> RoomSnapshot {
        try await get(
            "\(Self.apiPrefix)/rooms/\(try pathComponent(roomID))",
            as: RoomSnapshot.self
        )
    }

    /// Deterministic cursor replay: committed events with room_seq > `after`,
    /// ascending. `after`/`limit` are clamped to the H1 contract bounds
    /// (after >= 0, 1 <= limit <= 500) so the client can never emit a query
    /// the Hub would 400.
    func replayEvents(
        roomID: String,
        after: Int,
        limit: Int = RoomEventPage.defaultLimit
    ) async throws -> RoomEventPage {
        let boundedAfter = max(0, after)
        let boundedLimit = min(max(1, limit), RoomEventPage.maximumLimit)
        return try await get(
            "\(Self.apiPrefix)/rooms/\(try pathComponent(roomID))/events",
            query: [
                URLQueryItem(name: "after", value: String(boundedAfter)),
                URLQueryItem(name: "limit", value: String(boundedLimit))
            ],
            as: RoomEventPage.self
        )
    }

    // MARK: - Request pipeline

    private func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: Response.Type
    ) async throws -> Response {
        let request = try makeRequest(path: path, query: query)
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw RoomProjectionError.transport(AppLocalization.string("No HTTP response"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw classifyFailure(status: http.statusCode, data: data)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RoomProjectionError.undecodable(
                status: http.statusCode,
                detail: String(describing: error)
            )
        }
    }

    private func makeRequest(path: String, query: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL + path) else {
            throw RoomProjectionError.invalidBaseURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw RoomProjectionError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        // Cloudflare Access service tokens attach only to https/wss requests
        // (applying(to:) enforces that boundary itself).
        if let cloudflareAccess {
            request = cloudflareAccess.applying(to: request)
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await transport.send(request)
        } catch let error as RoomProjectionError {
            throw error
        } catch let error as URLError {
            throw RoomProjectionError.transport(error.localizedDescription)
        } catch {
            if error is CancellationError { throw error }
            throw RoomProjectionError.transport(String(describing: error))
        }
        guard result.0.count <= maxResponseBytes else {
            throw RoomProjectionError.oversizedResponse(limit: maxResponseBytes)
        }
        return result
    }

    /// Status/problem classification is code-first per the H1 contract:
    /// 401 `unauthorized` (credential rejected) is a different failure than
    /// either 403 (`insufficient_scope` = missing API scope,
    /// `capability_denied` = missing ANVIL grant), and 503 splits three ways.
    private func classifyFailure(status: Int, data: Data) -> RoomProjectionError {
        let problem = try? decoder.decode(RoomProblem.self, from: data)
        switch status {
        case 401:
            return .unauthorized(problem ?? Self.fallbackProblem(status: status, code: "unauthorized"))
        case 403:
            switch problem?.code {
            case "capability_denied":
                return .capabilityDenied(problem!)
            case "insufficient_scope":
                return .insufficientScope(problem!)
            default:
                return .problem(status: status, problem: problem)
            }
        case 404:
            if let problem, problem.code == "room_not_found" {
                return .roomNotFound(problem)
            }
            return .problem(status: status, problem: problem)
        case 503:
            switch problem?.code {
            case "room_projection_unavailable":
                return .projectionUnavailable(problem!)
            case "authentication_unavailable":
                return .authenticationUnavailable(problem!)
            case "infrastructure_unavailable":
                return .infrastructureUnavailable(problem!)
            default:
                return .problem(status: status, problem: problem)
            }
        default:
            return .problem(status: status, problem: problem)
        }
    }

    private static func fallbackProblem(status: Int, code: String) -> RoomProblem {
        RoomProblem(
            type: nil,
            title: nil,
            status: status,
            detail: nil,
            code: code,
            requestID: nil
        )
    }

    /// Path parameters are URL-encoded per segment so a malformed room id
    /// can never rewrite the route (e.g. "../../", embedded slashes).
    private func pathComponent(_ value: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw RoomProjectionError.invalidBaseURL
        }
        return encoded
    }
}

extension RoomProjectionClient {
    /// Builds the client for one saved dashboard entirely from its scoped
    /// Keychain records — the Hub credential AND the dashboard's own
    /// Cloudflare Access token. The Room credential load is keyed by the
    /// dashboard UUID; the CF access record is bound to the hub's origin —
    /// neither can serve a different dashboard or a different hub.
    static func forDashboard(
        _ dashboardID: UUID,
        transport: RoomTransport = .urlSession()
    ) throws -> RoomProjectionClient {
        guard let credential = KeychainHelper.loadRoomHubCredential(dashboardID: dashboardID) else {
            throw RoomProjectionError.missingCredential
        }
        return try RoomProjectionClient(
            credential: credential,
            transport: transport,
            cloudflareAccess: KeychainHelper.loadCloudflareAccess(for: credential.hubBaseURL)
        )
    }
}
