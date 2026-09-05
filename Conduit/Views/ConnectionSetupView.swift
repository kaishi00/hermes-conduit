//
//  ConnectionSetupView.swift
//  Conduit
//
//  Round-1 shell for the Connection Setup Assistant. This is deliberately
//  NOT the guided onboarding yet: it establishes the presentation mechanism
//  the assistant will fill in — a destination-routed help surface reachable
//  from the login card's entry point and from classified login failures —
//  and offers static quick checks per destination.
//

import SwiftUI

/// Placeholder shell for the Connection Setup Assistant. `initialDestination`
/// comes from the login card's entry point (`.start`) or from a classified
/// login failure's help destination, so later rounds can build the guided
/// flows without touching error classification again.
struct ConnectionSetupView: View {
    let initialDestination: ConnectionHelpDestination

    @Environment(\.dismiss) private var dismiss
    @State private var destination: ConnectionHelpDestination

    init(initialDestination: ConnectionHelpDestination) {
        self.initialDestination = initialDestination
        _destination = State(initialValue: initialDestination)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("connection-setup.content")
            .navigationTitle("Connection Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("connection-setup.done")
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Guided setup for your self-hosted Hermes dashboard is coming here. Meanwhile, these quick checks cover the most common causes of failed connections.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Topic", selection: $destination) {
                ForEach(ConnectionHelpDestination.allCases) { topic in
                    Text(topic.displayName).tag(topic)
                }
            }
            .font(.subheadline)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(destination.checks.enumerated()), id: \.offset) { _, check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.conduitAccent)
                            .padding(.top, 2)
                        Text(check)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
        }
    }
}

// MARK: - Per-destination quick checks

extension ConnectionHelpDestination {
    var displayName: String {
        switch self {
        case .start: return "Getting started"
        case .dashboard: return "Dashboard address"
        case .credentials: return "Credentials"
        case .network: return "Network & reachability"
        case .tls: return "HTTPS & certificates"
        case .cloudflare: return "Cloudflare Access"
        }
    }

    /// Static quick checks shown in the Round-1 shell. Safe-by-construction:
    /// never recommends exposing the dashboard to the public internet or
    /// weakening HTTPS. The guided walkthroughs (later rounds) replace these.
    var checks: [String] {
        switch self {
        case .start:
            return [
                "The dashboard address should look like https://hermes.example — include any path prefix your reverse proxy uses (for example https://example.com/hermes).",
                "Open the same address in Safari on this device. If the dashboard doesn’t load there, what you see is the same wall Conduit hits.",
                "Remote dashboards must use HTTPS. Plain HTTP works only for localhost, private LAN addresses, and Tailscale."
            ]
        case .dashboard:
            return [
                "Confirm the address points at the Hermes dashboard itself, not another service on the same host.",
                "Include custom ports (for example https://hermes.example:9119) and any reverse-proxy path prefix.",
                "If the dashboard moved or its certificate changed, re-enter the full address from scratch."
            ]
        case .credentials:
            return [
                "Conduit needs the username and password you use to sign in to the Hermes dashboard — not a Cloudflare or Tailscale account.",
                "Try signing in on the dashboard’s own web page to confirm the account still works.",
                "If the password was rejected after a dashboard change, reset it where your dashboard manages users."
            ]
        case .network:
            return [
                "Make sure the Hermes dashboard is actually running on its host machine.",
                "This device must be on the same network as the dashboard, or connected through Tailscale or a VPN. Tailscale Serve also gives you HTTPS for free.",
                "Mobile hotspots and guest Wi-Fi often block device-to-device traffic — try another network.",
                "Avoid opening the dashboard port directly to the internet; prefer Tailscale or an authenticated reverse proxy."
            ]
        case .tls:
            return [
                "If you use your own certificate authority, install and trust its root certificate on this device (Settings → General → VPN & Device Management → Certificate Trust Settings).",
                "Check the server certificate’s expiration and validity dates.",
                "Confirm this device’s date and time are correct."
            ]
        case .cloudflare:
            return [
                "Verify the Client ID and Secret belong to a Cloudflare Access service token for this application.",
                "Make sure a Service Auth policy allows that token to reach this Access application.",
                "Or turn off \"Use Cloudflare Access service token\" to sign in interactively through the in-app browser."
            ]
        }
    }
}
