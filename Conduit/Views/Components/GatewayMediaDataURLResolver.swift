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

    init(appState: AppState, profile: String) {
        self.appState = appState
        self.profile = profile
    }

    func dataURL(for path: String) async -> String? {
        guard let appState else { return nil }
        return await appState.gatewayMediaDataURL(for: path, profile: profile)
    }

    /// The file itself on disk, for media too large for a data URL (#569).
    func file(for path: String, maxBytes: Int = DashboardFileDownloadLimits.maxBytes) async -> GatewayMediaFileResult {
        guard let appState else { return .unavailable }
        return await appState.gatewayMediaFile(for: path, profile: profile, maxBytes: maxBytes)
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
