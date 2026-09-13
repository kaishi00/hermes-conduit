//
//  SavedDashboardRegistry.swift
//  Conduit
//
//  Multi-dashboard identity for issue #148: a stable, app-generated UUID —
//  never the normalized URL — is each dashboard's durable identity, so the
//  saved entry survives address changes (Tailnet name moves, port edits) and
//  two servers that both answer on profile "default" / session "default"
//  never share auth state.
//
//  The registry itself carries only metadata (id, label, normalized URL).
//  Every reusable authentication record — connection ticket, password
//  credentials, Cloudflare service token, dashboard cookie mirror — lives in
//  its own Keychain record whose account name embeds the dashboard UUID, so
//  dashboard A's state can never be read or cleared through dashboard B.
//
//  Storage is the Keychain, not UserDefaults: the registry names the servers
//  the user authenticates against, which is connection data and follows the
//  same privacy intent as the records it indexes.
//

import Foundation

/// One saved Hermes dashboard. The UUID is the identity; `normalizedURL` is
/// the current address it was last reached at.
struct SavedDashboard: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    var normalizedURL: String
}

/// The persisted multi-dashboard registry. `schemaVersion` guards future
/// shape changes; `activeDashboardID` is the dashboard the user last chose —
/// it is set at switch INTENT (before connecting), so a failed switch leaves
/// the target selected with its sign-in/repair surface instead of silently
/// falling back to the outgoing server.
struct SavedDashboardRegistry: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var activeDashboardID: UUID?
    var dashboards: [SavedDashboard]

    init(activeDashboardID: UUID? = nil, dashboards: [SavedDashboard] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.activeDashboardID = activeDashboardID
        self.dashboards = dashboards
    }

    func dashboard(with id: UUID) -> SavedDashboard? {
        dashboards.first { $0.id == id }
    }

    /// The saved dashboard currently reached at this normalized address.
    /// Normalized URLs are unique in the registry: adoption dedupes by URL,
    /// so two saved entries can never resolve to one server.
    func dashboard(atNormalizedURL url: String) -> SavedDashboard? {
        dashboards.first { $0.normalizedURL == url }
    }

    /// The ID a connection to this address belongs to: the saved dashboard's
    /// UUID when one exists, otherwise nil (the caller registers a new
    /// dashboard on adoption).
    func dashboardID(atNormalizedURL url: String) -> UUID? {
        dashboard(atNormalizedURL: url)?.id
    }
}

// MARK: - Label derivation

enum SavedDashboardLabel {
    /// Derives an initial display label from a dashboard address. A DNS host
    /// contributes its first label ("mac.tailnet.ts.net" → "Mac"); an IP
    /// literal stays whole ("192.168.1.5"). `existingLabels` disambiguates
    /// duplicates ("Mac", "Mac 2"), so two addresses can never render as two
    /// indistinguishable rows.
    static func derive(from baseURL: String, existingLabels: [String] = []) -> String {
        let host = URL(string: baseURL)?.host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let base: String
        if let host, !host.isEmpty {
            // IPv6 literals (any colon) and dotted-quad IPv4 stay whole; a
            // DNS host contributes its first label.
            if host.contains(":") {
                base = host
            } else {
                let looksLikeIP = host.dropFirst().allSatisfy { $0.isNumber || $0 == "." } && host.first?.isNumber == true
                if looksLikeIP {
                    base = host
                } else {
                    let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
                    base = firstLabel.localizedCapitalized
                }
            }
        } else {
            base = AppLocalization.string("Dashboard")
        }
        guard existingLabels.contains(base) else { return base }
        var candidate = base
        var counter = 2
        while existingLabels.contains(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }
}

// MARK: - Secure store

/// Keychain-backed registry persistence. The record is written LAST during
/// migration — its presence is the idempotency gate, so a migration that dies
/// halfway leaves no registry and the next launch retries from legacy state.
enum SavedDashboardRegistryStore {
    static let keychainAccount = "hermes-conduit.dashboard-registry.v1"

    static func load() -> SavedDashboardRegistry? {
        guard let data = KeychainHelper.loadDashboardRegistryData(),
              let registry = try? JSONDecoder().decode(SavedDashboardRegistry.self, from: data) else {
            return nil
        }
        return registry
    }

