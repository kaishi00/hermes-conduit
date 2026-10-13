import Foundation

/// Pins shared with Hermes (#555).
///
/// Hermes keeps a durable `pinned` flag per conversation (`sessions.pinned`,
/// lineage-wide), reports it on dashboard session rows and takes it through
/// `PATCH /api/sessions/{id}`. Hermes Desktop pins with the same flag. Hosts
/// older than the flag report nothing, and Conduit's pins stay on the phone
/// there, as before.
///
/// Conduit's own pin list stays the one the chat list reads, and keeps its
/// order: a listing that carries the flag reconciles it. The first time a host
/// reports the flag for a profile, pins that live only on this phone are sent
/// up rather than dropped; once every one of them is on the host, the host's
/// flag decides ("adopted"), so a pin or unpin on Desktop shows here too.
struct SessionPinSync: Equatable {
    /// A pin value Conduit just wrote. A listing fetched before the write
    /// landed would otherwise repaint the old value.
    struct PendingWrite: Equatable {
        var pinned: Bool
        var writtenAt: Date
        /// Orders writes for one conversation: only the latest one's failure
        /// may change state.
        var generation: UInt64
    }

    /// A phone-only pin to send to the host.
    struct Upload: Equatable {
        /// The id the pin is stored under.
        var pinID: String
        /// The id to write to: the listed row's own id, like read-state
        /// writes; an unlisted pin has only its stored id.
        var hostID: String
    }

    struct Reconciliation: Equatable {
        /// The profile's pin list after the listing.
        var pins: [String]
        /// Phone-only pins to send to the host before it is adopted, listed
        /// or not.
        var uploads: [Upload]
    }

    /// How long a written value outranks listings that disagree with it. A
    /// failed upload keeps its value until then too, so it isn't re-sent on
    /// every listing.
    static let pendingWriteLifetime: TimeInterval = 30

    /// The dashboard host the runtime state below describes.
    private(set) var host: String?
    /// Profiles whose listing from `host` carried the flag.
    private(set) var supportedProfiles: Set<String> = []
    /// "host\u{1F}profile" pairs whose pins the host owns (persisted).
    private(set) var adopted: Set<String>
    /// "profile\u{1F}pin id" → value Conduit wrote to the host.
    private(set) var pendingWrites: [String: PendingWrite] = [:]
    /// profile → pin ids the host took from this phone's uploads. Covers
    /// pins the listing doesn't show (an old chat past the first page).
    private(set) var uploaded: [String: Set<String>] = [:]
    private var writeGeneration: UInt64 = 0

    init(adopted: Set<String> = []) {
        self.adopted = adopted
    }

