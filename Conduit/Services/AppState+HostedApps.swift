//
//  AppState+HostedApps.swift
//  Conduit
//
//  Settings > Capabilities > Connectors > Apps (HostedAppsViews.swift): the
//  apps Hermes reaches through Nous Portal's hosted connectors, over the
//  gateway's `connectors.*` calls for the profile's own account, as Hermes
//  Desktop's Connectors page. What the section shows is kept so it opens
//  on it (#1533): the catalog, the accounts' names and the rules, never a
//  sign-in, which Hermes and the Portal hold.
//

import Foundation

/// Why the Apps section can't show or change the apps.
enum HostedAppsError: Error, Equatable, LocalizedError {
    case notConnected
    /// This Hermes has no hosted connector calls.
    case unsupported
    /// Another connection or profile took over while Hermes answered.
    case superseded
    /// The member has no rules of their own to change.
    case readOnlyRules
    /// The rules changed elsewhere since they were read.
    case rulesChanged

    var errorDescription: String? {
        switch self {
        case .notConnected: AppLocalization.string("Connect to Hermes to manage its apps.")
        case .unsupported: AppLocalization.string("This Hermes can't connect apps yet. Update Hermes to use them.")
        case .superseded: AppLocalization.string("That was interrupted before it finished. Try again.")
        case .readOnlyRules: AppLocalization.string("Your organization manages these switches.")
        case .rulesChanged: AppLocalization.string("The switches changed somewhere else. They show what's set now; try again.")
        }
    }
}

extension AppState {
    static let hostedAppsRoute = "rpc:connectors.list"

    /// What the apps a screen shows belong to: the dashboard, the profile
    /// and the client that carries it.
    var hostedAppsScope: String {
        "\(activeDashboardID?.uuidString ?? "")|\(activeProfile)|\(client.map { "\(ObjectIdentifier($0).hashValue)" } ?? "")|\(isConnected)"
    }

    /// The apps as Hermes gave them last time on this dashboard and profile.
    func keptHostedApps() -> HostedAppsSnapshot? {
        keptRead(HostedAppsSnapshot.self, Self.hostedAppsRoute, profile: activeProfile)
    }

    /// Whether hosted apps are on, the catalog, each app's connection, the
    /// accounts and the rules, kept for the section to open on next time.
    /// A Hermes that has them off answers an empty, unavailable snapshot.
    func loadHostedApps() async throws -> HostedAppsSnapshot {
        let profile = activeProfile
        return try await withHostedAppsClient { client in
            try await self.keepingRead(as: Self.hostedAppsRoute, profile: profile, owner: self.currentDashboardRuntimeOwner()) {
                let list: (available: Bool, statuses: [HostedAppStatus])
                do {
                    list = try await client.hostedAppStatuses()
                } catch let error as RpcError where error.reason == "CONNECTORS_UNAVAILABLE" {
                    return HostedAppsSnapshot.unavailable
                }
                guard list.available else { return HostedAppsSnapshot.unavailable }
                async let catalog = client.hostedAppCatalog()
                async let accounts = client.hostedAppAccounts()
                // The rules need a Nous account; before the first app
                // there may be none, and every app is on.
                let policy = try? await client.hostedAppPolicy()
                return try await HostedAppsSnapshot(
                    available: true, catalog: catalog, statuses: list.statuses, accounts: accounts, policy: policy
                )
            }
        }
    }

    func hostedAppTools(_ slug: String, refresh: Bool = false) async throws -> [HostedAppTool] {
        try await withHostedAppsClient { try await $0.hostedAppTools(slug, refresh: refresh) }
    }

    /// Starts an app's sign-in: a new account, or `repairing` one signed in
    /// again. The page to open comes with the answer.
    func connectHostedApp(_ slug: String, alias: String? = nil, repairing connectionID: String? = nil) async throws -> HostedAppOperation {
        try await withHostedAppsClient { try await $0.connectHostedApp(slug, alias: alias, repairing: connectionID) }
    }

    func hostedAppOperation(_ id: String) async throws -> HostedAppOperation {
        try await withHostedAppsClient { try await $0.hostedAppOperation(id) }
    }

    func wakeHostedAppOperation(_ id: String) async throws {
        try await withHostedAppsClient { try await $0.wakeHostedAppOperation(id) }
    }

