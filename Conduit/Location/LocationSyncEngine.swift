//
//  LocationSyncEngine.swift
//  Conduit
//
//  Talks to the notifier plugin's location routes for the profile sharing
//  is bound to: agrees the key (POST /location/key), sends sealed batches
//  (POST /location/ingest), and reads what Settings > Location shows
//  (status, the read log, place rules) or deletes (a rule, the host's copy).
//  The request closure decides the connection: the dashboard's own one, or
//  the host pass when Conduit runs in the background without it.
//

import CryptoKit
import Foundation
import OSLog

/// What the engine remembers between runs. No locations: the host's store
/// generation, what it last acknowledged, and why sending is paused.
struct LocationSyncState: Codable, Equatable {
    var generation: String?
    /// The saved places the host has, as LocationPrecisionRules.placesDigest.
    var placesDigest: String?
    var lastSent: Date?
    /// When the last fix reached the host, and why it was taken.
    var lastFixSent: Date?
    var lastFixSource: LocationFixSource?
    var lastAttempt: Date?
    var pause: LocationSyncPause?
}

/// Why sending stopped, in words Settings > Location shows.
enum LocationSyncPause: Codable, Equatable {
    case signInRequired
    case pluginMissing
    case refused(String)

    var message: String {
        switch self {
        case .signInRequired:
            return AppLocalization.string("Paused: sign in to this dashboard again. Location is sent again once you open Conduit.")
        case .pluginMissing:
            return AppLocalization.string("Paused: update the Conduit plugin on this host to share your location.")
        case .refused(let detail):
            return AppLocalization.string("Paused: the host refused location data (\(detail)).")
        }
    }
}

/// The host's answer to `/location/status`.
struct LocationHostStatus: Equatable {
    var stored: Bool
    var readsToday: Int
    var rules: Int
    var lastSync: String?
    var locateAvailable: Bool

    init(_ response: [String: Any]) {
        stored = response["stored"] as? Bool ?? false
        readsToday = response["reads_24h"] as? Int ?? 0
        rules = response["rules"] as? Int ?? 0
        lastSync = (response["device"] as? [String: Any])?["last_sync"] as? String
        locateAvailable = (response["locate"] as? [String: Any])?["available"] as? Bool ?? false
    }
}

/// One time the agent read the location (never the location itself).
struct LocationRead: Identifiable, Equatable {
    /// Keyed on the read itself so rows keep their identity when the host
    /// adds newer reads; `occurrence` keeps identical reads apart.
    var id: String { "\(at)|\(action)|\(sessionTitle ?? "")|\(platform ?? "")|\(occurrence)" }
    var occurrence: Int = 0
    var at: String
    var action: String
    var sessionTitle: String?
    var platform: String?

    var date: Date? { LocationHostDates.parse(at) }

    static func parse(_ response: [String: Any]) -> [LocationRead] {
        var seen: [String: Int] = [:]
        return (response["reads"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let at = entry["at"] as? String else { return nil }
            var read = LocationRead(at: at, action: entry["action"] as? String ?? "",
                                    sessionTitle: entry["session_title"] as? String, platform: entry["platform"] as? String)
            let base = read.id
            read.occurrence = seen[base, default: 0]
            seen[base, default: 0] += 1
            return read
        }
    }
}

/// A place rule the agent set up ("when I leave Home, Mon-Fri…").
struct LocationRule: Identifiable, Equatable {
    var id: String
    var what: String
    /// A saved place's id, or `*` for any saved place.
    var placeID: String?
    var placeName: String?
    /// `arrive`, `leave` or `either`.
    var event: String
    var days: String?
    var hours: String?
    var calls: Bool
    /// `daily` (once a day) or `every` (each time, at least 30 minutes apart).
    var repeatMode: String?
    var lastFired: String?

    var isAnySavedPlace: Bool { placeID == "*" }

