//
//  KeychainHelper.swift
//  Conduit
//
//  Keychain reads and writes for saved credentials, behind the storage
//  seam tests replace. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

enum KeychainHelper {
    /// Storage backend seam. Production storage is the system keychain; tests
    /// install an in-memory backend because the unsigned simulator test host
    /// carries no keychain entitlements — every SecItem call fails with
    /// errSecMissingEntitlement (-34018), which would make any write/read
    /// round-trip silently useless. All record semantics (accessibility on
    /// add, scoped-before-legacy reads, two-query deletes) stay ABOVE the
    /// seam so the seam changes storage, never behavior.
    protocol Backend {
        func data(for query: [String: Any]) -> Data?
        func update(_ data: Data, for query: [String: Any]) -> Int32
        func add(_ query: [String: Any]) -> Int32
        func delete(_ query: [String: Any])
        /// Changes an existing item's accessibility class, which a data
        /// update never does.
        func setAccessibility(_ accessibility: CFString, for query: [String: Any]) -> Int32
    }

    struct SystemKeychainBackend: Backend {
        func data(for query: [String: Any]) -> Data? {
            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return data
        }

        func update(_ data: Data, for query: [String: Any]) -> Int32 {
            SecItemUpdate(query as CFDictionary, [
                kSecValueData as String: data
            ] as CFDictionary)
        }

        func add(_ query: [String: Any]) -> Int32 {
            SecItemAdd(query as CFDictionary, nil)
        }

        func delete(_ query: [String: Any]) {
            SecItemDelete(query as CFDictionary)
        }

        func setAccessibility(_ accessibility: CFString, for query: [String: Any]) -> Int32 {
            SecItemUpdate(query as CFDictionary, [
                kSecAttrAccessible as String: accessibility
            ] as CFDictionary)
        }
    }

    nonisolated(unsafe) private(set) static var backend: Backend = SystemKeychainBackend()

    /// Swaps the backend (tests). Not thread-safe by design: XCTest suites
    /// run serially within a simulator, and the swap is restored in teardown.
    static func useBackendForTesting(_ backend: Backend) {
        Self.backend = backend
        credentialsAccessibilityMoves.lock()
        credentialsMovedAccounts = []
        credentialsAccessibilityMoves.unlock()
    }

    /// Saved passwords are readable after the first unlock, like the saved
    /// session and cookies: a call from Hermes that wakes Conduit on a
    /// locked phone can sign in again with one (Eric's choice, 2026-10-11).
    /// Face ID guards the on-screen launch restore only; a silent renewal
    /// reads the password without it, as it already did while unlocked.
    static let credentialsAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    private static let credentialsAccessibilityMoves = NSLock()
    nonisolated(unsafe) private static var credentialsMovedAccounts: Set<String> = []

    /// Moves a saved password to `credentialsAccessibility`. Passwords saved
    /// by earlier builds were readable only while unlocked, and a data
    /// update keeps an item's class, so the class is set explicitly: once
    /// per launch, when the password is read (so the phone is unlocked) or
    /// saved. It is a synchronous Keychain call on the caller's thread,
    /// like the read beside it.
    private static func moveCredentialsAccessibility(account: String, force: Bool) {
        credentialsAccessibilityMoves.lock()
        defer { credentialsAccessibilityMoves.unlock() }
        guard force || !credentialsMovedAccounts.contains(account) else { return }
        var status = backend.setAccessibility(credentialsAccessibility, for: scopedQuery(account: account))
        if status == errSecItemNotFound {
            status = backend.setAccessibility(credentialsAccessibility, for: legacyQuery(account: account))
        }
        if status == errSecSuccess {
            credentialsMovedAccounts.insert(account)
        }
    }

    private static let key = "hermes-conduit.connection.v1"
    private static let dashboardCookieKey = "hermes-conduit.dashboard-cookies.v1"
    private static let credentialsKey = "hermes-conduit.credentials.v1"
    private static let cloudflareAccessKey = "hermes-conduit.cloudflare-access.v1"
    private static let nativeOAuthTokensKey = "hermes-conduit.native-oauth-tokens.v1"
    private static let pendingServerSignOutsKey = "hermes-conduit.pending-server-sign-outs.v1"
    private static let pushRegistrationKey = "hermes-conduit.push-registration.v1"
    private static let customHeadersKey = "hermes-conduit.custom-headers.v1"
    private static let healthSyncKeyAccount = "hermes-conduit.health-sync-key.v1"
    private static let phoneSyncKeyAccount = "hermes-conduit.phone-sync-key.v1"
    private static let shortcutInboxKeyAccount = "hermes-conduit.shortcut-inbox-key.v1"
    private static let service = "com.milim.conduit"