    /// Gives up a sign-in, as Desktop's Stop waiting does: Hermes stops
    /// waiting, and the accounts it started that never finished go. Which
    /// ones is read again first: one finished since the last look stays,
    /// and when Hermes can't say, none is removed.
    func stopHostedAppSignIn(_ operation: HostedAppOperation) async throws {
        try await withHostedAppsClient { client in
            let fresh = try? await client.hostedAppOperation(operation.id)
            try await client.settleHostedAppOperation(operation.id)
            guard let fresh else { return }
            for target in fresh.targets where !target.connected {
                let id = target.connectionID ?? operation.target(target.name)?.connectionID
                if let id { try? await client.removeHostedAppAccount(id) }
            }
        }
    }

    /// Names an account; the kept apps take Hermes' copy at once.
    func renameHostedAppAccount(_ connectionID: String, to alias: String) async throws -> HostedAppAccount {
        let profile = activeProfile
        let owner = currentDashboardRuntimeOwner()
        let account = try await withHostedAppsClient { try await $0.renameHostedAppAccount(connectionID, to: alias) }
        keepWrittenChange(HostedAppsSnapshot.self, Self.hostedAppsRoute, profile: profile, on: owner) { kept in
            kept.accounts = kept.accounts.map { $0.connectionID == connectionID ? account : $0 }
        }
        return account
    }

    /// Disconnects an account; it leaves the kept apps at once.
    func removeHostedAppAccount(_ connectionID: String) async throws {
        let profile = activeProfile
        let owner = currentDashboardRuntimeOwner()
        try await withHostedAppsClient { try await $0.removeHostedAppAccount(connectionID) }
        keepWrittenChange(HostedAppsSnapshot.self, Self.hostedAppsRoute, profile: profile, on: owner) { kept in
            kept.accounts.removeAll { $0.connectionID == connectionID }
        }
    }

    /// Turns an app on or off for Hermes. Returns the rules as Hermes now
    /// holds them.
    func setHostedApp(_ slug: String, enabled: Bool, policy: HostedAppPolicy?) async throws -> HostedAppPolicy {
        try await writeHostedAppRules(policy: policy, change: ["type": "connector", "connector": slug, "enabled": enabled])
    }

    /// Sets which of an app's tools are off. Returns the rules as Hermes
    /// now holds them.
    func setHostedAppTools(_ slug: String, disabled: [String], policy: HostedAppPolicy?) async throws -> HostedAppPolicy {
        try await writeHostedAppRules(policy: policy, change: ["type": "tools", "connector": slug, "disabled_tools": disabled])
    }

    /// A change sent against the member rules' revision, then the rules
    /// read back (Hermes answers only the new revision), kept for the
    /// section. Rules changed elsewhere meanwhile are read and kept too,
    /// and the change isn't sent again.
    private func writeHostedAppRules(policy: HostedAppPolicy?, change: [String: Any]) async throws -> HostedAppPolicy {
        guard let revision = policy?.revision else { throw HostedAppsError.readOnlyRules }
        let profile = activeProfile
        let owner = currentDashboardRuntimeOwner()
        return try await withHostedAppsClient { client in
            var conflict = false
            do {
                _ = try await client.setHostedAppPolicy(change: change, expectedRevision: revision)
            } catch let error as RpcError where error.reason == "POLICY_CONFLICT" {
                conflict = true
            }
            let current = try await client.hostedAppPolicy()
            self.keepWrittenChange(HostedAppsSnapshot.self, Self.hostedAppsRoute, profile: profile, on: owner) { kept in
                kept.policy = current
            }
            if conflict { throw HostedAppsError.rulesChanged }
            return current
        }
    }

    /// Runs a call on the client in use, which carries the profile. An
    /// answer that lands after the client changed is thrown away: it was
    /// about another connection or profile.
    private func withHostedAppsClient<T>(_ call: (HermesClient) async throws -> T) async throws -> T {
        guard let client, isConnected else { throw HostedAppsError.notConnected }
        do {
            let value = try await call(client)
            guard self.client === client else { throw HostedAppsError.superseded }
            return value
        } catch let error as RpcError where error.code == HermesClient.methodNotFoundCode {
            throw HostedAppsError.unsupported
        }
    }
}
