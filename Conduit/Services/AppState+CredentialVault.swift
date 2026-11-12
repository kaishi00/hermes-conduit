//
//  AppState+CredentialVault.swift
//  Conduit
//
//  Settings > Passwords & logins (CredentialVaultViews.swift): the
//  profile's credential vault over the gateway's `vault.*` calls. The list
//  is metadata and is kept so the page opens on it (#1533); a password, a
//  card's numbers, an address and a master password go once onto the
//  socket and are never kept, logged or shown again.
//

import Foundation

/// Why the vault page can't show the vault.
enum CredentialVaultError: Error, Equatable, LocalizedError {
    /// Not connected to Hermes.
    case notConnected
    /// This Hermes has no vault calls (before 0.23).
    case unsupported
    /// Another connection or profile took over while Hermes answered: the
    /// answer was about the one before.
    case superseded

    var errorDescription: String? {
        switch self {
        case .notConnected: AppLocalization.string("Connect to Hermes to see its saved logins.", table: .connection)
        case .unsupported: AppLocalization.string("This Hermes has no credential vault yet. Update Hermes to 0.23 or later to keep logins here.", table: .connection)
        case .superseded: AppLocalization.string("That was interrupted before it finished. Try again.")
        }
    }
}

extension AppState {
    static let credentialVaultRoute = "rpc:vault.list"

    /// The vault as Hermes gave it last time on this dashboard and profile.
    func keptCredentialVault() -> CredentialVaultSnapshot? {
        keptRead(CredentialVaultSnapshot.self, Self.credentialVaultRoute, profile: activeProfile)
    }

    /// The profile's saved items and login sources, kept for the page to
    /// open on next time.
    func loadCredentialVault() async throws -> CredentialVaultSnapshot {
        let profile = activeProfile
        return try await withVaultClient { client in
            try await self.keepingRead(as: Self.credentialVaultRoute, profile: profile, owner: self.currentDashboardRuntimeOwner()) {
                // Sources first: an unlocked manager's items come with the list.
                let sources = try await client.vaultSources()
                let items = try await client.vaultItems()
                return CredentialVaultSnapshot(items: items, sources: sources)
            }
        }
    }

    /// Saves a login, card or address in Hermes' own vault. The kept list
    /// takes it at once, so the page never opens without it.
    func addCredentialVaultItem(_ request: VaultItemDraft.Request) async throws {
        try await writeVault {
            try await $0.addVaultItem(kind: request.kind, label: request.label, origin: request.origin, secret: request.secret)
        } keep: { id, kept in
            kept.add(id: id, request)
        }
    }

    /// Deletes an item from Hermes' own vault; false when it was gone.
    /// Either way it leaves the kept list.
    func removeCredentialVaultItem(id: String) async throws -> Bool {
        try await writeVault { try await $0.removeVaultItem(id: id) } keep: { _, kept in
            kept.items.removeAll { $0.id == id }
        }
    }

    /// Turning a manager off also locks it.
    func setCredentialVaultSource(_ name: String, enabled: Bool) async throws {
        try await writeVault { try await $0.setVaultSource(name, enabled: enabled) } keep: { _, kept in
            kept.changeSource(name, enabled: enabled, unlocked: enabled ? nil : false)
        }
    }

    /// The manager's items come with the next read.
    func unlockCredentialVaultSource(_ name: String, password: String) async throws {
        try await writeVault { try await $0.unlockVaultSource(name, password: password) } keep: { _, kept in
            kept.changeSource(name, unlocked: true)
        }
    }

    func lockCredentialVaultSource(_ name: String) async throws {
        try await writeVault { try await $0.lockVaultSource(name) } keep: { _, kept in
            kept.changeSource(name, unlocked: false)
        }
    }

    /// Runs a change, and once Hermes took it changes the list kept for
    /// the dashboard and profile it was made on, the one open by then or
    /// not, over the answer to any read asked before it (#1533). Also when
    /// the connection changed meanwhile: Hermes took it all the same.
    @discardableResult
    private func writeVault<T>(_ call: (HermesClient) async throws -> T, keep change: (T, inout CredentialVaultSnapshot) -> Void) async throws -> T {
        let profile = activeProfile
        let owner = currentDashboardRuntimeOwner()
        return try await withVaultClient(call) { value in
            self.keepWrittenChange(CredentialVaultSnapshot.self, Self.credentialVaultRoute, profile: profile, on: owner) { change(value, &$0) }
        }
    }

    /// Runs a vault call on the client in use, which carries the profile.
    /// An answer that lands after the client changed is thrown away: it was
    /// about another connection or profile.
    /// `took` runs as soon as Hermes answered, before that check.
    private func withVaultClient<T>(_ call: (HermesClient) async throws -> T, took: (T) -> Void = { _ in }) async throws -> T {
        guard let client, isConnected else { throw CredentialVaultError.notConnected }
        do {
            let value = try await call(client)
            took(value)
            guard self.client === client else { throw CredentialVaultError.superseded }
            return value
        } catch let error as RpcError where error.code == HermesClient.methodNotFoundCode {
            throw CredentialVaultError.unsupported
        }
    }
}
