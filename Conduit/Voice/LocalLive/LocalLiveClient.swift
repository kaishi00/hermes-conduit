//
//  LocalLiveClient.swift
//  Conduit
//
//  Local Live runs through the Hermes host: the conduit_push plugin relays
//  the call's audio to the user's speech server, the one Classic voice
//  listens through, and sends the call's turns to Conduit on the same
//  socket. The socket is opened with the same single-use dashboard ticket
//  the speech stream uses.
//

import Foundation

enum LocalLiveClientError: LocalizedError, Equatable {
    case unavailable(String)
    case socketUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .socketUnavailable:
            return AppLocalization.string("Could not open the Local Live connection.")
        }
    }
}

@MainActor
protocol LocalLiveConnecting: AnyObject {
    /// The upgrade request for one relay connection, with a fresh
    /// single-use ticket: call once per WebSocket.
    func socketRequest() async throws -> URLRequest
}

@MainActor
final class LocalLiveClient: LocalLiveConnecting {
    typealias Request = GrokLiveClient.Request
    typealias SocketRequest = GrokLiveClient.SocketRequest
    typealias MintTicket = GrokLiveClient.MintTicket

    private let request: Request
    private let mintTicket: MintTicket
    private let makeSocketRequest: SocketRequest
    private let profile: @MainActor () -> String
    /// The dashboard address, for the model address the status shows.
    private let dashboardBaseURL: @MainActor () -> String?

    init(
        profile: @escaping @MainActor () -> String = { "default" },
        dashboardBaseURL: @escaping @MainActor () -> String? = { nil },
        request: @escaping Request,
        mintTicket: @escaping MintTicket,
        socketRequest: @escaping SocketRequest
    ) {
        self.profile = profile
        self.dashboardBaseURL = dashboardBaseURL
        self.request = request
        self.mintTicket = mintTicket
        self.makeSocketRequest = socketRequest
    }

    /// Whether the host can run a call: a speech server address set, and a
    /// key the server can use to reach the plugin.
    func status() async throws -> SpeechServerVoiceStatus {
        let response: [String: Any]
        do {
            response = try await request(DashboardPath.withProfile(LocalLiveProtocol.statusPath, profile: profile()), "GET", nil, 30_000)
        } catch let error as DashboardTicketBridgeError {
            if GeminiLiveTokenClient.isMissingRoute(error) { return Self.pluginMissing }
            throw error
        }
        return SpeechServerVoiceStatus(response: response, dashboardBaseURL: dashboardBaseURL())
    }

    func socketRequest() async throws -> URLRequest {
        let ticket = try await mintTicket()
        return try await makeSocketRequest(LocalLiveProtocol.socketPath,
                                           [URLQueryItem(name: "ticket", value: ticket)] + LocalLiveProtocol.profileQueryItems(profile()))
    }

    static var pluginMissing: SpeechServerVoiceStatus {
        var status = SpeechServerVoiceStatus(unavailable: LocalLiveProtocol.pluginMissingReason)
        status.pluginMissing = true
        return status
    }

    /// Why a call can't start with this status; nil when it can.
    static func unavailableReason(_ status: SpeechServerVoiceStatus) -> String? {
        guard !status.available else { return nil }
        if let reason = status.reason, !reason.isEmpty { return reason }
        return AppLocalization.string("Local Live is not available on this Hermes server.")
    }
}
