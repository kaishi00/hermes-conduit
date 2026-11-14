import Foundation

/// What a conversation is doing right now, from the gateway's live registry
/// (`session.active_list`), for the chat list's Working / Needs input
/// filters (#454). Hermes Desktop builds its filters from the same rows.
enum SessionLiveStatus: Equatable {
    /// A turn is running.
    case working
    /// A clarify question or approval is waiting on the user.
    case needsInput
}

struct SessionLiveStatusIndex: Equatable {
    /// Every id a live row is known under (runtime and stored) → status.
    private(set) var statusByID: [String: SessionLiveStatus] = [:]
    /// Each busy row's ids and status, for a bot's counts on Bots Home.
    private(set) var busyRows: [BusyRow] = []
    /// Every row came from Hermes' session authority, which lists only the
    /// profile it was asked for, so the rows are that profile's. The legacy
    /// dashboard lists every profile's whichever is named: its rows still
    /// light chat rows by id, but can't be counted as one bot's.
    private(set) var isProfileScoped = false

    struct BusyRow: Equatable {
        let ids: Set<String>
        let status: SessionLiveStatus
    }

    init() {}

    /// Builds the index from one authoritative `session.active_list`
    /// snapshot. "starting" and "idle" rows are not busy (same rule as
    /// `LiveSessionStatus.isRunning`).
    init(rows: [LiveSessionStatus]) {
        isProfileScoped = rows.allSatisfy(\.isProfileScoped)
        for row in rows {
            let status: SessionLiveStatus
            switch row.status {
            case "waiting": status = .needsInput
            case "working": status = .working
            default: continue
            }
            let ids = Set([row.runtimeSessionId, row.storedSessionId].filter { !$0.isEmpty })
            for id in ids {
                // needs-input outranks working when two rows share an id.
                if statusByID[id] != .needsInput { statusByID[id] = status }
            }
            busyRows.append(BusyRow(ids: ids, status: status))
        }
    }

    /// How many live chats run and how many wait on the user, leaving out
    /// the chats `leavingOut` names (a bot's workstreams, which its own
    /// list counts). Nil when the rows can't be told to be one profile's.
    func counts(leavingOut: Set<String> = []) -> BotLiveChats? {
        guard isProfileScoped else { return nil }
        var counts = BotLiveChats()
        for row in busyRows where row.ids.isDisjoint(with: leavingOut) {
            switch row.status {
            case .working: counts.working += 1
            case .needsInput: counts.waiting += 1
            }
        }
        return counts
    }

    func status(for session: SessionSummary) -> SessionLiveStatus? {
        let ids = [session.id, session.storedSessionId, session.lineageRootId].compactMap { $0 } + session.alternateIds
        var found: SessionLiveStatus?
        for id in ids {
            switch statusByID[id] {
            case .needsInput?: return .needsInput
            case .working?: found = .working
            case nil: continue
            }
        }
        return found
    }
}

/// What a bot's chats are doing, from its profile's live registry and the
/// plugin's list of what waits on the user: its portrait on Bots Home says
/// it beside the bot's workstreams.
struct BotLiveChats: Equatable {
    /// Chats with a turn running.
    var working = 0
    /// Chats waiting on the user (an approval or a question).
    var waiting = 0
}

/// The live registries of the profiles other than the one in use that
/// something on screen shows (All, a project's page, Bots Home), each read
/// by name: Hermes' session authority lists only the profile it is asked
/// for, so the profile in use's read never had theirs.
struct OtherProfilesLiveStatus: Equatable {
    /// The connection the reads went through: another one's are stale.
    private(set) var client: ObjectIdentifier?
    private var indexes: [String: SessionLiveStatusIndex] = [:]

    init() {}

    static func key(_ profile: String) -> String {
        profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func index(for profile: String, client: ObjectIdentifier?) -> SessionLiveStatusIndex? {
        guard client != nil, client == self.client else { return nil }
        return indexes[Self.key(profile)]
    }

    /// A profile's registry as just read through `client`. A new
    /// connection's first read drops every other one's.
    mutating func set(_ index: SessionLiveStatusIndex, for profile: String, client: ObjectIdentifier) {
        if client != self.client {
            self.client = client
            indexes = [:]
        }
        indexes[Self.key(profile)] = index
    }

    /// Only these profiles stay: nothing on screen shows the others.
    mutating func keep(_ profiles: [String]) {
        let kept = Set(profiles.map(Self.key))
        indexes = indexes.filter { kept.contains($0.key) }
    }
}
