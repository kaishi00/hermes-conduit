//
//  AppState+ComputerPairing.swift
//  Conduit
//
//  Which saved dashboards Pair a Computer can send (ComputerPairing.swift),
//  and a pairing code the Camera opened Conduit with.
//

import Foundation

/// A saved dashboard as Pair a Computer lists it: what it would send, or
/// that the computer has to sign in itself (a browser or single sign-on
/// sign-in, or nothing saved here).
struct ComputerPairingChoice: Identifiable, Equatable, CustomStringConvertible {
    let id: UUID
    let label: String
    let url: String
    let isActive: Bool
    /// What's sent, secrets included; nil when nothing here can be.
    let host: ComputerPairing.Host?

    var description: String { "ComputerPairingChoice(\(id), \(host?.method.rawValue ?? "none"))" }

    /// The saved dashboards, the one in use first, then in the registry's
    /// order. A saved password goes as a password; Hermes' session token as
    /// a token. A browser sign-in's tokens belong to this phone and stay.
    static func choices(
        registry: SavedDashboardRegistry,
        credentials: (UUID) -> DashboardCredentials?,
        tokens: (UUID) -> NativeOAuthTokenSet?,
        proxyHeaders: (SavedDashboard) -> [String: String] = { _ in [:] }
    ) -> [ComputerPairingChoice] {
        let ordered = registry.dashboards.filter { $0.id == registry.activeDashboardID }
            + registry.dashboards.filter { $0.id != registry.activeDashboardID }
        return ordered.map { dashboard in
            let label = dashboard.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = label.isEmpty ? nil : label
            var host: ComputerPairing.Host?
            if let saved = credentials(dashboard.id), !saved.username.isEmpty, !saved.password.isEmpty {
                host = ComputerPairing.Host(url: dashboard.normalizedURL, method: .password, username: saved.username, password: saved.password, name: name)
            } else if let set = tokens(dashboard.id), set.isSessionToken, !set.accessToken.isEmpty {
                host = ComputerPairing.Host(url: dashboard.normalizedURL, method: .token, token: set.accessToken, name: name)
            }
            // The computer needs the proxy's headers to reach the dashboard at
            // all; like the phone it sends them over https only.
            let headers = dashboard.normalizedURL.lowercased().hasPrefix("https://") ? proxyHeaders(dashboard) : [:]
            if !headers.isEmpty { host?.headers = headers }
            return ComputerPairingChoice(
                id: dashboard.id,
                label: name ?? (URL(string: dashboard.normalizedURL)?.host ?? dashboard.normalizedURL),
                url: dashboard.normalizedURL,
                isActive: dashboard.id == registry.activeDashboardID,
                host: host
            )
        }
    }
}

extension AppState {
    /// Reads the Keychain: call it when Pair a Computer is about to send,
    /// not on every render.
    func computerPairingChoices() -> [ComputerPairingChoice] {
        ComputerPairingChoice.choices(
            registry: savedDashboardRegistry,
            credentials: { KeychainHelper.loadCredentials(dashboardID: $0) },
            tokens: { KeychainHelper.loadNativeOAuthTokens(dashboardID: $0) },
            proxyHeaders: { dashboard in
                var headers: [String: String] = [:]
                for header in CustomHeaderPolicy.sendable(CustomHeaderStore.shared.headers(forServerURL: dashboard.normalizedURL)) {
                    headers[header.name] = header.value
                }
                if let access = KeychainHelper.loadCloudflareAccess(dashboardID: dashboard.id, for: dashboard.normalizedURL), access.isConfigured {
                    headers["CF-Access-Client-Id"] = access.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                    headers["CF-Access-Client-Secret"] = access.clientSecret
                }
                return headers
            }
        )
    }

    /// A computer's pairing code the Camera read: RootView asks about it.
    func routeComputerPairingLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ConduitAppLink.scheme,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() == ComputerPairingLink.host else {
            return false
        }
        if let link = ComputerPairingLink(url: url) {
            pendingComputerPairing = link
        }
        return true
    }
}