    static func save(_ registry: SavedDashboardRegistry) {
        guard let data = try? JSONEncoder().encode(registry) else { return }
        KeychainHelper.saveDashboardRegistryData(data)
    }
}

// MARK: - Legacy migration

/// The pre-multi-dashboard auth state, read once from the legacy global
/// Keychain records. Every field is optional: real installs carry partial
/// state (browser-auth dashboards have no password credentials, Face ID
/// setups still carry the ticket, clean installs have nothing).
struct LegacyDashboardState: Equatable {
    var connection: HermesConnection?
    var credentials: DashboardCredentials?
    var cookieMirror: Data?
    var cloudflare: CloudflareAccessKeychainRecord?
    var rememberedDashboardURL: String?

    /// Whether anything at all was stored under the legacy layout.
    var isEmpty: Bool {
        connection == nil && credentials == nil && cookieMirror == nil && cloudflare == nil
    }

    /// The address the legacy dashboard was reached at. Password credentials
    /// are the most authoritative (they were saved against a normalized
    /// URL); the saved connection ticket and the Cloudflare origin follow;
    /// the remembered dashboard URL is the last resort. Cookies alone can
    /// never establish an address.
    var derivedDashboardURL: String? {
        if let baseURL = credentials?.baseURL, !baseURL.isEmpty { return baseURL }
        if let baseURL = connection?.baseUrl, !baseURL.isEmpty { return baseURL }
        if let origin = cloudflare?.origin, !origin.isEmpty { return origin }
        if let remembered = rememberedDashboardURL, !remembered.isEmpty { return remembered }
        return nil
    }
}

enum SavedDashboardMigration {
    /// The exact writes a migration performs, in order. Scoped records are
    /// written FIRST, the registry LAST, and legacy records are retired only
    /// after the complete new state is committed — at every crash point the
    /// old state still works and the next launch retries (or, once the
    /// registry exists, lazily finishes the retirement).
    struct Plan: Equatable {
        var dashboardID: UUID
        var normalizedURL: String
        var label: String
        var writesConnection: Bool
        var writesCredentials: Bool
        var writesCookies: Bool
        var writesCloudflare: Bool
        /// True when the legacy chat-resume server identity (a URL) should be
        /// relabeled to the dashboard UUID so the upgrade does not trigger a
        /// one-time runtime teardown.
        var relabelsServerIdentity: Bool
        var createsRegistry: Bool
        var retiresLegacy: Bool

        static let none = Plan(
            dashboardID: UUID(),
            normalizedURL: "",
            label: "",
            writesConnection: false,
            writesCredentials: false,
            writesCookies: false,
            writesCloudflare: false,
            relabelsServerIdentity: false,
            createsRegistry: false,
            retiresLegacy: false
        )
    }

    enum Outcome: Equatable {
        /// A registry already existed: nothing to do (legacy leftovers are
        /// retired lazily).
        case alreadyMigrated(retireLegacy: Bool)
        /// No legacy state at all: commit an empty registry so clean installs
        /// never re-run migration.
        case cleanInstall
        case migrated(Plan)
    }

