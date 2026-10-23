//
//  SyncedPreferences.swift
//  Conduit
//
//  Preferences shared by every iPhone and iPad signed in to the same Hermes
//  profile (#1089), kept by the notifier plugin (`/conduit-prefs`, plugin
//  0.54+) rather than iCloud: the host already holds the rest of what these
//  devices share, and the user can move the set to another host.
//
//  Each preference is a slot: a host key, how to read the value on this
//  device and how to write one from the host. The plugin keeps a flat map of
//  key to JSON value and the later change wins, timed by the host. This
//  device uploads only what changed here since its last sync (a ledger per
//  dashboard and profile remembers what it had then), then takes the host's
//  value for everything else.
//
//  Never synced: passwords, sign-in sessions, Cloudflare tokens and custom
//  headers (Keychain, this device only), live voice provider consent, which
//  one pays for GPT-Live, the attachment size limit, and anything internal.
//

import Foundation
import UIKit

/// One preference this device shares with the host.
struct SyncedPreferenceSlot {
    enum Merge {
        /// The host's value replaces this device's.
        case replace
        /// A list of strings that only grows here: items another device
        /// added since the last sync are added, and an item removed
        /// elsewhere stays on this device. The host keeps whole lists, so an
        /// item removed here comes back if another device that still has
        /// it uploads its list.
        case addOnly
    }

    let key: String
    /// The value as JSON (Bool, number, String, array or object), or nil
    /// for Conduit's default.
    let read: () -> Any?
    /// Writes the host's value; nil goes back to the default.
    let write: (Any?) -> Void
    var merge: Merge = .replace
    /// False holds the host's value back for now (a call is running); the
    /// next sync tries again.
    var canApply: () -> Bool = { true }
}

extension SyncedPreferenceSlot {
    enum Kind { case bool, int, double, string, strings, json }

    /// A preference stored under one UserDefaults key.
    static func defaults(_ key: String, _ localKey: String, _ kind: Kind, in defaults: UserDefaults,
                         canApply: @escaping () -> Bool = { true }) -> SyncedPreferenceSlot {
        SyncedPreferenceSlot(
            key: key,
            read: {
                guard let stored = defaults.object(forKey: localKey) else { return nil }
                switch kind {
                case .bool: return stored as? Bool
                case .int: return (stored as? NSNumber)?.intValue
                case .double: return (stored as? NSNumber)?.doubleValue
                case .string: return stored as? String
                case .strings: return stored as? [String]
                case .json:
                    return (stored as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
                }
            },
            write: { value in
                let stored: Any?
                switch kind {
                case .bool: stored = value as? Bool
                case .int: stored = (value as? NSNumber)?.intValue
                case .double: stored = (value as? NSNumber)?.doubleValue
                case .string: stored = value as? String
                case .strings: stored = value as? [String]
                case .json:
                    stored = value.flatMap { JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil }
                }
                if let stored {
                    defaults.set(stored, forKey: localKey)
                } else {
                    defaults.removeObject(forKey: localKey)
                }
            },
            canApply: canApply
        )
    }
}

/// How a first sync with a host settles which side wins.
enum SyncedPreferencesStart: Equatable {
    /// The host's values win; this device fills in only what the host lacks.
    case useHost
    /// This device's values replace the host's (also "Copy this device's
    /// settings here").
    case useDevice
}

/// What this device had right after its last sync with one dashboard and
/// profile, by key, as canonical JSON. A key missing had Conduit's default.
struct SyncedPreferencesLedgerEntry: Codable, Equatable {
    var lastLocal: [String: String] = [:]
    var syncedAt: Date?
    /// Keys whose host value differed but was held back (a call was
    /// running): the controller syncs again once the call ends.
    var held: Set<String>?
}

enum SyncedPreferencesEngine {
    static let capability = "conduit-prefs"
    static let path = "/api/plugins/conduit_push/conduit-prefs"

