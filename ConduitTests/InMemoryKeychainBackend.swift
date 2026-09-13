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
    private let service = "com.milim.conduit"

    private func key(for query: [String: Any]) -> Key? {
        guard let account = query[kSecAttrAccount as String] as? String else { return nil }
        let queryService = query[kSecAttrService as String] as? String ?? service
        return Key(service: queryService, account: account)
    }

    func data(for query: [String: Any]) -> Data? {
        key(for: query).flatMap { storage[$0] }
    }

    func update(_ data: Data, for query: [String: Any]) -> Int32 {
        guard let key = key(for: query), storage[key] != nil else {
            return errSecItemNotFound
        }
        storage[key] = data
        return errSecSuccess
    }

    func add(_ query: [String: Any]) -> Int32 {
        guard let key = key(for: query) else { return errSecParam }
        storage[key] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) {
        if let key = key(for: query) { storage.removeValue(forKey: key) }
    }

    /// Test diagnostics: whether a record exists for an account.
    func hasAccount(_ account: String) -> Bool {
        storage.keys.contains { $0.account == account }
    }
}
