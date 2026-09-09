import Foundation

@MainActor
final class MessagingService {
    static let namespace = "/api/plugins/bot-coms-messaging/v1"
    let requester: any DashboardJSONRequester
    var capability: MessagingCapability?
    init(requester: any DashboardJSONRequester) { self.requester = requester }

    func request<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        var scopedPath = path
        if path != "/capabilities", let capability {
            var query = URLComponents()
            query.queryItems = [URLQueryItem(name: "expected_server", value: capability.serverID), URLQueryItem(name: "expected_principal", value: capability.principalID)]
            if let encoded = query.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") { scopedPath += (path.contains("?") ? "&" : "?") + encoded }
        }
        let object = try await requester.requestJSON(path: Self.namespace + scopedPath, method: method, body: body,
                                                   timeoutMilliseconds: 12_000, maxResponseBytes: 2_000_000)
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    func hub() async throws -> [String: Any] {
        try await requester.requestJSON(path: "/api/dashboard/plugins/hub", method: "GET", body: nil,
                                        timeoutMilliseconds: 12_000, maxResponseBytes: 2_000_000)
    }
    func identity() async throws -> [String: Any] {
        try await requester.requestJSON(path: "/api/auth/me", method: "GET", body: nil,
                                        timeoutMilliseconds: 12_000, maxResponseBytes: 64_000)
    }
    func component(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains(".."),
              let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw MessagingError.invalidResponse
        }
        return encoded
    }
    func history(_ destination: MessagingDestination, before: Int? = nil) async throws -> MessagingHistory {
        let path = try destinationPath(destination)
        return try await request(MessagingHistory.self, path + (before.map { "?before=\($0)" } ?? ""))
    }
    func destinationPath(_ destination: MessagingDestination) throws -> String {
        if let id = destination.conversationID { return "/conversations/" + (try component(id)) }
        guard let profile = destination.profileID else { throw MessagingError.invalidResponse }
        return "/dms/" + (try component(profile))
    }
    func send(_ pending: PendingMessagingSend, to destination: MessagingDestination, revision: Int?) async throws -> MessagingSendReceipt {
        var body: [String: Any] = ["client_message_id": pending.id, "body": pending.text, "recipients": pending.recipients]
        if let revision { body["revision"] = revision }
        return try await request(MessagingSendReceipt.self, destinationPath(destination) + "/messages", method: "POST", body: body)
    }
    func reconcile(_ pending: PendingMessagingSend, to destination: MessagingDestination) async throws -> MessagingSendReceipt {
        try await request(MessagingSendReceipt.self, destinationPath(destination) + "/messages/by-client-id/" + component(pending.id))
    }
}