    /// The id a pin is stored under: the compression lineage root, so
    /// compression's id rotation keeps the pin.
    static func pinID(for session: SessionSummary) -> String {
        if let root = session.lineageRootId?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            return root
        }
        return session.id
    }

    /// Every id a pin for this conversation may be stored under.
    static func pinIDs(for session: SessionSummary) -> Set<String> {
        Set([pinID(for: session), session.id] + session.alternateIds)
    }

    private static func key(_ first: String, _ second: String) -> String {
        "\(first)\u{1F}\(second)"
    }

    /// Another host's flags and writes never apply to this one's chats.
    mutating func setHost(_ host: String?) {
        guard host != self.host else { return }
        self.host = host
        supportedProfiles = []
        pendingWrites = [:]
        uploaded = [:]
    }

    /// Whether a pin change for `profile` should be written to the host.
    func supportsPins(profile: String, host: String?) -> Bool {
        host != nil && host == self.host && supportedProfiles.contains(profile)
    }

    func isAdopted(profile: String) -> Bool {
        guard let host else { return false }
        return adopted.contains(Self.key(host, profile))
    }

    /// Folds a fresh listing from `host` into the profile's pins. Only rows
    /// fetched just now belong here: a cached row's flag may predate a change
    /// made since.
    mutating func reconcile(
        pins: [String],
        listed: [SessionSummary],
        profile: String,
        now: Date = Date()
    ) -> Reconciliation {
        pendingWrites = pendingWrites.filter {
            now.timeIntervalSince($0.value.writtenAt) < Self.pendingWriteLifetime
        }
        let reported = listed.filter { $0.isPinned != nil }
        guard let host, !reported.isEmpty else { return Reconciliation(pins: pins, uploads: []) }
        supportedProfiles.insert(profile)
        let wasAdopted = adopted.contains(Self.key(host, profile))
        let sent = uploaded[profile] ?? []

        var pins = pins
        var uploads: [Upload] = []
        var handled = Set<String>()
        var listedIDs = Set<String>()
        for session in reported {
            let id = Self.pinID(for: session)
            let ids = Self.pinIDs(for: session)
            listedIDs.formUnion(ids)
            guard handled.insert(id).inserted else { continue }
            let local = pins.contains { ids.contains($0) }
            let hostPinned = session.isPinned == true
            let writeKey = Self.key(profile, id)
            if let pending = pendingWrites[writeKey] {
                // Until the host shows the written value, the phone's
                // value stands.
                guard pending.pinned == hostPinned else { continue }
                pendingWrites[writeKey] = nil
            }
            if local == hostPinned { continue }
            if hostPinned {
                pins.append(id)
            } else if wasAdopted {
                pins.removeAll { ids.contains($0) }
            } else if !sent.contains(id) {
                uploads.append(Upload(pinID: id, hostID: session.id))
            }
        }

        if !wasAdopted {
            // Pins on chats this listing doesn't show go up too, so adopting
            // the host can't drop them when they show up later.
            for id in pins where !listedIDs.contains(id) && !sent.contains(id)
                && pendingWrites[Self.key(profile, id)] == nil && !uploads.contains(where: { $0.pinID == id }) {
                uploads.append(Upload(pinID: id, hostID: id))
            }
            let profilePrefix = Self.key(profile, "")
            let writesInFlight = pendingWrites.keys.contains { $0.hasPrefix(profilePrefix) }
            if uploads.isEmpty && !writesInFlight {
                adopted.insert(Self.key(host, profile))
                uploaded[profile] = nil
            }
        }
        return Reconciliation(pins: pins, uploads: uploads)
    }

    /// Records a write about to be sent and returns its generation.
    @discardableResult
    mutating func recordWrite(pinID: String, profile: String, pinned: Bool, at date: Date = Date()) -> UInt64 {
        writeGeneration &+= 1
        pendingWrites[Self.key(profile, pinID)] = PendingWrite(
            pinned: pinned,
            writtenAt: date,
            generation: writeGeneration
        )
        return writeGeneration
    }

    /// The host took an upload. Its pending value stays until a listing
    /// shows it or it lapses, so a listing fetched before it landed can't
    /// let the host's old value win.
    mutating func uploadSucceeded(pinID: String, profile: String) {
        uploaded[profile, default: []].insert(pinID)
    }

    /// A write that failed no longer speaks for the row. Returns false when
    /// a newer write has replaced it since, which then decides.
    @discardableResult
    mutating func discardWrite(pinID: String, profile: String, generation: UInt64) -> Bool {
        let writeKey = Self.key(profile, pinID)
        guard pendingWrites[writeKey]?.generation == generation else { return false }
        pendingWrites[writeKey] = nil
        return true
    }

    /// Forgets a deleted profile, so one re-created under its name starts
    /// over on every host.
    mutating func forget(profile: String) {
        supportedProfiles.remove(profile)
        adopted = adopted.filter { !$0.hasSuffix(Self.key("", profile)) }
        uploaded[profile] = nil
        let profilePrefix = Self.key(profile, "")
        pendingWrites = pendingWrites.filter { !$0.key.hasPrefix(profilePrefix) }
    }

    /// Forgets which hosts own pins, as when the phone's pins are cleared.
    mutating func reset() {
        supportedProfiles = []
        adopted = []
        pendingWrites = [:]
        uploaded = [:]
    }
}
