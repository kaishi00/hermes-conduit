import Foundation

/// MCP OAuth on a remote Hermes: the phone receives the browser's redirect;
/// Hermes owns PKCE, the exchange and token storage. Both Connectors and
/// Edit Bot use the same flow, with a transport captured before any await.
@MainActor
enum NativeMCPSignIn {
    /// The live listener, replaceable in tests without opening a browser.
    struct Loopback {
        var start: () async throws -> UInt16
        var expect: (String) -> Void
        var callback: () async throws -> String
        var stop: () -> Void

        static func live() -> Loopback {
            let server = NativeOAuthLoopbackServer(expectedState: nil, relaysCallback: true)
            return Loopback(
                start: { try await server.start(timeout: 6 * 60) },
                expect: { server.expect(state: $0) },
                callback: { try await server.waitForCallback() },
                stop: { server.stop() }
            )
        }
    }

    static func run(
        profile: String,
        name: String,
        rpc: @escaping @MainActor (String, [String: Any]) async throws -> AnyCodable,
        isCurrent: @MainActor () -> Bool,
        open: @MainActor (URL) -> Void,
        loopback suppliedLoopback: Loopback? = nil
    ) async -> BotMcpSignInOutcome {
        let loopback = suppliedLoopback ?? .live()
        var sessionID: String?
        var approved = false
        defer {
            loopback.stop()
            // Cleanup belongs to the captured transport/profile, even after
            // the UI moved or its task was cancelled. Never look up a new client.
            if let sessionID, !approved {
                Task { _ = try? await rpc("cancel", ["profile": profile, "name": name, "session_id": sessionID]) }
            }
        }
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        do {
            try checkCurrent()
            let port = try await loopback.start()
            try checkCurrent()
            let redirectURI = "http://127.0.0.1:\(port)/callback"
            // A UI cancellation must not discard a start reply after Hermes
            // accepted it: the RPC has its own timeout. Reconcile its handle
            // before giving up, then cancel that exact backend flow.
            let start = Task { try await rpc("start", ["profile": profile, "name": name, "client_redirect_uri": redirectURI]) }
            let started = try await start.value
            // Retain the handle before checking cancellation: a late start
            // still needs its backend waiter released.
            sessionID = BotMcpSetup.payload(started)["session_id"]?.stringValue
            try checkCurrent()
            if let problem = BotMcpSetup.failure(started) { return .failed(problem) }
            guard let flow = BotMcpSetup.startedFlow(started, redirectURI: redirectURI) else {
                return .failed(AppLocalization.string("Update Hermes to sign in to MCP servers from Conduit."))
            }
            loopback.expect(flow.state)
            open(flow.authURL)
            let query = try await loopback.callback()
            try checkCurrent()
            // The live listener validates state and path before returning.
            // Only the callback fields Hermes accepts cross the transport.
            var params = BotMcpSetup.callbackParams(NativeOAuthFlow.queryValues(query))
            params["profile"] = profile
            params["name"] = name
            params["session_id"] = flow.sessionID
            let relayed = try await rpc("callback", params)
            try checkCurrent()
            if let problem = BotMcpSetup.failure(relayed) { return .failed(problem) }
            var pollFailures = 0
            for _ in 0..<BotMcpSetup.pollAttempts {
                try checkCurrent()
                let polled: AnyCodable
                do {
                    polled = try await rpc("poll", ["profile": profile, "name": name, "session_id": flow.sessionID])
                    try checkCurrent()
                    pollFailures = 0
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try checkCurrent()
                    pollFailures += 1
                    if pollFailures >= BotMcpSetup.pollFailureLimit { throw error }
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                switch BotMcpSetup.pollStatus(polled) {
                case "approved":
                    approved = true
                    return .signedIn
                case "error": return .failed(BotMcpSetup.pollError(polled))
                default: try await Task.sleep(for: .seconds(1))
                }
            }
            return .failed(AppLocalization.string("Sign-in timed out. Please try again."))
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard isCurrent(), !Task.isCancelled else { return .cancelled }
            return .failed(UserFacingError.message(for: error))
        }
    }
}
