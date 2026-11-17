import Combine
import CryptoKit
import Foundation

/// Only server snapshots, never conduit_show cards or proposal/chat text.
struct PhoneScopedGrant: Identifiable {
    struct Snapshot: Decodable {
        struct Participant: Decodable { let profile: String; let chat: String; let identity: String; let policy_epoch: String }
        struct Origin: Decodable { let ref: String; let session: String; let identity: String; let epoch: String }
        struct Provenance: Decodable { let session: String; let turn_id: String; let tool_call_id: String }
        let installation: String
        let ask_id: String
        let sender: Participant
        let recipient: Participant
        let sender_ask: String
        let recipient_ask: String
        let origin: Origin?
        let provenance: Provenance
        let task: String
        let scope: String
    }
    let id: String
    let digest: String
    let status: String
    let snapshotText: String
    let snapshot: Snapshot

    init(row: [String: Any]) throws {
        guard let id = row["id"] as? String, id.range(of: "^G[0-9a-f]{32}$", options: .regularExpression) != nil,
              let digest = row["digest"] as? String, let status = row["status"] as? String,
              ["pending", "consumed", "declined", "revoked"].contains(status),
              let text = row["snapshot_text"] as? String,
              SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw PhoneConsentClient.Failure.malformed
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(text.utf8))
        guard !snapshot.task.isEmpty, !snapshot.scope.isEmpty, !snapshot.provenance.session.isEmpty,
              !snapshot.provenance.turn_id.isEmpty, !snapshot.provenance.tool_call_id.isEmpty else {
            throw PhoneConsentClient.Failure.malformed
        }
        self.id = id; self.digest = digest; self.status = status
        self.snapshotText = text; self.snapshot = snapshot
    }
}

struct PhoneConsentPreview {
    let device: String?
    let publicKey: String?
    let pairing: [String: String]
    let context: [String: String]
    let grants: [PhoneScopedGrant]

    init(response: [String: Any]) throws {
        guard response["protocol"] as? String == PhoneConsentClient.wireProtocol,
              let owner = response["owner"] as? String, let profile = response["profile_id"] as? String,
              let installation = response["installation"] as? String,
              let pairing = response["pairing"] as? [String: String],
              ["installation_id", "gateway_id", "binding"].allSatisfy({ !(pairing[$0] ?? "").isEmpty }),
              let rows = response["grants"] as? [[String: Any]] else { throw PhoneConsentClient.Failure.malformed }
        self.device = response["device"] as? String
        self.publicKey = response["public_key"] as? String
        self.pairing = pairing
        self.context = ["owner": owner, "profile_id": profile, "installation": installation, "pairing_binding": pairing["binding"]!]
        self.grants = try rows.map(PhoneScopedGrant.init(row:))
        guard Set(grants.map(\.id)).count == grants.count,
              grants.allSatisfy({ $0.snapshot.installation == installation }) else { throw PhoneConsentClient.Failure.malformed }
    }
}

/// Requests use the bridge captured when this panel opened, never a later dashboard.
@MainActor
final class PhoneConsentClient {
    nonisolated static let capability = "phone-scoped-consent-v1"
    nonisolated static let wireProtocol = "conduit-phone-consent/1"
    nonisolated static let path = "/api/plugins/conduit_push/phone-consent"
    enum Failure: Error { case malformed, changed }
    private let profile: String
    private let parameter: String
    private let request: WorkspaceFilesClient.Request

    init(profile: String, parameter: String, request: @escaping WorkspaceFilesClient.Request) {
        self.profile = profile; self.parameter = parameter; self.request = request
    }

    private func route(_ suffix: String = "") -> String {
        DashboardPath.withProfile(Self.path + suffix, profile: profile, parameter: parameter)
    }

    func read() async throws -> PhoneConsentPreview {
        try PhoneConsentPreview(response: await request(route(), "GET", nil))
    }

