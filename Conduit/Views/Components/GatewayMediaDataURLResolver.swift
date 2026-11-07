//
//  GatewayMediaDataURLResolver.swift
//  Conduit
//
//  A stable presentation dependency for gateway `MEDIA:` resolution.
//
//  Assistant/user Markdown content needs `AppState.gatewayMediaDataURL`
//  for gateway-hosted images, but capturing AppState (or building a fresh
//  closure each body evaluation) inside a settled row would either
//  subscribe the row to every AppState publish — invalidating hundreds of
//  settled rows on each streaming tick — or defeat SwiftUI's Equatable
//  gating because closures never compare equal. This resolver is a small
//  object with a stable identity per profile: rows hold it as a plain
//  reference, compare it by identity, and build the per-call closure
//  inside their own body.
//
//  AppState owns the canonical instance (see
//  `AppState.gatewayMediaResolver`) so ChatView's FIRST body pass already
//  has a resolver — no nil → resolver invalidation pass over the settled
//  transcript after appear. The appState reference is weak because the
//  AppState-cached resolver would otherwise retain its owner in a cycle;
//  AppState outlives every view that holds the resolver.
//

import SwiftUI

@MainActor
final class GatewayMediaDataURLResolver {
    private weak var appState: AppState?
    let profile: String
    /// Dashboard this resolver was built for: a retained resolver must never
    /// start a request against a different server after a switch.
    let dashboardID: UUID?

    init(appState: AppState, profile: String) {
        self.appState = appState
        self.profile = profile
        self.dashboardID = appState.activeDashboardID
    }

    private var currentAppState: AppState? {
        guard let appState, appState.activeDashboardID == dashboardID else { return nil }
        return appState
    }

    /// The connected Hermes' dashboard, while it is still the one this
    /// resolver was built for (a Desktop card's plugin route, #1522).
    var connectedDashboardBridge: DashboardTicketBridge? {
        currentAppState?.dashboardTicketBridge
    }

    func dataURL(for path: String) async -> String? {
        guard let appState = currentAppState else { return nil }
        let result = await appState.gatewayMediaDataURL(for: path, profile: profile)
        return appState.activeDashboardID == dashboardID ? result : nil
    }

    /// The file itself on disk, for media too large for a data URL (#569).
    func file(for path: String, maxBytes: Int = DashboardFileDownloadLimits.maxBytes) async -> GatewayMediaFileResult {
        guard let appState = currentAppState else { return .unavailable }
        let result = await appState.gatewayMediaFile(for: path, profile: profile, maxBytes: maxBytes)
        guard appState.activeDashboardID == dashboardID else {
            if case .downloaded(let download) = result {
                MediaPreviewPresenter.removeDirectory(download.directory)
            }
            return .unavailable
        }
        return result
    }

    /// A picture stored inside a persisted message, for when its file is
    /// gone from the server (#652).
    func inlineImageDataURL(_ ref: InlineImageRef) async -> String? {
        guard let appState = currentAppState else { return nil }
        let result = await appState.transcriptInlineImageDataURL(ref)
        return appState.activeDashboardID == dashboardID ? result : nil
    }

    /// Where a chat picture is kept on the phone: by the server file it
    /// names, else by its place inside its message. Scoped to the connected
    /// Hermes so two servers' same-named files never mix.
    func imageCacheKey(for attachment: Attachment) -> String? {
        guard currentAppState != nil else { return nil }
        let dashboard = dashboardID?.uuidString ?? ""
        if attachment.uri.hasPrefix("/") {
            return TranscriptImageCache.key(dashboard: dashboard, profile: profile, path: attachment.uri)
        }
        if let ref = attachment.inlineImage {
            return TranscriptImageCache.key(dashboard: dashboard, inlineImage: ref)
        }
        return nil
    }

    /// Where a reply's `MEDIA:` picture is kept on the phone, scoped like
    /// a server file attachment.
    func imageCacheKey(forMediaPath path: String) -> String? {
        guard currentAppState != nil, !path.isEmpty else { return nil }
        return TranscriptImageCache.key(dashboard: dashboardID?.uuidString ?? "", profile: profile, path: path)
    }
}

/// A gateway `MEDIA:` file fetched for opening.
enum GatewayMediaFileResult: Sendable {
    /// On disk; the receiver owns the file's directory.
    case downloaded(DashboardDownloadedFile)
    /// Larger than the phone downloads.
    case tooLarge
    /// Not fetched: an older Hermes without `/api/fs/download`, no sign-in
    /// yet, or a network failure. The data URL is the fallback.
    case unavailable
}

private struct GatewayMediaFilesKey: EnvironmentKey {
    static let defaultValue: GatewayMediaDataURLResolver? = nil
}

extension EnvironmentValues {
    /// Where Markdown's gateway file cards download videos, audio and
    /// documents from (#569). Nil keeps them on the data URL path alone.
    var gatewayMediaFiles: GatewayMediaDataURLResolver? {
        get { self[GatewayMediaFilesKey.self] }
        set { self[GatewayMediaFilesKey.self] = newValue }
    }
}
