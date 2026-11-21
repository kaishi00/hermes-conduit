//
//  DashboardRuntime.swift
//  Conduit
//
//  One dashboard's live state: its connection first (the client, the
//  bridge, whether it's connected, what its plugin serves), then the rest of
//  the cut list's instance rows, a slice at a time (the plan: "Dropping the
//  dashboard switch", /mnt/project-files/all-live/no-switch-plan.md).
//

import Combine
import Foundation
import UIKit

/// One dashboard's live state.
///
/// As with `ChatState` in stage 1, there is still one, `AppState`'s
/// `runtimeOnScreen`, refilled by a switch as AppState's own properties
/// were. Views and extensions read it through AppState's forwarders, and
/// AppState publishes its changes as its own. Once each combined dashboard
/// keeps one of its own, a switch inside the group shows another runtime
/// instead of tearing this one down and syncing the next.
///
/// Only the dashboard's own state moves here. What reacts to a change on
/// screen (the widget launch, the composer's pending send, the Watch's
/// shared context) stays in AppState's forwarding setters.
@MainActor
final class DashboardRuntime: ObservableObject {

    // MARK: Connection

    @Published var connection: HermesConnection?
    @Published var client: HermesClient?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var dashboardTicketBridge: DashboardTicketBridge?
    /// Moves on with each client, so callbacks queued by an earlier one
    /// are dropped.
    var clientEpoch = UUID()
    var connectedAt: Date?

    // MARK: Plugin

    /// What the host's notifier plugin serves.
    @Published var notifierPlugin: NotifierPluginStatus

    // MARK: Bots and chat lists