    /// Called only by the dedicated enrollment/action tap. Never retry a receipt.
    func perform(body: [String: Any], expected: [String: String], key: Curve25519.Signing.PrivateKey,
                 stillCurrent: () -> Bool) async throws -> [String: Any] {
        guard stillCurrent(), !Task.isCancelled else { throw Failure.changed }
        let challenge = try await request(route("/challenge"), "POST", body)
        guard stillCurrent(), !Task.isCancelled else { throw Failure.changed }
        let receipt = try Self.sign(challenge, key: key, expected: expected, now: Date())
        guard stillCurrent(), !Task.isCancelled else { throw Failure.changed }
        return try await request(route("/receipt"), "POST", receipt)
    }

    static func sign(_ challenge: [String: Any], key: Curve25519.Signing.PrivateKey,
                     expected: [String: String], now: Date) throws -> [String: Any] {
        guard let id = challenge["challenge"] as? String, let message = challenge["message"] as? String,
              let context = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              context["challenge"] as? String == id, context["protocol"] as? String == wireProtocol,
              context["public_key"] as? String == NotificationE2E.base64URL(key.publicKey.rawRepresentation),
              let expires = context["expires"] as? Int, Double(expires) > now.timeIntervalSince1970,
              Double(expires) <= now.timeIntervalSince1970 + 61,
              expected.allSatisfy({ context[$0.key] as? String == $0.value }) else { throw Failure.malformed }
        return ["challenge": id, "signature": NotificationE2E.base64URL(try key.signature(for: Data(message.utf8)))]
    }

    func revoke(device: String) async throws -> [String: Any] {
        try await request(route("/revoke-device"), "POST", ["device": device])
    }
}

/// No KeptAnswers, background delivery, optimistic approval or write retry.
@MainActor
final class PhoneConsentModel: ObservableObject {
    @Published private(set) var preview: PhoneConsentPreview?
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var unconfirmedInterrupt = false
    private var generation = 0
    private var matchingKey = false
    var canAct: Bool { preview?.device != nil && matchingKey && !busy }

    func invalidate() {
        generation += 1
        preview = nil
        matchingKey = false
    }

    func refresh(client: PhoneConsentClient, allowed: Bool, key: Curve25519.Signing.PrivateKey?) async {
        invalidate()
        let mark = generation
        guard allowed else { return }
        do {
            let value = try await client.read()
            guard generation == mark, !Task.isCancelled else { return }
            preview = value
            matchingKey = key.map { NotificationE2E.base64URL($0.publicKey.rawRepresentation) == value.publicKey } ?? false
            failed = false
        } catch {
            if generation == mark { failed = true }
        }
    }

    func perform(client: PhoneConsentClient, body: [String: Any], expected: [String: String],
                 key: Curve25519.Signing.PrivateKey, stillCurrent: () -> Bool) async {
        guard !busy, preview != nil, stillCurrent() else { return }
        let mark = generation
        busy = true
        defer { busy = false }
        // Hide all authority as soon as a write starts; an uncertain answer needs a fresh read and tap.
        preview = nil
        matchingKey = false
        do {
            let reply = try await client.perform(body: body, expected: expected, key: key,
                                                stillCurrent: { self.generation == mark && stillCurrent() })
            guard generation == mark, stillCurrent() else { return }
            failed = reply["ok"] as? Bool != true
            unconfirmedInterrupt = reply["interrupted"] as? Bool == false
        } catch {
            if generation == mark { failed = true }
        }
    }

    func revoke(client: PhoneConsentClient, device: String, stillCurrent: () -> Bool) async {
        guard !busy, stillCurrent() else { return }
        busy = true
        invalidate()
        let mark = generation
        defer { busy = false }
        do {
            let reply = try await client.revoke(device: device)
            guard generation == mark, stillCurrent() else { return }
            failed = reply["ok"] as? Bool != true
            unconfirmedInterrupt = reply["interrupted"] as? Bool == false
        } catch {
            if generation == mark { failed = true }
        }
    }
}
