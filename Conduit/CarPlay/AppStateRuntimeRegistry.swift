//
//  AppStateRuntimeRegistry.swift
//  Conduit
//
//  Process-wide home of the single AppState instance.
//
//  SwiftUI's `@StateObject` evaluates its factory lazily when the foreground
//  scene first renders, but a CarPlay-first launch can connect the CarPlay
//  scene before any phone scene exists. Both surfaces therefore resolve the
//  AppState through this MainActor registry: whoever needs it first creates
//  it, and the other surface adopts the exact same instance. The registry is
//  a reference/lifecycle seam only — it owns no business logic.
//

@MainActor
final class AppStateRuntimeRegistry {
    static let shared = AppStateRuntimeRegistry()

    private var stored: AppState?

    /// The process-wide AppState, created on first access. AppState's own
    /// initializer performs the authoritative cold-launch bootstrap (saved
    /// connection restore), so a CarPlay-first launch establishes connection
    /// readiness without waiting for any phone view to run.
    var appState: AppState {
        if let stored { return stored }
        let created = AppState()
        stored = created
        return created
    }

    internal init() {}

    /// Test isolation only.
    internal func resetForTesting() {
        stored = nil
    }
}
