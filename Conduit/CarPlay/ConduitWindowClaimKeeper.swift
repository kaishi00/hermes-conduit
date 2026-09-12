//
//  ConduitWindowClaimKeeper.swift
//  Conduit
//
//  Multi-scene support is enabled so the CarPlay scene can coexist with the
//  phone scene, but a SECOND foreground Conduit window (iPad Stage Manager /
//  dock "+") is not a supported surface: SwiftUI's singleton `Window` scene
//  is iOS-unavailable, so the process keeps a simple first-window claim.
//  The first WindowGroup window to appear claims it; later windows dismiss
//  themselves, and a closed primary window releases the claim so the next
//  window can become primary.
//

@MainActor
final class ConduitWindowClaimKeeper {
    /// Process-scoped by design: claims live exactly as long as this process
    /// launch, and a system kill of the primary window takes the process's
    /// claim with it. Within one launch, the RootView primary releases on
    /// close; if a primary ever leaks without onDisappear, new windows stay
    /// dismissed until relaunch (accepted: the app remains usable via
    /// CarPlay, and relaunch heals it).
    private static var isClaimed = false

    /// Returns true when the caller becomes the primary window; false when a
    /// primary window already exists and the caller should dismiss itself.
    static func claimPrimaryWindow() -> Bool {
        if isClaimed { return false }
        isClaimed = true
        return true
    }

    /// The primary window closed: the next window to appear may claim.
    static func releaseClaim() {
        isClaimed = false
    }

    /// Test isolation only.
    static func resetForTesting() {
        isClaimed = false
    }
}