    @Published var profiles: [String] = []
    /// The Chats list's All view, per dashboard (`AllProfilesChatsSettings`).
    @Published var allProfilesChatsSettings: AllProfilesChatsSettings = AllProfilesChatsSettings()
    /// Every profile's chats for All, read in one request.
    @Published var allProfilesCatalog: AllProfilesCatalog = AllProfilesCatalog()
    var allProfilesCatalogTask: Task<Void, Never>?
    /// Which read `allProfilesCatalogTask` is, so only it clears the handle.
    var allProfilesCatalogRead: UUID?
    @Published var isRefreshingBotRoster: Bool = false
    /// The running photo sync; each roster read queues the next behind it.
    var profileAvatarSyncTask: Task<Void, Never>?
    /// `profiles.list` `bot_mode_protocol`: the backend teaches bots the
    /// teammate-messaging protocol itself, so a new bot's SOUL stays
    /// identity-only.
    var botRosterSupportsProtocol: Bool = false
    /// Bumped at every server-identity boundary; responses captured under an
    /// older epoch are dropped, so a stale async roster can never overwrite
    /// the state of a different dashboard/profile.
    var botRosterEpoch: Int = 0
    /// Ownership token for the in-flight roster refresh: only the refresh
    /// that captured the CURRENT token may release the single-flight flag,
    /// so no superseded refresh can clear a newer one's claim and no
    /// identity change can strand the flag.
    var botRosterRefreshToken: UUID?
    var botRosterRefreshFlight: BotRosterRefreshFlight?
    /// Bot chats belong to the BOT's profile, not the dashboard's. Every
    /// re-resume of an open bot chat (reconnect, refresh, preserve-current
    /// sync) consults this in-memory registry to scope the resume RPC; it is
    /// never persisted — a canonical Bot Chat has no client-side pointer.
    /// Bot profile ownership per canonical-chat session id (runtime id,
    /// stored id, and every adopted alias). Superseded runtime ids are
    /// deliberately KEPT, never pruned on resume/compression rebinding:
    /// late lifecycle, stream, and compaction events may still arrive
    /// addressed to an old runtime id and must keep resolving to the right
    /// bot profile — dropping the alias would misroute those events into
    /// the ordinary dashboard scope. The map is runtime-only (cleared at
    /// the server-identity boundary in `invalidateBotModeState`) and grows
    /// by one entry per rebound id, which is bounded by how often a bot
    /// chat's runtime id is actually rebound. If a provably-dead alias
    /// lifecycle point ever exists upstream (e.g. an explicit
    /// session-destroyed event), a bounded cleanup could hook there —
    /// none exists today, so correctness wins over the small dictionary.
    var botChatSessionProfiles: [String: String] = [:]
    /// The bot's display label per canonical-chat session id — the title a
    /// restored Bot Chat presents. Runtime-only like the registry above (same
    /// lifetime: entries are kept until the server-identity boundary, with no
    /// per-session eviction, because a late lifecycle event can still arrive
    /// addressed to an id that is no longer live), and
    /// persisted into a `SessionReference`'s `botLabel` when the conversation
    /// becomes the workspace's last-selected one, so a cold launch can show
    /// the bot's name before the roster has loaded.
    var botChatSessionLabels: [String: String] = [:]
    /// Every id the client can POSITIVELY attribute to Bot Mode right now: the
    /// roster's canonical registry (id + lineage tip) and the runtime
    /// registry. Restoration and sessions-list hygiene both read this instead
    /// of re-deriving the rule, so they can never disagree about whether an id
    /// belongs to a bot's forever chat.
    /// Derived once per evidence change. Both of its sources are cold paths
    /// (a roster refresh, a bot-chat open), while its readers are hot: the
    /// sidebar projection runs on render and `presentationProfile(for:)` runs
    /// on every stream/tool/approval event, and the registry keeps aliases for
    /// the process lifetime — so rebuilding the value per read would scan a
    /// growing roster on the event path.
    var cachedBotOwnership: (generation: Int, ownership: SessionBotOwnership)?
    var botOwnershipGeneration: Int = 0
    /// Whether the roster on hand was verified since the CURRENT connection
    /// began. Cleared whenever a connection (or reconnect) is established, so
    /// absence evidence can never outlive the socket that produced it.
    var botRosterVerifiedForCurrentConnection: Bool = false
    var sessionCatalogCache: SessionCatalogCache = SessionCatalogCache()
    /// Counts catalog reads as they start, so the slow read a chat sync left
    /// for later can tell that a newer read began while it was paging.
    var catalogReadSequence: UInt64 = 0
    /// Ticket for each read that replaces the published list wholesale
    /// (`loadSessions` and a chat sync), taken when the read starts, and
    /// the newest ticket whose answer is listed. Reads overlap (a reconnect,
    /// a return to the list, a pull to refresh), and an older answer that
    /// lands after a newer one would put back a list from before it (#786).
    var sessionListReadTicket: UInt64 = 0
    var sessionListListedTicket: UInt64 = 0
    /// The catalog read that returning to the list starts, and whether
    /// another return asked for one while it ran.
    var leaveCatalogRefreshTask: Task<Void, Never>?
    var leaveCatalogRefreshPending: Bool = false
    var leaveCatalogRefreshReportsFailure: Bool = false
    /// The coalesced read serves a `sessions.changed`: if it fails, the
    /// change stays pending (issue 2294).
    var leaveCatalogRefreshReadsChange: Bool = false
    /// One chat on two devices (ChatSync.swift): when the list reads the
    /// catalog on its own, the open chat's registry checks, and the newest
    /// `session.active_list` snapshot they share, so the open chat reuses
    /// the list's poll instead of asking again.
    var chatListCatalogFreshness: ChatListCatalogFreshness = ChatListCatalogFreshness()
    /// The Chats list's poll pace, the sleep a return to the app or a tap
    /// cuts short, and a count of catalog reads that changed the list.
    var chatListPollPacer: ChatListPollPacer = ChatListPollPacer()
    /// The chat New Chat (or a project's new chat) just made here. Hermes
    /// lists a chat only once its first message is stored, so until then
    /// every catalog read would drop the row the create put in, and a list
    /// beside the open chat wouldn't show it (issue 1454). The lists keep
    /// it while it is the open chat and the catalog doesn't list it.
    @Published var newChatAwaitingListing: NewChatAwaitingListing?
    var isReadingNewestCatalogPage: Bool = false
    /// Backdrop glow colors picked in the profile picker (`#rrggbb`), for
    /// the selected dashboard.
    @Published var profileGlowPicks: [String: String] = [:]
    var profileAvatarRevision: Int = 0
    var profileGlowCache: (key: ProfileGlowCacheKey, colors: [String: ProfileGlowRGB])?
    /// Each photo's colors, kept while the photos stay the same, so a pick
    /// (a color drag sets one per tick) never samples the photos again.
    var profileGlowPalettes: (avatarRevision: Int, byURL: [URL: [ProfileGlowRGB]]) = (0, [:])
    /// Bot avatars from each profile's gateway asset store (the same pictures
    /// Hermes Desktop shows), keyed by profile name. Runtime-only, fenced by
    /// the roster epoch, cleared at the server-identity boundary.
    @Published var botAvatarImages: [String: UIImage] = [:]
    /// Bumped by an explicit roster reload so rows re-fetch their avatar
    /// (another client may have changed it; the roster carries no version).
    @Published var botAvatarGeneration: Int = 0
    /// When `reloadBotRoster` last asked for every picture again.
    var botAvatarsReloadedAt: Date?
    var botAvatarFetchedGeneration: [String: Int] = [:]
    /// Name to the generation its in-flight fetch serves, so a newer
    /// generation can start its own fetch instead of being deduped away.
    var botAvatarFetchInflight: [String: Int] = [:]
    /// Hermes' `sessions.changed` waiting for its catalog read, and the
    /// wait for one held back by the quiet-read wait (5 s, up to 60 s).
    var catalogChangeSignal: CatalogChangeSignal = CatalogChangeSignal()
    var catalogChangeReadTask: Task<Void, Never>?
    var latestActiveList: (rows: [LiveSessionStatus], profile: String, client: ObjectIdentifier, at: Date)?
    /// Dashboard and profile scopes whose plugin refused the history page
    /// route this run (`HistoryPage.isRefusedForScope`).
    var historyPageRefusedScopes: Set<String> = []
    /// Profile list reads sent, and the newest of them whose list (with
    /// names) was taken, so an older answer landing after it doesn't commit.
    var profileListReadsSent: UInt64 = 0
    var profileListReadCommitted: UInt64 = 0

