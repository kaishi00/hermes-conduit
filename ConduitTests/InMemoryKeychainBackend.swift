//
//  InMemoryKeychainBackend.swift
//  Conduit
//
//  KeychainHelper.Backend conformer for tests. The unsigned simulator test
//  host has no keychain entitlements — every SecItem call fails with
//  errSecMissingEntitlement — so tests that exercise secure-record round
//  trips install this backend: same semantics, per-instance storage.
//

import Foundation
import Security
@testable import Conduit

final class InMemoryKeychainBackend: KeychainHelper.Backend {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private var storage: [Key: Data] = [:]
    private var accessibilityClasses: [Key: String] = [:]
    private let service = "com.milim.conduit"

    private func key(for query: [String: Any]) -> Key? {
        guard let account = query[kSecAttrAccount as String] as? String else { return nil }
        let queryService = query[kSecAttrService as String] as? String ?? service
        return Key(service: queryService, account: account)
    }

    /// A locked phone: records readable only while unlocked read as absent,
    /// and writing them fails as it does on a device.
    var phoneLocked = false

    private func availableNow(accessibility: String?) -> Bool {
        guard phoneLocked else { return true }
        let whenUnlocked = [
            kSecAttrAccessibleWhenUnlocked as String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
        ]
        // No class given is Apple's default: readable only while unlocked.
        return !whenUnlocked.contains(accessibility ?? kSecAttrAccessibleWhenUnlocked as String)
    }

    private func readableNow(_ key: Key) -> Bool {
        availableNow(accessibility: accessibilityClasses[key])
    }

    func data(for query: [String: Any]) -> Data? {
        guard let key = key(for: query), readableNow(key) else { return nil }
        return storage[key]
    }

    func update(_ data: Data, for query: [String: Any]) -> Int32 {
        guard let key = key(for: query), storage[key] != nil else {
            return errSecItemNotFound
        }
        guard readableNow(key) else { return errSecInteractionNotAllowed }
        storage[key] = data
        return errSecSuccess
    }

    func add(_ query: [String: Any]) -> Int32 {
        guard let key = key(for: query) else { return errSecParam }
        let accessibility = query[kSecAttrAccessible as String] as? String
        guard availableNow(accessibility: accessibility) else { return errSecInteractionNotAllowed }
        storage[key] = query[kSecValueData as String] as? Data
        accessibilityClasses[key] = accessibility
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) {
        if let key = key(for: query) {
            storage.removeValue(forKey: key)
            accessibilityClasses.removeValue(forKey: key)
        }
    }

    func setAccessibility(_ accessibility: CFString, for query: [String: Any]) -> Int32 {
        guard let key = key(for: query), storage[key] != nil else {
            return errSecItemNotFound
        }
        guard readableNow(key) else { return errSecInteractionNotAllowed }
        accessibilityClasses[key] = accessibility as String
        return errSecSuccess
    }

    /// Test diagnostics: the accessibility class an account's record has.
    func accessibility(ofAccount account: String) -> String? {
        accessibilityClasses.first { $0.key.account == account }?.value
    }

    /// Test diagnostics: whether a record exists for an account.
    func hasAccount(_ account: String) -> Bool {
        storage.keys.contains { $0.account == account }
    }
}