    static func parse(_ response: [String: Any]) -> [LocationRule] {
        (response["rules"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return LocationRule(
                id: id,
                what: entry["what"] as? String ?? entry["task"] as? String ?? "",
                placeID: entry["place_id"] as? String,
                placeName: entry["place_name"] as? String,
                event: entry["event"] as? String ?? "",
                days: describe(entry["days"]),
                hours: describe(entry["hours"]),
                calls: entry["call"] as? Bool ?? false,
                repeatMode: entry["repeat"] as? String,
                lastFired: entry["last_fired"] as? String
            )
        }
    }

    /// Days and hours as the host wrote them: a string, or a list.
    private static func describe(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let list = value as? [Any], !list.isEmpty { return list.map { "\($0)" }.joined(separator: ", ") }
        return nil
    }
}

enum LocationHostDates {
    static func parse(_ value: String) -> Date? {
        plain.date(from: value) ?? (value.contains(".") ? withFraction.date(from: value) : nil)
    }

    // Built once: the read log parses a date per row.
    private static let plain = ISO8601DateFormatter()
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// The state file: Application Support, readable after first unlock,
/// excluded from backups.
struct LocationSyncStateStore {
    var url: URL

    static var standard: LocationSyncStateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return LocationSyncStateStore(url: base.appendingPathComponent("Location", isDirectory: true)
            .appendingPathComponent("state.json"))
    }

    func load() -> LocationSyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LocationSyncState.self, from: data) else { return LocationSyncState() }
        return state
    }

    func save(_ state: LocationSyncState) {
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ])
            do {
                try (folder as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
            } catch {
                Logger(subsystem: "com.milim.relay", category: "location")
                    .error("Location state folder backup exclusion failed: \(LogRedaction.message(error), privacy: .public)")
            }
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A locked phone: the next send writes it again.
        }
    }
}

/// The agreed key, in the App Group Keychain so the extension can use it.
struct LocationKeyStore {
    var load: () -> LocationCrypto.SessionKey?
    /// False when the key couldn't be stored (a Keychain error).
    var save: (LocationCrypto.SessionKey) -> Bool
    var clear: () -> Void

    static let keychain = LocationKeyStore(
        load: { LocationKeychain.loadKey() },
        save: { LocationKeychain.saveKey($0) },
        clear: { LocationKeychain.clearKey() }
    )

    static func memory() -> LocationKeyStore {
        final class Box { var key: LocationCrypto.SessionKey? }
        let box = Box()
        return LocationKeyStore(load: { box.key }, save: { box.key = $0; return true }, clear: { box.key = nil })
    }
}

enum LocationSyncEngineError: Error {
    /// POST /location/key answered 404: the plugin has no location sync.
    case keyRouteMissing
}