    /// What to upload: everything that changed here since the last sync, or
    /// on a first sync what `start` says. NSNull clears a key on the host.
    static func changes(
        slots: [SyncedPreferenceSlot],
        ledger: SyncedPreferencesLedgerEntry?,
        host: [String: Any]?,
        start: SyncedPreferencesStart
    ) -> [String: Any] {
        var changes: [String: Any] = [:]
        for slot in slots {
            let value = slot.read()
            let local = canonical(value)
            if let ledger {
                guard local != ledger.lastLocal[slot.key] else { continue }
            } else if start == .useHost {
                // A first sync: only what the host doesn't have yet.
                guard local != nil, host?[slot.key] == nil else { continue }
            }
            changes[slot.key] = value ?? NSNull()
        }
        return changes
    }

    /// What every slot holds now, as canonical JSON, taken before a sync's
    /// request so `apply` can tell what changed while it was out.
    static func snapshot(_ slots: [SyncedPreferenceSlot]) -> [String: String] {
        var values: [String: String] = [:]
        for slot in slots {
            values[slot.key] = canonical(slot.read())
        }
        return values
    }

    /// Takes the host's values for every key this device didn't just
    /// upload, and returns the new ledger entry. A key changed here since
    /// `before` (while the request was out) keeps its new value and stays
    /// owed to the host: the ledger records what it was before, so the next
    /// sync uploads it.
    @discardableResult
    static func apply(
        host: [String: Any],
        slots: [SyncedPreferenceSlot],
        uploaded: Set<String>,
        ledger: SyncedPreferencesLedgerEntry?,
        before: [String: String]? = nil,
        now: Date = Date()
    ) -> SyncedPreferencesLedgerEntry {
        var entry = SyncedPreferencesLedgerEntry(syncedAt: now)
        for slot in slots {
            let current = canonical(slot.read())
            if let before, before[slot.key] != current {
                // Missing from the ledger when it had the default before.
                entry.lastLocal[slot.key] = before[slot.key]
                continue
            }
            if !uploaded.contains(slot.key), !slot.canApply() {
                if canonical(host[slot.key]) != current {
                    entry.held = (entry.held ?? []).union([slot.key])
                }
            } else if !uploaded.contains(slot.key) {
                let value = host[slot.key]
                switch slot.merge {
                case .replace:
                    if canonical(value) != current {
                        slot.write(value)
                    }
                case .addOnly:
                    let local = slot.read() as? [String] ?? []
                    let previous = ledger?.lastLocal[slot.key].flatMap(decoded) as? [String] ?? []
                    let added = (value as? [String] ?? []).filter { !previous.contains($0) && !local.contains($0) }
                    if !added.isEmpty {
                        slot.write(local + added)
                    }
                }
            }
            if let local = canonical(slot.read()) {
                entry.lastLocal[slot.key] = local
            }
        }
        return entry
    }

    /// The host's values out of a `/conduit-prefs` answer, by key; nil for
    /// an answer without them (not the plugin's), which must never read as
    /// a host that cleared everything.
    static func hostValues(_ response: [String: Any]) -> [String: Any]? {
        guard let values = response["values"] as? [String: Any] else { return nil }
        var kept: [String: Any] = [:]
        for (key, entry) in values {
            guard let entry = entry as? [String: Any], let value = entry["value"], !(value is NSNull) else { continue }
            kept[key] = value
        }
        return kept
    }

    /// One spelling per JSON value, so two reads of the same value compare
    /// equal; nil for nil.
    static func canonical(_ value: Any?) -> String? {
        guard let value, !(value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func decoded(_ canonical: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(canonical.utf8), options: [.fragmentsAllowed])
    }
}

/// The sync's state on this device: whether it's on, each host's ledger,
/// and what the Settings page shows.
@MainActor
final class SyncedPreferencesController: ObservableObject {
    static let enabledKey = "conduit.syncedPrefs.enabled.v1"
    static let ledgerKey = "conduit.syncedPrefs.ledger.v1"

    enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    @Published private(set) var isEnabled: Bool
    @Published var status: Status = .idle