    static func saveConnection(_ conn: HermesConnection) {
        guard let data = try? JSONEncoder().encode(conn) else { return }
        save(data, account: key)
    }

    static func saveDashboardCookies(_ data: Data) {
        save(data, account: dashboardCookieKey)
    }

    static func loadDashboardCookies() -> Data? {
        load(account: dashboardCookieKey)
    }

    /// The record from before saved dashboards. Only the migrator reads it,
    /// and it rewrites it as a dashboard's own record (readable after the
    /// first unlock). Unreadable on a locked launch, it stays until a later
    /// launch or the retry on screen can read it
    /// (`SavedDashboardMigrator.adoptLeftoverCredentials`).
    static func saveCredentials(_ credentials: DashboardCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        save(
            data,
            account: credentialsKey,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    static func loadCredentials() -> DashboardCredentials? {
        guard let data = load(account: credentialsKey) else { return nil }
        return try? JSONDecoder().decode(DashboardCredentials.self, from: data)
    }

    static func clearCredentials() {
        delete(account: credentialsKey)
    }

    static func saveCloudflareAccess(_ access: CloudflareAccessCredentials, origin: String) {
        let stored = CloudflareAccessKeychainRecord(clientID: access.clientID, clientSecret: access.clientSecret, origin: origin)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        save(data, account: cloudflareAccessKey, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    /// Returns credentials only if the stored origin matches the given base URL.
    /// This prevents a token saved for one gateway from leaking to a different host.
    static func loadCloudflareAccess(for baseURL: String? = nil) -> CloudflareAccessCredentials? {
        guard let data = load(account: cloudflareAccessKey),
              let stored = try? JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: data) else { return nil }
        if let baseURL {
            let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? baseURL
            guard stored.origin == normalized else { return nil }
        }
        return stored.credentials
    }

    static func clearCloudflareAccess() {
        delete(account: cloudflareAccessKey)
    }

    /// Extra proxy headers (issue #305), keyed by secure server origin.
    /// Readable after first unlock like the Cloudflare token, so background
    /// reconnects reach a header-gated proxy too.
    static func saveCustomHeaders(_ headers: [String: [CustomHeader]]) {
        guard !headers.isEmpty else {
            delete(account: customHeadersKey)
            return
        }
        guard let data = try? JSONEncoder().encode(headers) else { return }
        save(data, account: customHeadersKey, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    static func loadCustomHeaders() -> [String: [CustomHeader]] {
        guard let data = load(account: customHeadersKey),
              let headers = try? JSONDecoder().decode([String: [CustomHeader]].self, from: data) else { return [:] }
        return headers
    }

    /// The raw legacy global Cloudflare record (origin included), read only
    /// by the legacy migration.
    static func loadCloudflareKeychainRecord() -> CloudflareAccessKeychainRecord? {
        guard let data = load(account: cloudflareAccessKey),
              let stored = try? JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: data) else { return nil }
        return stored
    }

    static func savePushRegistration(_ data: Data) {
        save(data, account: pushRegistrationKey)
    }

    static func loadPushRegistration() -> Data? {
        load(account: pushRegistrationKey)
    }

    static func clearPushRegistration() {
        delete(account: pushRegistrationKey)
    }

    // MARK: Pending server sign-outs

    /// Refresh tokens kept only until Hermes revokes them (#889). Nothing
    /// signs in with them. Readable after first unlock: a background launch
    /// retries too.
    static func savePendingServerSignOuts(_ entries: [PendingServerSignOut]) {
        guard !entries.isEmpty else {
            delete(account: pendingServerSignOutsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        save(data, account: pendingServerSignOutsKey)
    }

    static func loadPendingServerSignOuts() -> [PendingServerSignOut] {
        guard let data = load(account: pendingServerSignOutsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingServerSignOut].self, from: data)) ?? []
    }

    // MARK: Health sync key

    /// The key this phone agreed with the Hermes profile it shares health
    /// data with. Readable after first unlock: background syncs need it.
    static func saveHealthSyncKey(_ data: Data) {
        save(data, account: healthSyncKeyAccount)
    }

    static func loadHealthSyncKey() -> Data? {
        load(account: healthSyncKeyAccount)
    }

    static func clearHealthSyncKey() {
        delete(account: healthSyncKeyAccount)
    }

    // MARK: Phone sync key

    /// The keys this phone agreed with the Hermes profile it shares its
    /// calendar and status with. Readable after first unlock, as above.
    static func savePhoneSyncKey(_ data: Data) {
        save(data, account: phoneSyncKeyAccount)
    }

    static func loadPhoneSyncKey() -> Data? {
        load(account: phoneSyncKeyAccount)
    }

    static func clearPhoneSyncKey() {
        delete(account: phoneSyncKeyAccount)
    }

    /// The key this phone agreed with one dashboard and profile its Log to
    /// Hermes Shortcuts action posts to (`scope` is
    /// ShortcutInboxScope.storageID). Readable after first unlock, as
    /// above: automations run while the phone is locked.
    static func saveShortcutInboxKey(_ data: Data, scope: String) {
        save(data, account: "\(shortcutInboxKeyAccount).\(scope)")
    }

    static func loadShortcutInboxKey(scope: String) -> Data? {
        load(account: "\(shortcutInboxKeyAccount).\(scope)")
    }

    static func clearShortcutInboxKey(scope: String) {
        delete(account: "\(shortcutInboxKeyAccount).\(scope)")
    }

    // MARK: Dashboard registry (multi-server, #148)

    static let dashboardRegistryAccount = "hermes-conduit.dashboard-registry.v1"

    static func saveDashboardRegistryData(_ data: Data) {
        save(data, account: dashboardRegistryAccount)
    }

    static func loadDashboardRegistryData() -> Data? {
        load(account: dashboardRegistryAccount)
    }

    /// Removes the registry record. Used by tests to reset cross-test
    /// Keychain state; production never deletes the registry (migration
    /// idempotency depends on its presence).
    static func clearDashboardRegistry() {
        delete(account: dashboardRegistryAccount)
    }

    // MARK: Dashboard-scoped secure records (multi-server, #148)
    //
    // Every reusable authentication record gains a dashboard-scoped variant
    // whose Keychain account embeds the dashboard UUID. Scoped accounts can
    // never collide with the legacy global accounts (the UUID suffix is
    // globally unique), so the load-time legacy-query fallback below cannot
    // cross dashboards — and only the migration path intentionally reads the
    // legacy layout (see LegacyDashboardReader).

    static func scopedAccount(_ base: String, dashboardID: UUID) -> String {
        "\(base).\(dashboardID.uuidString)"
    }

    static func saveConnection(_ conn: HermesConnection, dashboardID: UUID) {
        guard let data = try? JSONEncoder().encode(conn) else { return }
        save(data, account: scopedAccount(key, dashboardID: dashboardID))
    }

    static func loadConnection(dashboardID: UUID) -> HermesConnection? {
        guard let data = load(account: scopedAccount(key, dashboardID: dashboardID)) else { return nil }
        return try? JSONDecoder().decode(HermesConnection.self, from: data)
    }

    /// Clears the scoped connection ticket AND the dashboard's durable cookie
    /// mirror, mirroring the legacy `clearConnection()` pairing.
    static func clearConnection(dashboardID: UUID) {
        clearSavedSession(dashboardID: dashboardID)
        delete(account: scopedAccount(nativeOAuthTokensKey, dashboardID: dashboardID))
    }

    /// Clears the scoped connection ticket and cookie mirror, keeping the
    /// dashboard's native grant.
    static func clearSavedSession(dashboardID: UUID) {
        delete(account: scopedAccount(key, dashboardID: dashboardID))
        delete(account: scopedAccount(dashboardCookieKey, dashboardID: dashboardID))
    }

    /// Whether the tokens were stored.
    @discardableResult
    static func saveNativeOAuthTokens(_ tokens: NativeOAuthTokenSet, dashboardID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return save(
            data,
            account: scopedAccount(nativeOAuthTokensKey, dashboardID: dashboardID),
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    static func loadNativeOAuthTokens(dashboardID: UUID) -> NativeOAuthTokenSet? {
        guard let data = load(account: scopedAccount(nativeOAuthTokensKey, dashboardID: dashboardID)) else { return nil }
        return try? JSONDecoder().decode(NativeOAuthTokenSet.self, from: data)
    }

    static func clearNativeOAuthTokens(dashboardID: UUID) {
        delete(account: scopedAccount(nativeOAuthTokensKey, dashboardID: dashboardID))
    }

    static func saveDashboardCookies(_ data: Data, dashboardID: UUID) {
        save(data, account: scopedAccount(dashboardCookieKey, dashboardID: dashboardID))
    }

    static func loadDashboardCookies(dashboardID: UUID) -> Data? {
        load(account: scopedAccount(dashboardCookieKey, dashboardID: dashboardID))
    }

    static func clearDashboardCookies(dashboardID: UUID) {
        delete(account: scopedAccount(dashboardCookieKey, dashboardID: dashboardID))
    }

    static func saveCredentials(_ credentials: DashboardCredentials, dashboardID: UUID) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let account = scopedAccount(credentialsKey, dashboardID: dashboardID)
        save(data, account: account, accessibility: credentialsAccessibility)
        // Saved over an earlier build's password, the item kept its class.
        moveCredentialsAccessibility(account: account, force: true)
    }

    static func loadCredentials(dashboardID: UUID) -> DashboardCredentials? {
        let account = scopedAccount(credentialsKey, dashboardID: dashboardID)
        guard let data = load(account: account) else { return nil }
        moveCredentialsAccessibility(account: account, force: false)
        return try? JSONDecoder().decode(DashboardCredentials.self, from: data)
    }

    static func clearCredentials(dashboardID: UUID) {
        delete(account: scopedAccount(credentialsKey, dashboardID: dashboardID))
    }

    static func saveCloudflareAccess(_ access: CloudflareAccessCredentials, origin: String, dashboardID: UUID) {
        let stored = CloudflareAccessKeychainRecord(clientID: access.clientID, clientSecret: access.clientSecret, origin: origin)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        save(
            data,
            account: scopedAccount(cloudflareAccessKey, dashboardID: dashboardID),
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    /// Returns the dashboard's stored token only when the stored origin
    /// matches the given base URL — the same origin fence the global record
    /// applies, now scoped per dashboard.
    static func loadCloudflareAccess(dashboardID: UUID, for baseURL: String? = nil) -> CloudflareAccessCredentials? {
        guard let record = loadCloudflareKeychainRecord(dashboardID: dashboardID) else { return nil }
        if let baseURL {
            let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? baseURL
            guard record.origin == normalized else { return nil }
        }
        return record.credentials
    }

    static func clearCloudflareAccess(dashboardID: UUID) {
        delete(account: scopedAccount(cloudflareAccessKey, dashboardID: dashboardID))
    }

    /// The raw Cloudflare record (origin included) for a dashboard, without
    /// origin matching.
    static func loadCloudflareKeychainRecord(dashboardID: UUID) -> CloudflareAccessKeychainRecord? {
        guard let data = load(account: scopedAccount(cloudflareAccessKey, dashboardID: dashboardID)),
              let stored = try? JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: data) else { return nil }
        return stored
    }

    static func saveCloudflareKeychainRecord(_ record: CloudflareAccessKeychainRecord, dashboardID: UUID) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        save(
            data,
            account: scopedAccount(cloudflareAccessKey, dashboardID: dashboardID),
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    /// Whether the record was written.
    @discardableResult
    private static func save(
        _ data: Data,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> Bool {
        let query = scopedQuery(account: account)
        // Accessibility belongs to a Keychain item at creation. Including it
        // in every update can reject an otherwise valid cookie update.
        let updateStatus = backend.update(data, for: query)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = accessibility
        return backend.add(insert) == errSecSuccess
    }

    static func loadConnection() -> HermesConnection? {
        guard let data = load(account: key) else { return nil }
        return try? JSONDecoder().decode(HermesConnection.self, from: data)
    }

    private static func load(account: String) -> Data? {
        load(query: scopedQuery(account: account)) ?? load(query: legacyQuery(account: account))
    }

    private static func load(query: [String: Any]) -> Data? {
        backend.data(for: query)
    }

    static func clearConnection() {
        delete(account: key)
        delete(account: dashboardCookieKey)
    }

    private static func delete(account: String) {
        backend.delete(scopedQuery(account: account))
        backend.delete(legacyQuery(account: account))
    }

    private static func scopedQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
    }
}