@MainActor
final class LocationSyncEngine: ObservableObject {
    typealias Request = (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    static let base = LocationHostClient.base
    static let log = Logger(subsystem: "com.milim.relay", category: "location")

    @Published private(set) var state: LocationSyncState
    @Published private(set) var lastError: String?

    private let store: LocationSyncStateStore
    let keys: LocationKeyStore
    /// A key agreed this run that the Keychain wouldn't store: used until
    /// Conduit quits, so a failing Keychain doesn't make every send agree a
    /// new key with the host. (The extension can't answer a locate then.)
    private var unsavedKey: LocationCrypto.SessionKey?
    /// Bumped by each new or forgotten key: the host drops the latest fix
    /// it had from this phone then, so a message's fix can't count on it.
    private(set) var keyAgreements = 0
    private let now: () -> Date
    private let deviceName: () -> String

    init(
        store: LocationSyncStateStore = .standard,
        keys: LocationKeyStore = .keychain,
        now: @escaping () -> Date = Date.init,
        deviceName: @escaping () -> String = { "iPhone" }
    ) {
        self.store = store
        self.keys = keys
        self.now = now
        self.deviceName = deviceName
        self.state = store.load()
    }

    // MARK: Sending

    /// Sends one batch, agreeing a key first if this phone has none the host
    /// knows, and again once if the host says it lost it. The saved places
    /// go along when the host's copy is out of date.
    enum SendOutcome: Equatable {
        case sent
        /// The host won't take this batch as it is: sending it again won't help.
        case refused
        /// Not sent now (no connection, signed out, a timeout, or a host
        /// whose plugin needs an update): the batch is kept to try later.
        case failed
    }

    @discardableResult
    func send(_ batch: LocationBatch, config: LocationSharedConfig, request: Request) async -> SendOutcome {
        var batch = batch
        state.lastAttempt = now()
        defer { store.save(state) }
        do {
            let voice = config.readsByVoice(at: now())
            // Maps requests reach this iPhone only through background sharing.
            let maps = config.settings.background
            var key = try await ensureKey(deviceID: config.deviceID, voice: voice, maps: maps, request: request)
            if state.placesDigest != LocationPrecisionRules.placesDigest(config.places) { batch.places = config.places }
            var answer: [String: Any]
            do {
                answer = try await post(batch, key: key, request: request)
            } catch DashboardTicketBridgeError.http(let status, let detail) where status == 409 && Self.needsNewKey(detail) {
                // unknown_key or bad_seal: the host forgot or replaced this
                // phone's key (a wipe, a new store). Agree a new one, once.
                Self.log.info("Location ingest answered 409 \(detail, privacy: .private); agreeing the key again")
                clearKey()
                key = try await ensureKey(deviceID: config.deviceID, voice: voice, maps: maps, request: request)
                batch.places = config.places
                answer = try await post(batch, key: key, request: request)
            }
            acknowledge(batch, answer: answer)
            return .sent
        } catch let error as DashboardTicketBridgeError {
            Self.log.info("Location send failed: \(LogRedaction.redactingURLs(Self.describe(error)), privacy: .public)")
            switch error {
            case .signInRequired:
                state.pause = .signInRequired
            case .http(let status, let detail) where status == 404:
                // A bare 404 could be a proxy or a restarting host. The key
                // is kept; the status route tells whether the plugin is gone.
                if await pluginIsMissing(deviceID: config.deviceID, request: request) {
                    Self.log.info("Location status answered 404 too: plugin missing")
                    state.pause = .pluginMissing
                } else {
                    lastError = detail
                }
            case .http(let status, let detail) where status == 409 && HostKeyConflict.isNewerPluginStore(detail):
                // A store written by a newer plugin: updating the plugin
                // fixes it. The batch stays to send after the update.
                state.pause = .pluginMissing
            case .http(let status, let detail) where status == 400 || status == 413:
                state.pause = .refused(detail)
                return .refused
            case .http(let status, let detail) where status == 409:
                // layer_off and the like: what the batch says doesn't match
                // what's shared. Nothing to retry.
                lastError = detail
                return .refused
            default:
                lastError = UserFacingError.message(for: error)
            }
            return .failed
        } catch LocationSyncEngineError.keyRouteMissing {
            // POST /location/key answered 404: the plugin has no location sync.
            Self.log.info("Location key route answered 404: plugin missing")
            state.pause = .pluginMissing
            return .failed
        } catch {
            lastError = UserFacingError.message(for: error)
            Self.log.info("Location send failed: \(LogRedaction.redactingURLs(Self.describe(error)), privacy: .public)")
            return .failed
        }
    }

    /// Whether GET /location/status answers 404 as well: then the plugin
    /// has no location sync. Any other answer (or none) is passing.
    private func pluginIsMissing(deviceID: String, request: Request) async -> Bool {
        do {
            _ = try await request(Self.statusPath(deviceID: deviceID), "GET", nil)
            return false
        } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
            return true
        } catch {
            return false
        }
    }

    /// `/status`, with the device id when the host would take it.
    nonisolated static func statusPath(deviceID: String) -> String {
        guard LocationIDs.isValidWireID(deviceID),
              let encoded = deviceID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#")))
        else { return "\(LocationHostClient.base)/status" }
        return "\(LocationHostClient.base)/status?device_id=\(encoded)"
    }

    /// The host's 409s that mean it has no usable key for this phone.
    nonisolated static func needsNewKey(_ detail: String) -> Bool {
        HostKeyConflict.isKeyLoss(detail)
    }

    private func post(_ batch: LocationBatch, key: LocationCrypto.SessionKey, request: Request) async throws -> [String: Any] {
        try await request("\(Self.base)/ingest", "POST", LocationIngest.body(batch, key: key))
    }

    private func acknowledged(_ update: (inout LocationSyncState) -> Void) {
        update(&state)
        store.save(state)
    }

