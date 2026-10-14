//
//  LocationLocate.swift
//  Conduit
//
//  The agent's on-demand locate (designs/location-v1-contract.md section 5),
//  as the Location Push extension receives it. The relay sends a `location`
//  push shaped like a notification: for a pairing with an end-to-end key a
//  sealed `conduit_e2e` envelope (inner `profile` and `locate.id`) with the
//  routing stub `conduit {type: "location.requested", e2e: 1, gateway_id,
//  dashboard_id}`; for a keyless pairing the plain stub with `profile` and
//  `locate.id`. It's opened with the same keys and trust rules as the
//  Notification Service Extension, and answered only for the dashboard and
//  profile sharing is bound to, while background sharing is on and not
//  paused.
//

import Foundation

struct LocationLocateRequest: Equatable {
    static let type = "location.requested"

    var id: String
    var profile: String?
    var gatewayID: String?
    var dashboardID: UUID?
    /// Identifies the push across deliveries (replay checks).
    var replayKey: String

    /// The request in a location push, or nil when it doesn't verify.
    static func parse(
        _ payload: [AnyHashable: Any],
        records: [E2EKeyRecord],
        knownGatewayIDs: Set<String>,
        keysProvisioned: Bool,
        now: Date = Date()
    ) -> LocationLocateRequest? {
        switch NotificationE2E.evaluate(
            payload, records: records, knownGatewayIDs: knownGatewayIDs, keysProvisioned: keysProvisioned, now: now
        ) {
        case .untrusted:
            return nil
        case .verified(let verified):
            guard verified.type == type, let id = locateID(verified.content["locate"]) else { return nil }
            let profile = (verified.content["profile"] as? String) ?? verified.record.profile
            return LocationLocateRequest(
                id: id, profile: profile, gatewayID: verified.record.gatewayID,
                dashboardID: verified.record.dashboardID.flatMap(UUID.init(uuidString:)),
                replayKey: verified.envelope.replayKey
            )
        case .legacy:
            guard let stub = NotificationE2E.routingStub(payload),
                  (stub["type"] as? String) == type,
                  let id = locateID(stub["locate"]) else { return nil }
            return LocationLocateRequest(
                id: id, profile: stub["profile"] as? String, gatewayID: stub["gateway_id"] as? String,
                dashboardID: (stub["dashboard_id"] as? String).flatMap(UUID.init(uuidString:)),
                replayKey: "plain:\(id)"
            )
        }
    }

    private static func locateID(_ value: Any?) -> String? {
        guard let id = (value as? [String: Any])?["id"] as? String,
              id.range(of: "^[A-Za-z0-9_-]{4,80}$", options: .regularExpression) != nil else { return nil }
        return id
    }

    /// Whether this phone answers: the request is for the bound dashboard
    /// and profile, and background sharing is on and not paused.
    func isAnswered(by config: LocationSharedConfig, at now: Date) -> Bool {
        guard let binding = config.binding, config.settings.shares(.locate, at: now),
              let dashboardID, dashboardID == binding.dashboardID else { return false }
        return Self.normalizedProfile(profile) == Self.normalizedProfile(binding.profile)
    }

    static func normalizedProfile(_ profile: String?) -> String {
        let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "default" : trimmed
    }
}