    /// Pure decision function. `existingRegistry` nil means "no registry yet".
    /// `legacy` carries the current global-record state; `storedServerIdentity`
    /// is the raw chat-resume identity key value (URL-shaped in legacy
    /// builds, UUID-shaped after a relabel).
    static func outcome(
        legacy: LegacyDashboardState,
        existingRegistry: SavedDashboardRegistry?,
        storedServerIdentity: String?,
        normalizedLegacyURL: String?
    ) -> Outcome {
        if existingRegistry != nil {
            // Registry present: migration already committed. The only work
            // left is retiring whatever legacy records still exist.
            return .alreadyMigrated(retireLegacy: !legacy.isEmpty)
        }
        guard !legacy.isEmpty, let rawURL = legacy.derivedDashboardURL else {
            // Nothing to migrate (clean install, or unusable fragments with
            // no address): commit the empty registry so this branch never
            // re-runs, and let the caller retire whatever fragments exist.
            return legacy.isEmpty ? .cleanInstall : .alreadyMigrated(retireLegacy: true)
        }
        let normalized = normalizedLegacyURL
            ?? (try? ConnectionURLPolicy.normalizedBaseURL(rawURL))
            ?? rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = SavedDashboardLabel.derive(from: normalized)
        // Relabel the server identity only when it currently names THIS
        // address (the common upgrade path). A stored identity for a
        // different URL means the user last used another server; leave it —
        // the next connection boundary handles the switch.
        let identityMatchesURL = storedServerIdentity
            .flatMap(AppState.normalizedChatResumeServerIdentity) == normalized
            || storedServerIdentity?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        return .migrated(Plan(
            dashboardID: UUID(),
            normalizedURL: normalized,
            label: label,
            writesConnection: legacy.connection != nil,
            writesCredentials: legacy.credentials != nil,
            writesCookies: legacy.cookieMirror != nil,
            writesCloudflare: legacy.cloudflare != nil,
            relabelsServerIdentity: identityMatchesURL,
            createsRegistry: true,
            retiresLegacy: true
        ))
    }
}

// MARK: - Orchestrator

@MainActor
enum SavedDashboardMigrator {
    /// Loads the registry, running the legacy migration when no registry
    /// exists yet. Called once per launch, before AppState hydrates its
    /// connection. Idempotent, retryable, and crash-safe by construction:
    /// see `SavedDashboardMigration.outcome`.
    static func loadRegistry(defaults: UserDefaults = .standard) -> SavedDashboardRegistry {
        if let existing = SavedDashboardRegistryStore.load() {
            if !LegacyDashboardReader.read(defaults: defaults).isEmpty {
                LegacyDashboardReader.retireLegacy()
            }
            return existing
        }
        let legacy = LegacyDashboardReader.read(defaults: defaults)
        let outcome = SavedDashboardMigration.outcome(
            legacy: legacy,
            existingRegistry: nil,
            storedServerIdentity: defaults.string(forKey: AppState.chatResumeServerIdentityKey),
            normalizedLegacyURL: nil
        )
        switch outcome {
        case .alreadyMigrated(let retireLegacy):
            // Unreachable with a nil registry except for the fragment branch:
            // commit the empty registry so the decision is terminal, and
            // retire the unusable fragments.
            if retireLegacy { LegacyDashboardReader.retireLegacy() }
            let registry = SavedDashboardRegistry()
            SavedDashboardRegistryStore.save(registry)
            return registry
        case .cleanInstall:
            let registry = SavedDashboardRegistry()
            SavedDashboardRegistryStore.save(registry)
            return registry
        case .migrated(let plan):
            return execute(plan: plan, legacy: legacy, defaults: defaults)
        }
    }

    /// Applies a migration plan. Ordering is load-bearing: every dashboard-
    /// scoped secure record is written before the registry commits, and the
    /// legacy records are deleted only after the registry is durable.
    static func execute(
        plan: SavedDashboardMigration.Plan,
        legacy: LegacyDashboardState,
        defaults: UserDefaults
    ) -> SavedDashboardRegistry {
        if let connection = legacy.connection, plan.writesConnection {
            KeychainHelper.saveConnection(connection, dashboardID: plan.dashboardID)
        }
        if let credentials = legacy.credentials, plan.writesCredentials {
            KeychainHelper.saveCredentials(credentials, dashboardID: plan.dashboardID)
        }
        if let cookies = legacy.cookieMirror, plan.writesCookies {
            KeychainHelper.saveDashboardCookies(cookies, dashboardID: plan.dashboardID)
        }
        if let cloudflare = legacy.cloudflare, plan.writesCloudflare {
            KeychainHelper.saveCloudflareKeychainRecord(cloudflare, dashboardID: plan.dashboardID)
        }
        if plan.relabelsServerIdentity {
            defaults.set(plan.dashboardID.uuidString, forKey: AppState.chatResumeServerIdentityKey)
        }
        let dashboard = SavedDashboard(
            id: plan.dashboardID,
            label: plan.label,
            normalizedURL: plan.normalizedURL
        )
        let registry = SavedDashboardRegistry(
            activeDashboardID: plan.dashboardID,
            dashboards: [dashboard]
        )
        SavedDashboardRegistryStore.save(registry)
        if plan.retiresLegacy {
            LegacyDashboardReader.retireLegacy()
        }
        return registry
    }
}

/// Reads and retires the legacy global auth records. Kept separate from the
/// KeychainHelper scoped APIs so the multi-server paths can never accidentally
/// reach for global state: only migration and lazy cleanup touch these.
enum LegacyDashboardReader {
    static func read(defaults: UserDefaults) -> LegacyDashboardState {
        LegacyDashboardState(
            connection: KeychainHelper.loadConnection(),
            credentials: KeychainHelper.loadCredentials(),
            cookieMirror: KeychainHelper.loadDashboardCookies(),
            cloudflare: KeychainHelper.loadCloudflareKeychainRecord(),
            rememberedDashboardURL: defaults.string(forKey: "conduit.dashboardURL")
        )
    }

    /// Deletes the legacy global records. The installation-wide push
    /// registration is deliberately untouched: push pairing is per-device,
    /// not per-dashboard.
    static func retireLegacy() {
        KeychainHelper.clearConnection()
        KeychainHelper.clearCredentials()
        KeychainHelper.clearCloudflareAccess()
    }
}