    private func acknowledge(_ batch: LocationBatch, answer: [String: Any]) {
        let at = now()
        state.lastSent = at
        state.pause = nil
        lastError = nil
        if let places = batch.places { state.placesDigest = LocationPrecisionRules.placesDigest(places) }
        if let fix = batch.fix {
            state.lastFixSent = at
            state.lastFixSource = fix.source
        }
        if let generation = answer["generation"] as? String {
            // A new store on the host has none of the places.
            if let known = state.generation, known != generation, batch.places == nil { state.placesDigest = nil }
            state.generation = generation
        }
    }

    /// The agreed key, set up when the phone has none for this device. With
    /// `voice` (a live voice mode may read the location), a key agreed
    /// before voice reads existed is set up again, once: the host then drops
    /// the latest position it had from this phone, and the next fix
    /// replaces it. With `maps` (background sharing, through which the host
    /// asks this iPhone for maps lookups), a key agreed before maps existed
    /// is set up again the same way, once.
    private func ensureKey(deviceID: String, voice: Bool, maps: Bool, request: Request) async throws -> LocationCrypto.SessionKey {
        for key in [keys.load(), unsavedKey].compactMap({ $0 }) where key.deviceID == deviceID {
            if (!voice || key.readsByVoice) && (!maps || key.answersMaps) { return key }
        }
        let devicePrivate = Curve25519.KeyAgreement.PrivateKey()
        let answer: [String: Any]
        do {
            answer = try await request("\(Self.base)/key", "POST", [
                "device_id": deviceID,
                "device_name": deviceName(),
                "public_key": NotificationE2E.base64URL(devicePrivate.publicKey.rawRepresentation),
            ])
        } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
            throw LocationSyncEngineError.keyRouteMissing
        }
        guard let hostPublic = answer["host_public_key"] as? String, let kid = answer["kid"] as? String else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The host didn't return a location key."))
        }
        let key = try LocationCrypto.agree(devicePrivate: devicePrivate, deviceID: deviceID, hostPublicKey: hostPublic, kid: kid)
        try Task.checkCancellation()
        if keys.save(key) {
            unsavedKey = nil
        } else {
            Self.log.error("Couldn't store the location key in the Keychain; keeping it in memory for this run")
            unsavedKey = key
        }
        // The host has nothing from this key yet.
        state.placesDigest = nil
        keyAgreements += 1
        if let generation = answer["generation"] as? String { state.generation = generation }
        return key
    }

    /// This phone's agreed key, for a live voice call's read of its own
    /// location. Nil until a send has agreed a key that reads.
    func voiceReadKey(deviceID: String) -> LocationCrypto.SessionKey? {
        [keys.load(), unsavedKey].compactMap { $0 }.first { $0.deviceID == deviceID && $0.readsByVoice }
    }

    private func clearKey() {
        keys.clear()
        unsavedKey = nil
        keyAgreements += 1
    }

    // MARK: Reading and deleting

    func status(deviceID: String, request: Request) async throws -> LocationHostStatus {
        LocationHostStatus(try await request(Self.statusPath(deviceID: deviceID), "GET", nil))
    }

    func reads(request: Request) async throws -> [LocationRead] {
        LocationRead.parse(try await request("\(Self.base)/reads?limit=50", "GET", nil))
    }

    func rules(request: Request) async throws -> [LocationRule] {
        LocationRule.parse(try await request("\(Self.base)/rules", "GET", nil))
    }

    func deleteRule(_ id: String, request: Request) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        _ = try await request("\(Self.base)/rules/\(encoded)", "DELETE", nil)
    }

    /// Deletes this phone's location data on the host, or everything the
    /// profile has (all devices and place rules). The key goes too: the
    /// host forgets it.
    func wipe(deviceID: String, everything: Bool, request: Request) async throws {
        do {
            _ = try await request("\(Self.base)/wipe", "POST", everything ? ["all": true] : ["device_id": deviceID])
        } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
            // No location sync on this host any more: nothing left to delete.
        }
        forgetHost()
    }

    /// Sharing moved to another destination, or the host's copy was deleted.
    func forgetHost() {
        clearKey()
        state = LocationSyncState()
        store.save(state)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? DashboardTicketBridgeError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}
