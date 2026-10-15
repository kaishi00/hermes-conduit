//
//  SessionMutationIdentity.swift
//  Conduit
//
//  Hermes (main, 2026-10) takes a session PATCH or DELETE only with its
//  mutation identity: a fresh request id and the row's current revision and
//  generation, read from GET /api/sessions/{id}/mutation-snapshot. Without
//  them it answers 409 mutation_identity_required, so pin, read state,
//  archive, rename and delete all failed. A host older than the snapshot
//  route takes the bare request, as before.
//

import Foundation

enum SessionMutationIdentity {
    /// The identity fields for a mutation, from a snapshot response; nil when
    /// the host gave no revision (an older host, or a failed read).
    static func fields(snapshot: [String: Any], requestID: String = UUID().uuidString.lowercased()) -> [String: Any]? {
        guard let revision = integer(snapshot["runtime_revision"]), revision >= 0 else { return nil }
        var fields: [String: Any] = ["request_id": requestID, "expected_revision": revision]
        if let generation = integer(snapshot["runtime_generation"]), generation >= 0 {
            fields["expected_generation"] = generation
        }
        return fields
    }

    /// A DELETE carries the identity in its query.
    static func path(_ path: String, adding fields: [String: Any]) -> String {
        let query = fields.keys.sorted().compactMap { key -> String? in
            guard let value = fields[key] else { return nil }
            let text = "\(value)"
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return "\(key)=\(encoded)"
        }
        guard !query.isEmpty else { return path }
        return path + (path.contains("?") ? "&" : "?") + query.joined(separator: "&")
    }

    /// A conflict worth one retry with a fresh snapshot: the row moved on
    /// between the snapshot and the write.
    static func isStaleRevision(_ error: Error) -> Bool {
        guard case DashboardTicketBridgeError.http(status: 409, detail: let detail) = error else { return false }
        return !detail.localizedCaseInsensitiveContains("session_busy")
    }

    private static func integer(_ value: Any?) -> Int? {
        // JSON booleans arrive as NSNumber too; a revision is never one.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}
