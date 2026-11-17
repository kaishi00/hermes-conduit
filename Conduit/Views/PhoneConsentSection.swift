import CryptoKit
import SwiftUI

/// Tap-only iPhone/iPad surface; deliberately absent from voice, Watch and CarPlay.
struct PhoneConsentSection: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    let profile: String
    @StateObject private var model = PhoneConsentModel()
    @State private var client: PhoneConsentClient?
    @State private var loadedVisit = ""
    @State private var confirmsEnrollment = false
    @State private var keySaveFailed = false

    private var supported: Bool { appState.notifierPlugin.reports(PhoneConsentClient.capability) }
    private var visit: String {
        [appState.activeDashboardID?.uuidString ?? "", profile, appState.activeProfile,
         appState.activeSessionId ?? "", String(appState.isConnected), String(supported), String(describing: scenePhase)]
            .joined(separator: "\u{1f}")
    }
    private var live: Bool {
        appState.isConnected && supported && scenePhase == .active && loadedVisit == visit && !model.busy
    }
    private var key: Curve25519.Signing.PrivateKey? {
        appState.activeDashboardID.flatMap { KeychainHelper.phoneConsentKey(dashboardID: $0, profile: profile) }
    }
    private var ownsPairing: Bool {
        guard let pairing = model.preview?.pairing, let installation = pairing["installation_id"],
              let gateway = pairing["gateway_id"] else { return false }
        return PushNotificationService.shared.ownsConsentPairing(installationID: installation, gatewayID: gateway)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.string("Scoped task consent", table: .bots)).font(.headline)
                Text(AppLocalization.string("Consent covers one exact task once, not command approval or an OS sandbox.", table: .bots))
                    .font(.footnote).foregroundStyle(.secondary)
                if !supported {
                    Text(AppLocalization.string("Scoped consent requires a compatible notifier and an owner sign-in.", table: .bots))
                } else if model.failed || keySaveFailed {
                    Text(AppLocalization.string("Consent could not be confirmed; refresh before another deliberate tap, as nothing is resent automatically.", table: .bots))
                        .foregroundStyle(.orange)
                }
                if model.unconfirmedInterrupt {
                    Text(AppLocalization.string("Revoked, but stopping the native task is unconfirmed; tools and resume remain blocked.", table: .bots))
                        .foregroundStyle(.orange)
                }
                if let preview = model.preview, live {
                    if ownsPairing {
                        Button(AppLocalization.string("Enable this phone for scoped consent", table: .bots)) { confirmsEnrollment = true }
                            .accessibilityIdentifier("phoneConsent.enroll")
                        if let device = preview.device {
                            Text(verbatim: device).font(.caption.monospaced()).textSelection(.enabled)
                            Button(AppLocalization.string("Revoke this phone’s scoped consent", table: .bots), role: .destructive) {
                                guard let client else { return }
                                let mark = visit
                                Task { await model.revoke(client: client, device: device, stillCurrent: { loadedVisit == mark && visit == mark }) }
                            }
                            .accessibilityIdentifier("phoneConsent.revokeDevice")
                        }
                    } else {
                        Text(AppLocalization.string("Pair this profile with this phone first; pairing encryption alone does not enable consent.", table: .bots))
                    }
                    ForEach(preview.grants.filter { ["pending", "consumed"].contains($0.status) }) { grant in
                        grantCard(grant)
                    }
                }
                Button(AppLocalization.string("Refresh consent", table: .bots)) {
                    guard let client else { return }
                    Task { await model.refresh(client: client, allowed: live, key: key) }
                }
                .disabled(!live)
                .accessibilityIdentifier("phoneConsent.refresh")
            }
            .textSelection(.enabled)
        }
        .confirmationDialog(AppLocalization.string("Enroll a separate signing key for this phone, replacing any prior enrollment and revoking its scoped tasks?", table: .bots), isPresented: $confirmsEnrollment, titleVisibility: .visible) {
            Button(AppLocalization.string("Enable this phone for scoped consent", table: .bots)) { enroll() }
        }
        .task(id: visit) {
            model.invalidate()
            loadedVisit = visit
            guard appState.isConnected, supported, scenePhase == .active,
                  let bridge = appState.dashboardTicketBridge else { client = nil; return }
            let captured = PhoneConsentClient(profile: profile, parameter: appState.notifierPlugin.dashboardProfileParameter) { path, method, body in
                try await bridge.requestJSON(path: path, method: method, body: body)
            }
            client = captured
            while !Task.isCancelled {
                if !model.busy { await model.refresh(client: captured, allowed: true, key: key) }
                try? await Task.sleep(for: .seconds(12))
            }
        }
        .onChange(of: visit) { _, _ in model.invalidate(); confirmsEnrollment = false }
        .onDisappear { model.invalidate(); confirmsEnrollment = false; client = nil }
        .accessibilityIdentifier("phoneConsent.section")
    }

    private func grantCard(_ grant: PhoneScopedGrant) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "\(grant.snapshot.sender.profile) → \(grant.snapshot.recipient.profile)").font(.headline)
            Text(verbatim: grant.snapshot.task)
            Text(verbatim: grant.snapshot.scope)
            // Complete immutable snapshot, including native session/turn/call, is never cut or editable.
            Text(verbatim: grant.snapshotText).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("phoneConsent.snapshot.\(grant.id)")
            Text(verbatim: grant.digest).font(.caption2.monospaced())
            if grant.status == "pending" {
                Button(AppLocalization.string("Approve this task once", table: .bots)) { act(grant, action: "grant_approve") }
                    .accessibilityIdentifier("phoneConsent.approve.\(grant.id)")
                Button(AppLocalization.string("Decline this task", table: .bots), role: .destructive) { act(grant, action: "grant_decline") }
                    .accessibilityIdentifier("phoneConsent.decline.\(grant.id)")
            } else {
                Button(AppLocalization.string("Revoke and stop this task", table: .bots), role: .destructive) { act(grant, action: "grant_revoke") }
                    .accessibilityIdentifier("phoneConsent.stop.\(grant.id)")
            }
        }
        .disabled(!live || !model.canAct || !ownsPairing)
        .padding(.vertical, 8)
    }

    private func act(_ grant: PhoneScopedGrant, action: String) {
        guard live, model.canAct, ownsPairing, let preview = model.preview,
              let device = preview.device, let key, let client else { return }
        let body = ["action": action, "device": device, "grant": grant.id, "digest": grant.digest]
        let expected = preview.context.merging(body) { _, new in new }
        let mark = visit
        Task { await model.perform(client: client, body: body, expected: expected, key: key,
                                   stillCurrent: { loadedVisit == mark && visit == mark }) }
    }

    private func enroll() {
        guard live, ownsPairing, let preview = model.preview, let dashboard = appState.activeDashboardID, let client else { return }
        let key = Curve25519.Signing.PrivateKey()
        guard KeychainHelper.savePhoneConsentKey(key, dashboardID: dashboard, profile: profile) else { keySaveFailed = true; return }
        keySaveFailed = false
        let publicKey = NotificationE2E.base64URL(key.publicKey.rawRepresentation)
        let body = ["action": "enroll", "public_key": publicKey,
                    "installation_id": preview.pairing["installation_id"]!, "gateway_id": preview.pairing["gateway_id"]!]
        let expected = preview.context.merging(["action": "enroll", "public_key": publicKey]) { _, new in new }
        let mark = visit
        Task { await model.perform(client: client, body: body, expected: expected, key: key,
                                   stillCurrent: { loadedVisit == mark && visit == mark }) }
    }
}
