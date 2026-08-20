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

@MainActor
final class GatewayMediaDataURLResolver {
    private let appState: AppState
    let profile: String

    init(appState: AppState, profile: String) {
        self.appState = appState
        self.profile = profile
    }

    func dataURL(for path: String) async -> String? {
        await appState.gatewayMediaDataURL(for: path, profile: profile)
    }
}
