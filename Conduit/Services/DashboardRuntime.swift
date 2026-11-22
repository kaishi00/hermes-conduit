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
    var botRosterRefreshFlight: AppState.BotRosterRefreshFlight?
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

    // MARK: Group rooms

    @Published var groupChatPhase: AppState.GroupChatPhase = .idle
    @Published var groupCapabilities: GroupCapabilities?
    @Published var groupRooms: [GroupRoom] = []
    /// The rooms this Hermes hosts with people you've linked that Group
    /// Chats lists until they start, and the people New Group Chat can
    /// invite (RoomDrafts.swift).
    @Published var linkedRoomDrafts: LinkedRoomDrafts?
    /// The rooms people you've linked invited this Hermes to, which Group
    /// Chats lists with the drafts (RoomInvites.swift).
    @Published var linkedRoomInvites: LinkedRoomInvites?
    /// Reads the invites again for a while after a Link is made
    /// (RoomInvites.swift followLinkedRoomInvites).
    var linkedRoomInviteFollow: Task<Void, Never>?
    /// What your agents' turns in rooms other people host wait for you to
    /// approve, which Group Chats lists first (RoomApprovals.swift).
    @Published var linkedRoomApprovals: LinkedRoomApprovals?
    /// The approvals answered here, by id: a read already under way when
    /// one was answered can't bring its row or card back.
    var answeredLinkedRoomApprovalIDs: Set<String> = []
    /// Bumped by a change made here to who and what Group Chats lists (a
    /// copy's delete, a Block, a leave or take out), so a copies,
    /// approvals, drafts or invites read it overtook is dropped: issued
    /// before the change, it could list what the change took away
    /// (issue 2347).
    var linkedRosterGeneration: Int = 0
    /// Your Hermes' copies of the rooms other people host that your agents
    /// joined, which Group Chats lists after your own (RoomCopies.swift).
    @Published var linkedRoomCopies: LinkedRoomCopies?
    /// The hosted rooms whose bots are talking now (each room's driver is
    /// working), read while Bots Home shows (`refreshTalkingRooms`), for
    /// its live-rooms row and the "In <room>" pills.
    @Published var talkingRoomIDs: Set<String> = []
    /// `groups.list` has answered since the group state was last cleared:
    /// until then the Bots list shows the rooms kept from its last answer on
    /// this dashboard (`shownGroupRooms`, #1533). Published so a room a
    /// launch waits on opens as soon as Hermes lists it (#1597).
    @Published var groupRoomsListed: Bool = false
    /// The last `groups.list` answer was its last page: only then does a
    /// room missing from `groupRooms` prove it's gone.
    var groupRoomsComplete: Bool = false
    var keptGroupRoomsMemo: (key: String, rooms: KeptGroupRooms?)?
    /// Hermes Desktop's group chats, read from its ui_meta projection on the
    /// `default` profile (refreshed with the bot roster). Read-only here:
    /// Desktop drives their rounds, and `groups.*` cannot address them.
    @Published var desktopGroupChats: [DesktopGroupChat] = []
    /// Hosted rooms' custom pictures (JPEG/PNG bytes) and the plugin's
    /// revision of each, keyed by room id (`GroupRoomPictures`).
    @Published var groupRoomPictureData: [String: Data] = [:]
    var groupRoomPictureRevisions: [String: String] = [:]
    /// Moves on each time a room's picture is set or removed here, so a
    /// slower refresh or an older change can't undo a newer one. Never
    /// reset: a reset could make a change look as if it never happened.
    var groupRoomPictureGenerations: [String: Int] = [:]
    /// How many set or remove requests are still on their way for each
    /// room; a room drops out once all of them have settled.
    var groupRoomPicturesChanging: [String: Int] = [:]
    /// Boards replies name by line, by id, once read (LineBoards).
    @Published var lineBoards: [String: RichBoard] = [:]
    /// Boards replies name that the plugin no longer has (pruned: the
    /// newest 500, a month), or answered in a shape Conduit can't draw:
    /// not asked for again, and the reply says one was there.
    @Published var lineBoardsGone: Set<String> = []
    var lineBoardsAsked: Set<String> = []
    /// The dashboard and profile `lineBoards` were read from.
    var lineBoardsScope: String = ""
    /// Bumped whenever `lineBoards` is forgotten, so a read from before
    /// stores nothing (issue 2083).
    var lineBoardsGeneration: Int = 0
    /// How each room over Links on Bots Home looks, by dashboard and room
    /// (RoomLooks.swift), for its tile's faces.
    @Published var homeRoomLooksByKey: [String: RoomLooks] = [:]
    var homeRoomLooksReadAt: [String: Date] = [:]
    /// What was last given each dashboard's Hermes (`PUT /rooms/looks`).
    var sharedRoomLooks: [UUID: String] = [:]
    /// The Group Chats probe asked again after a transient failure, so its
    /// notice clears on its own once Hermes answers (Eric 2026-11-04: it
    /// stayed after a reconnect the app never saw as a disconnect).
    var groupChatProbeRetry: TransientReadRetry = TransientReadRetry()
    /// The same for the bot roster's "Could not refresh bots".
    var botRosterRetry: TransientReadRetry = TransientReadRetry()
    /// Each room's reads in a row that failed.
    var talkingRoomMisses: [String: Int] = [:]
    /// A talking-rooms read is running.
    var talkingRoomsReading: Bool = false
    /// When the last talking-rooms read began.
    var talkingRoomsReadAt: Date?

    // MARK: Chat list reads, their partners

    /// The full catalog read under way, for a read asked for meanwhile to
    /// join rather than send its own (CatalogReadInFlight).
    var catalogReadInFlight: AppState.CatalogReadInFlight?
    /// The chat list's newest page going out, for a newest-page read asked
    /// for meanwhile to take its answer rather than send the same requests
    /// (NewestCatalogPageRead, issue 2604).
    var newestCatalogPageRead: AppState.NewestCatalogPageRead?
    /// Whether the listing that holds `sessionListListedTicket` took its
    /// cron rows from the catalog cache: a gateway listing fills none, so a
    /// later relist from the cache doesn't replace its rows (issue 2763).
    var sessionListListedCronFromCache: Bool = false
    // MARK: Live status, Pulse, gateway and plugin slots, models, voice tags

    /// The latest `session.active_list` snapshot and the profile it belongs
    /// to (#454).
    @Published var liveSessionStatusIndex: SessionLiveStatusIndex = SessionLiveStatusIndex()
    /// The one `session.active_list` read that settles a turn whose chat
    /// was just seen absent, whether or not the chat list (and its poll) is
    /// on screen.
    var liveTurnRegistryRecheck: Task<Void, Never>?
    var liveSessionStatusProfile: String?
    /// False once the gateway turned `session.active_list` down, so the chat
    /// list hides the Working and Needs input chips instead of showing a 0 it
    /// can't know. A successful poll turns it back on.
    @Published var liveSessionStatusAvailable: Bool = true
    /// What the user has and hasn't seen, per conversation (#454).
    @Published var chatReadState: ChatReadState = ChatReadState()
    /// The host the Desktop views below came from, when each profile was
    /// last asked, and the newest settled time it reported.
    var desktopViewsHost: String?
    var desktopViewsFailureLogged: Bool = false
    var desktopViewsFetchedAt: [String: Date] = [:]
    var desktopViewsCursor: [String: TimeInterval] = [:]
    /// The Bot Chats left this run, by dashboard and bot (`keepBotChatCopy`).
    var keptBotChatCopies: [String: AppState.KeptBotChatCopy] = [:]
    /// The last chats left after Load earlier brought in older rows, newest
    /// last (`keepLeftBackfilledTranscript`).
    var leftBackfilledTranscripts: [AppState.LeftBackfilledTranscript] = []
    /// When a Pulse feed read last landed, and for which dashboard
    /// (PulseFeed.swift).
    var pulseFeedAppliedAt: (dashboard: UUID?, at: Date)?
    /// The Pulse screen (PulseFeed.swift): its unseen cards for the
    /// button's badge, the chats' messages that have a card (chat id, then
    /// Hermes' message id, to card id), a request to show it, and Pulse's
    /// own chat, which the screen stands in for.
    @Published var pulseUnseen: Int = 0
    @Published var pulseSources: [String: [Int: Int]] = [:]
    @Published var pulseHomeChatID: String?
    @Published var runtime: RuntimeState = RuntimeState()
    @Published var gatewayDiagnostics: GatewayDiagnostics?
    @Published var gatewayDiagnosticsLoading: Bool = false
    /// Restart Gateway's progress and outcome, and the dashboard it belongs
    /// to (AppState+GatewayRestart.swift).
    @Published var gatewayRestart: GatewayRestartSlot = GatewayRestartSlot()
    var gatewayRestartTask: Task<Void, Never>?
    /// Update Hermes in Settings > Connection, and the dashboard it belongs
    /// to (AppState+HermesUpdate.swift).
    @Published var hermesUpdate: HermesUpdateState = .idle
    var hermesUpdateDashboardID: UUID?
    var hermesUpdateTask: Task<Void, Never>?
    /// Why the last Restart now failed, kept here so a wait view opened
    /// after it finished still shows it.
    @Published var gatewayRestartNowFailure: GatewayRestartNow.Failure?
    /// The Conduit plugin update's progress and outcome, and the dashboard
    /// it belongs to (AppState+NotifierPluginUpdate.swift).
    @Published var notifierPluginUpdate: NotifierPluginUpdateSlot = NotifierPluginUpdateSlot()
    var notifierPluginUpdateTask: Task<Void, Never>?
    /// Bumped per plugin status request; the accepted one is the newest
    /// request whose answer landed, so an older answer never lands over a
    /// newer one, but still lands when a newer request failed.
    var notifierPluginStatusGeneration: Int = 0
    var notifierPluginStatusAcceptedGeneration: Int = 0
    @Published var modelVisibility: ModelVisibility = ModelVisibility()
    /// The model sheet's pinned and recent models, for the active dashboard.
    @Published var modelQuickPicks: ModelQuickPicks = ModelQuickPicks()
    @Published var slashCommands: [SlashCommand] = AppState.builtInSlashCommands
    /// Hermes' argument words for each command (`commands.catalog` `sub`),
    /// by command name: `fast` → normal, fast, ultrafast, …
    @Published var slashSubcommands: [String: [String]] = AppState.conduitSlashSubcommands
    var lastSlashCatalogPayload: AnyCodable?
    /// Whether Hermes can generate pictures, as last asked
    /// (`refreshPictureGeneration`).
    @Published var canGeneratePictures: Bool = false
    var keptBotRosterMemo: (key: String, roster: KeptBotRoster?)?
    /// A failed sign-in refresh or ticket kept quiet during those retries,
    /// shown once they have failed, by the next ticket or by a readiness
    /// probe the gateway doesn't answer (#1624).
    var quietReconnectFailure: Error?
    /// Renewals that have failed quietly since the last one worked. Counted
    /// apart from the backoff's attempts, which a network change resets, so
    /// a link that keeps changing still surfaces the failure.
    var quietRenewalFailures: Int = 0
    /// A Reconnect someone asked for (the button, Settings, a gateway
    /// restart) shows its failure at once, as before #1624: it is an
    /// answer they are waiting for, not a resume.
    var surfacesRenewalFailureAtOnce: Bool = false
    /// See `roomFilePicturesResolver` (GroupRoomFiles.swift).
    var cachedRoomFilesResolver: GatewayMediaDataURLResolver?
    /// "host|profile" whose Hermes answered 404 for the mutation snapshot
    /// (older than the route): its writes skip the read until a write is
    /// refused for missing identity, which clears the mark.
    var hostsWithoutMutationSnapshot: Set<String> = []
    /// Voice tags from the Hermes host, keyed by `voiceHistoryKey`, then by
    /// session id.
    @Published var voiceSessionTagsByKey: [String: [String: VoiceSessionTag]] = [:]
    var voiceTagsFetchedAt: [String: Date] = [:]
    var voiceTagRefreshTask: Task<Void, Never>?
    /// Files sessions under Voice or Voice Jobs, here at once and on the
    /// host for every device.
    var voiceTagChain: Task<Void, Never>?
    var voiceTagGeneration: Int = 0

    // MARK: Group rooms, their in-flight flags

    /// A drafts read asked for with the people that hasn't run yet.
    var linkedRoomDraftsPeopleAsked: Bool = false
    /// A looks share is on its way, and another change waits for it.
    var roomLooksSharing: Bool = false
    var roomLooksShareAgain: Bool = false

    // MARK: Kept through a switch away

    /// The profile its kept lists were read on (`init(keepingListsOf:profile:)`).
    var keptListsProfile: String?

    /// `notifierPlugin`: what it starts from before its plugin answers (the
    /// saved Update notices choice).
    init(notifierPlugin: NotifierPluginStatus = NotifierPluginStatus()) {
        self.notifierPlugin = notifierPlugin
    }

    /// What a combined dashboard switched away from keeps of the runtime on
    /// screen, read before the switch clears it: its bots, chat list, group
    /// rooms, live status, Pulse marks, plugin status and commands. A switch
    /// back shows them at once, while its sync reads them again
    /// (`AppState.showKeptLists(of:)`).
    convenience init(keepingListsOf shown: DashboardRuntime, profile: String) {
        self.init(notifierPlugin: shown.notifierPlugin)
        copyKeptLists(from: shown)
        botModePhase = shown.botModePhase
        botRoster = shown.botRoster
        sessions = shown.sessions
        keptListsProfile = profile
    }

    /// The kept lists that AppState's forwarders take no action on, so
    /// they copy straight across. `botModePhase`, `botRoster`, `sessions`
    /// and `notifierPlugin` are kept too, but a switch back sets those
    /// through the forwarders, which act on a change.
    func copyKeptLists(from other: DashboardRuntime) {
        profiles = other.profiles
        botRosterSupportsProtocol = other.botRosterSupportsProtocol
        botChatSessionProfiles = other.botChatSessionProfiles
        botChatSessionLabels = other.botChatSessionLabels
        botAvatarImages = other.botAvatarImages
        groupChatPhase = other.groupChatPhase
        groupCapabilities = other.groupCapabilities
        groupRooms = other.groupRooms
        groupRoomsListed = other.groupRoomsListed
        groupRoomsComplete = other.groupRoomsComplete
        desktopGroupChats = other.desktopGroupChats
        groupRoomPictureData = other.groupRoomPictureData
        groupRoomPictureRevisions = other.groupRoomPictureRevisions
        linkedRoomCopies = other.linkedRoomCopies
        linkedRoomDrafts = other.linkedRoomDrafts
        linkedRoomInvites = other.linkedRoomInvites
        linkedRoomApprovals = other.linkedRoomApprovals
        talkingRoomIDs = other.talkingRoomIDs
        liveSessionStatusIndex = other.liveSessionStatusIndex
        liveSessionStatusProfile = other.liveSessionStatusProfile
        liveSessionStatusAvailable = other.liveSessionStatusAvailable
        pulseUnseen = other.pulseUnseen
        pulseSources = other.pulseSources
        pulseHomeChatID = other.pulseHomeChatID
        slashCommands = other.slashCommands
        slashSubcommands = other.slashSubcommands
        lastSlashCatalogPayload = other.lastSlashCatalogPayload
        canGeneratePictures = other.canGeneratePictures
    }
}
