//
//  LocationSharedStore.swift
//  Conduit
//
//  Where location sharing keeps its state, shared by the app and the
//  Location Push extension through the App Group:
//
//  - config.json: the binding, the user's choices and the saved places
//    (their coordinates live only here, on this phone);
//  - unsent.json: the latest fix that couldn't be sent and the last 50
//    arrive/leave events, with no outbox beyond that (losing a visit is
//    better than hoarding a timeline);
//  - the Keychain (App Group access group): the agreed key and the host
//    pass the extension signs in with.
//
//  Files are readable after first unlock (background wakes and the
//  extension run on a locked phone) and excluded from backups.
//

import Foundation
import Security

enum LocationSharedStore {
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NotificationE2E.appGroup)?
            .appendingPathComponent("Location", isDirectory: true)
    }

    // MARK: Config

    enum Read<Value> {
        case value(Value)
        /// Nothing saved yet.
        case missing
        /// Saved but unreadable now (before first unlock).
        case unreadable
    }

    static func readConfig(at url: URL? = folder?.appendingPathComponent("config.json")) -> Read<LocationSharedConfig> {
        read(LocationSharedConfig.self, at: url)
    }

    @discardableResult
    static func saveConfig(_ config: LocationSharedConfig, at url: URL? = folder?.appendingPathComponent("config.json")) -> Bool {
        write(config, to: url)
    }

    // MARK: Unsent

    static func readUnsent(at url: URL? = folder?.appendingPathComponent("unsent.json")) -> LocationUnsent {
        if case .value(let unsent) = read(LocationUnsent.self, at: url) { return unsent }
        return LocationUnsent()
    }

    @discardableResult
    static func saveUnsent(_ unsent: LocationUnsent, at url: URL? = folder?.appendingPathComponent("unsent.json")) -> Bool {
        write(unsent, to: url)
    }

    // MARK: Files

    private static func read<Value: Decodable>(_ type: Value.Type, at url: URL?) -> Read<Value> {
        guard let url else { return .missing }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { return .missing }
        return .value(value)
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL?) -> Bool {
        guard let url else { return false }
        do {
            var folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}

/// What couldn't be sent yet: only the latest fix and the last 50 events.
struct LocationUnsent: Codable, Equatable {
    static let maxEvents = 50

    struct Fix: Codable, Equatable {
        var id: String
        var source: LocationFixSource
        var raw: LocationRawFix
        var area: LocationArea?

        init(_ record: LocationFixRecord) {
            id = record.id
            source = record.source
            raw = record.raw
            area = record.area
        }

        var record: LocationFixRecord { LocationFixRecord(id: id, source: source, raw: raw, area: area) }
    }

    var fix: Fix?
    var events: [LocationPlaceEvent] = []
    /// Whether the phone was last inside each saved place, so a monitor's
    /// first answer after launch isn't taken for an arrival.
    var inside: [String: Bool] = [:]

    var isEmpty: Bool { fix == nil && events.isEmpty }

    /// Keeps the newer fix and the newest events.
    mutating func keep(fix newFix: LocationFixRecord?, events newEvents: [LocationPlaceEvent]) {
        if let newFix, newFix.raw.timestamp >= (fix?.raw.timestamp ?? .distantPast) { fix = Fix(newFix) }
        var merged = events
        for event in newEvents where !merged.contains(where: { $0.id == event.id }) { merged.append(event) }
        merged.sort { $0.at < $1.at }
        events = Array(merged.suffix(Self.maxEvents))
    }

    /// Drops what was sent.
    mutating func remove(fixID: String?, eventIDs: Set<String>) {
        if let fixID, fix?.id == fixID { fix = nil }
        events.removeAll { eventIDs.contains($0.id) }
    }
}

/// Generic items in the App Group Keychain: readable after first unlock,
/// never synced or restored to another device.
enum LocationKeychain {
    static let service = "com.milim.relay.location"
    static let keyAccount = "location-key.v1"
    static let hostPassAccount = "location-host-pass.v1"

    static func loadKey() -> LocationCrypto.SessionKey? {
        load(account: keyAccount).flatMap { try? JSONDecoder().decode(LocationCrypto.SessionKey.self, from: $0) }
    }

    static func saveKey(_ key: LocationCrypto.SessionKey) {
        if let data = try? JSONEncoder().encode(key) { save(data, account: keyAccount) }
    }

    static func clearKey() { delete(account: keyAccount) }

    static func loadHostPass() -> LocationHostPass? {
        load(account: hostPassAccount).flatMap { try? JSONDecoder().decode(LocationHostPass.self, from: $0) }
    }

    static func saveHostPass(_ pass: LocationHostPass) {
        if let data = try? JSONEncoder().encode(pass) { save(data, account: hostPassAccount) }
    }

    static func clearHostPass() { delete(account: hostPassAccount) }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: NotificationE2E.appGroup,
        ]
    }

    private static func load(account: String) -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func save(_ data: Data, account: String) {
        let query = query(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
