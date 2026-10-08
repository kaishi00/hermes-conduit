//
//  GrokLiveClient.swift
//  Conduit
//
//  Grok Live runs through the Hermes host: the conduit_push dashboard
//  plugin opens xAI's realtime socket with the host's SuperGrok sign-in
//  (or its XAI_API_KEY) and relays Conduit's events both ways. The xAI
//  credential never reaches Conduit; the socket is opened with the same
//  single-use dashboard ticket the speech stream uses.
//

import Foundation

enum GrokLiveClientError: LocalizedError, Equatable {
    case unavailable(GrokLiveAvailability)
    case socketUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable(let availability):
            return availability.userFacingReason
        case .socketUnavailable:
            return AppLocalization.string("Could not open the Grok Live connection.")
        }
    }
}

@MainActor
final class GrokLiveClient: GrokLiveConnecting {
    static let statusPath = "/api/plugins/conduit_push/grok-live/status"
    static let socketPath = "/api/plugins/conduit_push/grok-live/socket"

    /// The authenticated dashboard request, injected so tests can script
    /// responses. Production binds it to `DashboardTicketBridge.requestJSON`.
    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?, _ timeoutMilliseconds: Int) async throws -> [String: Any]
    /// Builds the relay's upgrade request for these query items (ticket and
    /// profile), with whatever headers the dashboard needs.
    typealias SocketRequest = @MainActor (_ path: String, _ queryItems: [URLQueryItem]) async throws -> URLRequest
    typealias MintTicket = @MainActor () async throws -> String

    private let request: Request
    private let mintTicket: MintTicket
    private let makeSocketRequest: SocketRequest
    /// The Hermes profile whose sign-in and settings the host uses.
    private let profile: @MainActor () -> String

    init(
        profile: @escaping @MainActor () -> String = { "default" },
        request: @escaping Request,
        mintTicket: @escaping MintTicket,
        socketRequest: @escaping SocketRequest
    ) {
        self.profile = profile
        self.request = request
        self.mintTicket = mintTicket
        self.makeSocketRequest = socketRequest
    }

    func availability() async throws -> GrokLiveAvailability {
        let response: [String: Any]
        do {
            response = try await request(DashboardPath.withProfile(Self.statusPath, profile: profile()), "GET", nil, 30_000)
        } catch let error as DashboardTicketBridgeError {
            if GeminiLiveTokenClient.isMissingRoute(error) { return .pluginMissing }
            throw error
        }
        return Self.availability(from: response)
    }

    func socketRequest() async throws -> URLRequest {
        let ticket = try await mintTicket()
        return try await makeSocketRequest(Self.socketPath, [
            URLQueryItem(name: "ticket", value: ticket),
            URLQueryItem(name: "profile", value: profile()),
        ])
    }

    // MARK: Parsing (static for tests)

    static func availability(from response: [String: Any]) -> GrokLiveAvailability {
        let reason = response["reason"] as? String ?? response["detail"] as? String ?? response["error"] as? String
        guard response["ok"] as? Bool == true, response["available"] as? Bool == true else {
            return .unavailable(reason: reason)
        }
        let model = (response["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? GrokLiveProtocol.defaultModel
        let voice = (response["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let auth = (response["auth"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .available(model: model, voice: voice, auth: auth)
    }
}
