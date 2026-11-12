//
//  AppState+DelegationRouting.swift
//  Conduit
//
//  Settings > Memory & delegation > Subagent routing (DelegationRouting
//  Settings in AuxiliaryViews.swift): the profile's delegation mode and its
//  routes over the dashboard's `/api/delegation/*` routes. The routing is
//  kept so the section opens on it (#1533), without a route's key preview,
//  which the store never keeps; the routes are edited only once Hermes has
//  answered, since a save sends that preview back.
//

import Foundation

/// Why the routing section can't read or change the routing.
enum DelegationRoutingError: Error, Equatable, LocalizedError {
    case notConnected
    /// This Hermes has no routing routes: the section isn't shown.
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notConnected: AppLocalization.string("Connect to Hermes to change how subagents are routed.")
        case .unsupported: AppLocalization.string("This Hermes can't route subagents yet. Update Hermes to use routes.")
        }
    }
}

extension AppState {
    static let delegationRoutingRoute = "/api/delegation/routing"

    /// The routing as Hermes gave it last time for this dashboard and
    /// profile, without any route's key.
    func keptDelegationRouting() -> DelegationRouting? {
        keptAnswer(Self.delegationRoutingRoute).flatMap(DelegationRouting.init(json:))
    }

    func loadDelegationRouting() async throws -> DelegationRouting {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { throw DelegationRoutingError.notConnected }
        let json = try await routingCall {
            try await self.keepingAnswer(profile: profile, owner: owner, keptAs: { $0["configured"] == nil ? nil : Self.delegationRoutingRoute }) {
                try await owner.bridge.requestJSON(path: DashboardPath.withProfile(Self.delegationRoutingRoute, profile: profile))
            }
        }
        guard let routing = DelegationRouting(json: json) else { throw HermesError.invalidResponse }
        return routing
    }

    /// Saves `delegation.backend`. Hermes takes only Default or a mode that
    /// can run for the profile.
    func chooseDelegationMode(_ mode: String) async throws {
        _ = try await writeRouting(path: "/api/delegation/backend", body: ["backend": mode]) { kept, _ in
            kept["configured"] = mode
            kept["blocked_reason"] = NSNull()
        }
    }

    /// Replaces the model routes and their default; Hermes' copy back.
    func saveDelegationModelRoutes(_ routing: DelegationRouting) async throws -> (routes: [DelegationRouting.ModelRoute], defaultRoute: String?) {
        let answer = try await writeRouting(path: "/api/delegation/backends/model_map", body: routing.modelMapBody) { kept, answer in
            if let block = answer["model_map"] { kept["model_map"] = block }
        }
        let block = answer["model_map"] as? [String: Any] ?? [:]
        return (DelegationRouting.modelRoutes(from: block), (block["default"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Replaces the profile routes and their default; Hermes' copy back.
    func saveDelegationProfileRoutes(_ routing: DelegationRouting) async throws -> (routes: [DelegationRouting.ProfileRoute], defaultRoute: String?) {
        let answer = try await writeRouting(path: "/api/delegation/backends/profile_routes", body: routing.profileRoutesBody) { kept, answer in
            if let block = answer["profile_routes"] { kept["profile_routes"] = block }
        }
        let block = answer["profile_routes"] as? [String: Any] ?? [:]
        return (DelegationRouting.profileRoutes(from: block), (block["default"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A write to the profile's config, in turn with Conduit's other config
    /// saves, so one doesn't put back what another changed. What Hermes
    /// took is what the section opens on next (`keep` changes the kept
    /// routing), even if the read after it never lands.
    private func writeRouting(
        path: String,
        body: [String: Any],
        keep: @escaping (inout [String: Any], [String: Any]) -> Void
    ) async throws -> [String: Any] {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { throw DelegationRoutingError.notConnected }
        let answer = try await routingCall {
            try await ProfileConfigWriteQueue.runThrowing {
                try await owner.bridge.requestJSON(path: DashboardPath.withProfile(path, profile: profile), method: "PUT", body: body)
            }
        }
        if var kept = keptAnswer(Self.delegationRoutingRoute, profile: profile, on: owner) {
            keep(&kept, answer)
            _ = try? await keepingAnswer(profile: profile, owner: owner, keptAs: { _ in Self.delegationRoutingRoute }, writes: true) { kept }
        }
        return answer
    }

    /// A Hermes before the routing routes answers 404 or 405.
    private func routingCall<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch DashboardTicketBridgeError.http(let status, let detail)
            where (status == 404 || status == 405) && !DashboardTicketBridgeError.isPluginOffDetail(detail) {
            throw DelegationRoutingError.unsupported
        }
    }
}