    // MARK: Bots and chat lists, observed on screen

    /// Lifecycle of the Bot Mode capability probe. `profiles.list` is the
    /// capability call: a gateway old enough to lack the method has no
    /// Bot Mode, and the UI degrades to "requires a newer Hermes gateway"
    /// without blocking Sessions or anything else.
    @Published var botModePhase: BotModePhase = .idle
    /// The read-only roster, as Hermes last answered on this dashboard.
    /// Hermes remains authoritative: the copy the Bots list keeps to open on
    /// (`shownBotRoster`) only stands in until it answers, and nothing
    /// writes from that copy.
    @Published var botRoster: [BotProfile] = []
    @Published var sessions: [SessionSummary] = []
    /// Published so a project's page beside the open chat reads its own
    /// list again when the catalog changes (issue 1454). A change also
    /// wakes the list's poll from a long wait, so a turn that started or
    /// ended elsewhere (its messages move the catalog, which a gateway's
    /// `sessions.changed` reads at once) shows Running or stops without
    /// waiting out the backoff (issue 851).
    @Published var chatListCatalogGeneration: Int = 0
    /// Each profile's `display_name` set in Hermes, when it has one (#1046):
    /// "Coding Assistant" for `coding-agent`. Names only; routing keeps the
    /// profile id.
    @Published var profileHermesNames: [String: String] = [:]
    /// Each profile's bot title (`ui_meta['hermes-bots'].title`), the name
    /// Edit Bot, the Profiles sheet and Hermes Desktop rename it with. It
    /// wins over `display_name`, as on Desktop and in the bot's pushes.
    @Published var profileBotTitles: [String: String] = [:]
    /// Names given in the profile picker to profiles a gateway without bot
    /// looks can't name, for the selected dashboard.
    @Published var profileDeviceNames: [String: String] = [:]

    /// `notifierPlugin`: what it starts from before its plugin answers (the
    /// saved Update notices choice).
    init(notifierPlugin: NotifierPluginStatus = NotifierPluginStatus()) {
        self.notifierPlugin = notifierPlugin
    }
}