    let defaults: UserDefaults
    /// A local change waits this long for others before it uploads.
    var debounce: Duration = .seconds(2)
    private var pendingUpload: Task<Void, Never>?
    private var heldRetry: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var syncing = false
    /// The round owed to a call that came while one was running; a copy
    /// of this device's settings wins over an ordinary sync.
    private var owed: SyncedPreferencesStart?
    private var uploadGeneration = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    deinit {
        // A block observer stays registered until removed.
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        pendingUpload?.cancel()
        heldRetry?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            pendingUpload?.cancel()
            pendingUpload = nil
            heldRetry?.cancel()
            heldRetry = nil
            status = .idle
        }
    }

    /// Starts a sync unless one is running; a call meanwhile gets one more
    /// round when it ends.
    func begin(_ start: SyncedPreferencesStart = .useHost) -> Bool {
        guard !syncing else {
            owed = owed == .useDevice ? .useDevice : start
            return false
        }
        syncing = true
        return true
    }

    /// Ends a sync; the start of the round owed, if one is.
    func end() -> SyncedPreferencesStart? {
        syncing = false
        defer { owed = nil }
        return owed
    }

    func ledger(for scope: String) -> SyncedPreferencesLedgerEntry? {
        guard let data = defaults.data(forKey: Self.ledgerKey),
              let ledgers = try? JSONDecoder().decode([String: SyncedPreferencesLedgerEntry].self, from: data) else {
            return nil
        }
        return ledgers[scope]
    }

    func setLedger(_ entry: SyncedPreferencesLedgerEntry?, for scope: String) {
        var ledgers = (defaults.data(forKey: Self.ledgerKey))
            .flatMap { try? JSONDecoder().decode([String: SyncedPreferencesLedgerEntry].self, from: $0) } ?? [:]
        ledgers[scope] = entry
        if let data = try? JSONEncoder().encode(ledgers) {
            defaults.set(data, forKey: Self.ledgerKey)
        }
    }

    /// Drops the ledgers of dashboards no longer saved.
    func keepLedgers(dashboardIDs: Set<String>) {
        guard let data = defaults.data(forKey: Self.ledgerKey),
              let ledgers = try? JSONDecoder().decode([String: SyncedPreferencesLedgerEntry].self, from: data) else { return }
        let kept = ledgers.filter { scope, _ in
            dashboardIDs.contains(String(scope.prefix { character in character != "|" }))
        }
        guard kept.count != ledgers.count, let encoded = try? JSONEncoder().encode(kept) else { return }
        defaults.set(encoded, forKey: Self.ledgerKey)
    }

    /// Runs `upload` a moment after the app's preferences change, so a
    /// change made on this device reaches the host without waiting for the
    /// next connect.
    func observeLocalChanges(_ upload: @escaping @MainActor () async -> Void) {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            // No object filter: which object posts it has varied by release.
            // No queue either: with `queue: .main` the posting thread waits
            // for the block on main, so a UserDefaults write off the main
            // thread blocked on it (and deadlocked a main thread waiting on
            // that writer, Nightly 2026-10-22). Hop over instead.
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Most writes are other keys: one check per interval, not
                    // a new task per write.
                    guard let self, self.isEnabled, self.pendingUpload == nil else { return }
                    let wait = self.debounce
                    self.uploadGeneration += 1
                    let generation = self.uploadGeneration
                    self.pendingUpload = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: wait)
                        guard let self else { return }
                        // A task cancelled while a newer one was scheduled leaves it be.
                        if self.uploadGeneration == generation { self.pendingUpload = nil }
                        guard !Task.isCancelled else { return }
                        await upload()
                    }
                }
            }
        }
    }

    /// Syncs again once `isHeld` reads false, for a host value held back
    /// while a call ran: nothing else is owed then, so no other trigger
    /// would bring it. Checks every `interval`; one wait at a time.
    func syncWhenReleased(interval: Duration = .seconds(15), isHeld: @escaping @MainActor () -> Bool,
                          _ sync: @escaping @MainActor () async -> Void) {
        guard heldRetry == nil else { return }
        heldRetry = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.isEnabled, !Task.isCancelled else { return }
                if !isHeld() {
                    self.heldRetry = nil
                    await sync()
                    return
                }
            }
        }
    }

    /// The name and id the host shows next to each value.
    static var deviceName: String { UIDevice.current.name }
}
