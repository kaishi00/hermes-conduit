import Foundation

/// Seed prompt for agent-assisted persistent messaging setup.
/// Embeds the full checklist so setup works even when the messaging-setup skill is not loaded yet.
enum MessagingSetupPrompt {
    /// Formats a Hermes dashboard identity the same way bot-coms messaging does.
    static func principal(from identity: [String: Any]) -> String? {
        guard let userID = identity["user_id"] as? String, !userID.isEmpty else { return nil }
        let provider = (identity["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !provider.isEmpty else { return nil }
        var value = "\(provider):\(userID)"
        if let orgID = identity["org_id"] as? String, !orgID.isEmpty {
            value += ":\(orgID)"
        }
        return value
    }

    static func text(principal: String?, activeProfile: String) -> String {
        var prompt = checklist
        prompt += "\n\nActive Hermes profile in this client: \(activeProfile.isEmpty ? "default" : activeProfile).\n"
        if let principal, !principal.isEmpty {
            prompt += """

            Operator principal (authenticated in this client): \(principal)
            Use this as `default_principals` (and every roster `principals` entry). Do NOT ask me to open a browser or paste `/api/auth/me`.
            Prefer one yes/no for the non-restarting install. Enable `auto_enroll_profiles: true` so every Hermes profile appears in messaging without rewriting config for each new profile.
            """
        } else {
            prompt += """

            I could not read your signed-in account id from this client. Ask me to sign in again in Conduit before inventing a principal. Do NOT ask me to open a browser or paste `/api/auth/me` JSON.
            """
        }
        return prompt
    }

    /// Backward-compatible static checklist (no client identity). Prefer `text(principal:activeProfile:)`.
    static var text: String { text(principal: nil, activeProfile: "") }

    private static let checklist = """
    Set up persistent bot messaging on this Hermes host.

    If the `messaging-setup` skill is available, follow it. Otherwise follow this checklist (also in https://github.com/jcmcneal/bot-coms docs/INSTALL.md § Persistent messaging). Board / bot-coms-board is NOT required.

    1. In the Hermes Python environment, install messaging:
       pip install -e "/path/to/bot-coms[messaging]"
       or: pip install "bot-coms[messaging] @ git+https://github.com/jcmcneal/bot-coms.git"
    2. bot-coms-messaging install-dashboard --hermes-root /absolute/shared-hermes-root
    3. Add bot-coms and bot-coms-messaging to the shared instance plugins.enabled without removing other entries.
    4. Write plugin-data/bot-coms-messaging/config.json with owner-only permissions, `default_principals`, and `auto_enroll_profiles: true` (stable server_id; do not use peer name `inbox` for a bot profile).
    5. Verify this Hermes build provides the backend plugin session service. Messaging runs inside the existing Hermes backend and reuses exact conversation sessions; do not install a separate worker or launchd/systemd sidecar. Follow the bot-coms migration instructions to drain legacy runs and preserve SQLite before cutover.
    6. Restart the dashboard/gateway only after I confirm active work can be interrupted. Remove the legacy messaging service registration as part of a verified cutover.
    7. Tell me to open Messaging in my client and tap Check again. Installation alone is not readiness — need API v1, eligible profiles, and a healthy backend messaging service.

    Prefer proposing exact commands and seeking approval. Do not invent principals, wipe plugins.enabled, or change approval defaults.
    """

    static let shareChecklist = """
    Enable persistent messaging on Hermes:
    1. pip install -e "/path/to/bot-coms[messaging]"
       or: pip install "bot-coms[messaging] @ git+https://github.com/jcmcneal/bot-coms.git"
       (https://github.com/jcmcneal/bot-coms)
    2. bot-coms-messaging install-dashboard --hermes-root /path/to/shared-hermes-root
    3. Enable bot-coms and bot-coms-messaging on the shared instance; write plugin-data/bot-coms-messaging/config.json with default_principals + auto_enroll_profiles (see bot-coms docs/INSTALL.md § Persistent messaging). Board is not required.
    4. Optional: point skills.external_dirs at bot-coms/skills so the messaging-setup skill is available.
    5. Verify Hermes supports the backend plugin session service. Follow the migration instructions for legacy runs, then restart the dashboard when existing work can be safely interrupted. Execution belongs to the Hermes backend; no separate worker or launchd/systemd sidecar is needed.
    6. In your client, open Messaging and tap Check again.
    Installation alone does not enable messaging: the adapter must report API v1 readiness. Do not change existing session approval defaults.
    """
}
