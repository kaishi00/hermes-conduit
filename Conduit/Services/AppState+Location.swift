//
//  AppState+Location.swift
//  Conduit
//
//  Location sharing's connection to Hermes. Batches go to the dashboard and
//  profile sharing is bound to, over that dashboard's own connection when
//  it's the one in use, else with the host pass (LocationHostClient): a
//  background wake may come before Conduit reconnects, and the Location
//  Push extension never has the connection. The pass is refreshed here
//  whenever the bound dashboard is connected. Never through the push relay.
//

import Foundation
import UIKit
import WebKit

extension AppState {
    /// Settings shows Location once the host's plugin serves it, or while
    /// sharing is on (so it can be turned off when the plugin went away).
    var showsLocationSettings: Bool {
        notifierPlugin.reports(LocationSharingController.capability) || LocationSharingController.shared.settings.isOn
    }

    /// The binding for the dashboard and profile in use, for turning on.
    var locationDestination: LocationBinding? {
        guard let dashboardID = activeDashboardID, let baseURL = connection?.baseUrl else { return nil }
        return LocationBinding(dashboardID: dashboardID, profile: activeProfile, host: URL(string: baseURL)?.host ?? baseURL)
    }

    /// Wires location sharing to this app's connections. Once, at launch.
    func activateLocationSharing() {
        let controller = LocationSharingController.shared
        guard controller.requestProvider == nil else { return }
        controller.requestProvider = { [weak self] binding in
            await self?.locationRequest(for: binding)
        }
        controller.activateAtLaunch()
    }

    /// The bound dashboard's connection, or the host pass for it.
    func locationRequest(for binding: LocationBinding) async -> LocationSyncEngine.Request? {
        // A background launch connects on its own; give it a moment.
        if activeDashboardID == binding.dashboardID, dashboardTicketBridge == nil {
            for _ in 0..<6 where dashboardTicketBridge == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if activeDashboardID == binding.dashboardID, let bridge = dashboardTicketBridge {
            return { [weak self] path, method, body in
                // A dashboard swapped mid-send isn't where location goes.
                guard let self, bridge === self.dashboardTicketBridge, self.activeDashboardID == binding.dashboardID else {
                    throw DashboardTicketBridgeError.notReady
                }
                return try await bridge.requestJSON(
                    path: DashboardPath.withProfile(path, profile: binding.profile),
                    method: method, body: body, timeoutMilliseconds: 15_000
                )
            }
        }
        guard let pass = LocationKeychain.loadHostPass(), pass.dashboardID == binding.dashboardID else { return nil }
        return { path, method, body in
            do {
                return try await LocationHostClient.requestJSON(
                    pass: pass, path: LocationHostClient.withProfile(path, profile: binding.profile),
                    method: method, body: body
                )
            } catch let error as LocationHostError {
                switch error {
                case .noPass: throw DashboardTicketBridgeError.notReady
                case .signInRequired: throw DashboardTicketBridgeError.signInRequired
                case .http(let status, let detail): throw DashboardTicketBridgeError.http(status: status, detail: detail)
                }
            } catch let error as URLError {
                throw DashboardTicketBridgeError.http(status: 0, detail: error.localizedDescription)
            }
        }
    }

    /// Connected to a dashboard: if it's the one location is bound to, keep
    /// the host pass current and send what's waiting.
    func locationHostConnected() async {
        let controller = LocationSharingController.shared
        guard let binding = controller.binding, controller.settings.isOn,
              activeDashboardID == binding.dashboardID, let bridge = dashboardTicketBridge else { return }
        if let pass = await locationHostPass(bridge: bridge, dashboardID: binding.dashboardID) {
            LocationKeychain.saveHostPass(pass)
        }
        controller.hostConnected()
    }

    /// The headers this dashboard's requests carry, for sending without the
    /// app: a native sign-in's access token, else the session cookies, and
    /// the proxy headers.
    private func locationHostPass(bridge: DashboardTicketBridge, dashboardID: UUID) async -> LocationHostPass? {
        let path = "\(LocationHostClient.base)/ingest"
        // The dashboard page's fetch resolves an absolute path against its
        // origin, so the pass keeps the origin.
        guard let url = DashboardTicketBridge.pageRequestURL(path: path, baseURL: bridge.baseURL),
              let scheme = url.scheme, let host = url.host else { return nil }
        var origin = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
        // A native sign-in's requests go under the base URL's path instead.
        if bridge.usesNativeOAuth, let normalized = try? ConnectionURLPolicy.normalizedBaseURL(bridge.baseURL) {
            origin = normalized
        }
        let request = URLRequest(url: url).applyingProxyHeaders(cloudflare: bridge.cloudflareAccess)
        var headers = request.allHTTPHeaderFields ?? [:]
        var expiresAt: Date?
        if bridge.usesNativeOAuth {
            guard let tokens = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID), !tokens.accessToken.isEmpty else {
                return nil
            }
            headers["Authorization"] = "Bearer \(tokens.accessToken)"
            if tokens.expiresAt > 0 { expiresAt = Date(timeIntervalSince1970: tokens.expiresAt) }
        } else {
            var cookies = DashboardCookiePersistence.mirroredCookies(dashboardID: dashboardID)
            if PhoneScenePresence.isInForeground, let live = await webKitCookies(bridge) { cookies += live }
            cookies += DashboardCookiePersistence.nativeCookieStorage(for: dashboardID).cookies ?? []
            cookies += bridge.backgroundIssuedCookies
            let fresh = DashboardTicketBridge.freshestCookies(cookies)
            let cookieHeader = NativeAuthCookiePolicy.headerFields(for: fresh, url: url)
            guard !cookieHeader.isEmpty else { return nil }
            // A cookie's own expiry says little (a session cookie has
            // none): the host's answer decides whether the pass still works.
            headers.merge(cookieHeader) { _, new in new }
        }
        return LocationHostPass(dashboardID: dashboardID, baseURL: origin, headers: headers,
                                expiresAt: expiresAt, savedAt: Date())
    }

    /// WebKit's cookies for the dashboard, or nil if it doesn't answer soon.
    private func webKitCookies(_ bridge: DashboardTicketBridge) async -> [HTTPCookie]? {
        let store = bridge.webView.configuration.websiteDataStore.httpCookieStore
        return await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie]?, Never>) in
            let once = LocationOnce()
            store.getAllCookies { cookies in
                Task { @MainActor in once.run { continuation.resume(returning: cookies) } }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                once.run { continuation.resume(returning: nil) }
            }
        }
    }

    /// The saved places "Don't call me while I'm at" offers: the ones sent
    /// to this dashboard and profile, so the host knows their ids.
    var locationPlacesForCalls: [LocationSavedPlace] {
        let controller = LocationSharingController.shared
        guard let binding = controller.binding, binding.dashboardID == activeDashboardID,
              binding.profile == activeProfile else { return [] }
        return controller.places
    }

    // MARK: Voice calls

    /// Whether the user is talking to Hermes by voice: a live call, the
    /// classic Voice sheet, or CarPlay voice.
    var isTalkingToHermesByVoice: Bool {
        isLiveVoiceCallActive || showVoiceSheet || isCarPlayVoiceSurfaceActive
    }

    /// A voice call began: location shares a fix now and when the phone moves.
    func noteVoiceCallStartedForLocation() {
        LocationSharingController.shared.voiceCallStarted { [weak self] in
            self?.isTalkingToHermesByVoice ?? false
        }
    }
}
