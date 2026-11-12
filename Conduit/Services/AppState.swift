//
//  AppState.swift
//  Conduit
//
//  The session snapshot returned by Hermes is the source of truth for a turn.
//  Stream events enrich that snapshot, but never replace it with a guess after
//  foregrounding, reconnecting, or launching the app again.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

let sessionCatalogLog = Logger(subsystem: "com.milim.relay", category: "SessionCatalog")
let titleGenerationLog = Logger(subsystem: "com.milim.relay", category: "TitleGeneration")
let sessionYoloLog = Logger(subsystem: "com.milim.relay", category: "SessionYolo")
/// Foreground/turn-lifecycle decisions: why a refresh chose observation vs
/// resume, and how prompt submissions were classified. Ids only — never
/// prompt text, credentials, or message content.
let lifecycleLog = Logger(subsystem: "com.milim.relay", category: "TurnLifecycle")
/// Server-replacement speech retirement: which speech operations were live
/// when the outgoing server's ownership was revoked. Ids and booleans only —
/// never prompt text, credentials, or speech content.
let speechOwnershipLog = Logger(subsystem: "com.milim.relay", category: "SpeechOwnership")

@MainActor
final class AppState: ObservableObject {

    // MARK: - Connection

    @Published var connection: HermesConnection? {
        didSet {
            if oldValue?.baseUrl != connection?.baseUrl {
                agentSettings.leave(scope: agentSettingsScope)
                presentedScreens.leave()
            }
        }
    }
    @Published var client: HermesClient?
    @Published var isConnected = false {
        didSet {
            if isConnected {
                if widgetAwaitingInteractiveAuthenticationDashboardID == activeDashboardID {
                    widgetAwaitingInteractiveAuthenticationDashboardID = nil
                }
                widgetLaunchCoordinator.readinessChanged()
                // Back from a drop or a gateway restart: the list reads at
                // once rather than waiting out a long backoff step.
                if !oldValue {
                    noteChatListInteraction()
                    // A new connection is a new run of tries: what the last
                    // one spent doesn't leave this one without retries.
                    groupChatProbeRetry.succeeded()
                    botRosterRetry.succeeded()
                }
            }
            if oldValue != isConnected { schedulePendingComposerSendCheck() }
            // Nothing left to keep answering pings for off screen.
            if oldValue, !isConnected { backgroundConnectionGrace.end() }
        }
    }
    @Published var isConnecting = false
    /// A failed sign-in refresh or ticket kept quiet during those retries,
    /// shown once they have failed, by the next ticket or by a readiness
    /// probe the gateway doesn't answer (#1624).
    var quietReconnectFailure: Error?
    /// Renewals that have failed quietly since the last one worked. Counted
    /// apart from the backoff's attempts, which a network change resets, so
    /// a link that keeps changing still surfaces the failure.
    var quietRenewalFailures = 0
    /// A Reconnect someone asked for (the button, Settings, a gateway
    /// restart) shows its failure at once, as before #1624: it is an
    /// answer they are waiting for, not a resume.
    var surfacesRenewalFailureAtOnce = false
    /// The device has a usable network path (the app's one path monitor).
    @Published var networkPathUsable = true
    @Published var profiles: [String] = []
    /// The Chats list's All view, per dashboard (`AllProfilesChatsSettings`).
    @Published var allProfilesChatsSettings = AllProfilesChatsSettings()
    /// Every profile's chats for All, read in one request.
    @Published var allProfilesCatalog = AllProfilesCatalog()
    var allProfilesCatalogTask: Task<Void, Never>?
    /// Which read `allProfilesCatalogTask` is, so only it clears the handle.
    var allProfilesCatalogRead: UUID?
    @Published private(set) var sessionFilterOrder: [SessionSource] = AppState.defaultSessionFilterOrder

    var cachedGatewayMediaResolver: (profile: String, resolver: GatewayMediaDataURLResolver)?
    /// See `roomFilePicturesResolver` (GroupRoomFiles.swift).
    var cachedRoomFilesResolver: GatewayMediaDataURLResolver?

    /// The open chat's pictures, which a tapped one pages through in the
    /// viewer: the saved copy's while it stands in for the chat. One
    /// instance, so the rows reading it never redraw for it; the list is
    /// read only when a picture is tapped.
    lazy var chatImageGallery = ImageGallerySource { [weak self] in
        guard let self else { return [] }
        return ChatImageGallery.items(in: self.chatRowsOnScreen, resolver: self.gatewayMediaResolver)
    }

    var otherProfileGatewayMediaResolvers: [String: GatewayMediaDataURLResolver] = [:]

    @Published var activeProfile: String = "default" {
        didSet {
            refreshActiveChatScrollSessionIdentity()
            if oldValue != activeProfile {
                // Its own saved voice jobs, if no boundary already took them.
                if voiceJobLedgerRestoredKey != nil { scheduleVoiceJobLedgerRestore() }
                composerNotice = nil
                botsListNotice = nil
                restoreDisplayPreferences()
                restoreBusyInputMode()
                dismissChatTakeover()
                agentSettings.leave(scope: agentSettingsScope)
                presentedScreens.leave()
                schedulePendingComposerSendCheck()
                Task { await syncPreferences() }
                updateChatOnScreen()
            }
        }
    }
    /// The saved multi-dashboard registry (#148). `activeDashboardID` is the
    /// dashboard the user last chose — set at switch intent, kept on failed
    /// switches, so a selected target never silently falls back to another
    /// server.
    @Published private(set) var savedDashboardRegistry: SavedDashboardRegistry {
        didSet {
            if oldValue.activeDashboardID != savedDashboardRegistry.activeDashboardID {
                composerNotice = nil
                botsListNotice = nil
                widgetSettledCatalogOwner = nil
                let selectedDashboard = savedDashboardRegistry.activeDashboardID
                let selectedProfile = selectedDashboard.flatMap { rememberedActiveProfile(for: $0) } ?? "default"
                publishWidgetCurrentWorkspace(dashboardID: selectedDashboard, profile: selectedProfile)
                reloadDashboardScopedPresentation()
                schedulePendingComposerSendCheck()
                // The takeover belongs to the other host's chat.
                dismissChatTakeover()
                // Until the newly selected host answers, the manager it last
                // reported words the plugin asks, not the old host's.
                let askedBefore = PluginUpdateAsk.managedAsk
                PluginUpdateAsk.setActive(managedBy: NotifierPluginStatus.Remembered.managedBy(for: selectedDashboard, in: defaults))
                if PluginUpdateAsk.managedAsk != askedBefore { shareWatchCallVoices() }
            }
        }
    }
    @Published var defaultProfileName: String {
        didSet {
            persistSiriProfileNames()
            stampMainBotConduitName()
        }
    }
    /// Each profile's `display_name` set in Hermes, when it has one (#1046):
    /// "Coding Assistant" for `coding-agent`. Names only; routing keeps the
    /// profile id.
    @Published var profileHermesNames: [String: String] = [:] {
        didSet {
            persistSiriProfileNames()
            stampMainBotConduitName()
        }
    }
    /// Each profile's bot title (`ui_meta['hermes-bots'].title`), the name
    /// Edit Bot, the Profiles sheet and Hermes Desktop rename it with. It
    /// wins over `display_name`, as on Desktop and in the bot's pushes.
    @Published var profileBotTitles: [String: String] = [:] {
        didSet {
            persistSiriProfileNames()
            stampMainBotConduitName()
        }
    }
    @Published var profileAvatarURLs: [String: URL] {
        // Also bumped when a photo's bytes change under the same URL, so the
        // glow colors drawn from the photos are worked out again.
        didSet { profileAvatarRevision &+= 1 }
    }
    /// Backdrop glow colors picked in the profile picker (`#rrggbb`), for
    /// the selected dashboard.
    @Published var profileGlowPicks: [String: String] = [:]
    /// Names given in the profile picker to profiles a gateway without bot
    /// looks can't name, for the selected dashboard.
    @Published var profileDeviceNames: [String: String] = [:] {
        didSet { persistSiriProfileNames() }
    }
    var profileAvatarRevision = 0
    var profileGlowCache: (key: ProfileGlowCacheKey, colors: [String: ProfileGlowRGB])?
    /// Each photo's colors, kept while the photos stay the same, so a pick
    /// (a color drag sets one per tick) never samples the photos again.
    var profileGlowPalettes: (avatarRevision: Int, byURL: [URL: [ProfileGlowRGB]]) = (0, [:])
    @Published private(set) var isProfileSwitching = false
    @Published var appIconChoice: AppIconChoice
    @Published var dashboardTicketBridge: DashboardTicketBridge?
    var voiceAssistantObservers: [UUID: @MainActor (VoiceAssistantEvent) -> Void] = [:]
    /// The turn Voice cancelled, by its execution generation (see
    /// `takeVoiceEventAfterCancel`).
    var voiceCancelledTurns: [String: Int] = [:]
    /// Which write made each chat's note, so a failed cancel takes back
    /// only its own (`restoreVoiceCancelNote`).
    var voiceCancelNoteWrites: [String: Int] = [:]
    var lastVoiceCancelNoteWrite = 0
    /// The execution generation the stream event being handled names.
    var handledStreamEventGeneration: Int?
    /// Tests stand in for the client's `runningTurnGeneration(for:)`.
    var runningTurnGenerationLookup: ((String) -> Int?)?

    // MARK: - Session (AppState+Session.swift)

    @Published var sessions: [SessionSummary] = [] {
        didSet {
            sessionsRevision &+= 1
            catalogRowsByAnyID = nil
            refreshActiveChatScrollSessionIdentity()
            observeChatReadState()
            updateSessionReferenceTitles()
        }
    }
    /// Catalog owner captured only after its asynchronous load is admitted.
    /// Widget projection checks this before pairing rows with the selected ID.
    var widgetSettledCatalogOwner: WidgetWorkspaceID?
    var widgetSnapshotPublicationSuppressionDepth = 0
    var widgetSnapshotStoreOverride: WidgetSnapshotStore?
    var widgetSnapshotReloadOverride: (() -> Void)?
    /// The Pulse widget's file and reload, for tests (AppState+PulseWidget).
    var pulseWidgetStoreOverride: PulseWidgetStore?
    var pulseWidgetReloadOverride: (() -> Void)?
    /// The open cards the Pulse widget last had reloaded for, by id and
    /// when each came: a feed read that changes them reloads it.
    var pulseWidgetCardsSeen: [Int: Double]?
    /// The cards a Pulse widget Do it is sending now, by dashboard, so a second press sends nothing.
    var pulseWidgetDoItsRunning: Set<PulseWidgetLink> = []
    // MARK: Shared drafts (AppState+ShareDraft.swift)
    /// Test seam: the share inbox in place of the App Group's.
    var shareDraftInboxOverride: ShareDraftInbox?
    /// Test seam: where the composer's limit is published for the share sheet.
    var shareDraftSettingsDefaultsOverride: UserDefaults?
    /// The shared draft whose chat is opening.
    var sharedDraftLaunch: SharedDraftLaunch?
    /// A shared draft is being put in the composer.
    var isDeliveringSharedDraft = false
    /// The launch that just ended was a shared draft's, which says what
    /// happened itself: the widget's words don't apply.
    var sharedDraftLaunchOwnsFinish = false
    /// A shared draft with no dashboard of its own, waiting for the user to
    /// pick one.
    @Published var sharedDraftChoice: SharedDraftChoice?
    /// Drafts the user put off choosing a dashboard for: not asked about
    /// again until Conduit next comes to the front.
    var postponedSharedDraftIDs: Set<UUID> = []
    var widgetAwaitingInteractiveAuthenticationDashboardID: UUID?
    /// Refresh tokens a sign-out handed to Hermes' logout, until revoked.
    var serverSignOutQueue: ServerSignOutQueue = .shared
    lazy var widgetLaunchCoordinator: WidgetLaunchCoordinator = {
        let clock = ContinuousClock()
        let origin = clock.now
        return WidgetLaunchCoordinator(
            now: { origin.duration(to: clock.now) },
            prepare: { [weak self] link, lease in
                guard let self else { return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable")) }
                return await self.prepareWidgetLaunch(link, lease: lease)
            },
            perform: { [weak self] link, lease in
                guard let self else { return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable")) }
                return await self.performWidgetLaunch(link, lease: lease)
            },
            finish: { [weak self] outcome in
                guard let self else { return }
                if self.sharedDraftLaunchOwnsFinish {
                    self.sharedDraftLaunchOwnsFinish = false
                    self.newChatLaunchStartedInApp = false
                    if case .failed = outcome { self.widgetAwaitingInteractiveAuthenticationDashboardID = nil }
                    return
                }
                let startedInApp = self.newChatLaunchStartedInApp
                self.newChatLaunchStartedInApp = false
                if startedInApp, outcome == .handled { self.focusNewChatComposer() }
                guard case .failed(let widgetMessage) = outcome else { return }
                self.widgetAwaitingInteractiveAuthenticationDashboardID = nil
                // The widget's words send someone back to the widget.
                let message = startedInApp
                    ? AppLocalization.string("Couldn't start a new chat. Check your connection and try again.")
                    : widgetMessage
                self.errorMessage = message
                // The composer shows errorMessage only while it's locked,
                // and the V2 lists or a call's screen cover it, so a notice
                // says it too, or the tap looks ignored (a call stops a
                // launch for another workspace). Only V2 draws the notice.
                if V2ShellPreference.isOn { self.showNotice(message, systemImage: "exclamationmark.circle") }
            },
            pendingLinkChanged: { [weak self] link in
                self?.widgetLaunchPendingLinkChanged(link)
            },
            ended: { [weak self] link, outcome in
                self?.sharedDraftLaunchEnded(link, outcome: outcome)
            }
        )
    }()
    /// The app's own New Chat, not a widget, sent the pending launch.
    var newChatLaunchStartedInApp = false
    /// A Mac has a keyboard at hand, so the app's own New Chat opens ready
    /// to type. Tests stand in for a Mac.
    var newChatFocusesComposer = ProcessInfo.processInfo.isiOSAppOnMac
    var widgetSessionMutationRequestOverride: ((String, String, [String: Any]?) async throws -> [String: Any])?
    /// "host|profile" whose Hermes answered 404 for the mutation snapshot
    /// (older than the route): its writes skip the read until a write is
    /// refused for missing identity, which clears the mark.
    var hostsWithoutMutationSnapshot: Set<String> = []
    /// Tests and the UI fixture: stands in for Hermes creating a chat, for
    /// a widget's New Chat and the app's own alike.
    var widgetSessionCreatorOverride: (@MainActor (HermesClient, String?) async throws -> (sessionId: String, storedSessionId: String?, profile: String?))?
    @Published var cronSessions: [SessionSummary] = [] {
        didSet {
            cronSessionsRevision &+= 1
            refreshActiveChatScrollSessionIdentity()
            // Pinned runs carry read state too (#485).
            observeChatReadState()
            updateSessionReferenceTitles()
        }
    }
    @Published var projects: [ProjectSummary] = [] {
        didSet {
            projectPositionsBySessionID = nil
            projectsSeededFromSavedList = false
        }
    }
    /// The project pages came from the saved Chats list, not from Hermes:
    /// they leave with it, and say nothing yet about whether this Hermes
    /// takes new projects. Any later write to `projects` replaces them.
    var projectsSeededFromSavedList = false
    /// For each conversation id a project previews, the position of the
    /// first project that lists it. Built once per `projects` change for
    /// `knownProjectID(for:)`, which the chat list asks for every row on
    /// every render.
    private var projectPositionsBySessionID: [String: Int]?
    /// The catalog's rows under every id they answer to, built once per
    /// `sessions` change for `catalogRow(answeringTo:)`.
    private var catalogRowsByAnyID: [String: SessionSummary]?
    @Published var supportsProjects = false
    /// The client whose gateway rejected `session.workspace.move` as an
    /// unknown method. Scoped to that client so any new connection (a
    /// reconnect, or a gateway upgraded in place) probes the RPC again.
    weak var workspaceMoveUnsupportedClient: HermesClient? {
        willSet { objectWillChange.send() }
    }

    /// The client whose gateway rejected `projects.update` or
    /// `projects.delete`; project rename and delete stop being offered for
    /// it while the project list itself stays.
    private weak var projectEditingUnsupportedClient: HermesClient? {
        willSet { objectWillChange.send() }
    }
    @Published var projectsLoading = false
    /// The last projects load failed for a reason other than the host not
    /// having projects (a dropped or timed-out request), so an empty list
    /// isn't "no projects".
    @Published var projectsLoadFailed = false
    @Published var archivedSessions: [SessionSummary] = []
    @Published var pinnedSessionIDs: [String] = []
    /// Starred chats, per profile, on this phone only (#757).
    @Published var sessionStars = SessionStars()
    /// The Pinned section's order, per profile (issue 1354).
    @Published var pinnedChatOrder = PinnedChatOrder()
    /// The bots' order on Bots Home and every bot list (AppState+BotOrder).
    @Published var botOrder = BotOrder()
    /// The group chats' order on Bots Home and every list of rooms, by room
    /// id (AppState+BotOrder).
    @Published var groupRoomOrder = BotOrder.rooms
    /// Group Settings asked for from a room's tile on Bots Home: the room
    /// opens, then its screen shows the settings once Hermes has read them.
    @Published var groupSettingsOnOpen: GroupSettingsRequest?
    /// Which Bot Chat grows out of its Bots Home portrait (BotZoomArm).
    var botZoom = BotZoomArm()
    /// Replies pinned to the top of their chat, per profile (#918). Kept on
    /// this device only (AppState+PinnedReplies).
    @Published var pinnedRepliesByProfile: [String: [PinnedReply]] = [:]
    /// A pinned reply the overview asked to show; the chat scrolls to it
    /// once its transcript has the row (AppState+PinnedReplies).
    @Published var pendingPinnedReplyReveal: PinnedReplyReveal?
    var openChatPinnedRepliesCache: (
        key: OpenChatPinnedRepliesKey,
        value: (pins: [PinnedReply], messageIDs: Set<String>)
    )?
    /// A pin change that stayed on this phone because Hermes didn't take
    /// it, shown for a moment with Hermes' reason (#555).
    @Published var pinSyncNotice: PinSyncNotice?
    /// The refusal `showCallRefusal` left on the drawer shell's error line (V2 off).
    var callRefusalOnErrorLine: String?
    /// What the user has and hasn't seen, per conversation (#454).
    @Published var chatReadState = ChatReadState()
    /// The latest `session.active_list` snapshot and the profile it belongs
    /// to (#454).
    @Published var liveSessionStatusIndex = SessionLiveStatusIndex()
    /// Where active_list snapshots and a required sign-in reach the Lock
    /// Screen's turn activities (LiveTurnActivities); tests watch them. A
    /// snapshot answers true when a turn's chat was just seen absent and
    /// another read is needed to settle it.
    var liveTurnActivitiesRegistrySnapshot: @MainActor (Set<String>, String, String?) -> Bool = { ids, profile, dashboardID in
        LiveTurnActivities.shared?.reconcile(liveSessionIDs: ids, profile: profile, dashboardID: dashboardID) ?? false
    }
    /// The one `session.active_list` read that settles a turn whose chat
    /// was just seen absent, whether or not the chat list (and its poll) is
    /// on screen.
    var liveTurnRegistryRecheck: Task<Void, Never>?
    /// Ends a dashboard's turn activities (Disconnect, Sign Out, a required
    /// sign-in), or with `true` only those the relay can't end by push.
    var liveTurnActivitiesEndDashboard: @MainActor (String?, Bool) -> Void = { dashboardID, keepingThoseOnRelay in
        LiveTurnActivities.shared?.endTurns(ofDashboard: dashboardID, keepingThoseOnRelay: keepingThoseOnRelay)
    }

    var liveSessionStatusProfile: String?
    /// The client whose gateway rejected `session.active_list`, so the chat
    /// list's poll stops asking it.
    weak var activeListUnsupportedClient: HermesClient?
    /// False once the gateway turned `session.active_list` down, so the chat
    /// list hides the Working and Needs input chips instead of showing a 0 it
    /// can't know. A successful poll turns it back on.
    @Published var liveSessionStatusAvailable = true
    /// The client whose failed poll was already logged, so a flaky
    /// connection leaves one line rather than one per tick.
    weak var activeListFailureLoggedClient: HermesClient?
    /// The host the Desktop views below came from, when each profile was
    /// last asked, and the newest settled time it reported.
    var desktopViewsHost: String?
    var desktopViewsFailureLogged = false
    var desktopViewsFetchedAt: [String: Date] = [:]
    var desktopViewsCursor: [String: TimeInterval] = [:]
    @Published var sessionMutationID: String?
    @Published var isRefreshingSessionCatalog = false
    /// Whether `sessions` is the catalog Hermes answered for the dashboard
    /// profile on screen (see SessionCatalogLoad.swift).
    @Published var sessionCatalogLoadState = SessionCatalogLoadState()

    /// The list's own first catalog read while it runs.
    var sessionCatalogFirstRead: SessionCatalogFirstRead?
    @Published var activeSessionId: String? {
        didSet {
            refreshActiveChatScrollSessionIdentity()
            if oldValue != activeSessionId {
                // Read replies aloud follows only the open chat's turn.
                messageReadAloudController.stopFollowing { self.eventBelongsToActiveSession($0) }
                noteChatLeft(oldValue)
                noteActiveChatSeen()
                // A file lookup's "isn't on the server" was about the chat
                // left, and an answer still coming is too.
                clearWorkspaceLookupNotice()
                workspaceRevealGeneration &+= 1
                // The chat New Chat made takes the New Chat's draft only
                // while it's the one open.
                if let created = newChatOpenedSessionID, activeSessionId != created {
                    newChatOpenedSessionID = nil
                }
                schedulePendingComposerSendCheck()
                // The Model and Context sheets act on the chat they came up
                // over. Another chat taking its place (a notification, an
                // app link) takes them down; a new id for the same
                // conversation leaves them up.
                if !activeChatScrollSessionIdentity.contains(oldValue) {
                    // Only when they're up: assigning false to a flag
                    // already false still publishes AppState, and this runs
                    // on every chat the person opens.
                    if showModelPicker { showModelPicker = false }
                    if showContextSheet { showContextSheet = false }
                    // A failed send's line under the composer was the chat
                    // left's; a reconnect's new id for the same one keeps it.
                    if let failure = sendFailureShown {
                        if errorMessage == failure { errorMessage = nil }
                        sendFailureShown = nil
                    }
                }
                updateChatOnScreen()
            }
        }
    }
    @Published var activeChatScrollSessionIdentity = ChatScrollSessionIdentity.none
    @Published private(set) var chatTranscriptRevision: UInt64 = 0
    /// A message an Artifacts screen asked to show; the chat scrolls to it
    /// once its transcript has the row (AppState+Artifacts).
    @Published var pendingArtifactReveal: ArtifactReveal?
    /// The open chat's plan card (AppState+ChatCards). Its own observable:
    /// the card changing redraws the card alone.
    let chatCards = ChatCardsModel()
    /// Every chat Hermes waits on the user in, every profile's (issue 1705;
    /// AppState+NeedsYou). Its own observable, as `chatCards`.
    let needsYou = NeedsYouStore()
    /// A chat opened from the Needs you list or banner, to scroll to its
    /// waiting card once its transcript has it.
    @Published var pendingNeedsYouReveal: NeedsYouReveal?
    /// Cached once per transcript mutation so view updates do not rescan the full history.
    @Published private(set) var pendingClarifyMessageID: String?
    /// What that card is, for the jump button's words.
    @Published private(set) var pendingDecisionKind = PendingDecisionKind.question
    @Published var messages: [ChatMessage] = [] {
        didSet {
            chatTranscriptRevision &+= 1
            let pendingClarify = ChatResumeCoordinator.pendingClarifyMessageID(in: messages)
            if pendingClarifyMessageID != pendingClarify {
                pendingClarifyMessageID = pendingClarify
            }
            let kind = pendingClarify.flatMap { id in messages.last { $0.id == id } }
                .map(PendingDecisionKind.init(message:)) ?? .question
            if pendingDecisionKind != kind {
                pendingDecisionKind = kind
            }
            advanceChatViewportExpectedTranscriptRevisionIfNeeded()
            // Hermes' rows take over from the saved copy's in the same
            // update: the chat view draws one or the other, never a mix, and
            // rows with the same id stay where they are (#1533).
            if !messages.isEmpty, offlineChatPresentation != nil {
                offlineChatPresentation = nil
            }
        }
    }
    /// Read-only copy of a recently opened conversation, shown while the
    /// server has not answered yet (#99): the chat view draws its rows as
    /// the chat's, provisionally. It never feeds `messages`, `sessions`, or
    /// any resume/selection/routing decision, and while it's up nothing
    /// that needs Hermes' word acts on its rows (approvals, Load earlier,
    /// Retry, Edit, reactions, pins).
    @Published var offlineChatPresentation: OfflineChatPresentation? {
        // A message waiting for the chat on screen follows what's shown.
        didSet {
            if (oldValue == nil) != (offlineChatPresentation == nil) { updateChatOnScreen() }
            guard pendingComposerSend != nil else { return }
            if (oldValue == nil) != (offlineChatPresentation == nil)
                || oldValue?.chatSessionIDs != offlineChatPresentation?.chatSessionIDs {
                schedulePendingComposerSendCheck()
            }
        }
    }
    /// The Chats list as it was last shown on this phone, listed while this
    /// scope's live list hasn't landed (a launch, a profile switch).
    /// Presentation only, like the saved copy: nothing that resumes, routes
    /// or sends reads it.
    @Published var savedChatList: SavedChatListPresentation? {
        didSet { savedChatListRevision &+= 1 }
    }
    var savedChatListRevision = 0
    var listedSessionsCache: (key: ListedSessionsKey, rows: [SessionSummary])?
    /// A chat tapped in the saved list: it opens once the live list lands,
    /// ahead of the automatic resume.
    var chatPickedFromSavedList: SavedChatListPick?
    /// The Bot Chats left this run, by dashboard and bot (`keepBotChatCopy`).
    var keptBotChatCopies: [String: KeptBotChatCopy] = [:]

    /// The last chats left after Load earlier brought in older rows, newest
    /// last (`keepLeftBackfilledTranscript`).
    var leftBackfilledTranscripts: [LeftBackfilledTranscript] = []
    /// The bot the chat on screen was open for, taken before a bot open
    /// notes its destination's ids (`noteBotChatOpen`): the destination can
    /// share the id the chat on screen is open as.
    var outgoingBotChatCopyOwner: (sessionID: String, bot: String?)?
    /// The scope whose list in memory came from Hermes after the saved files
    /// were last wiped, and so may be saved.
    var savableChatListScope: WidgetWorkspaceID?
    @Published var activeSessionTitle = AppLocalization.string("New conversation")
    /// Persisted-history pagination window of the active conversation.
    /// Drives the "Load earlier messages" affordance; nil means the current
    /// transcript is either a legacy one-shot hydration or not persisted-
    /// history-backed at all, and no older pages exist to fetch.
    @Published var persistedTranscriptWindow: PersistedTranscriptWindowState?
    /// Row ids POSITIVELY known to originate from validated persisted-
    /// transcript hydration (raw rows carrying a durable `id`/`message_id`)
    /// for the active conversation, adopted from the latest accepted
    /// hydration and cleared whenever a reconcile begins or fails to adopt a
    /// transcript. Consumed only by the ambiguous-delivery verifier as
    /// ordering anchors — never populated from visible id shape, so local
    /// optimistic / streaming / positional ids can never masquerade as
    /// persisted anchors.
    var durablePersistedRowIDs: Set<String> = []
    @Published var isChatRefreshing = false
    @Published var chatResumeBehavior: ChatResumeBehavior = .continueWhereLeftOff
    @Published var chatReturnSurface: ChatReturnSurface = .conversation
    /// One-shot request for MainView to present the sessions drawer as the
    /// preferred return surface. MainView consumes the latest value once per
    /// increment; the request is only issued for qualifying returns (cold
    /// launch or a real background → active transition) when the preference
    /// is `.sessions` and no explicit navigation or modal owns the surface.
    @Published var preferredReturnSurfaceRequest: UInt64 = 0
    @Published var chatResumeRestorationRequest: ChatResumeRestorationRequest?
    @Published var chatViewportTransitionGeneration: UInt64 = 0
    /// Keeps the current transcript visible while a notification destination is
    /// being prepared, so the chat never appears to jump to an empty canvas.
    @Published var isOpeningNotificationSession = false
    @Published var isBranchingChat = false
    /// Runtime ids of conversations with a dedicated `session.compress` RPC
    /// in flight. Manual compression is LLM-bound and can take minutes, so
    /// the chat shows a small "Compressing…" affordance while the ACTIVE
    /// conversation is compressing, and a second `/compress` for the same
    /// conversation is refused. Per-session on purpose, matching upstream
    /// Desktop's `compressInFlightRef`: compressions of different
    /// conversations run concurrently.
    @Published var compressingSessionIDs: Set<String> = []
    /// Conversations the GATEWAY reports as actively compacting
    /// (`status.update` `kind: "compacting"`), or whose manual compression
    /// answered `status: "pending"` — server-side compression still running
    /// after the local RPC ended. Distinct from `compressingSessionIDs`
    /// (local RPC in-flight): the RPC can return while the host keeps
    /// compressing, and only the `compacted` edge (or an authoritative
    /// reconnect, which invalidates unverified gateway state) clears it.
    @Published var serverCompactingSessionIDs: Set<String> = []
    var serverCompactionClaims: [String: ServerCompactionClaim] = [:]
    /// Scheduled bounded-expiry tasks per claim runtime id; replaced on
    /// refresh, cancelled when the claim clears early.
    var serverCompactionClaimExpiryTasks: [String: Task<Void, Never>] = [:]
    /// Terminal-compaction generations per conversation runtime id, bumped by
    /// every authoritative terminal signal (`compacted` edges and terminal
    /// `session.compress` results).
    var serverCompactionTerminalGenerations: [String: Int] = [:]
    @Published var turnState: TurnState = .idle {
        didSet {
            guard oldValue != turnState else { return }
            // A message waiting for this chat goes once it takes one.
            schedulePendingComposerSendCheck()
            // A running turn keeps the backdrop drifting; only its edges
            // are reported, not every streamed token.
            InteractionIdleState.shared.setTurnRunning(turnState.isRunning)
            // Its reply sends no push while the chat is on screen.
            updateChatOnScreen()
        }
    }
    /// Whether `turnState` may have missed server-side turn edges. Set at
    /// lifecycle boundaries where the socket can die or the gateway can change
    /// state unobserved (scene dips, reconnects, ambiguous submissions);
    /// cleared only when an authoritative source (the `session.active_list`
    /// probe, a resume snapshot, or a typed prompt outcome) re-confirms the
    /// state. A stale idle state must not route the next input as a new-turn
    /// `prompt.submit` — Hermes would apply its busy policy to it and the
    /// message would silently join a turn the user never saw start.
    /// Publishes its flips: the chat list's Working marker reads it.
    var turnStateIsStale = false {
        willSet { if newValue != turnStateIsStale { objectWillChange.send() } }
    }

    var turnLifecycleEvidence = TurnLifecycleEvidence(revision: 0, running: false)
    /// Session identities with a locally-observed running turn at the last
    /// scene transition (empty = no continuity evidence). A foreground probe
    /// whose working/waiting row matches one of these ids continues a turn
    /// Conduit already knows — the fast observational path. A working/waiting
    /// row WITHOUT this evidence may be a turn another surface started while
    /// Conduit was suspended, so liveness alone must not stand in for
    /// transcript freshness. Captured at the transition (before
    /// reconciliation resets any state), consumed by exactly one foreground
    /// refresh.
    var preSuspensionTurnRunningSessionIDs: Set<String> = []
    /// Armed by a real `.background` transition and consumed synchronously by
    /// the next `.active` transition: the socket can die while suspended, so
    /// bounded persisted-history activity from another surface could have
    /// been missed. Overlay (`.inactive`) dips keep the socket alive — live
    /// events keep flowing — so they observe but do not arm the freshness
    /// check.
    var foregroundFreshnessCheckArmed = false
    /// Whether the visible persisted transcript may be MISSING rows —
    /// conceptually disjoint from `turnStateIsStale`, which answers "do I
    /// know whether Hermes is currently busy?". Set when a bounded
    /// foreground freshness read failed transiently on a real background
    /// return, and when a resume Hermes refused as too long for the whole
    /// transcript kept the rows on screen while its history read failed for
    /// now (issue 2025); a liveness answer (the registry probe) can never
    /// clear it.
    /// Cleared only when an authoritative transcript source proves
    /// convergence: an unchanged bounded verdict, an advancement merge, or a
    /// resume/reconcile hydration (`applyChatResume`).
    var transcriptFreshnessIsStale = false
    var pendingLocalOrderingDebt: PendingLocalOrderingDebt?
    var locallyOwnedInFlightTurn: LocallyOwnedInFlightTurn?
    var persistedOrderingFrontier = PersistedOrderingFrontier()
    @Published private(set) var busyInputMode: BusyInputMode = .steer
    @Published private(set) var displayPreferences = ProfileDisplayPreferences() {
        // Kept on the device too, so the saved chats draw as Settings says
        // before the host answers (offline from launch).
        didSet { if displayPreferences != oldValue { rememberDisplayPreferences() } }
    }
    /// The profile's `timezone` config value ("" = the server's local time)
    /// and the profile it was read for. Hermes runs cron schedules in it.
    @Published private(set) var profileTimeZoneSetting: (profile: String, value: String)?
    /// The running turn's live reply text and thinking card. They publish on
    /// their own object, never on AppState: while a turn streams they change
    /// 20 to 30 times a second, and an AppState publish re-renders every view
    /// that observes it, so any open sheet re-rendered at that rate and lagged.
    let liveTurn = LiveTurnProjection()
    /// An explicit user-send request lets ChatView scroll after SwiftUI has
    /// inserted the outgoing bubble, even if the user previously browsed up.
    @Published var chatScrollRequest = 0
    @Published var chatScrollToTopRequest = 0
    /// Bumped once an unread chat's open has its transcript in, or as it
    /// opens when its saved rows end mid-turn (#1533): ChatView lands it at
    /// the start of its latest reply (#365), taking it once
    /// (takeChatReplyStartLanding), also when it mounts after the bump.
    @Published var chatReplyStartLandingRequest = 0
    var chatReplyStartLandingTaken = 0

    /// Bumped on every write to `sessions`.
    var sessionsRevision = 0
    var activeProfileSessionsCache: (key: ActiveProfileSessionsKey, rows: [SessionSummary])?

    /// Bumped on every write to `cronSessions`.
    var cronSessionsRevision = 0
    var activeProfileCronSessionsCache: (key: ActiveProfileCronSessionsKey, rows: [SessionSummary])?

    // MARK: - Bot Mode (AppState+BotMode.swift)

    /// Lifecycle of the Bot Mode capability probe. `profiles.list` is the
    /// capability call: a gateway old enough to lack the method has no
    /// Bot Mode, and the UI degrades to "requires a newer Hermes gateway"
    /// without blocking Sessions or anything else.
    @Published var botModePhase: BotModePhase = .idle {
        // Device names count only until the gateway shows bot looks.
        didSet { if oldValue != botModePhase { persistSiriProfileNames() } }
    }
    /// The read-only roster, as Hermes last answered on this dashboard.
    /// Hermes remains authoritative: the copy the Bots list keeps to open on
    /// (`shownBotRoster`) only stands in until it answers, and nothing
    /// writes from that copy.
    @Published var botRoster: [BotProfile] = [] {
        didSet {
            stampMainBotConduitName()
            invalidateBotOwnershipCache()
            publishWidgetSnapshot()
        }
    }
    @Published var isRefreshingBotRoster = false
    /// Bot avatars from each profile's gateway asset store (the same pictures
    /// Hermes Desktop shows), keyed by profile name. Runtime-only, fenced by
    /// the roster epoch, cleared at the server-identity boundary.
    @Published var botAvatarImages: [String: UIImage] = [:]
    /// Bumped by an explicit roster reload so rows re-fetch their avatar
    /// (another client may have changed it; the roster carries no version).
    @Published var botAvatarGeneration = 0
    /// When `reloadBotRoster` last asked for every picture again.
    var botAvatarsReloadedAt: Date?
    var botAvatarFetchedGeneration: [String: Int] = [:]
    /// Name to the generation its in-flight fetch serves, so a newer
    /// generation can start its own fetch instead of being deduped away.
    var botAvatarFetchInflight: [String: Int] = [:]
    /// Each picture write this app makes takes the next serial, kept per
    /// profile, so a roster or asset read that started before the write
    /// never puts the older picture back.
    var profileAvatarWriteSerial = 0
    var profileAvatarLastWrite: [String: Int] = [:]
    /// The running photo sync; each roster read queues the next behind it.
    var profileAvatarSyncTask: Task<Void, Never>?
    /// Each profile's last queued photo write. Writes to one profile run in
    /// the order they were asked for, so the latest one lands last.
    var profilePhotoWriteQueue: [String: Task<String?, Never>] = [:]
    /// `profiles.list` `bot_mode_protocol`: the backend teaches bots the
    /// teammate-messaging protocol itself, so a new bot's SOUL stays
    /// identity-only.
    var botRosterSupportsProtocol = false
    /// Bumped at every server-identity boundary; responses captured under an
    /// older epoch are dropped, so a stale async roster can never overwrite
    /// the state of a different dashboard/profile.
    var botRosterEpoch = 0
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
    var botChatOpenFlights: [String: BotChatOpenFlight] = [:]
    @Published var botChatOnItsWay: BotChatOnItsWay? {
        didSet {
            guard oldValue != botChatOnItsWay else { return }
            updateChatOnScreen()
            // The cover went, and with it nothing covers the chat it showed.
            if oldValue != nil, botChatOnItsWay == nil { noteActiveChatSeen(respectingMarks: true) }
        }
    }
    /// Why a Bot Chat opened from a list of bots didn't open, for that list
    /// to show (`openBotChatFromList`); the list takes it.
    @Published var botsListNotice: String?

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
    var botOwnershipGeneration = 0

    /// Whether the roster on hand was verified since the CURRENT connection
    /// began. Cleared whenever a connection (or reconnect) is established, so
    /// absence evidence can never outlive the socket that produced it.
    var botRosterVerifiedForCurrentConnection = false

    // MARK: - Runtime

    /// When a Pulse feed read last landed, and for which dashboard
    /// (PulseFeed.swift).
    var pulseFeedAppliedAt: (dashboard: UUID?, at: Date)?

    @Published var runtime = RuntimeState()
    @Published var activeAgents = 0
    @Published var delegateAgents: [DelegateAgentActivity] = []
    /// When each delegate agent last sent an event. An event that changes
    /// nothing its card shows renews this without publishing the cards, and
    /// the roster check counts it as the card's latest news.
    var delegateAgentSeenAt: [String: Date] = [:]
    /// A card with an event this recent may belong to an agent the gateway
    /// roster hasn't registered yet, so the roster check leaves it alone.
    static let delegateAgentRosterGrace: TimeInterval = 30
    /// A file path tapped in a reply, for the open chat's Folder tab to
    /// show (AppState+Workspace.swift).
    @Published var workspaceReveal: WorkspaceReveal?
    /// Counts file taps, so a slow lookup for an earlier one is dropped.
    var workspaceRevealGeneration = 0
    /// The "isn't on the server" notice the last file lookup put above the composer.
    var workspaceLookupNotice: String?
    /// The notice the lookup's covered, shown again when the lookup's goes.
    var workspaceNoticeUnder: (text: String, systemImage: String)?
    /// Counts the tools Hermes finished that may have changed files, so an
    /// open Folder tab reads its folders again.
    @Published var workspaceChanges = 0
    @Published var gatewayDiagnostics: GatewayDiagnostics?
    @Published var gatewayDiagnosticsLoading = false
    /// Restart Gateway's progress and outcome, and the dashboard it belongs
    /// to (AppState+GatewayRestart.swift).
    @Published var gatewayRestart = GatewayRestartSlot()
    var gatewayRestartTask: Task<Void, Never>?
    /// Restart now is under way (restartGatewayNow): one at a time, however
    /// many places show the wait.
    @Published var gatewayRestartingNow = false
    /// Why the last Restart now failed, kept here so a wait view opened
    /// after it finished still shows it.
    @Published var gatewayRestartNowFailure: GatewayRestartNow.Failure?
    /// The Conduit plugin update's progress and outcome, and the dashboard
    /// it belongs to (AppState+NotifierPluginUpdate.swift).
    @Published var notifierPluginUpdate = NotifierPluginUpdateSlot()
    var notifierPluginUpdateTask: Task<Void, Never>?
    /// Dashboard and profile pairs Conduit already tried to pair on its own
    /// this launch, so a refused or failed pairing isn't retried on every
    /// connect.
    var automaticPairingAttempts: Set<String> = []
    /// Bumped per plugin status request; the accepted one is the newest
    /// request whose answer landed, so an older answer never lands over a
    /// newer one, but still lands when a newer request failed.
    var notifierPluginStatusGeneration = 0
    var notifierPluginStatusAcceptedGeneration = 0
    @Published private(set) var modelVisibility = ModelVisibility()
    /// The model sheet's pinned and recent models, for the active dashboard.
    @Published private(set) var modelQuickPicks = ModelQuickPicks()

    // MARK: - UI state

    @Published var themePreference: ThemePreference {
        didSet {
            defaults.set(themePreference.rawValue, forKey: themePreferenceKey)
        }
    }
    @Published var showSidebar = false {
        didSet {
            // Closing the drawer uncovers the open chat (#454).
            // A list of bots closing for another bot's chat uncovers nothing:
            // that chat's cover shows (botChatCoversOpenChat).
            if oldValue, !showSidebar { noteActiveChatSeen(respectingMarks: true) }
            // Covering it (Back to the list, the drawer opening) leaves it:
            // what it showed until now was seen. The list it returns to
            // reads the catalog again (refreshCatalogAfterLeavingChat, from
            // RootView, whenever the chat is covered).
            if !oldValue, showSidebar, !botChatCoversOpenChat { noteChatLeft(activeSessionId) }
            if oldValue != showSidebar { updateChatOnScreen() }
            // The drawer covers the chat, so its live rows need not redraw at
            // streaming cadence while it is up or animating (liveRowsHidden).
            if showSidebar {
                pauseLivePublishes()
            } else {
                resumeLivePublishesIfShown()
            }
        }
    }

    /// The open chat's live rows can't be seen: the sessions drawer covers
    /// them, or Conduit is in the background or inactive (sceneHidesLiveRows). Their text and reasoning
    /// publishes (to `liveTurn`, which only those rows observe) pause then.
    /// In the background a reply streaming in otherwise kept the main
    /// thread drawing it, the whole growing reply on each publish, so iOS's
    /// watchdog killed Conduit when it couldn't finish going to the
    /// background or quitting (8BADF00D). The live buffers stay
    /// authoritative and are republished once the rows show again.
    var liveRowsHidden: Bool { showSidebar || sceneHidesLiveRows }
    /// Conduit is in the background, or inactive on an iPhone or iPad (the
    /// app switcher, Control Center, a system alert), where a swipe away
    /// from the switcher asks Conduit to quit while a reply still redraws.
    /// An iPad app on a Mac is inactive whenever another app is in front,
    /// where the reply stays in view, so there only the background counts.
    var sceneHidesLiveRows = false
    /// On a Mac, inactive means another app is in front, where Conduit's
    /// window stays in view. Tests set their own.
    var inactiveSceneStaysInView = ProcessInfo.processInfo.isiOSAppOnMac
    /// Conduit's screens are in view: the scene is active, or on a Mac its
    /// window shows behind another app's. The Chats list's live reads keep
    /// going there, so its Running and Approve keep up with the chats
    /// beside the app in front (issue 1615).
    var sceneIsInView: Bool {
        isSceneActive || (inactiveSceneStaysInView && sceneHasBeenActive && !sceneHidesLiveRows)
    }

    func pauseLivePublishes() {
        streamingPublishTask?.cancel()
        streamingPublishTask = nil
        hasScheduledStreamingPublish = false
        reasoningPublishTask?.cancel()
        reasoningPublishTask = nil
        hasScheduledReasoningPublish = false
    }

    /// What streamed while the live rows were hidden, in one publish.
    func resumeLivePublishesIfShown() {
        guard !liveRowsHidden else { return }
        if !streamingBuffer.isEmpty, streamingBuffer != streamingText {
            lastStreamingPublishBurst = max(
                streamingBuffer.count - streamingText.count,
                0
            )
            lastStreamingPublishDate = Date()
            streamingText = streamingBuffer
        }
        flushReasoningPublish()
    }
    /// Closes the modal sessions drawer if it is open. Session-opening flows
    /// inside the sidebar call this unconditionally: in drawer mode it
    /// dismisses the sheet, while in the iPad persistent-sidebar layout the
    /// drawer is never presented (`showSidebar` stays false), so this is a
    /// no-op and the persistent column remains visible.
    func dismissSidebarDrawer() {
        guard showSidebar else { return }
        showSidebar = false
    }

    /// The bot whose chat a list of bots is opening, or the room Bots Home
    /// is (`BotZoomArm.roomKey`). The list closes first and the shell routes
    /// the chat then, before it lands, so this tells it a Bot Chat or a room
    /// is coming (it stays in Bots) whatever was open before.
    var botChatOpening: String?
    /// Each open a list of bots marked and hasn't ended, by name: how many
    /// taps, and whether the chat's screen they open on was pushed as the
    /// list closed (`openBotChatFromList`). A tap made while the list is
    /// still closing over an earlier tap's push opens on that screen too.
    var botChatMarks: [String: (taps: Int, pushed: Bool)] = [:]
    /// The name the last mark was made for: only its open covers the chat,
    /// since a newer tap takes the screen from an earlier one still out.
    var botChatLatestMark: String?

    /// Closes the list for `name`'s Bot Chat; `endOpeningBotChat` once the
    /// open has finished, opened or not.
    func beginOpeningBotChat(_ name: String) {
        botChatOpening = name
        let pushed = showSidebar || botChatMarks.values.contains { $0.pushed }
        let mark = botChatMarks[name]
        botChatMarks[name] = ((mark?.taps ?? 0) + 1, (mark?.pushed ?? false) || pushed)
        botChatLatestMark = name
        dismissSidebarDrawer()
    }

    func endOpeningBotChat(_ name: String) {
        if botChatOpening == name { botChatOpening = nil }
        guard let mark = botChatMarks[name] else { return }
        if mark.taps > 1 {
            botChatMarks[name] = (mark.taps - 1, mark.pushed)
            return
        }
        botChatMarks[name] = nil
        // What the chat shows from now on is seen, once nothing covers it.
        noteActiveChatSeen(respectingMarks: true)
        updateChatOnScreen()
    }

    /// The open chat (or room) is hidden behind a bot a list of bots is
    /// opening: its cover shows, or the latest mark, for another bot or a
    /// room, is still out, from the moment the list closes. What arrives
    /// meanwhile isn't seen, so it's not marked read and its notifications
    /// stay. An earlier tap still out covers nothing: a newer one took over.
    var botChatCoversOpenChat: Bool {
        if botChatComingOverAnother != nil { return true }
        guard let name = botChatLatestMark, botChatMarks[name] != nil else { return false }
        guard activeRoomSurface == nil, let open = activeBotChatProfile else { return true }
        return !profilesMatch(open, name)
    }

    /// The shell placed the conversation for the marked Bot Chat: the mark
    /// is spent, so a plain session a notification opens before the Bot
    /// Chat lands still goes to Sessions.
    func botChatOpeningPlaced() {
        botChatOpening = nil
    }

    /// Whether the shell keeps the conversation it's placing in Bots: a
    /// Bot Chat or a workstream's chat is open, or a list of bots marked
    /// one as coming.
    var placesConversationAsBotChat: Bool {
        activeBotChatProfile != nil || activeWorkstream != nil || botChatOpening != nil
    }
    @Published var showModelPicker = false
    @Published var showContextSheet = false
    @Published var showWorkspaceSheet = false
    @Published var showGatewaySheet = false
    @Published var showAgentsSheet = false
    @Published var showVoiceSheet = false {
        // Talking to Hermes in Voice shares location, when the user chose to.
        didSet { if showVoiceSheet, !oldValue { noteVoiceCallStartedForLocation() } }
    }
    /// Mirrors MainView's Settings sheet item so return-surface decisions can
    /// tell whether Settings owns the surface across a background/foreground cycle.
    @Published var isSettingsSheetPresented = false
    /// A Settings page a link asked for (`conduit://settings/calls`):
    /// MainView opens Settings there and clears it.
    @Published var settingsLinkRequest: ConduitAppLink.SettingsLink?
    /// A Kanban task to show (a Pulse card from its worker): the shell
    /// opens Tasks › Board, and the board opens the task and clears it.
    @Published var kanbanTaskOpenRequest: KanbanTaskOpenRequest?
    /// Bumped when something that opens a chat needs Settings out of the
    /// way (a widget's New Chat or Talk); MainView owns the sheet.
    @Published private(set) var settingsDismissRequest: UInt64 = 0
    /// Also asked while Settings is only queued behind a closing drawer.
    func requestSettingsDismissal() {
        settingsDismissRequest &+= 1
    }
    @Published var errorMessage: String? {
        didSet { errorMessageWrites &+= 1 }
    }
    /// Counts every write to `errorMessage`, the same text again included,
    /// so an open can tell whether it said why it failed (issue 2079).
    private(set) var errorMessageWrites = 0
    /// The open chat's sync error, raised while a room covers the chat. A
    /// room's banner shows `errorMessage`, so a chat that fails to resume
    /// behind it (a return to the app) would put its error in the room
    /// (#1459); it waits here and shows when the room closes back to the chat.
    var chatErrorBehindRoom: String?
    /// What took the place of the room last closed: a chat opening (a
    /// session open) or a new chat, which the shell shows where the room's
    /// screen was rather than dropping back to the list (Group Info's Ask
    /// and Wrap Up landed on Bots Home). Every close sets it, so it never
    /// outlives the close it describes.
    var roomHandedTo: RoomHandoff = .none

    enum RoomHandoff: Equatable {
        /// Back, a disband, a server change: the room's screen goes.
        case none
        /// A session open, whose id is already the active one: it places itself.
        case openedChat
        /// A new chat, which has no id until Hermes answers: always an
        /// ordinary chat, in Sessions, whatever Bot Chat was open before.
        case newChat
    }
    /// The restore error the open chat's last failed resume showed, which a
    /// later resume of it that works clears (issue 2025).
    var chatRestoreFailureShown: String?
    /// Where a chat sync puts its error: `errorMessage`, or
    /// `chatErrorBehindRoom` while a room is on screen.
    var chatSyncErrorMessage: String? {
        get { activeRoomSurface == nil ? errorMessage : chatErrorBehindRoom }
        set {
            if activeRoomSurface == nil {
                errorMessage = newValue
            } else {
                chatErrorBehindRoom = newValue
            }
        }
    }
    /// A reasoning write is in flight, from the composer chip or the Model
    /// sheet; both wait for it so picks land in order.
    @Published var isWritingReasoningEffort = false
    /// A classified sign-in failure awaiting presentation on the login card.
    /// Typed (not a string) so LoginView renders the full presentation —
    /// title, actions, help routing — and delivered as a publisher so the
    /// handoff works even when LoginView is already mounted (onReceive fires
    /// on new emissions and replays the current value on mount). Consumed
    /// once by LoginView; never read by the connected composer banner, so a
    /// sign-in failure cannot resurface stale over a healthy session.
    @Published var pendingLoginFailure: ConnectionFailurePresentation?
    /// A sign-in code link that opened Conduit or was tapped in a chat
    /// (DashboardConnectLink.swift). RootView asks about it in a sheet,
    /// over the sign-in screen or a connected app alike.
    @Published var pendingConnectLink: DashboardConnectLink?
    /// A Link invite that opened Conduit or was tapped in a chat
    /// (RoomLinks.swift). RootView shows who it's from in a sheet, which
    /// asks before linking.
    @Published var pendingRoomLink: RoomLinkURL?
    /// An invite to a room whose notification was tapped (RoomInvites.swift):
    /// RootView shows its join card.
    @Published var presentedRoomInvite: RoomInvite?
    /// An approval in a room hosted elsewhere whose notification was tapped
    /// (RoomApprovals.swift): RootView shows its card.
    @Published var presentedRoomApproval: RoomApproval?
    /// Round 6: the classified failure of the most recent failed connection
    /// attempt (saved-credential reconnect, repair activation, or a failed
    /// explicit connect). Typed — never recovered from user-facing strings —
    /// so Repair Connection can seed its routing from the actual problem.
    /// Cleared by any successful connection, by explicit disconnect, and
    /// when the user starts a manual login (which abandons the prior
    /// failure's repair context).
    @Published var lastConnectionFailure: ConnectionFailure? {
        // Wherever a failure is forgotten (a connect, a sign-out, a
        // dashboard switch), a quiet one goes with it (#1624).
        didSet {
            if lastConnectionFailure == nil {
                quietReconnectFailure = nil
                quietRenewalFailures = 0
            }
        }
    }
    @Published var showLogin = true {
        didSet {
            // The sign-in surface never keeps a saved copy in memory: after an
            // authentication failure it must not reappear on the next sign-in.
            // (The files stay until sign-out/removal/switch wipes them.)
            if showLogin {
                dismissOfflineChatPresentation()
                dismissSavedChatList()
            }
            // Sign-in raised with Conduit off the phone screen (a call from
            // Hermes or the Apple Watch launched it in the background, or
            // only CarPlay shows it): Face ID can't show there, and a locked
            // phone keeps a saved password unreadable. The saved sign-in
            // runs again once Conduit is on screen instead of leaving the
            // user signed out.
            signInWaitsForForeground = showLogin && phoneScreenIsAway()
            // Signed in: a draft shared meanwhile opens now (#812).
            if oldValue, !showLogin, isSceneActive {
                Task { @MainActor [weak self] in self?.pickUpSharedDrafts() }
            }
        }
    }
    /// A sign-in screen came up while Conduit was off the phone screen; the
    /// next return to the screen retries the saved sign-in.
    var signInWaitsForForeground = false
    /// Settings › Saved Dashboards › Ask Which Dashboard at Launch (#1908):
    /// this launch waits on the dashboard list for a tap instead of signing
    /// in to the last dashboard used. It ends when a dashboard is picked or
    /// switched to, when something the launch came for (a notification, a
    /// link, Siri, the car, the Watch, a call) signs in, or when Conduit
    /// comes on screen signed in already.
    var launchAwaitsDashboardChoice = false
    /// How long a launch waits for Conduit's phone screen before it counts
    /// as a launch in the background, which signs in as before. Test seam.
    var launchDashboardChoiceGrace: Duration = .seconds(2)
    /// The grace ran out with no phone screen: the background launch's own
    /// sign-in is under way, or waits for the screen.
    var launchSignsInInBackground = false
    var launchDashboardChoiceTask: Task<Void, Never>?
    /// Whether no phone screen of Conduit is in the foreground: a launch in
    /// the background, or CarPlay alone. Test seam.
    var phoneScreenIsAway: @MainActor () -> Bool = {
        !PhoneScenePresence.isInForeground
    }
    /// The Pulse screen (PulseFeed.swift): its unseen cards for the
    /// button's badge, the chats' messages that have a card (chat id, then
    /// Hermes' message id, to card id), a request to show it, and Pulse's
    /// own chat, which the screen stands in for.
    @Published var pulseUnseen = 0
    @Published var pulseSources: [String: [Int: Int]] = [:]
    @Published var pulseOpenRequest: PulseOpenRequest?
    @Published var pulseHomeChatID: String?
    /// Pulse's chat per dashboard as the last feed named it, kept across
    /// launches: until the feed is read again after a launch or a
    /// reconnect, the Pulse button and the hidden chat go by it. Views read
    /// it through `pulseHomeChat`, so every change goes through
    /// `storePulseHomes`, which tells them.
    private(set) lazy var pulseRememberedHomes: [String: String] =
        defaults.dictionary(forKey: Self.pulseHomesKey) as? [String: String] ?? [:]
    static let pulseHomesKey = "conduit.pulse.homeChats"
    /// The profile Pulse runs in per dashboard, as the last feed named it
    /// (`pulseHomeProfile`); none kept for a plugin that names none.
    private(set) lazy var pulseRememberedProfiles: [String: String] =
        defaults.dictionary(forKey: Self.pulseProfilesKey) as? [String: String] ?? [:]
    static let pulseProfilesKey = "conduit.pulse.homeProfiles"
    /// The bot whose Bot Chat Do it and Ask open for a Pulse card from no
    /// chat, per dashboard (`pulseDoItBot`); none for a new chat.
    private(set) lazy var pulseDoItBots: [String: String] =
        defaults.dictionary(forKey: Self.pulseDoItBotsKey) as? [String: String] ?? [:]
    static let pulseDoItBotsKey = "conduit.pulse.doItBots"

    /// Sets where Do it goes for a card from no chat on this dashboard:
    /// `bot`'s Bot Chat, or a new chat for nil.
    func setPulseDoItBot(_ bot: String?) {
        guard let key = activeDashboardID?.uuidString, pulseDoItBots[key] != bot else { return }
        var bots = pulseDoItBots
        bots[key] = bot
        storePulseDoItBots(bots)
    }

    private func storePulseDoItBots(_ bots: [String: String]) {
        objectWillChange.send()
        pulseDoItBots = bots
        defaults.set(bots, forKey: Self.pulseDoItBotsKey)
    }

    func rememberPulseHome(_ chat: String?, profile: String?) {
        guard let key = activeDashboardID?.uuidString else { return }
        if pulseRememberedProfiles[key] != profile {
            var profiles = pulseRememberedProfiles
            profiles[key] = profile
            storePulseProfiles(profiles)
        }
        guard pulseRememberedHomes[key] != chat else { return }
        var homes = pulseRememberedHomes
        homes[key] = chat
        storePulseHomes(homes)
    }

    /// A removed dashboard's Pulse chat goes with it.
    func forgetPulseHome(of dashboardID: UUID) {
        var bots = pulseDoItBots
        if bots.removeValue(forKey: dashboardID.uuidString) != nil { storePulseDoItBots(bots) }
        var profiles = pulseRememberedProfiles
        if profiles.removeValue(forKey: dashboardID.uuidString) != nil { storePulseProfiles(profiles) }
        var homes = pulseRememberedHomes
        guard homes.removeValue(forKey: dashboardID.uuidString) != nil else { return }
        storePulseHomes(homes)
    }

    /// Do it's New Chat, for a Pulse item from no chat (PulseFeed.swift):
    /// only when New Chat can start one at once, never one that waits. The
    /// chat is the one this call's own create opened, as createNewSession
    /// returns it, while it's still the one open: another create landing
    /// meanwhile (a call's chat, Ask Hermes About, a widget) opens a chat
    /// that isn't this one's. The Pulse screen stays up until it opened, so
    /// a chat that didn't start leaves it there to say why. Nil when none
    /// started.
    func startPulseNewChat() async -> String? {
        guard canStartNewChatNow, !isStartingNewChat, !showsPendingNewChat else { return nil }
        guard let created = await createNewSessionMarkingStart(), activeSessionId == created else { return nil }
        dismissSidebarDrawer()
        return created
    }

    /// Do it's switch to Pulse's profile, for a new chat there: whether it
    /// finished with that profile on screen. False when a newer navigation
    /// took the screen meanwhile, which a new chat mustn't replace.
    func switchProfileForPulse() async -> Bool {
        await switchProfile(to: pulseHomeProfile, reusing: nil)
    }

    private func storePulseHomes(_ homes: [String: String]) {
        objectWillChange.send()
        pulseRememberedHomes = homes
        defaults.set(homes, forKey: Self.pulseHomesKey)
    }

    private func storePulseProfiles(_ profiles: [String: String]) {
        objectWillChange.send()
        pulseRememberedProfiles = profiles
        defaults.set(profiles, forKey: Self.pulseProfilesKey)
    }

    /// Morning briefs folded on the Pulse screen, per dashboard: each
    /// brief's card id with the cards in it still open when it was folded,
    /// each with when it came (PulseLayout.Brief.isFolded), kept across
    /// launches, so a brief read and folded stays out of the way until it's
    /// opened again or a card in it comes back open. `pulseFoldedBriefsKept`
    /// briefs of each: the one just folded, and the others with the highest
    /// ids, which are the newest: the host numbers cards in the order it
    /// makes them.
    private(set) lazy var pulseFoldedBriefs: [String: [String: [String: Double]]] =
        defaults.dictionary(forKey: Self.pulseFoldedBriefsKey) as? [String: [String: [String: Double]]] ?? [:]
    static let pulseFoldedBriefsKey = "conduit.pulse.foldedBriefs"
    static let pulseFoldedBriefsKept = 30

    /// The cards `brief` had open when it was folded, by id, each with when
    /// it came; nil while it isn't folded.
    func pulseBriefFold(_ brief: Int) -> [Int: Double]? {
        guard let key = activeDashboardID?.uuidString,
              let open = pulseFoldedBriefs[key]?[String(brief)] else { return nil }
        let cards = open.compactMap { card, at in Int(card).map { ($0, at) } }
        return Dictionary(cards, uniquingKeysWith: { first, _ in first })
    }

    /// Folds `brief` with `open`, the cards in it still open then
    /// (PulseLayout.Brief.openCards), or opens it again (nil).
    func foldPulseBrief(_ brief: Int, open: [Int: Double]?) {
        guard let key = activeDashboardID?.uuidString else { return }
        var briefs = pulseFoldedBriefs[key] ?? [:]
        let noted = open.map { cards in Dictionary(uniqueKeysWithValues: cards.map { (String($0.key), $0.value) }) }
        guard briefs[String(brief)] != noted else { return }
        briefs[String(brief)] = noted
        // An older brief folded now stays folded: the oldest other fold goes.
        let others = briefs.keys.compactMap { Int($0) }.filter { $0 != brief }.sorted()
        let kept = Set(others.suffix(Self.pulseFoldedBriefsKept - 1)).union([brief])
        briefs = briefs.filter { id, _ in Int(id).map { kept.contains($0) } ?? false }
        var all = pulseFoldedBriefs
        all[key] = briefs.isEmpty ? nil : briefs
        storePulseFoldedBriefs(all)
    }

    /// `card`, in `brief`, put back open with Undo or Put back: the fold no
    /// longer counts it as open when it was folded, so a folded brief opens
    /// to show it, and folds again once it's handled.
    func unfoldPulseCard(_ card: Int, in brief: Int) {
        guard var open = pulseBriefFold(brief), open.removeValue(forKey: card) != nil else { return }
        foldPulseBrief(brief, open: open)
    }

    /// A removed dashboard's folded briefs go with it.
    private func forgetPulseFoldedBriefs(of dashboardID: UUID) {
        var all = pulseFoldedBriefs
        guard all.removeValue(forKey: dashboardID.uuidString) != nil else { return }
        storePulseFoldedBriefs(all)
    }

    private func storePulseFoldedBriefs(_ all: [String: [String: [String: Double]]]) {
        objectWillChange.send()
        pulseFoldedBriefs = all
        defaults.set(all, forKey: Self.pulseFoldedBriefsKey)
    }
    @Published var composerPrefillText = ""
    @Published var composerPrefillToken = UUID()
    /// The draft the prefill is for, until ComposerBar puts it in. A new
    /// chat's draft load can land in the same update as the prefill, so
    /// the composer waits until this draft is the one loaded. Set only by
    /// `prefillComposer`, with the text and then the token.
    var composerPrefillDraftKey: ComposerDraftKey?
    /// A quote waiting for the composer (#385). ComposerBar, which owns the
    /// draft, applies it and then consumes it.
    @Published var composerQuoteRequest: ComposerQuoteRequest?
    /// A "Replying to" card's tap (issue 1420): the chat or room on screen
    /// scrolls to the reply it quoted, then clears it.
    @Published var pendingQuotedReplyJump: QuotedReplyJump?
    /// The same for the open group room's composer, kept apart so a chat's
    /// composer never takes a quote meant for a room.
    @Published var roomQuoteRequest: ComposerQuoteRequest?
    /// Files dropped on the open chat (#1408), waiting for its composer to
    /// stage them, and the same for the open room's composer.
    @Published var composerDropRequest: AttachmentDropRequest?
    @Published var roomDropRequest: AttachmentDropRequest?
    /// Words added to a room's kept draft from outside its composer (a
    /// dictation Retry). The open room's composer adds them to its field.
    @Published var roomDraftAppend: RoomDraftAppend?
    struct RoomDraftAppend: Equatable {
        let id = UUID()
        let dashboardID: UUID
        let roomID: String
        let words: String
    }
    /// A bot to add to the room composer's "To" row (its picture tapped, or
    /// its message replied to). The room composer applies and consumes it.
    @Published var roomRecipientRequest: RoomRecipientRequest?
    /// Asks the composer to take focus (a screenshot chat opened with the
    /// keyboard). ComposerBar focuses and then consumes it.
    @Published var composerFocusRequest: ComposerFocusRequest?
    /// Asks the open chat's composer to start dictating (its big button
    /// set to Dictation, or Dictate in the button's menu). ComposerBar
    /// starts and then consumes it.
    @Published var composerDictationRequest: ComposerDictationRequest?

    // MARK: - Sending while connecting (AppState+PendingSend.swift)

    /// A message sent before its chat was ready (#417): it shows in that
    /// chat as "Sends when connected" and goes once the chat is ready. Its
    /// file beside the dashboard's saved chats brings it back as a draft
    /// if Conduit stops first.
    @Published var pendingComposerSend: PendingComposerSend?
    /// Words the composer puts back: a waiting message taken back to edit,
    /// or one its chat never took. ComposerBar applies each, then consumes it.
    @Published var composerRestoreRequests: [ComposerRestoreRequest] = []
    /// A composer send still checking Hermes before its message shows: the
    /// composer says it's sending meanwhile (#1401).
    @Published var composerSendChecks: [ComposerSendCheck] = []
    /// Sends whose chat was left while their reply was lost: Hermes may
    /// have them, so their words come back without an "unsent" notice.
    var composerSubmissionsOfUnknownDelivery: [ComposerSubmissionContext] = []
    /// Why a waiting message went back to a draft, until it's dismissed or
    /// the composer is used.
    @Published var composerNotice: String? {
        didSet {
            // Each notice says what it is; a new one starts as a waiting
            // message's until its writer says otherwise.
            if composerNotice != oldValue { composerNoticeSystemImage = Self.composerReturnNoticeSystemImage }
        }
    }
    /// The symbol beside the notice: a message that came back, or a draft
    /// shared from another app (AppState+ShareDraft.swift).
    @Published var composerNoticeSystemImage = AppState.composerReturnNoticeSystemImage
    static let composerReturnNoticeSystemImage = "arrow.uturn.backward.circle"
    /// The chat Conduit last created, while it's the one open: it takes the
    /// New Chat draft and a message that waited for it.
    var newChatOpenedSessionID: String? {
        didSet {
            if newChatOpenedSessionID == nil { newChatOpenedDurableSessionID = nil }
        }
    }
    var newChatOpenedDurableSessionID: String?
    /// The ids of an empty chat Hermes lost and of the fresh chat Conduit
    /// opened in its place (replaceLostEmptyNewChat): a draft typed in the
    /// lost one is the fresh one's, as the New Chat draft is its chat's.
    var lostChatReplacement: (lost: Set<String>, fresh: Set<String>)?
    var pendingComposerSendCheckScheduled = false
    /// A waiting message whose chat is ready but still settling is looked
    /// at again shortly: not all of that settling is published.
    var pendingComposerSendRecheckTask: Task<Void, Never>?
    /// Waiting messages handed to the normal send and not back yet. Their
    /// files stay until it goes, so a switch back to their dashboard
    /// mustn't restore them meanwhile.
    var deliveringPendingComposerSendIDs: Set<UUID> = []
    /// New Chats creating their chat right now: the transcript on screen
    /// until then is the one being left, so the composer doesn't wait on it.
    var newSessionCreationsInFlight = 0

    // MARK: - Ask Hermes About Screen (AppState+ScreenQuestion.swift)

    /// Screenshots waiting on their chat for the next question sent there.
    @Published var pendingScreenshots: [PendingScreenshot] = []
    /// A screenshot kept while Hermes was unreachable, attached once it
    /// connects.
    var parkedScreenQuestion: ParkedScreenQuestion?
    @Published var parkedScreenQuestionRevision: UInt64 = 0
    /// The one waiter that attaches the parked screenshot once Conduit
    /// settles; it clears itself when it ends.
    var parkedScreenQuestionResumeTask: Task<Void, Never>?
    /// A wake-up found that waiter busy: it takes one more pass.
    var parkedScreenQuestionNeedsAnotherPass = false
    /// When the phone scene last left the foreground: the screenshot
    /// action's recent-chat rule measures from it.
    var lastLeftForegroundAt: Date?
    /// Where the last cold launch, return or reconnect spent its time,
    /// shown in Gateway Diagnostics (#417). Deliberately not @Published:
    /// recording a step must not re-render every AppState observer in the
    /// middle of the very launch it measures. The sheet reads it when shown.
    var connectionTimeline: ConnectionTimeline?
    /// When the newest screenshot routed or parked was taken: an older one
    /// superseded by it is dropped.
    var newestScreenQuestionAt: Date?
    /// When the phone scene last came on screen: a screenshot taken a
    /// while after that was taken in Conduit.
    var sceneActiveSince: Date?
    /// `isSceneActive` starts true before any scene event, so a launch
    /// that never reached the foreground does not count as leaving it.
    var sceneHasBeenActive = false

    // MARK: - Capabilities

    @Published var slashCommands: [SlashCommand] = AppState.builtInSlashCommands
    /// Hermes' argument words for each command (`commands.catalog` `sub`),
    /// by command name: `fast` → normal, fast, ultrafast, …
    @Published var slashSubcommands: [String: [String]] = AppState.conduitSlashSubcommands
    @Published var skills: [CapabilitySkill] = []
    @Published var toolsets: [CapabilityToolset] = []
    /// The active profile's tools catalog, for step rows (`ChatStepLabel`).
    @Published private(set) var toolCatalog = ToolCatalog()
    /// A short summary per finished run of steps: by dashboard and profile
    /// (`toolCatalogKey`), then by the run's first tool call
    /// (AppState+StepSummaries.swift).
    @Published var stepSummaries: [String: [String: String]] = ChatStepSummaries.saved()
    /// Summary questions Hermes accepted, by btw task id, to their run.
    var stepSummaryTasks: [String: ChatStepSummaries.Run] = [:]
    /// Summary questions sent whose task id hasn't come back yet.
    var stepSummaryUnclaimed = 0
    /// Answers that came before their question's task id did; cleared
    /// once no question is waiting for its id.
    var stepSummaryEarlyAnswers: [String: String] = [:]
    /// Runs asked about and not answered yet, with when they were asked.
    @Published var stepSummaryRequested: [ChatStepSummaries.Run: Date] = [:]
    /// Test seam: answers `POST /side-question` in place of the dashboard.
    var stepSummarySender: (([String: Any]) async throws -> [String: Any])?
    /// The suggestion row's guesses (AppState+Predictive.swift).
    let predictive = PredictiveStore()
    /// The open chat's queue on the session authority: messages waiting
    /// their turn and turns a restart cut off (AppState+AuthorityQueue.swift).
    let authorityQueue = AuthorityQueueStore()
    /// The user's own messages the authority queued, by their admission id
    /// (the receipt's, which their queue row and their turn's start name):
    /// their bubble waits in the dock above the composer and comes back to
    /// the transcript when their turn starts. The newest few are kept.
    var queuedSendRows: [String: ChatMessage] = [:]
    var queuedSendOrder: [String] = []
    /// The user's sends the authority took as a new turn, by admission id,
    /// with their bubble's id: one Hermes then lists as waiting behind
    /// another client's turn moves to the dock too. Cleared when it starts.
    var ownSendRowIDs: [String: String] = [:]
    /// Admissions whose turn this socket saw start, so a reply that comes
    /// after its start never holds that bubble back.
    var startedAdmissionIDs: Set<String> = []
    /// For a started admission whose bubble wasn't held yet: the row its
    /// turn began after (nil, an empty transcript), so a late bubble goes
    /// above its reply.
    var startedAdmissionAnchors: [String: String?] = [:]
    /// What the row asks the composer to do: send, edit or insert a guess.
    @Published var predictiveComposerRequest: PredictiveComposerRequest?
    /// The reply suggested replies were last asked for (asked once each).
    var predictiveRepliesAsked: PredictiveStore.Anchor?
    /// The draft last asked about, and the wait for the next pause.
    var predictiveDraftAsked: (sessionID: String, draft: String)?
    var predictivePauseTask: Task<Void, Never>?
    /// The follow-up checks for the reply on screen, and the next one.
    var predictiveFollowUp = PredictiveFollowUpState()
    var predictiveFollowUpTask: Task<Void, Never>?
    /// The hidden turn sent for Hermes to follow up, until it settles.
    /// `after` is the chat's last row when it was sent: only a reply
    /// after it is the follow-up's.
    var predictiveFollowUpTurn: (sessionID: String, why: String, after: String?)?
    /// Advanced by forgetPredictiveState: an answer asked before it is
    /// dropped, whatever is on screen when it comes.
    var predictiveGeneration = 0
    /// The hidden turn was queued behind a turn already running (another
    /// client's): the next turn to end is that one, not the follow-up.
    var predictiveFollowUpQueued = false
    /// The hidden prompt is on its way and Hermes hasn't said how it took
    /// it: a turn ending meanwhile is the one ahead, not the follow-up.
    var predictiveFollowUpSending = false
    /// A turn ended while the hidden prompt was on its way: when it comes
    /// back queued, it was queued behind that one.
    var predictiveFollowUpAheadEnded = false
    /// Turns of messages sent before the hidden prompt was queued that
    /// ran ahead of it, so a reply Conduit never sees end is stopped
    /// waiting for.
    var predictiveFollowUpTurnsAhead = 0
    /// When the hidden prompt was sent, if Hermes queued it: only a message
    /// sent before then can run ahead of it.
    var predictiveFollowUpQueuedAt: Date?
    /// Row ids of messages other clients sent while the follow-up waits;
    /// a reply ending before one is read can't be told apart.
    var predictiveFollowUpUnreadMessages: Set<Int> = []
    /// Bumped by each follow-up sent and each stop: a send that returns
    /// after either leaves the follow-up waiting now as it is.
    var predictiveFollowUpSend = 0
    /// When the last reply settled here, so a follow-up check can say how
    /// long ago without reading timestamps.
    var predictiveReplyEnded: (anchor: PredictiveStore.Anchor, at: Date)?
    /// Test seam: answers `POST /predict` in place of the dashboard.
    var predictiveSender: (([String: Any]) async throws -> [String: Any])?
    /// Whose catalog `toolCatalog` is (dashboard and profile), and the
    /// catalogs Hermes already sent this run, or is sending now.
    private var toolCatalogOwner: String?
    private var toolCatalogFetched: Set<String> = []
    private var toolCatalogLoading: Set<String> = []
    /// The dashboard, bridge and profile the installed skills/toolsets were
    /// read from. Rows are only presentable, and their switches only act,
    /// while this equals `currentCapabilitiesOwner`: two dashboards can have
    /// a profile of the same name.
    @Published private(set) var capabilitiesOwner: CapabilitySnapshotOwner?
    /// The installed skills and toolsets shown are the ones kept from
    /// Hermes' last answer (#1533), drawn until it answers again.
    @Published private(set) var capabilitiesAreKept = false
    /// Switches write through the dashboard: offline, with only the kept
    /// lists to show, they wait for it instead of flipping back unsaid.
    var canChangeCapabilities: Bool { dashboardTicketBridge != nil }
    /// Monotonic request token for capability loads; older requests can never
    /// commit over newer ones (protects the A -> B -> A race).
    private var capabilityLoadGeneration: UInt64 = 0
    /// Skill and toolset switches, written in the order flipped.
    private let capabilityToggleWrites = CapabilityToggleWrites()
    @Published var mcpServers: [CapabilityMcpServer] = []
    @Published var voiceCapabilitySnapshot = VoiceCapabilitySnapshot.unavailable
    @Published var isVoiceEnabled = false
    @Published var voiceTranscriptionMode: VoiceTranscriptionMode = .hermes
    /// The active profile's saved choice of who speaks Classic voice
    /// replies; nil is automatic (`voiceSpeechOutput`).
    @Published var voiceSpeechOutputChoice: VoiceSpeechOutput?
    @Published var continuousConversationEnabled = true
    /// "Keep listening when locked" for the active profile.
    @Published var keepVoiceListeningWhenLocked = false
    /// Push to talk in Classic voice (#886), for the active profile.
    @Published var voicePushToTalkEnabled = false
    /// The active profile's own choice for the big button beside a chat's
    /// composer (`ChatVoiceButtonAction` raw value); nil follows the app's.
    @Published var chatVoiceButtonOverride: String?
    @Published var appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()

    var voiceAssistantObserverID: UUID?

    // MARK: Gemini Live voice mode

    /// Presents the Gemini Live sheet. Separate from `showVoiceSheet`: the
    /// two voice modes never run at once.
    @Published var showGeminiLiveSheet = false
    @Published var showQwenLiveSheet = false

    /// Gemini wins when a merged blob has both on, as configuredLiveVoiceEngine reads it.
    var isQwenLiveEnabled: Bool {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        return preferences.qwenLiveEnabled && !preferences.geminiLiveEnabled
    }
    /// A live mode whose provider still needs the user's OK after a call
    /// the phone wasn't showing (CarPlay, the Watch) stopped on it (#827):
    /// the phone asks on its own sheet.
    @Published var liveVoiceConsentRequest: LiveVoiceModeName?

    /// Gemini Live is an opt-in, per-profile Voice mode (off by default).
    var isGeminiLiveEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLiveEnabled
    }

    /// Voice-job model and reasoning (nil = the profile's defaults).
    func setVoiceJobModel(provider: String?, model: String?, reasoningEffort: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        preferences.voiceJobProvider = model == nil ? nil : provider
        preferences.voiceJobModel = model
        preferences.voiceJobReasoningEffort = reasoningEffort
        objectWillChange.send()
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The models Hermes offers, for the model pickers (the model sheet,
    /// the bot editor's, Voice and Pulse settings'): the gateway's
    /// `model.options`, kept on the phone as the same answer Usage keeps
    /// (#1533). The model sheet asks for its chat's session. Nil when
    /// Hermes didn't answer, so a picker keeps the models it shows.
    /// `refresh` is Refresh models: Hermes fetches every provider's live
    /// list first (issue 1807).
    func loadModelProviders(sessionId: String? = nil, refresh: Bool = false) async -> [ProviderInfo]? {
        let profile = activeProfile
        guard let client else { return nil }
        let read = { try await client.modelOptionsAnswer(sessionId: sessionId, refresh: refresh) }
        let answer: [String: Any]?
        if let owner = currentDashboardRuntimeOwner() {
            answer = try? await keepingAnswer(profile: profile, owner: owner, keptAs: { _ in KeptRoute.providerQuotas }, read)
        } else {
            answer = try? await read()
        }
        guard let answer, profile == activeProfile else { return nil }
        return Self.modelProviders(in: answer)
    }

    /// Those models as last read, kept on the phone, for the pickers to
    /// open on.
    func keptModelProviders() -> [ProviderInfo] {
        keptAnswer(KeptRoute.providerQuotas).map(Self.modelProviders(in:)) ?? []
    }

    /// The models Hermes offers in `profile`, which may not be the one
    /// open: Settings > Pulse's, for the profile Pulse runs in, where its
    /// model is set (issue 1681). Another profile's come from the
    /// dashboard's route for it, kept as the Model page keeps them. Nil when
    /// Hermes didn't answer, or the dashboard changed meanwhile.
    func loadModelProviders(inProfile profile: String) async -> [ProviderInfo]? {
        if profilesMatch(profile, activeProfile) { return await loadModelProviders() }
        guard let owner = currentDashboardRuntimeOwner(),
              let answer = try? await readKeepingAnswer(KeptRoute.modelOptions, profile: profile, owner: owner),
              ownsDashboardRuntime(owner) else { return nil }
        return Self.modelProviders(in: answer)
    }

    /// `profile`'s models as last read, kept on the phone.
    func keptModelProviders(inProfile profile: String) -> [ProviderInfo] {
        if profilesMatch(profile, activeProfile) { return keptModelProviders() }
        return keptAnswer(KeptRoute.modelOptions, profile: profile).map(Self.modelProviders(in:)) ?? []
    }

    /// The providers of a `model.options` answer.
    static func modelProviders(in answer: [String: Any]) -> [ProviderInfo] {
        (AnyCodable.from(answer).objectValue?["providers"]?.arrayValue ?? []).compactMap(ProviderInfo.init(from:))
    }

    /// Hermes' voice reply model (`auxiliary.voice_chat`) for this profile,
    /// or nil when this Hermes has no such slot; it throws when Hermes
    /// didn't answer. The answer is kept for the section to open on (#1533).
    func loadVoiceReplyModel() async throws -> VoiceReplyModelSetting? {
        try await loadHelperModel(task: VoiceReplyModelSetting.task)
    }

    /// The voice reply model as Hermes gave it last, kept on the phone.
    func keptVoiceReplyModel() -> VoiceReplyModelSetting? {
        keptHelperModel(task: VoiceReplyModelSetting.task)
    }

    /// Hermes' helper model slots (`/api/model/auxiliary`) for this
    /// profile, as Models & providers lists them; throws when Hermes didn't
    /// answer. Kept, with Voice replies' read, for the page to open on.
    func loadHelperModels() async throws -> [HelperModelSlot] {
        HelperModelSlot.slots(in: try await readHelperModels())
    }

    /// The helper models as Hermes gave them last, kept on the phone;
    /// Pulse's too with `includingSetElsewhere`.
    func keptHelperModels(includingSetElsewhere: Bool = false) -> [HelperModelSlot]? {
        keptAnswer(KeptRoute.modelAuxiliary).map { HelperModelSlot.slots(in: $0, includingSetElsewhere: includingSetElsewhere) }
    }

    /// One helper model slot, or nil when this Hermes has no such slot.
    func loadHelperModel(task: String) async throws -> VoiceReplyModelSetting? {
        VoiceReplyModelSetting(auxiliaryResponse: try await readHelperModels(), task: task)
    }

    func keptHelperModel(task: String) -> VoiceReplyModelSetting? {
        keptAnswer(KeptRoute.modelAuxiliary).flatMap { VoiceReplyModelSetting(auxiliaryResponse: $0, task: task) }
    }

    /// Whether the kept helper models list the slot, or nil when none are
    /// kept.
    func keptHelperModelListed(task: String) -> Bool? {
        keptAnswer(KeptRoute.modelAuxiliary).map { VoiceReplyModelSetting(auxiliaryResponse: $0, task: task) != nil }
    }

    /// `profile`'s helper model slots, which may not be the open profile's:
    /// Edit Bot > Work sets its bot's work watch there. The open profile's
    /// share its read; another's come from the dashboard's route for it,
    /// kept as Models & providers keeps them.
    func loadHelperModels(inProfile profile: String) async throws -> [HelperModelSlot] {
        HelperModelSlot.slots(in: try await readHelperModels(inProfile: profile))
    }

    func keptHelperModels(inProfile profile: String) -> [HelperModelSlot]? {
        if profilesMatch(profile, activeProfile) { return keptHelperModels() }
        return keptAnswer(KeptRoute.modelAuxiliary, profile: profile).map { HelperModelSlot.slots(in: $0) }
    }

    func loadHelperModel(task: String, inProfile profile: String) async throws -> VoiceReplyModelSetting? {
        VoiceReplyModelSetting(auxiliaryResponse: try await readHelperModels(inProfile: profile), task: task)
    }

    func keptHelperModel(task: String, inProfile profile: String) -> VoiceReplyModelSetting? {
        if profilesMatch(profile, activeProfile) { return keptHelperModel(task: task) }
        return keptAnswer(KeptRoute.modelAuxiliary, profile: profile).flatMap { VoiceReplyModelSetting(auxiliaryResponse: $0, task: task) }
    }

    private func readHelperModels(inProfile profile: String) async throws -> [String: Any] {
        if profilesMatch(profile, activeProfile) { return try await readHelperModels() }
        guard let owner = currentDashboardRuntimeOwner() else { throw DashboardTicketBridgeError.notReady }
        let answer = try await readKeepingAnswer(KeptRoute.modelAuxiliary, profile: profile, owner: owner)
        guard ownsDashboardRuntime(owner) else { throw CancellationError() }
        return answer
    }

    /// Hermes' `/api/model/auxiliary` answer, carried from the read to
    /// every reader sharing it.
    private struct HelperModelsAnswer: @unchecked Sendable { let json: [String: Any] }

    /// The helper models read in flight. A reader asking meanwhile on the
    /// same profile and Hermes shares it: the Model page and its Helper
    /// models section open together. A save in its profile drops it, so a
    /// read asked after the save isn't answered from before it; another
    /// profile's save (the work watch's) leaves it under way. A reader that leaves
    /// doesn't cancel it: the next one joins it, and the bridge's request
    /// timeout ends one Hermes never answers.
    private var helperModelsRead: (profile: String, owner: DashboardRuntimeOwner, task: Task<HelperModelsAnswer, Error>)?

    private func readHelperModels() async throws -> [String: Any] {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { throw DashboardTicketBridgeError.notReady }
        let task: Task<HelperModelsAnswer, Error>
        if let read = helperModelsRead, profilesMatch(read.profile, profile), ownsDashboardRuntime(read.owner) {
            task = read.task
        } else {
            task = Task { [self] in
                HelperModelsAnswer(json: try await readKeepingAnswer(KeptRoute.modelAuxiliary, profile: profile, owner: owner))
            }
            helperModelsRead = (profile, owner, task)
        }
        let result = await task.result
        if helperModelsRead?.task == task { helperModelsRead = nil }
        guard profilesMatch(profile, activeProfile) else { throw CancellationError() }
        return try result.get().json
    }

    /// A live voice mode's status line on Voice settings as its last check
    /// said (GPT-Live's, the billing's on screen), kept on the phone so the
    /// line opens on it (#1533).
    func keptLiveVoiceStatus(_ mode: LiveVoiceModeName) -> LiveVoiceStatusLine? {
        keptAnswer(Self.liveVoiceStatusRoute(mode, billing: gptLiveBilling)).flatMap(LiveVoiceStatusLine.init(answer:))
    }

    /// Keeps what a check of `mode` said, for the dashboard and profile
    /// Voice settings showed when this was made; nothing once another
    /// dashboard took over, or after a wipe. GPT-Live's checks keep through
    /// gptLiveStatusKeeper.
    func liveVoiceStatusKeeper(_ mode: LiveVoiceModeName) -> (LiveVoiceStatusLine) -> Void {
        let keep = statusLineKeeper()
        let route = Self.liveVoiceStatusRoute(mode, billing: gptLiveBilling)
        return { keep($0, route) }
    }

    /// GPT-Live's, under the billing its check asked about: the billing can
    /// change while a check is out.
    func gptLiveStatusKeeper() -> (LiveVoiceStatusLine, GPTLiveBilling) -> Void {
        let keep = statusLineKeeper()
        return { keep($0, Self.liveVoiceStatusRoute(.gptLive, billing: $1)) }
    }

    private func statusLineKeeper() -> (LiveVoiceStatusLine, String) -> Void {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return { _, _ in } }
        let removals = offlineChatCache.removals
        return { [weak self] line, route in
            guard let self else { return }
            // A check's line is kept as a read's answer is, the last to land.
            self.keepAnswer(
                line.answer, for: route, profile: profile, owner: owner, removals: removals,
                turn: self.nextKeptAnswerTurn(), writes: false
            )
        }
    }

    /// GPT-Live's per billing, as each checks another sign-in.
    private static func liveVoiceStatusRoute(_ mode: LiveVoiceModeName, billing: GPTLiveBilling) -> String {
        KeptRoute.liveVoiceStatus + (mode == .gptLive ? "\(mode.storageID)/\(billing.rawValue)" : mode.storageID)
    }

    /// How Hermes took the voice reply model, for the section to show
    /// beside the pickers (#1533). `confirmed` answers Hermes' price check.
    func setVoiceReplyModel(_ setting: VoiceReplyModelSetting, confirmed: Bool = false) async -> HelperModelSaveResult {
        await setHelperModel(
            setting, confirmed: confirmed,
            offline: AppLocalization.string("Connect to Hermes to configure voice for this profile."),
            failure: { AppLocalization.string("Could not save the voice reply model: \($0)") }
        )
    }

    /// Writes a helper model slot (Models & providers > Helper models), in
    /// `profile` when given (Edit Bot > Work's work watch, for its bot).
    func setHelperModel(_ setting: VoiceReplyModelSetting, confirmed: Bool, profile: String? = nil) async -> HelperModelSaveResult {
        await setHelperModel(
            setting, confirmed: confirmed, profile: profile,
            offline: AppLocalization.string("Connect to Hermes to change this profile's models."),
            failure: { AppLocalization.string("Could not save the helper model: \($0)") }
        )
    }

    private func setHelperModel(
        _ setting: VoiceReplyModelSetting, confirmed: Bool, profile: String? = nil, offline: String, failure: (String) -> String
    ) async -> HelperModelSaveResult {
        let profile = profile ?? activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return .refused(offline) }
        let dashboardTicketBridge = owner.bridge
        do {
            // Hermes writes the profile config for it: in turn with every
            // other config save.
            let result = try await ProfileConfigWriteQueue.runThrowing { [self] in
                try await dashboardTicketBridge.requestJSON(
                    path: dashboardPath("/api/model/set", profile: profile),
                    method: "POST",
                    body: setting.assignmentBody(profile: profile, confirmed: confirmed)
                )
            }
            if result["confirm_required"] as? Bool == true {
                return .needsConfirmation(
                    result["confirm_message"] as? String ?? AppLocalization.string("Hermes requires confirmation before using this model.")
                )
            }
            // The kept slots take the save at once, so the pages open on
            // it even if the read after it never lands, and an answer to a
            // read asked before it isn't kept over it (#1533).
            keepHelperModelWrite(setting, profile: profile, owner: owner)
            // A save drops the read of the profile it saved, even one that
            // isn't open now (a switch leaves a read under way); another
            // profile's save (Edit Bot > Work's work watch) leaves it alone.
            if let read = helperModelsRead, profilesMatch(read.profile, profile) { helperModelsRead = nil }
            // An open list's read asked before the save is dropped for one
            // asked after it.
            NotificationCenter.default.post(name: HelperModelSlot.saved, object: nil)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return .saved }
            // The shared read, so the open lists' reads after the save
            // join it.
            Task { [weak self] in
                _ = try? await self?.readHelperModels()
            }
            return .saved
        } catch {
            return .refused(failure(UserFacingError.message(for: error)))
        }
    }

    /// The kept `/api/model/auxiliary` answer with `setting`'s slot as
    /// Hermes took it; with nothing kept, the write is still counted.
    private func keepHelperModelWrite(_ setting: VoiceReplyModelSetting, profile: String, owner: DashboardRuntimeOwner) {
        guard var answer = keptAnswer(KeptRoute.modelAuxiliary, profile: profile, on: owner),
              var tasks = answer["tasks"] as? [[String: Any]],
              let index = tasks.firstIndex(where: { $0["task"] as? String == setting.task }) else {
            noteKeptAnswerWrite(for: KeptRoute.modelAuxiliary, profile: profile, owner: owner)
            return
        }
        var row = tasks[index]
        row["provider"] = setting.provider.isEmpty ? "auto" : setting.provider
        row["model"] = setting.model
        row["reasoning_effort"] = setting.reasoningEffort ?? ""
        // Hermes kept the endpoint (a save never sends one); the kept row
        // keeps the one it had, as Hermes answered.
        if setting.baseURL == nil { row["base_url"] = "" }
        tasks[index] = row
        answer["tasks"] = tasks
        keepWrittenAnswer(answer, for: KeptRoute.modelAuxiliary, profile: profile, owner: owner, removals: offlineChatCache.removals)
    }

    /// Where Gemini Live's quick lookups search on this profile.
    var geminiLiveSearchMode: GeminiLiveSearchMode {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLiveSearch ?? .automatic
    }

    /// Applies from the next Gemini Live conversation.
    func setGeminiLiveSearchMode(_ mode: GeminiLiveSearchMode) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: GeminiLiveSearchMode? = mode == .automatic ? nil : mode
        guard preferences.geminiLiveSearch != stored else { return }
        objectWillChange.send()
        preferences.geminiLiveSearch = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The prebuilt voice Gemini Live speaks with on this profile; nil is
    /// Gemini's default voice.
    var geminiLiveVoice: String? {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLiveVoice
    }

    /// Applies from the next Gemini Live conversation.
    func setGeminiLiveVoice(_ voice: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored = voice.flatMap { $0.isEmpty ? nil : $0 }
        guard preferences.geminiLiveVoice != stored else { return }
        objectWillChange.send()
        preferences.geminiLiveVoice = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The search the next Gemini Live session uses, resolved when it
    /// starts (automatic asks the host whether it has a search backend).
    var geminiLiveSearchSource: GeminiLiveSearchSource = .google

    /// Whether Gemini Live gets the Hermes host's memory on this profile.
    /// Off until the user turns it on: it sends that memory to Google.
    var geminiLiveMemoryEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLiveMemory ?? false
    }

    /// Applies from the next Gemini Live conversation.
    func setGeminiLiveMemoryEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.geminiLiveMemory != stored else { return }
        objectWillChange.send()
        preferences.geminiLiveMemory = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether Gemini Live speaks as the profile's SOUL.md persona. Off
    /// until the user turns it on: it sends SOUL.md to Google.
    var geminiLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLivePersonality ?? false
    }

    /// Applies from the next Gemini Live conversation.
    func setGeminiLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.geminiLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.geminiLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The profile's persona for the next Gemini Live session.
    private var geminiLivePersonality: String?
    /// The host's memory for the next Gemini Live session, read when it
    /// starts so it reflects what Hermes has learned since the last one.
    private var geminiLiveMemoryContext: GeminiLiveMemoryContext?
    /// Where Qwen Live's quick lookups search on this profile.
    var qwenLiveSearchMode: GeminiLiveSearchMode {
        loadVoiceProfilePreferences(profile: activeProfile).qwenLiveSearch ?? .automatic
    }

    /// Applies from the next Qwen Live conversation.
    func setQwenLiveSearchMode(_ mode: GeminiLiveSearchMode) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: GeminiLiveSearchMode? = mode == .automatic ? nil : mode
        guard preferences.qwenLiveSearch != stored else { return }
        objectWillChange.send()
        preferences.qwenLiveSearch = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The prebuilt voice Qwen Live speaks with on this profile; nil is
    /// Qwen's default voice.
    var qwenLiveVoice: String? {
        loadVoiceProfilePreferences(profile: activeProfile).qwenLiveVoice
    }

    /// Applies from the next Qwen Live conversation.
    func setQwenLiveVoice(_ voice: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored = voice.flatMap { $0.isEmpty ? nil : $0 }
        guard preferences.qwenLiveVoice != stored else { return }
        objectWillChange.send()
        preferences.qwenLiveVoice = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The search the next Qwen Live session uses, resolved when it
    /// starts (automatic asks the host whether it has a search backend).
    var qwenLiveSearchSource: GeminiLiveSearchSource = .none

    /// Whether Qwen Live gets the Hermes host's memory on this profile.
    /// Off until the user turns it on: it sends that memory to Alibaba Cloud.
    var qwenLiveMemoryEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).qwenLiveMemory ?? false
    }

    /// Applies from the next Qwen Live conversation.
    func setQwenLiveMemoryEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.qwenLiveMemory != stored else { return }
        objectWillChange.send()
        preferences.qwenLiveMemory = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether Qwen Live speaks as the profile's SOUL.md persona. Off
    /// until the user turns it on: it sends SOUL.md to Alibaba Cloud.
    var qwenLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).qwenLivePersonality ?? false
    }

    /// Applies from the next Qwen Live conversation.
    func setQwenLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.qwenLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.qwenLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The profile's persona for the next Qwen Live session.
    private var qwenLivePersonality: String?
    /// The host's memory for the next Qwen Live session, read when it
    /// starts so it reflects what Hermes has learned since the last one.
    private var qwenLiveMemoryContext: GeminiLiveMemoryContext?
    /// The transcript `submitVoiceTranscript` is submitting, while it is.
    var spokenSubmissionText: String?
    /// The phone's change cards waiting when the user last sent words; nil
    /// until they first do in this run. Classic voice's yes answers only a
    /// card asked for since (`noteUserWordsSent`).
    var phoneChangesWaitingAtLastWords: Set<String>?
    /// Where a caller of `submitComposer` says `text` came from (a Shortcut,
    /// a live call's request), for the plugin's report (#888). Keyed by the
    /// text like `spokenSubmissionText`, so a typed send interleaving on
    /// another text never takes it.
    var submissionTurnSurface: (text: String, surface: TurnSurface)?
    /// Seam for tests: takes the plugin's turn-surface reports.
    var turnSurfaceSender: (([String: Any]) async throws -> Void)?
    /// Seam for tests: takes the discards of failed sends' reports.
    var turnSurfaceDiscarder: (([String: Any]) async throws -> Void)?
    /// Tests: the pauses before a failed discard is tried again.
    var turnSurfaceDiscardRetryDelays: [Duration]?
    /// What the host holds as on screen for this device (ChatOnScreen.swift).
    var chatOnScreenTracker = ChatOnScreen.Tracker()
    /// Renews the hold while the open chat's turn runs.
    var chatOnScreenRenewal: Task<Void, Never>?
    /// The last on-screen report, which the next one goes after.
    var chatOnScreenLastSend: Task<Void, Never>?
    /// When the last hold sent runs out on the host; nil once let go.
    var chatOnScreenHoldEnds: Date?
    /// Seam for tests: takes the on-screen reports (path, body).
    var chatOnScreenSender: ((String, [String: Any]) async throws -> Void)?

    private func resolveGeminiLiveSearchSource() async -> GeminiLiveSearchSource {
        let mode = geminiLiveSearchMode
        let hermesAvailable = mode == .automatic ? await geminiLiveTokenClient.webSearchAvailable() : false
        return mode.resolved(hermesAvailable: hermesAvailable)
    }

    private func resolveQwenLiveSearchSource() async -> GeminiLiveSearchSource {
        guard qwenLiveSearchMode != .off else { return .none }
        return await qwenLiveTokenClient.webSearchAvailable() ? .hermes : .none
    }

    /// A live mode turned on (Settings > Voice, an agent's config write)
    /// while a classic conversation runs ends that conversation, as a mode
    /// switch from the call's menu or a live start from the car does.
    /// Otherwise the car followed the new mode while the classic call went
    /// on listening behind it, on no surface that showed or ended it (#1935).
    /// A call screen under push to talk waiting for its first press counts
    /// too: it has no session yet, and its press would open Classic's mic.
    private func closeClassicConversationForLiveMode() {
        let waitsForFirstPress = showVoiceSheet && voiceConversationController.isPushToTalkActive
        guard voiceConversationController.hasConversationSession || waitsForFirstPress else { return }
        closeVoiceConversation()
    }

    func setGeminiLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.geminiLiveEnabled != enabled else { return }
        objectWillChange.send()
        preferences.geminiLiveEnabled = enabled
        // One live voice engine per profile: turning Gemini on turns the others off.
        if enabled {
            preferences.qwenLiveEnabled = false
            preferences.gptLiveEnabled = false
            preferences.grokLiveEnabled = false
            preferences.localLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            closeClassicConversationForLiveMode()
            closeQwenLiveConversation()
            closeGPTLiveConversation()
            closeGrokLiveConversation()
            closeLocalLiveConversation()
        } else {
            closeGeminiLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    func setQwenLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.qwenLiveEnabled != enabled || (enabled && (preferences.geminiLiveEnabled || preferences.gptLiveEnabled || preferences.grokLiveEnabled || preferences.localLiveEnabled)) else { return }
        objectWillChange.send()
        preferences.qwenLiveEnabled = enabled
        // One live voice engine per profile: turning Qwen on turns the others off.
        if enabled {
            preferences.geminiLiveEnabled = false
            preferences.gptLiveEnabled = false
            preferences.grokLiveEnabled = false
            preferences.localLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            closeClassicConversationForLiveMode()
            closeGeminiLiveConversation()
            closeGPTLiveConversation()
            closeGrokLiveConversation()
            closeLocalLiveConversation()
        } else {
            closeQwenLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// Hermes-hosted Gemini Live credentials (the conduit_push plugin), read
    /// through whichever dashboard bridge is current at call time.
    lazy var geminiLiveTokenClient = makeLiveTokenClient(provider: .gemini) { [weak self] in
        self?.activeProfile ?? "default"
    }

    lazy var qwenLiveTokenClient = makeLiveTokenClient(provider: .qwen) { [weak self] in
        self?.activeProfile ?? "default"
    }

    /// Gemini or Qwen Live's host routes for `profile`: the active
    /// profile's for the phone's calls, a Watch call's own profile for the
    /// Watch's, which may not be the one the iPhone is on (#1564).
    func makeLiveTokenClient(provider: DirectLiveProvider, profile: @escaping @MainActor () -> String) -> GeminiLiveTokenClient {
        GeminiLiveTokenClient(profile: profile, provider: { provider }, request: { [weak self] path, method, body, timeout in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        })
    }

    /// Built on first use only: boundaries that merely check whether Gemini
    /// Live is running must not construct its audio engines.
    var geminiLiveControllerCreated = false
    var qwenLiveControllerCreated = false
    var isQwenLiveActive: Bool { qwenLiveControllerCreated && qwenLiveController.isActive }

    /// Whether a Gemini Live conversation is running, without creating one.
    var isGeminiLiveActive: Bool {
        geminiLiveControllerCreated && geminiLiveController.isActive
    }

    lazy var geminiLiveController = makeDirectLiveController(provider: .gemini)
    lazy var qwenLiveController = makeDirectLiveController(provider: .qwen)

    /// Provider-specific state and credentials, shared audio/tool machinery.
    private func makeDirectLiveController(provider: DirectLiveProvider) -> GeminiLiveConversationController {
        let qwen = provider == .qwen
        let mode: LiveVoiceModeName = qwen ? .qwenLive : .geminiLive
        if qwen { qwenLiveControllerCreated = true } else { geminiLiveControllerCreated = true }
        let tokens = qwen ? qwenLiveTokenClient : geminiLiveTokenClient
        let audio = makeLiveVoiceAudio(outputSampleRate: GeminiLiveProtocol.outputSampleRate)
        let controller = GeminiLiveConversationController(
            makeSession: { [weak self] in
                let search = qwen ? (self?.qwenLiveSearchSource ?? .none) : (self?.geminiLiveSearchSource ?? .google)
                let memory = qwen ? self?.qwenLiveMemoryContext : self?.geminiLiveMemoryContext
                let session = GeminiLiveSession(
                    tokens: tokens,
                    systemInstruction: GeminiLiveConversationController.instructions(
                        search: search,
                        memory: memory,
                        personality: qwen ? self?.qwenLivePersonality : self?.geminiLivePersonality,
                        answerLength: self?.liveVoiceStyle.answerLength ?? .standard,
                        followedBy: (self?.liveVoiceResumeContext?.instructionBlock ?? "")
                            + (self?.liveHermesCallInstructions(delegation: false) ?? "")
                            + (self.map { $0.liveVoiceThreadInstructions(delegation: false) + $0.phoneVoiceSettingHint(for: mode) } ?? "")
                            + VoiceHostTool.functionToolsFirst(self?.voiceBackgroundJobSupervisor.hostTools ?? [])
                            + LiveVoiceStyle.askFirstInstructions(on: self?.voiceBackgroundJobSupervisor.asksBeforeSending == true)
                            + (self?.liveVoiceStyle.instructions ?? "")
                    ),
                    functions: GeminiLiveToolBridge.declarations(
                        webSearch: search == .hermes,
                        memoryRecall: memory?.canRecall == true,
                        thread: self?.voiceBackgroundJobSupervisor.liveThread != nil,
                        callback: self?.supportsHermesCalls == true,
                        waitsOn: self?.liveHermesCall?.kind,
                        chats: true,
                        jobApprovals: true
                    ) + VoiceHostTool.declarations(self?.voiceBackgroundJobSupervisor.hostTools ?? []),
                    googleSearch: search == .google,
                    voice: qwen ? self?.qwenLiveVoice : self?.geminiLiveVoice
                )
                if qwen { session.onTrace = { LiveCallTrace.shared.note($0) } }
                return session
            },
            availability: { [weak self] in
                guard let self else { return try await tokens.availability() }
                // Resolved before each conversation, so a changed setting or
                // a newly configured host backend applies on the next one.
                // The host calls run together: one after another they
                // stacked four round trips in front of every connection.
                let wantsMemory = qwen ? self.qwenLiveMemoryEnabled : self.geminiLiveMemoryEnabled
                let wantsPersonality = qwen ? self.qwenLivePersonalityEnabled : self.geminiLivePersonalityEnabled
                async let search = qwen ? self.resolveQwenLiveSearchSource() : self.resolveGeminiLiveSearchSource()
                async let memory = wantsMemory ? tokens.memoryContext() : nil
                async let loadedPersonality = wantsPersonality ? tokens.personality() : nil
                async let hostTools: Void = self.prepareVoiceHostTools(for: mode)
                let status = try await tokens.availability()
                // Unavailable: return now; leaving scope cancels the other
                // calls instead of waiting on them.
                guard status.isAvailable else { return status }
                let resolvedSearch = await search
                let resolvedMemory = await memory
                let resolvedPersonality = await loadedPersonality
                if qwen {
                    self.qwenLiveSearchSource = resolvedSearch
                    self.qwenLiveMemoryContext = resolvedMemory
                    self.qwenLivePersonality = resolvedPersonality
                } else {
                    self.geminiLiveSearchSource = resolvedSearch
                    self.geminiLiveMemoryContext = resolvedMemory
                    self.geminiLivePersonality = resolvedPersonality
                }
                await hostTools
                return status
            },
            // Fails closed: without the app state, the stored answer decides.
            missingConsent: { [weak self] in self?.requestLiveVoiceConsentIfMissing(mode) ?? LiveVoiceProviderConsent.missing(mode) },
            tools: GeminiLiveToolBridge(supervisor: self.voiceBackgroundJobSupervisor, webSearch: tokens, memory: tokens),
            input: audio.input,
            output: audio.output,
            // The same "End conversation" phrases as the classic Voice mode.
            endConversationPhrases: { [weak self] in
                guard let self else { return [] }
                return self.loadVoiceProfilePreferences(profile: self.activeProfile).resolvedSpokenEndConversationPhrases
            },
            // A call Hermes made opens with why it called, not a greeting (#449).
            openingPrompt: { [weak self] in self?.liveHermesCall?.openingTurn ?? self?.liveVoiceStyle.openingPrompt },
            provider: provider
        )
        controller.startsMuted = { [weak self] in self?.hermesCallStartsMuted ?? false }
        // Gemini sends no turn detection events, so only Qwen's calls are traced.
        if qwen { controller.traceName = "Qwen Live" }
        // A hands-free goodbye closes the sheet like the Close button.
        controller.onEndConversation = { [weak self] in
            if qwen { self?.closeQwenLiveConversation() } else { self?.closeGeminiLiveConversation() }
        }
        return controller
    }

    /// Opens Gemini Live instead of the classic Voice conversation. The
    /// classic conversation (and Read Aloud) is closed first so the two
    /// modes never share the audio session.
    @discardableResult
    func openGeminiLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .geminiLive { minimisedLiveVoice = nil }
        showGeminiLiveSheet = true
        if !geminiLiveController.isActive {
            geminiLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            beginVoiceCallRecording(engine: .geminiLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.geminiLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.geminiLive) else { return }
                await geminiLiveController.start()
            }
        }
        return true
    }

    /// Starts Gemini Live for the CarPlay surface. CarPlay presents it, so
    /// no phone sheet opens; the classic conversation and read aloud stop
    /// first, as on the phone.
    func startGeminiLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        guard !geminiLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        beginVoiceCallRecording(engine: .geminiLive)
        await geminiLiveController.start()
    }

    /// CarPlay went away. A Gemini Live conversation only CarPlay was
    /// presenting ends; one the phone's sheet or minimised bar shows keeps going. A
    /// conversation that already failed drops its memory and persona too:
    /// nothing presents it, so nothing would close it.
    func releaseCarPlayGeminiLive() {
        guard !(isSceneActive && (showGeminiLiveSheet || minimisedLiveVoice == .geminiLive)) else { return }
        if isGeminiLiveActive {
            closeGeminiLiveConversation()
        } else {
            // Its work lets go of the call too (#449).
            finishHermesCallbacks(engine: .geminiLive)
            dropGeminiLiveHostContext()
            if voiceCallRecorder?.engine == .geminiLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .geminiLive { minimisedLiveVoice = nil }
        }
    }

    func closeGeminiLiveConversation() {
        callOffWaitingCall(.geminiLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .geminiLive)
        if geminiLiveControllerCreated { geminiLiveController.stop() }
        showGeminiLiveSheet = false
        if minimisedLiveVoice == .geminiLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        dropGeminiLiveHostContext()
        if voiceCallRecorder?.engine == .geminiLive { finishVoiceCallRecording() }
    }

    /// Personal text (the host's memory and persona) isn't kept around
    /// between conversations, nor once nothing presents one.
    private func dropGeminiLiveHostContext() {
        geminiLiveMemoryContext = nil
        geminiLivePersonality = nil
    }

    /// Boundary teardown (disconnect, server/profile change, forced
    /// sign-out). Background jobs are retired by the same boundaries.
    func stopGeminiLiveConversation() {
        // A conversation that already failed with no sheet up has nothing
        // to close, but its host text still goes at the boundary.
        guard showGeminiLiveSheet || minimisedLiveVoice == .geminiLive || isGeminiLiveActive else {
            dropGeminiLiveHostContext()
            // Its recording still closes, so the call is saved, and its
            // work lets go of the call (#449).
            if voiceCallRecorder?.engine == .geminiLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .geminiLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.geminiLive)
        closeGeminiLiveConversation()
    }

    /// Opens Qwen Live instead of the classic Voice conversation. The
    /// classic conversation (and Read Aloud) is closed first so the two
    /// modes never share the audio session.
    @discardableResult
    func openQwenLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .qwenLive { minimisedLiveVoice = nil }
        showQwenLiveSheet = true
        if !qwenLiveController.isActive {
            qwenLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            beginVoiceCallRecording(engine: .qwenLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.qwenLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.qwenLive) else { return }
                await qwenLiveController.start()
            }
        }
        return true
    }

    /// Starts Qwen Live for the CarPlay surface. CarPlay presents it, so
    /// no phone sheet opens; the classic conversation and read aloud stop
    /// first, as on the phone.
    func startQwenLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        guard !qwenLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        beginVoiceCallRecording(engine: .qwenLive)
        await qwenLiveController.start()
    }

    /// CarPlay went away. A Qwen Live conversation only CarPlay was
    /// presenting ends; one the phone's sheet or minimised bar shows keeps going. A
    /// conversation that already failed drops its memory and persona too:
    /// nothing presents it, so nothing would close it.
    func releaseCarPlayQwenLive() {
        guard !(isSceneActive && (showQwenLiveSheet || minimisedLiveVoice == .qwenLive)) else { return }
        if isQwenLiveActive {
            closeQwenLiveConversation()
        } else {
            // Its work lets go of the call too (#449).
            finishHermesCallbacks(engine: .qwenLive)
            dropQwenLiveHostContext()
            if voiceCallRecorder?.engine == .qwenLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .qwenLive { minimisedLiveVoice = nil }
        }
    }

    func closeQwenLiveConversation() {
        callOffWaitingCall(.qwenLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .qwenLive)
        if qwenLiveControllerCreated { qwenLiveController.stop() }
        showQwenLiveSheet = false
        if minimisedLiveVoice == .qwenLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        dropQwenLiveHostContext()
        if voiceCallRecorder?.engine == .qwenLive { finishVoiceCallRecording() }
    }

    /// Personal text (the host's memory and persona) isn't kept around
    /// between conversations, nor once nothing presents one.
    private func dropQwenLiveHostContext() {
        qwenLiveMemoryContext = nil
        qwenLivePersonality = nil
    }

    /// Boundary teardown (disconnect, server/profile change, forced
    /// sign-out). Background jobs are retired by the same boundaries.
    func stopQwenLiveConversation() {
        // A conversation that already failed with no sheet up has nothing
        // to close, but its host text still goes at the boundary.
        guard showQwenLiveSheet || minimisedLiveVoice == .qwenLive || isQwenLiveActive else {
            dropQwenLiveHostContext()
            // Its recording still closes, so the call is saved, and its
            // work lets go of the call (#449).
            if voiceCallRecorder?.engine == .qwenLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .qwenLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.qwenLive)
        closeQwenLiveConversation()
    }

    // MARK: GPT-Live voice mode

    /// Presents the GPT-Live sheet. Separate from the classic and Gemini Live
    /// sheets: no two voice modes run at once.
    @Published var showGPTLiveSheet = false

    /// GPT-Live on the host's ChatGPT subscription: an opt-in, per-profile
    /// Voice mode (off by default), never on together with Gemini Live.
    var isGPTLiveEnabled: Bool {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        return preferences.gptLiveEnabled && !preferences.qwenLiveEnabled && !preferences.geminiLiveEnabled
    }

    func setGPTLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.gptLiveEnabled != enabled || (enabled && (preferences.qwenLiveEnabled || preferences.geminiLiveEnabled || preferences.grokLiveEnabled || preferences.localLiveEnabled)) else { return }
        objectWillChange.send()
        preferences.gptLiveEnabled = enabled
        // One live voice engine per profile: turning GPT-Live on turns the others off.
        if enabled {
            preferences.qwenLiveEnabled = false
            preferences.geminiLiveEnabled = false
            preferences.grokLiveEnabled = false
            preferences.localLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            closeClassicConversationForLiveMode()
            closeQwenLiveConversation()
            closeGeminiLiveConversation()
            closeGrokLiveConversation()
            closeLocalLiveConversation()
        } else {
            closeGPTLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// The voice GPT-Live speaks with on this profile; nil is the host's
    /// configured voice.
    var gptLiveVoice: String? {
        loadVoiceProfilePreferences(profile: activeProfile).gptLiveVoice
    }

    /// Applies from the next GPT-Live conversation.
    func setGPTLiveVoice(_ voice: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored = voice.flatMap { $0.isEmpty ? nil : $0 }
        guard preferences.gptLiveVoice != stored else { return }
        objectWillChange.send()
        preferences.gptLiveVoice = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    // MARK: GPT-Live billing (#559)

    /// Who pays for this profile's GPT-Live calls, as chosen in Settings.
    var gptLiveBilling: GPTLiveBilling {
        loadVoiceProfilePreferences(profile: activeProfile).resolvedGPTLiveBilling
    }

    /// Applies from the next GPT-Live conversation. Settings only calls it
    /// with `.api` after the user confirmed per-minute billing.
    func setGPTLiveBilling(_ billing: GPTLiveBilling) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: GPTLiveBilling? = billing == .subscription ? nil : billing
        guard preferences.gptLiveBilling != stored else { return }
        objectWillChange.send()
        preferences.gptLiveBilling = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The path the next GPT-Live call asks the host for. A call Hermes
    /// placed stays on the subscription unless the user allowed API-key
    /// calls for those too: nobody is billed for a call they didn't start
    /// without having said so.
    var gptLiveCallBilling: GPTLiveBilling {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.resolvedGPTLiveBilling == .api else { return .subscription }
        let hermesPlacedCall = liveHermesCall != nil || pendingHermesCall != nil
        if hermesPlacedCall, preferences.gptLiveAPIHermesCalls != true { return .subscription }
        return .api
    }

    /// The voice for the next call, from the list of the path it's billed on.
    var gptLiveCallVoice: String? {
        gptLiveCallBilling == .api ? gptLiveAPIVoice : gptLiveVoice
    }

    var gptLiveAPIVoice: String? {
        loadVoiceProfilePreferences(profile: activeProfile).gptLiveAPIVoice
    }

    func setGPTLiveAPIVoice(_ voice: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored = voice.flatMap { $0.isEmpty ? nil : $0 }
        guard preferences.gptLiveAPIVoice != stored else { return }
        objectWillChange.send()
        preferences.gptLiveAPIVoice = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    var gptLiveAPIHermesCalls: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).gptLiveAPIHermesCalls ?? false
    }

    func setGPTLiveAPIHermesCalls(_ allowed: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = allowed ? true : nil
        guard preferences.gptLiveAPIHermesCalls != stored else { return }
        objectWillChange.send()
        preferences.gptLiveAPIHermesCalls = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Minutes an API-key call may run; 0 is no limit.
    var gptLiveAPIMaxMinutes: Int {
        GPTLiveAPICallLimit.minutes(loadVoiceProfilePreferences(profile: activeProfile).gptLiveAPIMaxMinutes)
    }

    func setGPTLiveAPIMaxMinutes(_ minutes: Int) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Int? = minutes == GPTLiveAPICallLimit.defaultMinutes ? nil : max(0, minutes)
        guard preferences.gptLiveAPIMaxMinutes != stored else { return }
        objectWillChange.send()
        preferences.gptLiveAPIMaxMinutes = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether GPT-Live gets the Hermes host's memory on this profile. Off
    /// until the user turns it on: it sends that memory to OpenAI.
    var gptLiveMemoryEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).gptLiveMemory ?? false
    }

    /// Applies from the next GPT-Live conversation.
    func setGPTLiveMemoryEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.gptLiveMemory != stored else { return }
        objectWillChange.send()
        preferences.gptLiveMemory = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether GPT-Live speaks as the profile's SOUL.md persona. Off until
    /// the user turns it on: it sends SOUL.md to OpenAI.
    var gptLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).gptLivePersonality ?? false
    }

    /// Applies from the next GPT-Live conversation.
    func setGPTLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.gptLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.gptLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The persona and memory for the next GPT-Live call, read when it
    /// starts and dropped when it closes.
    private var gptLivePersonality: String?
    private var gptLiveMemoryContext: GeminiLiveMemoryContext?
    /// Whether the next GPT-Live call does its own web lookups ("Look up:")
    /// on the host's search backend, read when it starts.
    private var gptLiveWebLookUps = false

    /// The host text the live modes hold between a call's start and close,
    /// by field.
    var liveVoiceHostContextForTesting: [String] {
        [
            geminiLiveMemoryContext != nil ? "geminiMemory" : nil,
            geminiLivePersonality != nil ? "geminiPersona" : nil,
            gptLiveMemoryContext != nil ? "gptMemory" : nil,
            gptLivePersonality != nil ? "gptPersona" : nil,
            grokLiveMemoryContext != nil ? "grokMemory" : nil,
            grokLivePersonality != nil ? "grokPersona" : nil,
            localLivePersonality != nil ? "localPersona" : nil,
        ].compactMap { $0 }
    }

    /// Fills every live mode's host text, as a call's start would.
    func installLiveVoiceHostContextForTesting() {
        let memory = GeminiLiveMemoryContext(text: "memory", canRecall: false)
        geminiLiveMemoryContext = memory
        geminiLivePersonality = "persona"
        gptLiveMemoryContext = memory
        gptLivePersonality = "persona"
        grokLiveMemoryContext = memory
        grokLivePersonality = "persona"
    }

    /// Local Live's SOUL.md, as an agent-mode call's start would read it.
    func installLocalLivePersonaForTesting(_ persona: String = "persona") {
        localLivePersonality = persona
    }

    /// GPT-Live calls start on the Hermes host (the conduit_push plugin),
    /// through whichever dashboard bridge is current at call time.
    lazy var gptLiveClient = makeGPTLiveClient { [weak self] in
        self?.activeProfile ?? "default"
    }

    /// GPT-Live's host routes for `profile` (see makeLiveTokenClient).
    func makeGPTLiveClient(profile: @escaping @MainActor () -> String) -> GPTLiveClient {
        GPTLiveClient(profile: profile, billing: { [weak self] in
            // Never the API key without an AppState to say the user chose it.
            self?.gptLiveCallBilling ?? .subscription
        }, request: { [weak self] path, method, body, timeout in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        })
    }

    /// Built on first use only, like Gemini Live's.
    var gptLiveControllerCreated = false

    /// Whether a GPT-Live conversation is running, without creating one.
    var isGPTLiveActive: Bool {
        gptLiveControllerCreated && gptLiveController.isActive
    }

    lazy var gptLiveController: GPTLiveConversationController = {
        gptLiveControllerCreated = true
        let client = gptLiveClient
        // Memory and persona come from the same host routes Gemini Live reads.
        let hostContext = geminiLiveTokenClient
        let controller = GPTLiveConversationController(
            makeSession: { [weak self] in
                let session = GPTLiveSession(
                    client: client,
                    history: self?.liveVoiceResumeContext?.gptLiveHistory ?? [],
                    voice: self?.gptLiveCallVoice,
                    briefing: self?.gptLiveBriefing() ?? GPTLiveConversationController.briefing(),
                    // A call Hermes made opens with its brief instead (#449),
                    // spoken first rather than waiting for the user (#544).
                    greeting: self?.liveHermesCall == nil ? self?.liveVoiceStyle.greeting : nil,
                    callOpening: self?.liveHermesCall != nil
                )
                // The session's own setup steps in the call trace (#1611).
                session.onTrace = { LiveCallTrace.shared.note($0) }
                return session
            },
            availability: { [weak self] in
                let status = try await client.availability()
                if status.isAvailable, let self {
                    // Off only when the user turned web lookups off.
                    let wantsLookUps = self.geminiLiveSearchMode != .off
                    async let lookUps = wantsLookUps ? hostContext.webSearchAvailable() : false
                    self.gptLiveMemoryContext = self.gptLiveMemoryEnabled ? await hostContext.memoryContext() : nil
                    self.gptLivePersonality = self.gptLivePersonalityEnabled ? await hostContext.personality() : nil
                    await self.prepareVoiceHostTools(for: .gptLive)
                    self.gptLiveWebLookUps = await lookUps
                }
                return status
            },
            // Fails closed: without the app state, the stored answer decides.
            missingConsent: { [weak self] in self?.requestLiveVoiceConsentIfMissing(.gptLive) ?? LiveVoiceProviderConsent.missing(.gptLive) },
            briefing: { [weak self] in self?.gptLiveBriefing() ?? GPTLiveConversationController.briefing() },
            openingPrompt: { [weak self] in self?.liveHermesCall?.openingTurn ?? self?.liveVoiceStyle.openingPrompt },
            supervisor: self.voiceBackgroundJobSupervisor,
            webSearch: hostContext,
            // The same "End conversation" phrases as the other voice modes.
            endConversationPhrases: { [weak self] in
                guard let self else { return [] }
                return self.loadVoiceProfilePreferences(profile: self.activeProfile).resolvedSpokenEndConversationPhrases
            }
        )
        // A hands-free goodbye closes the sheet like the Close button.
        controller.onEndConversation = { [weak self] in self?.closeGPTLiveConversation() }
        controller.startsMuted = { [weak self] in self?.hermesCallStartsMuted ?? false }
        controller.traceName = "GPT-Live"
        controller.apiCallLimit = { [weak self] in
            guard let self else { return nil }
            return GPTLiveAPICallLimit.duration(self.loadVoiceProfilePreferences(profile: self.activeProfile).gptLiveAPIMaxMinutes)
        }
        return controller
    }()

    /// The phone's GPT-Live briefing: Conduit's rules, persona and memory,
    /// then this call's own blocks. One builder for the session request and
    /// the context a host that doesn't take briefings gets, so both fit the
    /// plugin's size limit the same way.
    func gptLiveBriefing() -> String {
        GPTLiveConversationController.briefing(
            memory: gptLiveMemoryContext,
            personality: gptLivePersonality,
            answerLength: liveVoiceStyle.answerLength,
            followedBy: (liveVoiceResumeContext?.summaryInstructionBlock ?? "")
                + liveHermesCallInstructions(delegation: true)
                + liveVoiceThreadInstructions(delegation: true) + phoneVoiceSettingHint(for: .gptLive)
                + hermesCallsInstructions(delegation: true)
                + VoiceHostTool.gptLiveRules(voiceBackgroundJobSupervisor.hostTools)
                + GPTLiveConversationController.jobApprovalRule
                + (gptLiveWebLookUps ? GPTLiveConversationController.webLookUpRule : "")
                + LiveVoiceStyle.askFirstInstructions(on: voiceBackgroundJobSupervisor.asksBeforeSending)
                + liveVoiceStyle.instructions
        )
    }

    /// Opens GPT-Live instead of the other voice modes, which (with Read
    /// Aloud) are closed first so they never share the audio session.
    @discardableResult
    func openGPTLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .gptLive { minimisedLiveVoice = nil }
        showGPTLiveSheet = true
        if !gptLiveController.isActive {
            gptLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            beginVoiceCallRecording(engine: .gptLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.gptLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.gptLive) else { return }
                await gptLiveController.start()
            }
        }
        return true
    }

    /// Starts GPT-Live for the CarPlay surface. CarPlay presents it, so no
    /// phone sheet opens; the other voice modes and read aloud stop first,
    /// as on the phone.
    func startGPTLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        guard !gptLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        beginVoiceCallRecording(engine: .gptLive)
        await gptLiveController.start()
    }

    /// CarPlay went away. A GPT-Live call only CarPlay was presenting ends;
    /// one the phone's sheet or minimised bar shows keeps going. A call that already failed
    /// drops its memory and persona too: nothing presents it, so nothing
    /// would close it.
    func releaseCarPlayGPTLive() {
        guard !(isSceneActive && (showGPTLiveSheet || minimisedLiveVoice == .gptLive)) else { return }
        if isGPTLiveActive {
            closeGPTLiveConversation()
        } else {
            // Its work lets go of the call too (#449).
            finishHermesCallbacks(engine: .gptLive)
            dropGPTLiveHostContext()
            if voiceCallRecorder?.engine == .gptLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .gptLive { minimisedLiveVoice = nil }
        }
    }

    func closeGPTLiveConversation() {
        callOffWaitingCall(.gptLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .gptLive)
        if gptLiveControllerCreated { gptLiveController.stop() }
        showGPTLiveSheet = false
        if minimisedLiveVoice == .gptLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        dropGPTLiveHostContext()
        if voiceCallRecorder?.engine == .gptLive { finishVoiceCallRecording() }
    }

    /// Personal text (the host's memory and persona) isn't kept around
    /// between conversations, nor once nothing presents one.
    private func dropGPTLiveHostContext() {
        gptLiveMemoryContext = nil
        gptLiveWebLookUps = false
        gptLivePersonality = nil
    }

    /// Boundary teardown (disconnect, server/profile change, sign-out, or
    /// another voice mode taking over).
    func stopGPTLiveConversation() {
        // A conversation that already failed with no sheet up has nothing
        // to close, but its host text still goes at the boundary.
        guard showGPTLiveSheet || minimisedLiveVoice == .gptLive || isGPTLiveActive else {
            dropGPTLiveHostContext()
            // Its recording still closes, so the call is saved, and its
            // work lets go of the call (#449).
            if voiceCallRecorder?.engine == .gptLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .gptLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.gptLive)
        closeGPTLiveConversation()
    }

    // MARK: Grok Live voice mode

    /// Presents the Grok Live sheet. Separate from the other voice sheets:
    /// no two voice modes run at once.
    @Published var showGrokLiveSheet = false

    /// Grok Live through the host's SuperGrok sign-in: an opt-in, per-profile
    /// Voice mode (off by default), never on together with another live mode.
    var isGrokLiveEnabled: Bool {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        return preferences.grokLiveEnabled && !preferences.qwenLiveEnabled && !preferences.geminiLiveEnabled && !preferences.gptLiveEnabled
    }

    func setGrokLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let othersOn = preferences.qwenLiveEnabled || preferences.geminiLiveEnabled || preferences.gptLiveEnabled || preferences.localLiveEnabled
        guard preferences.grokLiveEnabled != enabled || (enabled && othersOn) else { return }
        objectWillChange.send()
        preferences.grokLiveEnabled = enabled
        // One live voice engine per profile: turning Grok Live on turns the others off.
        if enabled {
            preferences.qwenLiveEnabled = false
            preferences.geminiLiveEnabled = false
            preferences.gptLiveEnabled = false
            preferences.localLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            closeClassicConversationForLiveMode()
            closeQwenLiveConversation()
            closeGeminiLiveConversation()
            closeGPTLiveConversation()
            closeLocalLiveConversation()
        } else {
            closeGrokLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// Whether Grok Live gets the Hermes host's memory on this profile. Off
    /// until the user turns it on: it sends that memory to xAI.
    var grokLiveMemoryEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).grokLiveMemory ?? false
    }

    /// Applies from the next Grok Live conversation.
    func setGrokLiveMemoryEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.grokLiveMemory != stored else { return }
        objectWillChange.send()
        preferences.grokLiveMemory = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// Whether Grok Live speaks as the profile's SOUL.md persona. Off until
    /// the user turns it on: it sends SOUL.md to xAI.
    var grokLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).grokLivePersonality ?? false
    }

    /// Applies from the next Grok Live conversation.
    func setGrokLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.grokLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.grokLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// What the next Grok Live call starts with, read when it starts and
    /// dropped when it closes: the host's memory and persona, and the voice
    /// its config names.
    private var grokLivePersonality: String?
    private var grokLiveMemoryContext: GeminiLiveMemoryContext?
    /// Grok looks things up with xAI's own search, never the host's (#598).
    let grokLiveSearchSource: GeminiLiveSearchSource = .grok
    private var grokLiveVoice: String?

    /// Grok Live's relay socket and status on the Hermes host (the
    /// conduit_push plugin), through whichever dashboard bridge is current
    /// at call time.
    lazy var grokLiveClient = makeGrokLiveClient { [weak self] in
        self?.activeProfile ?? "default"
    }

    /// Grok Live's host routes for `profile` (see makeLiveTokenClient).
    func makeGrokLiveClient(profile: @escaping @MainActor () -> String) -> GrokLiveClient {
        GrokLiveClient(profile: profile, profileParameter: { [weak self] in
            self?.notifierPlugin.dashboardProfileParameter ?? "profile"
        }, request: { [weak self] path, method, body, timeout in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }, mintTicket: { [weak self] in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.mintTicket()
        }, socketRequest: { [weak self] path, queryItems in
            guard let bridge = self?.dashboardTicketBridge, let connection = self?.connection else {
                throw DashboardTicketBridgeError.notReady
            }
            let url = try ConnectionURLPolicy.webSocketURL(baseURL: connection.baseUrl, path: path, queryItems: queryItems)
            // Behind Cloudflare Access the upgrade needs the service-token
            // headers, like the speech stream's. The authorizer then adds the
            // dashboard's own session cookies (cookie mode).
            let request = URLRequest(url: url).applyingProxyHeaders(cloudflare: bridge.cloudflareAccess)
            return try await bridge.requestAuthorizer.authorizeUpgrade(request)
        })
    }

    /// Built on first use only, like Gemini Live's.
    var grokLiveControllerCreated = false

    /// Whether a Grok Live conversation is running, without creating one.
    var isGrokLiveActive: Bool {
        grokLiveControllerCreated && grokLiveController.isActive
    }

    /// Grok Live runs on Gemini Live's conversation controller: only the
    /// session (xAI's events over the host's relay) differs.
    lazy var grokLiveController: GeminiLiveConversationController = {
        grokLiveControllerCreated = true
        let client = grokLiveClient
        // Memory and persona come from the host routes Gemini Live reads;
        // web search is xAI's own (#598).
        let hostContext = geminiLiveTokenClient
        let audio = makeLiveVoiceAudio(outputSampleRate: GrokLiveProtocol.outputSampleRate)
        let controller = GeminiLiveConversationController(
            makeSession: { [weak self] in
                let search = GeminiLiveSearchSource.grok
                let memory = self?.grokLiveMemoryContext
                // Built a step at a time: one long `+` chain of optionals is
                // slow for the type checker.
                var tail: String = GrokLiveProtocol.grokInstructions(now: Date(), timeZone: .current)
                tail += self?.liveVoiceResumeContext?.instructionBlock ?? ""
                tail += self?.liveHermesCallInstructions(delegation: false) ?? ""
                tail += self?.liveVoiceThreadInstructions(delegation: false) ?? ""
                tail += self?.phoneVoiceSettingHint(for: .grokLive) ?? ""
                tail += VoiceHostTool.functionToolsFirst(self?.voiceBackgroundJobSupervisor.hostTools ?? [])
                tail += LiveVoiceStyle.askFirstInstructions(on: self?.voiceBackgroundJobSupervisor.asksBeforeSending == true)
                tail += self?.liveVoiceStyle.instructions ?? ""
                let instructions = GeminiLiveConversationController.instructions(
                    search: search,
                    memory: memory,
                    personality: self?.grokLivePersonality,
                    answerLength: self?.liveVoiceStyle.answerLength ?? .standard,
                    acknowledgesOnceStarted: true,
                    followedBy: tail
                )
                let session = GrokLiveSession(
                    client: client,
                    instructions: instructions,
                    functions: GeminiLiveToolBridge.declarations(
                        webSearch: false,
                        memoryRecall: memory?.canRecall == true,
                        thread: self?.voiceBackgroundJobSupervisor.liveThread != nil,
                        callback: self?.supportsHermesCalls == true,
                        waitsOn: self?.liveHermesCall?.kind,
                        chats: true,
                        jobApprovals: true
                    ) + VoiceHostTool.declarations(self?.voiceBackgroundJobSupervisor.hostTools ?? []),
                    voice: self?.grokLiveVoice
                )
                session.onTrace = { LiveCallTrace.shared.note($0) }
                return session
            },
            availability: { [weak self] in
                guard let self else { throw GrokLiveClientError.socketUnavailable }
                let wantsMemory = self.grokLiveMemoryEnabled
                let wantsPersonality = self.grokLivePersonalityEnabled
                // The host calls run together, as Gemini Live's do.
                async let memory = wantsMemory ? hostContext.memoryContext() : nil
                async let personality = wantsPersonality ? hostContext.personality() : nil
                async let hostTools: Void = self.prepareVoiceHostTools(for: .grokLive)
                let status = try await client.availability()
                // The controller shows a thrown reason as it is; Grok Live's
                // names Grok Live.
                guard case .available(let model, let voice, _) = status else {
                    throw GrokLiveClientError.unavailable(status)
                }
                self.grokLiveMemoryContext = await memory
                self.grokLivePersonality = await personality
                await hostTools
                self.grokLiveVoice = voice
                return .available(model: model)
            },
            // Fails closed: without the app state, the stored answer decides.
            missingConsent: { [weak self] in self?.requestLiveVoiceConsentIfMissing(.grokLive) ?? LiveVoiceProviderConsent.missing(.grokLive) },
            // xAI has no non-blocking calls: start_job is answered once the
            // job runs, and its outcome follows as a text update.
            tools: GeminiLiveToolBridge(supervisor: self.voiceBackgroundJobSupervisor, webSearch: hostContext, memory: hostContext, holdsJobCalls: false),
            input: audio.input,
            output: audio.output,
            // The same "End conversation" phrases as the other voice modes.
            endConversationPhrases: { [weak self] in
                guard let self else { return [] }
                return self.loadVoiceProfilePreferences(profile: self.activeProfile).resolvedSpokenEndConversationPhrases
            },
            openingPrompt: { [weak self] in self?.liveHermesCall?.openingTurn ?? self?.liveVoiceStyle.openingPrompt }
        )
        // A hands-free goodbye closes the sheet like the Close button.
        controller.onEndConversation = { [weak self] in self?.closeGrokLiveConversation() }
        controller.startsMuted = { [weak self] in self?.hermesCallStartsMuted ?? false }
        controller.traceName = "Grok Live"
        return controller
    }()

    /// Opens Grok Live instead of the other voice modes, which (with Read
    /// Aloud) are closed first so they never share the audio session.
    @discardableResult
    func openGrokLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopLocalLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .grokLive { minimisedLiveVoice = nil }
        showGrokLiveSheet = true
        if !grokLiveController.isActive {
            grokLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            // Grok's start_job answers at once: a job's result has to be
            // read from its chat for the call to hear it (#599).
            voiceBackgroundJobSupervisor.liveCallReadsReplies = true
            beginVoiceCallRecording(engine: .grokLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.grokLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.grokLive) else { return }
                await grokLiveController.start()
            }
        }
        return true
    }

    /// Starts Grok Live for the CarPlay surface. CarPlay presents it, so no
    /// phone sheet opens; the other voice modes and read aloud stop first,
    /// as on the phone.
    func startGrokLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopLocalLiveConversation()
        guard !grokLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        voiceBackgroundJobSupervisor.liveCallReadsReplies = true
        beginVoiceCallRecording(engine: .grokLive)
        await grokLiveController.start()
    }

    /// CarPlay went away. A Grok Live call only CarPlay was presenting ends;
    /// one the phone's sheet or minimised bar shows keeps going. A call that already failed
    /// drops its memory and persona too: nothing presents it, so nothing
    /// would close it.
    func releaseCarPlayGrokLive() {
        guard !(isSceneActive && (showGrokLiveSheet || minimisedLiveVoice == .grokLive)) else { return }
        if isGrokLiveActive {
            closeGrokLiveConversation()
        } else {
            // Its work lets go of the call too (#449).
            finishHermesCallbacks(engine: .grokLive)
            dropGrokLiveHostContext()
            voiceBackgroundJobSupervisor.liveCallReadsReplies = false
            if voiceCallRecorder?.engine == .grokLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .grokLive { minimisedLiveVoice = nil }
        }
    }

    func closeGrokLiveConversation() {
        callOffWaitingCall(.grokLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .grokLive)
        if grokLiveControllerCreated { grokLiveController.stop() }
        showGrokLiveSheet = false
        if minimisedLiveVoice == .grokLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        dropGrokLiveHostContext()
        voiceBackgroundJobSupervisor.liveCallReadsReplies = false
        if voiceCallRecorder?.engine == .grokLive { finishVoiceCallRecording() }
    }

    /// Personal text (the host's memory and persona) isn't kept around
    /// between conversations, nor once nothing presents one.
    private func dropGrokLiveHostContext() {
        grokLiveMemoryContext = nil
        grokLivePersonality = nil
    }

    /// Boundary teardown (disconnect, server/profile change, sign-out, or
    /// another voice mode taking over).
    func stopGrokLiveConversation() {
        // A conversation that already failed with no sheet up has nothing
        // to close, but its host text still goes at the boundary.
        guard showGrokLiveSheet || minimisedLiveVoice == .grokLive || isGrokLiveActive else {
            dropGrokLiveHostContext()
            voiceBackgroundJobSupervisor.liveCallReadsReplies = false
            // Its recording still closes, so the call is saved, and its
            // work lets go of the call (#449).
            if voiceCallRecorder?.engine == .grokLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .grokLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.grokLive)
        closeGrokLiveConversation()
    }

    // MARK: Local Live voice mode

    /// Presents the Local Live sheet. Separate from the other voice sheets:
    /// no two voice modes run at once.
    @Published var showLocalLiveSheet = false

    /// Local Live through the user's own speech server: an opt-in,
    /// per-profile Voice mode (off by default), never on together with
    /// another live mode.
    var isLocalLiveEnabled: Bool {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        return preferences.localLiveEnabled && !preferences.qwenLiveEnabled && !preferences.geminiLiveEnabled
            && !preferences.gptLiveEnabled && !preferences.grokLiveEnabled
    }

    /// Local Live in agent mode (Live > Local) rather than Classic's
    /// hands-free option on the speech server.
    var isLocalLiveAgent: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).localLiveAgent
    }

    /// The same for `profile`, which a call from Hermes and the voice start
    /// it asks for both read, so they pick the same voice.
    func usesLocalLiveAgent(profile: String) -> Bool {
        loadVoiceProfilePreferences(profile: profile).localLiveAgent
    }

    func setLocalLiveAgent(_ agent: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        guard preferences.localLiveAgent != agent else { return }
        objectWillChange.send()
        preferences.localLiveAgent = agent
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        // A running call keeps its mode until it next connects: a new call,
        // or a reconnect after the socket drops, picks this up.
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// Whether the host's web lookups were available when the agent-mode
    /// call last checked.
    private var localLiveWebLookUps = false
    /// The profile's SOUL.md for the next agent-mode call, read when it
    /// starts and dropped when it closes, as the other live modes' are.
    private var localLivePersonality: String?
    /// Counts persona lookups and teardowns, so a lookup that finishes
    /// after its call ended or a newer one started stores nothing.
    private var localLivePersonaLookup = 0

    /// A starting call's claim on the persona; any earlier claim goes stale.
    private func claimLocalLivePersonaLookup() -> Int {
        localLivePersonaLookup &+= 1
        return localLivePersonaLookup
    }

    /// Personal text goes, and any lookup still running is dropped.
    private func dropLocalLivePersonality() {
        localLivePersonality = nil
        localLivePersonaLookup &+= 1
    }

    /// Whether Local Live's fast model speaks as the profile's SOUL.md
    /// persona (issue 583). Off until the user turns it on: it sends
    /// SOUL.md to the fast model's server, and a long one slows a small
    /// model's first words.
    var localLivePersonalityEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).localLivePersonality ?? false
    }

    /// Applies from the next Local Live call.
    func setLocalLivePersonalityEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let stored: Bool? = enabled ? true : nil
        guard preferences.localLivePersonality != stored else { return }
        objectWillChange.send()
        preferences.localLivePersonality = stored
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// What an agent-mode call gives the host's fast model: the live
    /// instructions and Grok Live's tools, run here, with the phone's own
    /// tools the user lets Local Live use. Nil outside agent mode.
    func localLiveAgentSetup() -> LocalLiveProtocol.AgentSetup? {
        guard isLocalLiveAgent else { return nil }
        let supervisor = voiceBackgroundJobSupervisor
        var tail: String = LocalLiveProtocol.agentInstructions
        tail += GrokLiveProtocol.clockInstructions(now: Date(), timeZone: .current)
        tail += liveVoiceResumeContext?.instructionBlock ?? ""
        tail += liveHermesCallInstructions(delegation: false)
        tail += liveVoiceThreadInstructions(delegation: false)
        tail += phoneVoiceSettingHint(for: .localLive)
        tail += VoiceHostTool.functionToolsFirst(supervisor.hostTools)
        tail += LiveVoiceStyle.askFirstInstructions(on: supervisor.asksBeforeSending)
        tail += liveVoiceStyle.instructions
        let instructions = GeminiLiveConversationController.instructions(
            search: localLiveWebLookUps ? .hermes : .none,
            personality: localLivePersonality,
            answerLength: liveVoiceStyle.answerLength,
            acknowledgesOnceStarted: true,
            followedBy: tail
        )
        let functions = GeminiLiveToolBridge.declarations(
            webSearch: localLiveWebLookUps,
            thread: supervisor.liveThread != nil,
            waitsOn: liveHermesCall?.kind,
            chats: true,
            jobApprovals: true
        ) + VoiceHostTool.declarations(supervisor.hostTools)
        return LocalLiveProtocol.AgentSetup(instructions: instructions, functions: functions)
    }

    func setLocalLiveEnabled(_ enabled: Bool) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        let othersOn = preferences.qwenLiveEnabled || preferences.geminiLiveEnabled || preferences.gptLiveEnabled || preferences.grokLiveEnabled
        guard preferences.localLiveEnabled != enabled || (enabled && othersOn) else { return }
        objectWillChange.send()
        preferences.localLiveEnabled = enabled
        // One live voice engine per profile: turning Local Live on turns the others off.
        if enabled {
            preferences.qwenLiveEnabled = false
            preferences.geminiLiveEnabled = false
            preferences.gptLiveEnabled = false
            preferences.grokLiveEnabled = false
        }
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
        if enabled {
            // A running Classic call stays: the car follows it (#1378). A
            // push to talk screen still waiting for its first press has no
            // session for the car to follow, so it closes (#1935).
            if showVoiceSheet, voiceConversationController.isPushToTalkActive,
               !voiceConversationController.hasConversationSession {
                closeVoiceConversation()
            }
            closeQwenLiveConversation()
            closeGeminiLiveConversation()
            closeGPTLiveConversation()
            closeGrokLiveConversation()
        } else {
            closeLocalLiveConversation()
        }
        CarPlayVoiceCoordinator.shared.voiceModeChanged(in: self)
    }

    /// Local Live's relay socket and status on the Hermes host (the
    /// conduit_push plugin), through whichever dashboard bridge is current
    /// at call time.
    lazy var localLiveClient = makeLocalLiveClient { [weak self] in
        self?.activeProfile ?? "default"
    }

    /// Local Live's host routes for `profile` (see makeLiveTokenClient).
    func makeLocalLiveClient(profile: @escaping @MainActor () -> String) -> LocalLiveClient {
        LocalLiveClient(profile: profile, profileParameter: { [weak self] in
            self?.notifierPlugin.dashboardProfileParameter ?? "profile"
        }, dashboardBaseURL: { [weak self] in
            self?.connection?.baseUrl
        }, request: { [weak self] path, method, body, timeout in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }, mintTicket: { [weak self] in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.mintTicket()
        }, socketRequest: { [weak self] path, queryItems in
            guard let bridge = self?.dashboardTicketBridge, let connection = self?.connection else {
                throw DashboardTicketBridgeError.notReady
            }
            let url = try ConnectionURLPolicy.webSocketURL(baseURL: connection.baseUrl, path: path, queryItems: queryItems)
            // Behind Cloudflare Access the upgrade needs the service-token
            // headers, like the speech stream's. The authorizer then adds the
            // dashboard's own session cookies (cookie mode), as for Grok's relay.
            let request = URLRequest(url: url).applyingProxyHeaders(cloudflare: bridge.cloudflareAccess)
            return try await bridge.requestAuthorizer.authorizeUpgrade(request)
        })
    }

    /// Built on first use only, like the other live modes'.
    var localLiveControllerCreated = false

    /// Whether a Local Live call is running, without creating one.
    var isLocalLiveActive: Bool {
        localLiveControllerCreated && localLiveController.isActive
    }

    /// The chat a Local Live call that started with none made for its
    /// turns, kept for the rest of the call.
    var localLiveOwnChat: VoiceThreadTarget?

    /// A Local Live call's turns, run as Hermes turns in the call's chat.
    lazy var localLiveTurns: LocalLiveTurnRunner = LocalLiveTurnRunner(backend: LocalLiveTurnRunner.Backend(
        resolveChat: { [weak self] in
            guard let self else { throw HermesError.notConnected }
            let client = try await self.clientForVoiceRequest()
            // A call from Home or Siri has no chat: its first turn makes one,
            // and the rest of the call goes on there. So does a call whose
            // chat was deleted (issue 1797).
            let own = self.localLiveOwnChat
            let call = self.voiceBackgroundJobSupervisor.liveCallID
            let resolved = try await LocalLiveTurnRunner.callChat(
                // A deleted one still names the bot its new chat is made on.
                attached: self.voiceBackgroundJobSupervisor.liveThread ?? self.voiceBackgroundJobSupervisor.deletedLiveThread,
                own: own,
                runtime: { try await self.localLiveChatRuntime($0) },
                create: { profile in
                    // No profile asked is the active one, as of the ask.
                    let expected = profile ?? self.activeProfile
                    let created = try await client.createSession(inProfile: profile)
                    // Made on another profile: never the call's chat on its bot.
                    if let made = created.profile, !Self.profilesMatch(made, expected) {
                        throw HermesError.invalidResponse
                    }
                    return VoiceThreadTarget(runtimeSessionID: created.sessionId, storedSessionID: created.storedSessionId,
                                             title: "", profile: profile)
                }
            )
            // Not after the call ended meanwhile: a new call has its own.
            if resolved.own != own, self.voiceBackgroundJobSupervisor.liveCallID == call { self.localLiveOwnChat = resolved.own }
            return resolved.chat
        },
        isBusy: { [weak self] chat in
            guard let self else { return false }
            if chat.runtimeID == self.activeSessionId { return self.isBusy }
            let client = try await self.clientForVoiceRequest()
            let rows = try await client.activeSessions(inProfile: chat.profile)
            return rows.contains { $0.runtimeSessionId == chat.runtimeID && $0.isRunning }
        },
        submit: { [weak self] chat, text in
            guard let self else { throw HermesError.notConnected }
            let client = try await self.clientForVoiceRequest()
            if chat.runtimeID == self.activeSessionId {
                // On screen it goes through the composer, so the chat shows
                // and streams it like Classic voice's turns.
                var foundBusy = self.isBusy
                if !foundBusy {
                    self.spokenSubmissionText = text
                    defer { self.spokenSubmissionText = nil }
                    let stillWanted = self.localLiveTurns.currentTurnCheck()
                    if await self.submitComposerForCall(text: text, onBusy: { foundBusy = true }, stillWanted: stillWanted) {
                        // Admitted behind a turn a restart cut off: the
                        // chat's card holds it until it's discarded.
                        if client.chatIsHeldByLostTurn(chat.runtimeID) {
                            return .notStarted(message: AppLocalization.string("Hermes queued this in the chat. Its reply will appear there."))
                        }
                        return .started(runtimeID: chat.runtimeID)
                    }
                }
                if foundBusy { throw VoiceThreadBusyError() }
                if let thread = self.voiceBackgroundJobSupervisor.liveThread ?? self.localLiveOwnChat { self.noteCallChatIfGone(thread) }
                throw VoiceAudioError.unavailable(self.callRefusalMessageForOpenChat()
                    ?? AppLocalization.string("Hermes could not send this to the chat."))
            }
            let reportedOn = self.activeDashboardID
            await self.reportTurnSurface(self.messageTurnSurface(spoken: true), runtimeSessionID: chat.runtimeID, text: text)?.value
            let outcome: PromptSubmissionOutcome
            do {
                outcome = try await self.sendCallPromptTakingOver(
                    runtimeID: chat.runtimeID, otherSessionIDs: [], profile: chat.profile,
                    stillWanted: self.localLiveTurns.currentTurnCheck()
                ) {
                    try await client.sendPrompt(chat.runtimeID, text: text, surface: AppState.spokenPromptSurface, voiceTurn: true)
                }
            } catch {
                self.discardTurnSurface(runtimeSessionID: chat.runtimeID, text: text, after: error, reportedOn: reportedOn)
                throw error
            }
            switch outcome {
            case .accepted where client.chatIsHeldByLostTurn(chat.runtimeID), .queued:
                return .notStarted(message: AppLocalization.string("Hermes queued this in the chat. Its reply will appear there."))
            case .accepted:
                return .started(runtimeID: chat.runtimeID)
            case .steered, .redirected:
                return .notStarted(message: AppLocalization.string("Hermes added this to the reply already running in the chat."))
            }
        },
        redirect: { [weak self] runtimeID, text in
            guard let self else { return .notRunning }
            return try await self.redirectLiveVoiceFollowUp(sessionID: runtimeID, text: text)
        },
        // As in Classic voice: a yes or no to the one card waiting.
        answerWaiting: { [weak self] text in
            await self?.answerWaitingBySpeech(text) ?? false
        },
        respondToApproval: { [weak self] approval, choice, profile in
            guard let self else { return false }
            return (try? await self.respondToApprovalByVoice(approval, choice: choice, profile: profile)) ?? false
        },
        respondToClarify: { [weak self] clarify, questionID, answer, sessionID, profile in
            guard let self else { return nil }
            return try? await self.respondToClarifyByVoice(
                clarify, questionID: questionID, answer: answer, sessionID: sessionID, profile: profile
            )
        }
    ))

    /// Local Live runs on Gemini Live's conversation controller: only the
    /// session (the speech server's events over the host's relay) differs,
    /// and its turns go to Hermes instead of a live model.
    lazy var localLiveController: GeminiLiveConversationController = {
        localLiveControllerCreated = true
        let client = localLiveClient
        let turns = localLiveTurns
        let hostContext = geminiLiveTokenClient
        let audio = makeLiveVoiceAudio(outputSampleRate: LocalLiveProtocol.sampleRate)
        let controller = GeminiLiveConversationController(
            makeSession: { [weak self] in
                let session = LocalLiveSession(client: client)
                session.onTrace = { LiveCallTrace.shared.note($0) }
                // The greeting setting, said by the speech server itself:
                // Hermes isn't asked, so "own words" is a short fixed line.
                session.greeting = { [weak self] in
                    // A call from Hermes opens with why it called instead.
                    guard self?.liveHermesCall == nil, let greeting = self?.liveVoiceStyle.greeting else { return nil }
                    return greeting.isEmpty ? AppLocalization.string("Hi, I'm listening.") : greeting
                }
                // The turns follow the newest session: a turn opened on an
                // older one can't be answered on this socket.
                turns.dropTurn()
                session.onTurn = { turnID, text in turns.start(turnID: turnID, text: text) }
                session.onTurnCancel = { turnID in turns.cancel(turnID: turnID) }
                // Live > Local: the host's fast model answers, and its
                // tool calls run here as Grok Live's do.
                session.agentSetup = { [weak self] in self?.localLiveAgentSetup() }
                session.onTurnsDropped = { turns.dropTurn() }
                turns.onDelta = { [weak session] turnID, text in session?.sendTurnDelta(turnID, text: text) }
                turns.onDone = { [weak session] turnID in session?.sendTurnDone(turnID) }
                turns.onVisual = { [weak self] markdown in
                    self?.voiceBackgroundJobSupervisor.showOnScreen(
                        title: AppLocalization.string("From Hermes"), markdown: markdown, evenIfHidden: true) != nil
                }
                return session
            },
            availability: { [weak self] in
                // The call's claim on the persona, taken before any wait:
                // a newer call's start or any teardown bumps the count, and
                // a stale claim then stores and clears nothing. A lookup
                // that outlives a profile switch is dropped too, so another
                // profile's SOUL.md never reaches this call.
                let lookup = self?.claimLocalLivePersonaLookup()
                let profile = self?.activeProfile
                let status = try await client.status()
                if let reason = LocalLiveClient.unavailableReason(status) {
                    throw LocalLiveClientError.unavailable(reason)
                }
                if let self, self.isLocalLiveAgent {
                    // The phone's own tools (calendar, reminders, alarms,
                    // maps, health, location) the user lets Local Live use.
                    async let hostTools: Void = self.prepareVoiceHostTools(for: .localLive)
                    async let personality = self.localLivePersonalityEnabled ? hostContext.personality() : nil
                    // Off only when the user turned web lookups off.
                    if self.geminiLiveSearchMode != .off {
                        self.localLiveWebLookUps = await hostContext.webSearchAvailable()
                    } else {
                        self.localLiveWebLookUps = false
                    }
                    let persona = await personality
                    if self.localLivePersonaLookup == lookup {
                        self.localLivePersonality = self.activeProfile == profile ? persona : nil
                    }
                    await hostTools
                } else if let self, self.localLivePersonaLookup == lookup {
                    self.localLivePersonality = nil
                }
                return .available(model: status.modelName)
            },
            // Tools run only in agent mode, where the host's fast model calls
            // them; otherwise Hermes does the work in the call's chat. Like
            // Grok's, start_job answers once the job runs and its outcome
            // follows as a text update.
            tools: GeminiLiveToolBridge(supervisor: self.voiceBackgroundJobSupervisor, webSearch: hostContext, memory: hostContext, holdsJobCalls: false),
            input: audio.input,
            output: audio.output,
            // The same "End conversation" phrases as the other voice modes.
            endConversationPhrases: { [weak self] in
                guard let self else { return [] }
                return self.loadVoiceProfilePreferences(profile: self.activeProfile).resolvedSpokenEndConversationPhrases
            },
            // A call from Hermes in agent mode: the fast model says why
            // Hermes called, as on the other live modes. Outside agent mode
            // a call from Hermes opens Classic voice instead.
            openingPrompt: { [weak self] in
                guard let self, self.isLocalLiveAgent else { return nil }
                return self.liveHermesCall?.openingTurn
            }
        )
        // A hands-free goodbye closes the sheet like the Close button.
        controller.onEndConversation = { [weak self] in self?.closeLocalLiveConversation() }
        controller.startsMuted = { [weak self] in self?.hermesCallStartsMuted ?? false }
        controller.traceName = "Local Live"
        return controller
    }()

    /// Opens Local Live instead of the other voice modes, which (with Read
    /// Aloud) are closed first so they never share the audio session.
    @discardableResult
    func openLocalLiveConversation(attachingTo thread: VoiceThreadTarget? = nil, initialCaptureAuthorization: WidgetInitialCaptureAuthorization? = nil) -> Bool {
        guard isConnected else { return false }
        messageReadAloudController.stop()
        if showVoiceSheet { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        showSidebar = false
        if minimisedLiveVoice == .localLive { minimisedLiveVoice = nil }
        showLocalLiveSheet = true
        if !localLiveController.isActive {
            localLiveController.installInitialWidgetCaptureAuthorization(initialCaptureAuthorization)
            // A new call is attached to the chat it was started from; a
            // running one keeps what it had.
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
            localLiveTurns.reset()
            localLiveOwnChat = nil
            beginVoiceCallRecording(engine: .localLive)
            CarPlayVoiceCoordinator.shared.conversationStartingOnPhone(in: self)
            let waited = liveCallOpens(.localLive)
            Task {
                // Not if it was called off on its waiting screen meanwhile.
                guard !waited || waitedCallStarts(.localLive) else { return }
                await localLiveController.start()
            }
        }
        return true
    }

    /// Starts Local Live for the CarPlay surface. CarPlay presents it, so no
    /// phone sheet opens; the other voice modes and read aloud stop first,
    /// as on the phone.
    func startLocalLiveForCarPlay(attachingTo thread: VoiceThreadTarget? = nil) async {
        guard isConnected else { return }
        messageReadAloudController.stop()
        if showVoiceSheet || voiceConversationController.hasLiveVoiceSession { closeVoiceConversation() }
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        guard !localLiveController.isActive else { return }
        // A call started from CarPlay's chat list is attached to that chat,
        // as one started from a chat on the phone is.
        if let thread {
            voiceBackgroundJobSupervisor.attachLiveThread(thread)
        } else {
            voiceBackgroundJobSupervisor.detachLiveThread()
        }
        localLiveTurns.reset()
        localLiveOwnChat = nil
        beginVoiceCallRecording(engine: .localLive)
        await localLiveController.start()
    }

    /// CarPlay went away. A Local Live call only CarPlay was presenting
    /// ends; one the phone's sheet or minimised bar shows keeps going.
    func releaseCarPlayLocalLive() {
        guard !(isSceneActive && (showLocalLiveSheet || minimisedLiveVoice == .localLive)) else { return }
        if isLocalLiveActive {
            closeLocalLiveConversation()
        } else {
            // Its work lets go of the call too (#449), and no turn of it
            // runs on.
            finishHermesCallbacks(engine: .localLive)
            if localLiveControllerCreated { localLiveTurns.reset() }
            localLiveOwnChat = nil
            // Personal text goes with the call it was fetched for.
            dropLocalLivePersonality()
            if voiceCallRecorder?.engine == .localLive { finishVoiceCallRecording() }
            // A minimised call that failed has nothing left to show.
            if minimisedLiveVoice == .localLive { minimisedLiveVoice = nil }
        }
    }

    func closeLocalLiveConversation() {
        callOffWaitingCall(.localLive)
        // Before the call stops, while its transcript still reads (#449).
        finishHermesCallbacks(engine: .localLive)
        if localLiveControllerCreated {
            localLiveController.stop()
            localLiveTurns.reset()
        }
        localLiveOwnChat = nil
        dropLocalLivePersonality()
        showLocalLiveSheet = false
        if minimisedLiveVoice == .localLive { minimisedLiveVoice = nil }
        voiceBackgroundJobSupervisor.detachLiveThread()
        if voiceCallRecorder?.engine == .localLive { finishVoiceCallRecording() }
    }

    /// Boundary teardown (disconnect, server/profile change, sign-out, or
    /// another voice mode taking over).
    func stopLocalLiveConversation() {
        guard showLocalLiveSheet || minimisedLiveVoice == .localLive || isLocalLiveActive else {
            // Personal text goes at the boundary even with no call up.
            dropLocalLivePersonality()
            // Its recording still closes, so the call is saved.
            if voiceCallRecorder?.engine == .localLive { finishVoiceCallRecording() }
            finishHermesCallbacks(engine: .localLive)
            // Not while another mode's call runs: it may be attached.
            if !isLiveVoiceCallActive { voiceBackgroundJobSupervisor.detachLiveThread() }
            return
        }
        releaseWaitingCall(.localLive)
        closeLocalLiveConversation()
    }

    lazy var voiceConversationController = VoiceConversationController(
        capture: self.voiceConversationAudio.capture,
        playback: self.voiceConversationAudio.playback,
        // With echo cancelled, Hermes' own voice can't reach the
        // microphone on any route: the speaker behaves like a headset.
        routePolicyProvider: { [audio = self.voiceConversationAudio] in
            audio.cancelsEcho ? .fullDuplex : VoiceBargeInRoutePolicy.current()
        },
        submit: { [weak self] transcript in
            guard let self else { return false }
            return await self.submitVoiceTranscript(transcript)
        },
        interrupt: { [weak self] in
            guard let self else { return false }
            return await self.interruptForVoice()
        },
        steer: { [weak self] text in
            guard let self else { return .failed }
            return await self.steerForVoice(text)
        },
        onEndConversation: { [weak self] in
            self?.closeVoiceConversation()
        },
        backgroundJobs: self.voiceBackgroundJobSupervisor,
        // Push to talk needs the phone's voice screen in front of the user:
        // CarPlay and a call from Hermes stay hands-free.
        pushToTalkSurfaceAvailable: { [weak self] in
            guard let self else { return false }
            return self.isSceneActive && self.showVoiceSheet
                && !self.isCarPlayVoiceSurfaceActive && !self.isNativeHermesCallAnswered
        }
    )
    /// Classic voice audio: the default capture and playback, or one
    /// echo-cancelling engine when speaker talk-over is on, chosen for each
    /// conversation.
    lazy var voiceConversationAudio = VoiceConversationAudioSelector(
        wantsEchoCancellation: { [weak self] in self?.usesEchoCancellingVoiceAudio ?? false },
        standardCapture: AVAudioCaptureService(),
        standardPlayback: AVSpeechPlaybackService(),
        makeEchoCancelling: { EchoCancellingLiveVoiceAudio(outputSampleRate: GeminiLiveProtocol.outputSampleRate) }
    )
    /// Background jobs started from Voice (issue #163): each job is an
    /// ordinary Hermes session created on the current client, and its
    /// finished result is handed back to the Voice conversation.
    lazy var voiceBackgroundJobSupervisor: VoiceBackgroundJobSupervisor = {
        let supervisor = VoiceBackgroundJobSupervisor(backend: VoiceBackgroundJobBackend(
            createSession: { [weak self] targetProfile, callsModel in
                guard let self else { throw HermesError.notConnected }
                let client = try await self.clientForVoiceRequest()
                if let targetProfile {
                    // A job on another profile or bot runs on that profile's
                    // own model: this profile's voice-job model is not its.
                    // A call's own job on that profile (a Watch call's, or a
                    // Bot Chat call's on its bot) uses its voice-job model, as
                    // the call's relay jobs do (#1564).
                    var options: (model: String?, provider: String?, reasoningEffort: String?) = (nil, nil, nil)
                    if callsModel {
                        options = self.watchCallJobSession(self.loadVoiceProfilePreferences(profile: targetProfile), profile: targetProfile)
                    }
                    let created = try await client.createSession(
                        model: options.model,
                        provider: options.provider,
                        reasoningEffort: options.reasoningEffort,
                        inProfile: targetProfile
                    )
                    if let returnedProfile = created.profile, !self.profilesMatch(returnedProfile, targetProfile) {
                        throw HermesError.invalidResponse
                    }
                    return (created.sessionId, created.storedSessionId, targetProfile)
                }
                // Same model/provider as a composer-created chat, and the
                // same refusal when Hermes lands it in another profile.
                let profile = self.activeProfile
                // Voice jobs can run on their own (faster) model and
                // reasoning level, chosen in Voice settings.
                let options = self.loadVoiceProfilePreferences(profile: profile).voiceJobSessionOptions(
                    runtimeModel: self.runtime.model,
                    runtimeProvider: self.runtime.provider
                )
                let created = try await client.createSession(
                    model: options.model,
                    provider: options.provider,
                    reasoningEffort: options.reasoningEffort
                )
                if let returnedProfile = created.profile, !self.profilesMatch(returnedProfile, profile) {
                    throw HermesError.invalidResponse
                }
                return (created.sessionId, created.storedSessionId, profile)
            },
            setTitle: { [weak self] sessionID, title in
                guard let client = try? await self?.clientForVoiceRequest() else { return }
                try? await client.setSessionTitle(sessionID, title: title)
            },
            keepInRegistry: { [weak self] targetProfile, sessionID, title, instructions, fromWatch, callChat, endedWith, call in
                self?.keepVoiceJobInRegistry(profile: targetProfile, sessionID: sessionID, title: title,
                                             instructions: instructions, fromWatch: fromWatch, callChat: callChat,
                                             endedWith: endedWith, call: call)
            },
            sendToCallWorkstream: { [weak self] thread, request in
                await self?.sendCallRequestToWorkstream(thread, request)
            },
            callLeftChat: { [weak self] profile, chat, call in
                self?.voiceCallLeftChat(profile: profile, chat: chat, call: call)
            },
            activeProfile: { [weak self] in self?.activeProfile },
            submit: { [weak self] sessionID, text in
                guard let self else { throw HermesError.notConnected }
                let client = try await self.clientForVoiceRequest()
                _ = try await client.sendPrompt(sessionID, text: text)
            },
            reportTurnSurface: { [weak self] sessionID, text, fromWatch in
                guard let self else { return { _ in } }
                let reportedOn = self.activeDashboardID
                let surface = TurnSurface.voiceJob(fromWatch: fromWatch, carPlay: self.isCarPlayVoiceSurfaceActive)
                await self.reportTurnSurface(surface, runtimeSessionID: sessionID, text: text)?.value
                return { [weak self] error in
                    self?.discardTurnSurface(runtimeSessionID: sessionID, text: text, after: error, reportedOn: reportedOn)
                }
            },
            cancel: { [weak self] sessionID in
                guard let self else { throw HermesError.notConnected }
                let client = try await self.clientForVoiceRequest()
                // A job in the open chat: its turn is noted as any cancel there is.
                let open = self.activeSessionId.flatMap { self.eventBelongsToActiveSession(sessionID) ? $0 : nil }
                let noteBeforeCancel = open.map { self.voiceCancelNote(in: $0) }
                let wasRunning = self.isBusy
                if let open { self.noteRunningTurnBeforeCancel(in: open) }
                let noteWrite = open.flatMap { self.voiceCancelNoteWrites[$0] }
                do {
                    let stopped = try await client.cancel(sessionID, profile: self.presentationProfile(for: sessionID))
                    if let open { self.noteVoiceStoppedTurn(sessionId: open, generation: stopped, wasRunning: wasRunning, ifStill: noteWrite) }
                } catch {
                    if let open, let noteBeforeCancel {
                        self.restoreVoiceCancelNote(in: open, to: noteBeforeCancel, ifStill: noteWrite)
                    }
                    throw error
                }
            },
            liveSessions: { [weak self] targetProfile in
                guard let self else { throw HermesError.notConnected }
                let client = try await self.clientForVoiceRequest()
                return try await client.activeSessions(inProfile: targetProfile)
            },
            resolveProfile: { [weak self] spokenName in
                self?.voiceJobProfileTarget(named: spokenName) ?? .unknown
            },
            threadIsBusy: { [weak self] thread in
                await self?.liveVoiceThreadIsBusy(thread) ?? false
            },
            resolveThreadRuntime: { [weak self] thread in
                guard let self else { throw HermesError.notConnected }
                return try await self.liveVoiceThreadRuntime(thread)
            },
            submitThreadTurn: { [weak self] thread, runtimeID, text in
                guard let self else { throw HermesError.notConnected }
                return try await self.submitLiveVoiceThreadTurn(thread, runtimeID: runtimeID, text: text)
            },
            redirect: { [weak self] sessionID, text in
                guard let self else { throw HermesError.notConnected }
                return try await self.redirectLiveVoiceFollowUp(sessionID: sessionID, text: text)
            },
            steer: { [weak self] sessionID, text in
                guard let self else { throw HermesError.notConnected }
                return try await self.steerLiveVoiceFollowUp(sessionID: sessionID, text: text)
            },
            latestThreadReply: { [weak self] thread in
                await self?.latestLiveVoiceThreadReply(thread)
            },
            threadOwnsSession: { [weak self] thread, sessionID in
                guard let self else { return thread.owns(sessionID: sessionID) }
                return self.knownSessionIDs(for: sessionID).union([sessionID]).contains { thread.owns(sessionID: $0) }
            },
            latestThreadPrompt: { [weak self] thread in
                guard let self, self.isOpenChat(thread),
                      let message = Self.liveVoiceUnansweredPrompt(in: self.messages) else { return nil }
                return Self.liveVoiceTypedPrompt(message)
            },
            isBotChat: { [weak self] thread in
                guard let self else { return false }
                return [thread.runtimeSessionID, thread.storedSessionID ?? ""]
                    .contains { !$0.isEmpty && self.botConversationProfile(for: $0) != nil }
            },
            threadAwaitsSeveralPrompts: { [weak self] thread in
                guard let self, self.isOpenChat(thread) else { return false }
                let afterReply = self.messages.lastIndex(where: { $0.role == .assistant }).map { $0 + 1 } ?? self.messages.startIndex
                return self.messages[afterReply...].filter { $0.role == .user && !$0.isSteer }.count > 1
            },
            saveLedger: { [weak self] saved in
                self?.saveVoiceJobLedger(saved)
            },
            ledgerKey: { [weak self] in self?.voiceJobLedgerKey },
            openThreadMessages: { [weak self] thread in
                guard let self, self.isOpenChat(thread) else { return nil }
                return self.messages
            },
            searchChats: { [weak self] query, profile in
                guard let self else { throw HermesError.notConnected }
                return try await self.searchChatsForVoice(query, profile: profile)
            },
            readChat: { [weak self] sessionID, profile in
                guard let self else { throw HermesError.notConnected }
                return try await self.readChatForVoice(sessionID, profile: profile)
            },
            respondToApproval: { [weak self] approval, choice, profile in
                guard let self else { throw HermesError.notConnected }
                return try await self.respondToApprovalByVoice(approval, choice: choice, profile: profile)
            },
            respondToClarify: { [weak self] clarify, questionID, answer, sessionID, profile in
                guard let self else { throw HermesError.notConnected }
                return try await self.respondToClarifyByVoice(
                    clarify, questionID: questionID, answer: answer, sessionID: sessionID, profile: profile
                )
            }
        ))
        supervisor.callbacks = self.makeHermesCallbackBackend()
        supervisor.callDecisions = VoiceCallDecisions(
            waitsOn: { [weak self] in self?.hermesCallWaitsOn },
            approve: { [weak self] choice in await self?.answerHermesCallApproval(choice: choice) ?? .failed },
            answer: { [weak self] answer in await self?.answerHermesCallQuestion(answer) ?? .failed }
        )
        supervisor.onNoticePending = { [weak self] in
            guard let self else { return }
            if self.isQwenLiveActive {
                self.qwenLiveController.deliverPendingJobUpdates()
            } else if self.isGeminiLiveActive {
                self.geminiLiveController.deliverPendingJobUpdates()
            } else if self.isGPTLiveActive {
                self.gptLiveController.deliverPendingJobUpdates()
            } else if self.isGrokLiveActive {
                self.grokLiveController.deliverPendingJobUpdates()
            } else if self.isLocalLiveActive {
                // Live > Local puts the host's fast model on the front, so a
                // job's result is news to the call and goes out as one of its
                // turns, as in the other live modes. A call that hands each
                // utterance to Hermes drops it instead: Hermes' reply is the
                // call's own turn, and a notice would be said twice.
                //
                // A call with no ready connection yet has no mode to read:
                // while the microphone permission and the handshake are
                // pending, it keeps the notice for the connection to come
                // rather than spending it on a drop it can't take back.
                let controller = self.localLiveController
                switch LocalLiveNoticeHandling.forCall(
                    runsAgentTurns: controller.sessionRunsAgentTurns,
                    sessionIsReady: controller.sessionIsReady,
                    configuredAgent: self.isLocalLiveAgent
                ) {
                case .deliverAsUpdate:
                    controller.deliverPendingJobUpdates()
                case .drop:
                    self.voiceBackgroundJobSupervisor.dropPendingNotices()
                }
            } else {
                self.voiceConversationController.deliverPendingBackgroundJobNoticeIfIdle()
            }
        }
        supervisor.liveCallTranscript = { [weak self] in
            guard let self else { return nil }
            if self.isQwenLiveActive { return self.qwenLiveController.transcript }
            if self.isGeminiLiveActive { return self.geminiLiveController.transcript }
            if self.isGPTLiveActive { return self.gptLiveController.transcript }
            if self.isGrokLiveActive { return self.grokLiveController.transcript }
            if self.isLocalLiveActive { return self.localLiveController.transcript }
            return nil
        }
        supervisor.liveCallScreenIsVisible = { [weak self] in
            guard let self else { return false }
            return self.isSceneActive && (self.showQwenLiveSheet || self.showGeminiLiveSheet || self.showGrokLiveSheet || self.showLocalLiveSheet)
        }
        supervisor.openChat = { [weak self] match in
            self?.openChatFromLiveCall(match.sessionID) ?? false
        }
        supervisor.onScreenCardShown = { [weak self] card in
            guard let self, let recorder = self.voiceCallRecorder else { return }
            self.captureVoiceCall()
            recorder.screen(card)
            self.checkpointVoiceCall(recorder)
        }
        supervisor.onCallChatAdopted = { [weak self] thread in
            self?.keepVoiceCallWithAdoptedChat(thread)
        }
        supervisor.onThreadTurnStarted = { [weak self] job, thread in
            guard let self, let recorder = self.voiceCallRecorder else { return }
            self.captureVoiceCall()
            recorder.note(Self.voiceThreadTurnNote(job, thread: thread))
            self.checkpointVoiceCall(recorder)
        }
        supervisor.onJobStoredSessionLearned = { [weak self] runtimeID, storedID in
            guard let self else { return }
            self.learnVoiceSessionAlias(runtimeID: runtimeID, storedID: storedID)
            // Filed under Voice Jobs by its durable id too, wherever the
            // runtime was filed.
            for (key, tags) in self.voiceSessionTagsByKey {
                if let tag = tags[runtimeID] { self.voiceSessionTagsByKey[key]?[storedID] = tag }
            }
            // And kept that way: the badge list and the call's tag write at
            // its end carry the durable id as well.
            let job = self.voiceBackgroundJobSupervisor.jobs.first { $0.runtimeSessionID == runtimeID }
            guard job?.isThreadTurn != true else { return }
            self.rememberVoiceJobSessions([storedID], profile: job?.profile)
            if let recorder = self.voiceCallRecorder, recorder.jobSessionIDs.contains(runtimeID) {
                recorder.jobSessionIDs.append(storedID)
            }
        }
        supervisor.onJobSessionCreated = { [weak self] sessionIDs in
            guard let self else { return }
            if sessionIDs.count == 2 { self.learnVoiceSessionAlias(runtimeID: sessionIDs[0], storedID: sessionIDs[1]) }
            if let job = self.voiceBackgroundJobSupervisor.jobs.first(where: { job in sessionIDs.contains { job.owns(sessionID: $0) } }),
               let targetProfile = job.profile, targetProfile != self.activeProfile {
                // A job on another profile is that profile's chat: badged
                // there, and noted in the call. Voice tags live in the
                // calling profile's history, so it carries none.
                self.rememberVoiceJobSessions(sessionIDs, profile: targetProfile)
                if let recorder = self.voiceCallRecorder {
                    self.captureVoiceCall()
                    recorder.note(AppLocalization.string("Started a background job on \(job.profileLabel ?? targetProfile): \(job.title)."))
                }
                return
            }
            self.rememberVoiceJobSessions(sessionIDs)
            // Filed under Voice Jobs on every device, with the call (or the
            // classic voice chat) it came from.
            if let recorder = self.voiceCallRecorder,
               let job = self.voiceBackgroundJobSupervisor.jobs.first(where: { job in sessionIDs.contains { job.owns(sessionID: $0) } }) {
                self.captureVoiceCall()
                recorder.note(Self.voiceJobStartedNote(job))
            }
            // A job while the classic Voice sheet is up is that chat's.
            let closing = self.closingVoiceCallUntil.map { Date() < $0 } == true && !self.showVoiceSheet ? self.closingVoiceCallRecorder : nil
            if let recorder = self.voiceCallRecorder ?? closing {
                // Nothing reaches the host while the call runs: the job is
                // tagged with the call's row once the call ends, and kept
                // with its queued save meanwhile. Here it shows under Voice
                // Jobs at once.
                recorder.jobSessionIDs += sessionIDs
                if recorder === self.voiceCallRecorder {
                    self.checkpointVoiceCall(recorder)
                } else {
                    var outbox = VoiceTranscriptOutbox.load(from: self.defaults)
                    outbox.addJobs(sessionIDs, toCall: recorder.callID)
                    outbox.store(in: self.defaults)
                }
                let key = self.voiceHistoryKey(profile: recorder.profile)
                // A call kept with its chat files its jobs under the chat.
                let parentID = recorder.sessionID ?? recorder.chatID
                for id in sessionIDs where !id.isEmpty {
                    self.voiceSessionTagsByKey[key, default: [:]][id] = VoiceSessionTag(
                        kind: .job, parentID: parentID, parentTitle: self.voiceJobParentTitle(parentID)
                    )
                }
            } else {
                let parentID = self.showVoiceSheet ? self.activeSessionId : nil
                self.tagVoiceSessions(sessionIDs, kind: .job, parentID: parentID, parentTitle: self.voiceJobParentTitle(parentID))
            }
            self.voiceJobSessionListRefreshTask?.cancel()
            self.voiceJobSessionListRefreshTask = Task { [weak self] in
                await self?.loadSessions(forceRefresh: true)
            }
        }
        self.scheduleVoiceJobLedgerRestore()
        return supervisor
    }()

    /// Where the voice jobs' ledger is kept for this dashboard and profile
    /// (M5b): a relaunch follows the jobs a call left running.
    var voiceJobLedgerKey: String {
        "conduit.voiceJobLedger.\(activeDashboardID?.uuidString ?? "none").\(activeProfile)"
    }

    /// Saves only into the ledger this run brought back: a boundary's empty
    /// ledger never overwrites the next dashboard's or profile's.
    func saveVoiceJobLedger(_ saved: [SavedVoiceJob]) {
        guard let key = voiceJobLedgerRestoredKey, key == voiceJobLedgerKey else { return }
        // Only this ledger's jobs: another profile's stay in its own.
        let saved = saved.filter { $0.ledgerKey == nil || $0.ledgerKey == key }
        if saved.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: key)
        }
    }

    /// After whatever boundary is under way settles, takes back the active
    /// dashboard and profile's saved jobs.
    func scheduleVoiceJobLedgerRestore() {
        voiceJobLedgerRestoredKey = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let key = self.voiceJobLedgerKey
            guard self.voiceJobLedgerRestoredKey != key else { return }
            self.voiceJobLedgerRestoredKey = key
            self.voiceBackgroundJobSupervisor.restore(SavedVoiceJob.decode(self.defaults.data(forKey: key)))
        }
    }
    /// Logical identity of a Voice conversation suspended by an app lifecycle
    /// transition (scene backgrounded / device locked). Identity only: it
    /// never holds audio resources, gateway or transport references, session
    /// leases, or task handles. Recorded when the scene deactivates with the
    /// Voice sheet open, consumed by foreground restoration, and cleared by
    /// every destructive Voice boundary (explicit Close, spoken End
    /// Conversation, profile switch, server replacement, disconnect, forced
    /// sign-out, voice disabled). In memory only — process death
    /// intentionally loses it.
    struct SuspendedVoiceConversation: Equatable {
        let profile: String
        let sessionID: String
        let serverIdentity: String?
    }
    @Published var suspendedVoiceConversation: SuspendedVoiceConversation?
    /// One-shot intent for the Voice sheet's auto-listen on fresh
    /// presentation. Armed only by `openVoiceConversation` and consumed
    /// exactly once (by the sheet, or by the `.active` edge for a sheet that
    /// appeared off screen), so a restored suspended conversation can
    /// never hot-start the microphone when SwiftUI recreates the sheet's
    /// view identity. Lifecycle suspension and every destructive Voice
    /// boundary disarm it.
    var voiceSheetShouldAutoListen = false

    func consumeVoiceSheetAutoListen() -> Bool {
        guard voiceSheetShouldAutoListen else { return false }
        voiceSheetShouldAutoListen = false
        return true
    }

    /// The sheet's auto-listen. A sheet that appears while no Voice surface
    /// is presenting — Conduit opened in the background by an answered
    /// Hermes call (#558) — leaves the intent armed instead of spending it on
    /// a listen the capture gate would refuse; the `.active` scene edge
    /// starts it (`startDeferredVoiceSheetAutoListen`).
    func consumeVoiceSheetAutoListenIfPresenting() -> Bool {
        guard hasActiveVoiceSurface else { return false }
        return consumeVoiceSheetAutoListen()
    }

    /// Starts the auto-listen a sheet left armed because it appeared before
    /// Conduit was on screen. Every boundary that must not hot-start the
    /// microphone (Close, background suspension, a CallKit mute) disarms the
    /// intent first, and it is consumed on the main actor right before the
    /// listen, so a Close in between wins.
    func startDeferredVoiceSheetAutoListen() {
        // Early out only: the consume inside the task is the decision.
        guard showVoiceSheet, voiceSheetShouldAutoListen else { return }
        Task { [weak self] in
            guard let self, self.showVoiceSheet, self.consumeVoiceSheetAutoListenIfPresenting() else { return }
            await self.voiceConversationController.startListening()
        }
    }

    /// The profile the voice conversation controller's current session was
    /// opened for. Close-time mute persistence is keyed on this rather than
    /// on session liveness alone: an audio interruption or any boundary that
    /// stops the controller must still let a same-profile Close persist the
    /// user's mute, while a Close arriving after a profile flip (the sheet's
    /// deferred `onDismiss`) must not write the outgoing profile's mute into
    /// the now-active profile's blob.
    var voiceControllerSessionProfile: String?

    // MARK: - Wake phrase (#174) (AppState+WakePhrase.swift)

    /// Device-local wake phrase bindings, keyed by dashboard and profile.
    lazy var wakeConfiguration = WakeConfigurationStore(defaults: defaults)
    lazy var wakeWordService = AppleSpeechWakeWordService()
    lazy var wakeLifecycle = WakeLifecycleCoordinator(service: wakeWordService)
    /// The store is not observable: this publish is what re-renders Voice
    /// settings and wakes the lifecycle (via objectWillChange) after a
    /// wake setting changes.
    @Published var wakeSettingsRevision: UInt64 = 0
    /// Why foreground wake listening last stopped or could not start.
    @Published var wakeListeningFailure: String?
    /// Voice launches between a wake/Siri request and the sheet appearing:
    /// the listener must stay off across a profile switch in that gap.
    var voiceLaunchesInFlight = 0
    var lastAppliedWakeSnapshot: WakeLifecycleSnapshot?
    var wakeObservations: [AnyCancellable] = []
    var isWakeRefreshScheduled = false
    /// Cached `WakeRoutePolicy.currentRouteIsCarPlay()`: reading the audio
    /// route is too costly for every publish, so it refreshes only on route
    /// changes.
    var isWakeRouteCarPlay = false
    /// Cached `isOtherAudioPlaying`: another app's music or podcast pauses
    /// wake unless the user keeps it listening over other audio. Refreshed
    /// by `wakeOtherAudioMonitor`, the silence hint, and right before arming.
    var isWakeOtherAudioPlaying = false
    /// Wake is waiting for another app's audio to stop (shown in Voice
    /// settings).
    @Published var isWakePausedForOtherAudio = false
    /// Polls other apps' audio while wake is armed or waiting for it.
    /// AVAudioSession's silence hint reaches only an app with an active
    /// session, so it cannot tell a paused listener when the audio stops.
    var wakeOtherAudioMonitor: Task<Void, Never>?
    var wakeOtherAudioPollInterval: Duration = .seconds(2)
    /// Seam for tests.
    var wakeOtherAudioProbe: () -> Bool = { WakeRoutePolicy.isOtherAudioPlaying() }

    /// Whether the CarPlay scene currently presents the shared Voice
    /// conversation. Pure surface bookkeeping: CarPlay is another Voice
    /// presentation surface over the same runtime, never a second owner.
    @Published var isCarPlayVoiceSurfaceActive = false

    /// Manual per-message read aloud for completed assistant responses.
    /// TTS-only: independent of the voice conversation and of STT.
    lazy var messageReadAloudController = MessageReadAloudController(
        reportError: { [weak self] message in
            self?.errorMessage = message
        }
    )
    /// The bridge instance the read aloud gateway was built against. The
    /// gateway captures its bridge at init, so a gateway outliving its bridge
    /// (disconnect, re-login, bridge rotation) is dead and must be rebuilt
    /// rather than kept.
    var readAloudGatewayBridge: DashboardTicketBridge?
    /// The room bot whose profile read aloud last spoke as, and the profile
    /// that was active then. Kept while that profile stays active, so a
    /// capability refresh doesn't cut off a bot mid-message.
    var readAloudSpeaker: (profile: String, activeProfile: String)?
    /// Test-only seam: builds the read aloud gateway for a profile instead
    /// of `makeVoiceGateway`, so which profile a read speaks as can be
    /// checked without opening a socket.
    var readAloudGatewayFactoryForTesting: ((String) -> VoiceGatewayService?)?

    /// Test-only seam: stands in for `isLiveVoiceCallActive` in the voice
    /// Camera's live-call path, which needs a running call's controller.
    var liveVoiceCallActiveForTesting: Bool?

    /// Test-only seam: when set, the voice capability refresh requests
    /// through it instead of the dashboard bridge, keeping
    /// `refreshVoiceCapabilities` hermetic in tests. Mirrors the
    /// `installVoiceCapabilityStateForTesting` precedent.
    var voiceCapabilityRequesterForTesting: VoiceConfigurationRequesting?

    // MARK: - Cron

    @Published var cronJobs: [CronJob] = []
    @Published var cronRuns: [CronRun] = []
    /// The job `cronRuns` is the history of (#1707).
    private(set) var cronRunsJobID: String?
    /// The newest Run history read, so an older one that lands last is dropped.
    private var cronRunsLoad = 0
    /// Whether `cronRuns` holds an answer for `cronRunsJobID` yet, so the
    /// sheet says a job hasn't run only once it knows.
    @Published private(set) var cronRunsLoaded = false
    /// Why the open job's history couldn't be read, before any answer came:
    /// the sheet says so rather than that the job hasn't run.
    @Published private(set) var cronRunsFailure: String?
    @Published private(set) var cronJobsLoading = false
    @Published private(set) var cronJobActionID: String?
    /// Bumped by a job delete so a list load that started before it can't
    /// bring the deleted job back.
    private var cronJobsGeneration = 0
    /// The read in flight and the list generation, profile and connection
    /// it is for. A second ask for the same list joins it.
    private var cronJobsRead: (owner: String, token: UUID, task: Task<Void, Never>)?
    /// Cron jobs whose runs don't notify (AppState+CronNotifications), for
    /// the dashboard and profile in `cronMutedJobsKey`.
    @Published var cronMutedJobIDs: Set<String> = []
    @Published var cronMutedJobsKey: String?
    /// Cron jobs delivered to a Bot Chat whose report starts the bot's turn
    /// (the rest just show it), read with `cronMutedJobIDs` and keyed by
    /// the same `cronMutedJobsKey`.
    @Published var cronActingJobIDs: Set<String> = []
    /// Whether the host's Hermes shows a Bot Chat job's report without a
    /// turn (the plugin's `shows_reports`), for `cronMutedJobsKey`.
    @Published var cronShowsBotChatReports = false
    @Published var cronNotificationsChangingJobID: String?
    /// A notification read asked for while a save was in flight. The
    /// capability report can land then, so the read is repeated when the
    /// save ends instead of being dropped.
    var cronNotificationsReadDeferred = false
    /// Moves with every save, so a refresh that started before one drops its answer.
    var cronNotificationsGeneration = 0
    lazy var cronNotificationsClient = CronNotificationsClient(request: { [weak self] path, method, body in
        guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        return try await bridge.requestJSON(path: path, method: method, body: body)
    })
    /// Which sources' replies notify (Settings > Notifications, #115).
    lazy var replySourcesClient = ReplySourcesClient(request: { [weak self] path, method, body in
        guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        return try await bridge.requestJSON(path: path, method: method, body: body)
    })

    // MARK: - Lifecycle coordination

    var reconciliationToken = UUID()
    /// Set by the resume admission gate when it rejects a contradictory or
    /// foreign-owned identity. Automatic-return recovery treats ordinary
    /// resume failures as retryable; a rejected identity is deterministic,
    /// so reconnect scheduling skips it instead of looping on the same
    /// contradiction. Main-actor state, valid for the current reconcile only.
    var reconciliationWasIdentityRejected = false
    /// Set only when the currently owned resume RPC definitively reports
    /// that its requested session no longer exists. Callers use this to
    /// retire a saved automatic-return target instead of retrying it forever.
    var reconciliationSessionWasNotFound = false
    /// Set when the resume RPC refused a Kanban worker's transcript (4132).
    /// Hermes never reopens one as a chat, so it also counts as not found:
    /// a saved automatic-return target is retired and a notification isn't
    /// retried. This flag keeps its own message from being reworded.
    var reconciliationWasKanbanWorker = false
    /// Catalog rows `session.resume` answered 4007 for during an automatic
    /// resume, per dashboard and profile, for this app run. The catalog can
    /// keep listing a conversation the gateway no longer resumes; without
    /// this, the retry after a failed fresh-chat create would select and
    /// probe the same dead rows again.
    var deadResumeRowIDs: [String: Set<String>] = [:]
    var reconciliation: Reconciliation?
    /// Side-agent answers that came in while a reconciliation was open.
    /// Hermes keeps no copy of them, so unlike the buffered stream they
    /// can't come back with a later transcript: they show once the boundary
    /// closes, whether its reconcile committed or was dropped.
    var heldSideAgentCompletions: [StreamEvent] = []
    var activeClientEpoch = UUID()
    var activeAssistantMessageId: String?
    var activeReasoningMessageId: String?
    var receivedReasoningForCurrentTurn = false
    /// Authoritative merged reasoning for the live thinking card. Raw deltas
    /// merge into this buffer immediately; the published transcript is only
    /// republished at a coalesced cadence so an expanded ThinkingCard cannot
    /// monopolize main-actor layout work during a live reasoning stream.
    var reasoningBuffer = ""
    var reasoningPublishTask: Task<Void, Never>?
    var hasScheduledReasoningPublish = false
    var streamingBuffer = ""
    /// The last row a `message.interim` sealed in the running turn.
    var interimRowID: String?
    /// Every row `message.interim` sealed while the current turn runs: its
    /// progress notes, which a call's chat seed leaves out (#1991). A
    /// finished reply can keep an interim row's id, so the id alone doesn't
    /// tell.
    var runningTurnNoteIDs: Set<String> = []
    /// Gateway deltas can arrive much faster than SwiftUI can lay out a chat
    /// transcript. Keep the authoritative buffer intact, but publish at a
    /// display-friendly cadence so an active response cannot monopolize the
    /// main actor (and make sheets or session rows feel untappable).
    var streamingPublishTask: Task<Void, Never>?
    /// A fast gateway can emit its final delta and completion inside one
    /// publish interval. Keep that final projection alive briefly so the UI's
    /// character reveal can drain instead of jumping straight to the result.
    var streamingCompletionTask: Task<Void, Never>?
    var pendingStreamingCompletion: PendingStreamingCompletion?
    var hasScheduledStreamingPublish = false
    var lastStreamingPublishBurst = 0
    var lastStreamingPublishDate: Date?
    var responseHapticConclusionTask: Task<Void, Never>?
    var responseHaptics = ResponseHapticState()
    var scenePhaseTask: Task<Void, Never>?
    var scenePhaseAttemptID: UUID?
    /// Keeps the chat socket answering Hermes' pings for a short while
    /// off screen, so a quick switch to another app comes back to the same
    /// connection (notifier #296).
    var backgroundConnectionGrace = BackgroundConnectionGrace()
    /// The first seconds back on screen: a reconnect that finishes in that
    /// time doesn't show "Reconnecting…" over the saved chat. Long enough
    /// for a sign-in refresh, a ticket and the socket over a slow remote
    /// link; a message sent meanwhile ends it, so its wait is explained
    /// (#1624).
    @Published var isReturningQuietly = false
    var quietReturnTask: Task<Void, Never>?
    /// Armed only by a real .background phase. Ordinary inactive → active
    /// transitions (Control Center, incoming-call banner) must not be treated
    /// as reopening the app, so they never arm the preferred return surface.
    var hasEnteredBackgroundScenePhase = false
    var hasRequestedColdLaunchReturnSurface = false
    /// Presentation watermark for the preferred return surface: how far
    /// through `preferredReturnSurfaceRequest` MainView has consumed, kept
    /// here (not in view state) so it survives MainView teardown on sign-out.
    var consumedReturnSurfaceRequest: UInt64 = 0
    var deferredReturnSurfaceRequest: UInt64?
    var explicitSessionOpenTask: Task<Bool, Never>?
    var explicitSessionOpenRequestID: UUID?
    var activeAutomaticChatResumeWork: ChatResumeAutomaticWorkToken?
    var chatViewportSnapshotProvider: (
        id: UUID,
        capture: @MainActor () -> ChatRenderedViewportSnapshot?
    )?

    var chatViewportTransition: ChatViewportTransition?
    var activeNotificationOpenAttemptID: UUID?
    var activeAutomaticSyncOperation: AutomaticSyncOperation?
    var activeAutomaticReconnectOperation: AutomaticReconnectOperation?
    var reconnectTask: ChatResumeReconnectCancellation?
    let reconnectScheduler: ChatResumeReconnectScheduler
    let reconnectExecutor: ChatResumeReconnectExecutor?
    let chatResumeLifecycleOperations: ChatResumeLifecycleOperations
    let groupChatOperations: GroupChatLifecycleOperations
    /// The session-composer draft store. Lives ABOVE the room/session
    /// viewport swap (RootView replaces ChatView wholesale while a room is
    /// open), so a typed draft survives navigating to a room and back — a
    /// per-view store would be destroyed by the very navigation the save
    /// is meant to survive.
    let composerDraftStore = ComposerDraftStore()
    /// Coalesces presentation-cache flushes during streaming so we
    /// don't serialize and write UserDefaults on every WebSocket frame.
    var presentationCacheFlushTask: Task<Void, Never>?
    /// Session-list refresh after a Voice background job creates its chat.
    var voiceJobSessionListRefreshTask: Task<Void, Never>?
    /// The saved ledger this run took back (M5b), the only one it saves into.
    var voiceJobLedgerRestoredKey: String?
    /// Monotonic fence for deferred presentation-cache writes. Bumped when
    /// the active profile identity changes so a coalesced flush scheduled
    /// under one profile can never land in another profile's namespace.
    var presentationCacheProfileEpoch = 0
    /// Injectable stand-in for the debounce sleep. Defaults to wall-clock
    /// `Task.sleep`; deterministic tests park a pending flush mid-flight
    /// through this seam instead of racing its timing.
    let presentationCacheDebounceSuspension: @Sendable (
        Duration
    ) async throws -> Void

    var restoredPendingDecisionCardsAwaitingConfirmation: PendingDecisionRestorationGuard?
    /// Timestamp of the last successful coalesced cache flush; used to
    /// enforce a maximum 5-second interval even during continuous streaming.
    var lastPresentationCacheFlushDate: Date?
    /// Hermes currently starts its automatic title task against the launch
    /// profile's database. Keep a small, one-per-session recovery task for a
    /// secondary profile, then stand down as soon as Hermes has written one.
    let sessionTitleRecoveryTracker = SessionTitleRecoveryTracker()
    let sessionRenameOperationsOverride: SessionRenameOperation.Operations?
    let sessionCatalogLoaderOverride: ((Bool) async throws -> [SessionSummary])?
    /// Test seam mirroring `sessionCatalogLoader`: overrides the dashboard
    /// `/api/profiles` fetch inside `loadProfiles()` so success, failure, and
    /// late-response ordering can be modeled without a live WebKit bridge.
    private let profileDiscoveryLoaderOverride: (@MainActor () async throws -> [String: Any])?
    /// Published because `isRecoveringConnection` reads it.
    @Published var reconnectAttempts = 0
    /// Whether the UI scene is active. Backgrounded scene updates must
    /// complete within ~10s of wall clock before the watchdog kills the app
    /// (0x8BADF00D), so reconnect work is deferred while this is false.
    /// Deliberately true at init: launches head toward active, and blocking
    /// the cold-start restore on the first scene-phase event would regress
    /// startup. `.inactive` is treated like `.background` on purpose — it
    /// immediately precedes backgrounding on home-press, and a socket that
    /// dies under a system overlay is recovered by the `.active` scene task.
    var isSceneActive = true {
        // Off screen (the app leaving, CarPlay or the Watch taking over): a
        // reply that lands now pushes.
        didSet { if oldValue != isSceneActive { updateChatOnScreen() } }
    }
    /// Shortcut sends running now (Send to Hermes, and Siri's "Ask ‹chat›",
    /// which runs it), and the Pulse widget's buttons (issue 2190). A
    /// shortcut runs with Conduit in the background or not running at all,
    /// so while one runs it may reconnect on its own, as a call does, and
    /// only for the time of the run (#2164).
    var shortcutSendsRunning = 0
    /// A connect a run started, let finish after the run ended. Cut off at
    /// its next step it would leave Conduit "connecting" with nothing
    /// running, which only the phone coming on screen repairs, and every
    /// later run would wait on it in vain.
    var shortcutConnectHeld = false
    var owedPostConnectBootstrap: OwedPostConnectBootstrap?
    var connectedAt: Date?
    var sessionCatalogCache = SessionCatalogCache()
    /// Counts catalog reads as they start, so the slow read a chat sync left
    /// for later can tell that a newer read began while it was paging.
    private var catalogReadSequence: UInt64 = 0
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
    var leaveCatalogRefreshPending = false
    var leaveCatalogRefreshReportsFailure = false
    /// One chat on two devices (ChatSync.swift): when the list reads the
    /// catalog on its own, the open chat's registry checks, and the newest
    /// `session.active_list` snapshot they share, so the open chat reuses
    /// the list's poll instead of asking again.
    var chatListCatalogFreshness = ChatListCatalogFreshness()
    var openChatSync = OpenChatSync()
    /// Hermes' `sessions.changed` waiting for its catalog read, and the
    /// wait for one held back by the 5 s spacing.
    var catalogChangeSignal = CatalogChangeSignal()
    var catalogChangeReadTask: Task<Void, Never>?
    /// The registry read before reading rows a catalog read found moved.
    var openChatCatalogCheck: Task<Void, Never>?
    var latestActiveList: (rows: [LiveSessionStatus], profile: String, client: ObjectIdentifier, at: Date)?
    var openChatSyncRead: Task<Void, Never>?
    var openChatSyncReadID: UUID?
    /// Another device is getting the reply of a turn in the open chat; its
    /// working line says so.
    @Published var activeChatRepliesElsewhere = false
    /// The clock of those checks; tests move it.
    var chatSyncNow: @MainActor () -> Date = { Date() }
    /// Low Power Mode and Low Data Mode, which stretch every poll
    /// (PowerPolicy.swift); tests set them.
    var deviceConditions: @MainActor () -> DeviceConditions = { DeviceConditionsMonitor.shared.current }
    /// The jitter after a failed poll, in 0..<1; tests pin it.
    var pollJitter: @MainActor () -> Double = { Double.random(in: 0..<1) }
    /// The reconnect's jitter, in 0..<1; tests pin it.
    var reconnectJitter: @MainActor () -> Double = { Double.random(in: 0..<1) }
    /// Whether the dashboard answers at all, asked before a backed-off
    /// reconnect while Conduit is on screen. Nil skips it: tests that
    /// supply a reconnect executor have no gateway to ask, unless they set
    /// one.
    var gatewayReadinessProbe: (@MainActor (String) async -> Bool)?
    /// The app's one path monitor, followed for reconnects and the chat
    /// socket's check (`networkPathChanged`).
    private var deviceConditionsSubscription: AnyCancellable?
    var lastPathGeneration = 0
    /// When a path change last restarted the reconnect from its first step.
    var lastPathReconnectAt: Date?
    /// Bumped when a scheduled reconnect is canceled (Connection Repair, a
    /// sign-out), so a cycle waiting on its readiness probe doesn't go on.
    var reconnectCycleGeneration = 0
    /// The Chats list's poll pace, the sleep a return to the app or a tap
    /// cuts short, and a count of catalog reads that changed the list.
    var chatListPollPacer = ChatListPollPacer()
    let chatListPollSleep = WakeableSleep()
    /// Published so a project's page beside the open chat reads its own
    /// list again when the catalog changes (issue 1454). A change also
    /// wakes the list's poll from a long wait, so a turn that started or
    /// ended elsewhere (its messages move the catalog, which a gateway's
    /// `sessions.changed` reads at once) shows Running or stops without
    /// waiting out the backoff (issue 851).
    @Published var chatListCatalogGeneration = 0 {
        didSet {
            // Any wait past 4 s: a later step, or the first one stretched
            // by Low Power or Low Data Mode.
            let wait = PollCadence.stretched(chatListPollPacer.backoff.interval, by: deviceConditions())
            if wait > PollCadence.chatListSteps[0] { chatListPollSleep.wake() }
        }
    }
    /// The chat New Chat (or a project's new chat) just made here. Hermes
    /// lists a chat only once its first message is stored, so until then
    /// every catalog read would drop the row the create put in, and a list
    /// beside the open chat wouldn't show it (issue 1454). The lists keep
    /// it while it is the open chat and the catalog doesn't list it.
    @Published var newChatAwaitingListing: NewChatAwaitingListing?
    private var projectsRequestGeneration = 0
    /// Fences optional approval-queue reads across re-entrant MainActor
    /// awaits. A late response must not populate a replacement conversation.
    var pendingApprovalsRequestGeneration: UInt64 = 0
    let sessionPresentationCache: SessionPresentationCache
    let offlineChatCache: OfflineChatCacheStore
    let sessionYoloStore: SessionYoloStore
    let conversationIdentityIndex: ConversationIdentityIndex
    var sessionYoloWriteRevision: UInt64 = 0
    var sessionYoloWriteRevisions: [ChatScrollSessionKey: UInt64] = [:]
    /// Sessions whose user-initiated YOLO write is awaiting its RPC, tracked
    /// by reference count so overlapping writes for the same session each own
    /// an independent registration. The override store is only updated after
    /// the gateway accepts, so readers (notably the resume re-assert) must not
    /// treat the store as current while any write is in flight.
    var inFlightSessionYoloWriteCounts: [ChatScrollSessionKey: Int] = [:]
    /// The last session-level `yolo` the gateway itself reported, distinct
    /// from `runtime.yolo`, which also folds in the profile floor and the
    /// stored override.
    var lastReportedSessionYolo: Bool?

    // MARK: - Saved chat list (AppState+ChatList.swift)

    /// The reader has scrolled up off the chat's newest row (the scroller
    /// says so as it starts and stops following it): a long chat's oldest
    /// pages stay while they may be reading them.
    var chatReaderIsUpInOlderRows = false

    // MARK: - Persistence (AppState+Persistence.swift, AppState+PinSync.swift, AppState+Notices.swift, AppState+Voice.swift)

    let defaults: UserDefaults
    let activeSessionTitlesByProfileKey = "conduit.activeSessionTitlesByProfile.v1"
    let pinnedSessionIDsByProfileKey = "conduit.pinnedSessionIdsByProfile.v1"
    let pinnedRepliesByProfileKey = "conduit.pinnedRepliesByProfile.v1"
    let hostPinsAdoptedKey = "conduit.hostPinsAdopted.v1"
    let phoneOnlyPinsKey = "conduit.phoneOnlyPins.v1"
    let voiceJobSessionIDsByProfileKey = "conduit.voiceJobSessionIdsByProfile.v1"
    let activeProfileKey = "conduit.activeProfile"
    private let themePreferenceKey = "conduit.themePreference"
    let dashboardURLKey = "conduit.dashboardURL"
    private let modelVisibilityKey = "conduit.modelVisibility.v1"
    private let profileOrderKey = "conduit.profileOrder.v1"
    private let sessionFilterOrderKey = "conduit.sessionFilterOrder.v1"
    let reviewSummaryCacheKey = "conduit.reviewSummaryCache.v1"
    let knownProfilesKey = "conduit.knownProfiles.v1"
    /// Each known profile's name, for Siri and Shortcuts.
    let knownProfileNamesKey = "conduit.knownProfileNames.v1"
    /// Per-dashboard copies of profile-level presentation choices (#148).
    /// Profile names repeat across Hermes servers ("default" everywhere), so
    /// these are keyed by dashboard UUID. The pre-scoping global values were
    /// adopted by the registry's first dashboard.
    private let activeProfileByDashboardKey = "conduit.activeProfileByDashboard.v1"
    let profileOrderByDashboardKey = "conduit.profileOrderByDashboard.v1"
    private let modelVisibilityByDashboardKey = "conduit.modelVisibilityByDashboard.v1"
    private let modelQuickPicksByDashboardKey = "conduit.modelQuickPicksByDashboard.v1"
    let profileAppearanceStore: ProfileAppearanceStore
    var activeSessionTitlesByProfile: [String: String] = [:]
    var pinnedSessionIDsByProfile: [String: [String]] = [:]
    /// Pins shared with Hermes' own flag where the host has it (#555).
    var sessionPinSync = SessionPinSync()
    var hostPinWriteChain: Task<Void, Never>?
    /// Session ids of chats started as Voice background jobs, per profile,
    /// newest last. Presentation only (the session-list badge).
    @Published var voiceJobSessionIDsByProfile: [String: [String]] = [:]
    let chatResumeCoordinator: ChatResumeCoordinator
    let recoverySequence: ChatResumeRecoverySequence
    let clearSessionPresentationCache: () -> Void
    let initialChatResumeServerIdentity: String?

    var chatOwnSessionIDsCache: [ChatOwnSessionIDsKey: Set<String>] = [:]

    var activeChatSessionSummaryCache: (key: ActiveChatSessionSummaryKey, row: SessionSummary?)?

    init(
        defaults: UserDefaults = .standard,
        chatResumeCoordinator: ChatResumeCoordinator? = nil,
        recoverySequence: ChatResumeRecoverySequence = ChatResumeRecoverySequence(),
        loadSavedConnection shouldLoadSavedConnection: Bool = true,
        dashboardRegistry preloadedRegistry: SavedDashboardRegistry? = nil,
        clearSessionPresentationCache: @escaping () -> Void = {
            SessionPresentationCache.shared.clear()
        },
        sessionRenameOperations: SessionRenameOperation.Operations? = nil,
        sessionCatalogLoader: ((Bool) async throws -> [SessionSummary])? = nil,
        profileDiscoveryLoader: (@MainActor () async throws -> [String: Any])? = nil,
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        reconnectExecutor: ChatResumeReconnectExecutor? = nil,
        chatResumeLifecycleOperations: ChatResumeLifecycleOperations = .live,
        groupChatOperations: GroupChatLifecycleOperations = .live,
        sessionPresentationCache: SessionPresentationCache = .shared,
        offlineChatCache: OfflineChatCacheStore? = nil,
        sessionYoloStore: SessionYoloStore? = nil,
        conversationIdentityIndex: ConversationIdentityIndex? = nil,
        profileAppearanceStore: ProfileAppearanceStore? = nil,
        presentationCacheDebounceSuspension: (@Sendable (Duration) async throws -> Void)? = nil,
        deviceConditionsUpdates: AnyPublisher<DeviceConditions, Never>? = nil
    ) {
        self.presentationCacheDebounceSuspension =
            presentationCacheDebounceSuspension
            ?? { duration in try await Task.sleep(for: duration) }
        self.defaults = defaults
        // The picture you show in rooms over Links (RoomLooks.swift).
        self._roomPersonPicture = Published(wrappedValue: RoomLooksUpload.storedPersonPicture(defaults))
        let noticeChannel = NotifierPluginNoticeChannel.load(from: defaults)
        self.notifierPluginNoticeChannel = noticeChannel
        // The saved Update notices choice holds from the first status read.
        self._notifierPlugin = Published(wrappedValue: NotifierPluginStatus(
            followsMain: noticeChannel.followsMain,
            asksToUpdate: noticeChannel.asksToUpdate
        ))
        // The registry (and its legacy migration) loads before any connection
        // hydration: scoped auth records are meaningless without it.
        let initialRegistry = preloadedRegistry
            ?? SavedDashboardMigrator.loadRegistry(defaults: defaults)
        self.savedDashboardRegistry = initialRegistry
        // Screens that ask for a plugin update word it for a host that
        // manages the plugin from launch, before its status is read.
        PluginUpdateAsk.setActive(managedBy: NotifierPluginStatus.Remembered.managedBy(for: initialRegistry.activeDashboardID, in: defaults))
        // #1317 kept Off for older installs; Recent holds for every install
        // that hasn't picked one now (issue 1583).
        defaults.removeObject(forKey: ProjectChatsInChats.retiredDeviceDefaultKey)
        self.profileAppearanceStore = profileAppearanceStore ?? ProfileAppearanceStore(defaults: defaults)
        self.sessionPresentationCache = sessionPresentationCache
        self.offlineChatCache = offlineChatCache ?? Self.makeDefaultOfflineChatCache()
        self.sessionYoloStore = sessionYoloStore ?? SessionYoloStore(defaults: defaults)
        self.conversationIdentityIndex = conversationIdentityIndex ?? ConversationIdentityIndex()
        self.chatResumeCoordinator = chatResumeCoordinator
            ?? ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults))
        self.recoverySequence = recoverySequence
        self.clearSessionPresentationCache = clearSessionPresentationCache
        sessionRenameOperationsOverride = sessionRenameOperations
        sessionCatalogLoaderOverride = sessionCatalogLoader
        profileDiscoveryLoaderOverride = profileDiscoveryLoader
        self.reconnectScheduler = reconnectScheduler ?? scheduleChatResumeReconnectTask
        self.reconnectExecutor = reconnectExecutor
        if reconnectExecutor == nil {
            let probe: @MainActor (String) async -> Bool = { baseURL in
                await GatewayReadinessProbe.answers(baseURL)
            }
            gatewayReadinessProbe = probe
        }
        self.chatResumeLifecycleOperations = chatResumeLifecycleOperations
        self.groupChatOperations = groupChatOperations
        self.initialChatResumeServerIdentity = defaults
            .string(forKey: Self.chatResumeServerIdentityKey)
            .flatMap(Self.normalizedStoredChatResumeIdentity)
            ?? defaults.string(forKey: "conduit.dashboardURL")
                .flatMap(Self.normalizedChatResumeServerIdentity)
        chatResumeBehavior = self.chatResumeCoordinator.behavior
        chatReturnSurface = defaults.string(forKey: Self.chatReturnSurfaceKey)
            .flatMap(ChatReturnSurface.init(rawValue:)) ?? .conversation
        let initialDashboardID = initialRegistry.activeDashboardID
        if let primaryDashboardID = initialRegistry.dashboards.first?.id {
            self.profileAppearanceStore.adoptLegacyAppearance(into: primaryDashboardID)
        }
        defaultProfileName = self.profileAppearanceStore.loadDefaultName(dashboardID: initialDashboardID)
        profileAvatarURLs = self.profileAppearanceStore.loadAvatarURLs(dashboardID: initialDashboardID)
        profileGlowPicks = self.profileAppearanceStore.loadGlowColors(dashboardID: initialDashboardID)
        profileDeviceNames = self.profileAppearanceStore.loadDeviceNames(dashboardID: initialDashboardID)
        profileBotTitles = self.profileAppearanceStore.loadBotTitles(dashboardID: initialDashboardID)
        profileHermesNames = self.profileAppearanceStore.loadHermesNames(dashboardID: initialDashboardID)
        appIconChoice = UIApplication.shared.alternateIconName == AppIconChoice.light.alternateIconName ? .light : .dark
        themePreference = ThemePreference(
            rawValue: defaults.string(forKey: themePreferenceKey) ?? ""
        ) ?? .dark
        adoptLegacyProfilePreferences(into: initialRegistry.dashboards.first?.id)
        modelVisibility = scopedModelVisibility(dashboardID: initialDashboardID)
        modelQuickPicks = storedModelQuickPicks()[Self.dashboardPreferenceBucket(initialDashboardID)] ?? ModelQuickPicks()
        if let savedFilterOrder = defaults.stringArray(forKey: sessionFilterOrderKey) {
            sessionFilterOrder = Self.normalizedSessionFilterOrder(savedFilterOrder)
        }
        activeProfile = defaults.string(forKey: activeProfileKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
        if activeProfile.isEmpty { activeProfile = "default" }
        displayPreferences = storedDisplayPreferences(dashboardID: initialDashboardID, profile: activeProfile)
            ?? ProfileDisplayPreferences()
        // The global key is what cold launch opens (the resume state and
        // tests key off it). Mirror it into the active dashboard's entry so
        // the two can never disagree after launch; this also seeds the entry
        // on upgrade from pre-scoping builds.
        if let initialDashboardID {
            rememberActiveProfile(activeProfile, for: initialDashboardID)
        }
        activeSessionTitlesByProfile = defaults.dictionary(forKey: activeSessionTitlesByProfileKey) as? [String: String] ?? [:]
        if let data = defaults.data(forKey: pinnedSessionIDsByProfileKey),
           let stored = try? JSONDecoder().decode([String: [String]].self, from: data) {
            pinnedSessionIDsByProfile = stored
        }
        sessionStars = SessionStars(defaults: defaults)
        pinnedChatOrder = PinnedChatOrder(defaults: defaults)
        botOrder = BotOrder(defaults: defaults)
        groupRoomOrder = BotOrder(defaults: defaults, key: BotOrder.roomStorageKey, kind: .rooms)
        allProfilesChatsSettings = AllProfilesChatsSettings(defaults: defaults)
        if let data = defaults.data(forKey: pinnedRepliesByProfileKey),
           let stored = try? JSONDecoder().decode([String: [PinnedReply]].self, from: data) {
            pinnedRepliesByProfile = stored
        }
        sessionPinSync = SessionPinSync(
            adopted: Set(defaults.stringArray(forKey: hostPinsAdoptedKey) ?? []),
            phoneOnly: Set(defaults.stringArray(forKey: phoneOnlyPinsKey) ?? [])
        )
        if let data = defaults.data(forKey: chatReadLedgerKey),
           let stored = try? JSONDecoder().decode(ChatReadLedger.self, from: data) {
            chatReadState = ChatReadState(ledger: stored)
        }
        if let data = defaults.data(forKey: voiceJobSessionIDsByProfileKey),
           let stored = try? JSONDecoder().decode([String: [String]].self, from: data) {
            voiceJobSessionIDsByProfile = stored
        }
        // Hydrate the visible profile list from the persisted known-profile
        // cache before any discovery runs. A cold launch must not present an
        // effectively empty list — starting from `[]` is what let a single
        // failed /api/profiles refresh collapse the picker to one entry and
        // persist that degraded list over the complete cache. The union also
        // heals a cache a pre-fix build already degraded: `default` and the
        // remembered active profile are re-added on first launch.
        profiles = orderedProfiles(
            (defaults.stringArray(forKey: knownProfilesKey) ?? []) + [activeProfile, "default"]
        )
        restoreActiveSessionState(for: activeProfile)
        restorePinnedSessions(for: activeProfile)
        // The saved Chats list and the chat it opens on are read ahead off
        // the main thread now, while the sign-in reads the keychain, so the
        // saved copy launch shows comes from memory more often than from a
        // file decoded on the main thread (issue 1963).
        if shouldLoadSavedConnection, let initialDashboardID {
            self.offlineChatCache.prefetch(dashboardID: initialDashboardID, profile: activeProfile, transcripts: 1)
        }
        if shouldLoadSavedConnection {
            beginLaunchSignIn()
        }
        // The monitor publishes on the main actor (willSet: `current` still
        // holds the old value, so the handler uses the one it is given).
        let monitor = DeviceConditionsMonitor.shared
        lastPathGeneration = monitor.current.pathGeneration
        networkPathUsable = monitor.current.pathSatisfied
        deviceConditionsSubscription = (deviceConditionsUpdates ?? monitor.$current.eraseToAnyPublisher())
            .sink { [weak self] conditions in
                MainActor.assumeIsolated { self?.deviceConditionsChanged(conditions) }
            }
        // After init's own defaults reads, so they don't queue behind it.
        sessionPresentationCache.prewarm()
        installRichDiffReader()
        installRichReviewReader()
    }

    /// A call that failed in the car for a reason the car couldn't name
    /// ("See your iPhone"), waiting for the phone's screen to come on.
    var carPlayFailureForPhone: String?

    // MARK: - Voice history (AppState+Voice.swift, AppState+AppLinks.swift, AppState+PinnedChatOrder.swift)
    //
    // Saved Gemini Live / GPT-Live calls and the Voice / Voice Jobs filters.
    // The conduit_push plugin writes a call's turns into the host's session
    // history (no agent turn) and keeps the voice tags; see VoiceHistory.swift.

    lazy var voiceHistoryClient = VoiceHistoryClient(request: { [weak self] path, method, body in
        guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        return try await bridge.requestJSON(path: path, method: method, body: body)
    })

    /// Voice tags from the Hermes host, keyed by `voiceHistoryKey`, then by
    /// session id.
    @Published var voiceSessionTagsByKey: [String: [String: VoiceSessionTag]] = [:]
    /// Bumped whenever a call-chat link lands, so observers (the Sessions
    /// drawer's nests) can re-resolve parents the row list alone doesn't
    /// show changing.
    @Published var voiceCallChatLinksRevision = 0
    var voiceTagsFetchedAt: [String: Date] = [:]
    var voiceTagRefreshTask: Task<Void, Never>?

    /// The call being saved: set when a live call starts, cleared when it
    /// closes. Nothing reaches the host until the call ends: a save while
    /// the call runs stalled it, so the call is only checkpointed on the
    /// device meanwhile.
    var voiceCallRecorder: VoiceTranscriptRecorder?
    /// The dashboard the recorded call is on, and its bridge when it had
    /// one. Switching selects the next dashboard before it closes the call,
    /// so the call's saves never go by the selection.
    var voiceCallDashboard: (id: String, owner: DashboardRuntimeOwner?)?
    /// The chat the recorded call is attached to, linked to its row once saved.
    var voiceCallAttachment: VoiceCallAttachment?
    lazy var voiceCallChatLinks = VoiceCallChatLinks.load(from: defaults)
    lazy var voiceSessionAliases = VoiceSessionAliases.load(from: defaults)
    var voiceCallCheckpointTask: Task<Void, Never>?
    var voiceCallTranscriptSubscription: AnyCancellable?
    var voiceCallCheckpointedTurns = 0
    var voiceCallCheckpointedAt = Date.distantPast
    /// What the last checkpoint stored, so one with nothing new (the
    /// 15-second timer in a quiet call) doesn't rewrite the outbox.
    var voiceCallCheckpointed: VoiceCallCheckpoint?
    /// The call whose closing save is still running: a job it started that
    /// reports in now is still tagged with its row.
    weak var closingVoiceCallRecorder: VoiceTranscriptRecorder?
    /// A closing save that runs longer than this no longer claims new jobs.
    var closingVoiceCallUntil: Date?
    /// A saved call the next live call continues (Resume Call).
    var pendingVoiceResume: (sessionID: String, context: VoiceResumeContext)?
    /// The last call attached to a chat, which a reconnect in the same chat
    /// goes on as (#556) instead of starting a second call.
    var lastChatCall: (recorder: VoiceTranscriptRecorder, chatID: String, startedAt: Date, endedAt: Date)?
    /// The call kept with its chat whose transcript is open (#556).
    @Published var chatCallTranscript: VoiceChatCall?
    /// The call card tap whose fetch may still set the transcript.
    var chatCallTranscriptRequest: UUID?
    /// A call Hermes made (#449) that the live call now connecting answers.
    var pendingHermesCall: HermesCallOpening?
    /// Opens the voice of a call answered in CallKit; the CallKit call's
    /// end cancels it.
    var hermesCallOpenTask: Task<Void, Never>?
    /// The answered call whose open may still end what it opened; cleared
    /// when voice starts any other way.
    var hermesCallOpenGeneration: UUID?
    /// What the live call now connecting was called about, read by its
    /// session builders (reconnects included) until the call closes.
    var liveHermesCall: HermesCallOpening?
    /// The question and approval cards the live call from Hermes has heard
    /// of, in its instructions or a note, by request id.
    var hermesCallToldCards: Set<String> = []
    /// The engine of the live call whose work Hermes may call about.
    var hermesCallbackEngine: VoiceCallEngine?
    /// Keeps the host's call presence while a live call runs (#449), and
    /// the profile it was set for.
    var hermesCallPresenceTask: Task<Void, Never>?
    var hermesCallPresenceProfile: String?
    /// The last call's "away", which a new call's presence goes after.
    var hermesCallPresenceRelease: Task<Void, Never>?
    /// A call from Hermes rings or runs in CallKit (HermesNativeCalls): like
    /// a CarPlay or Watch call, it keeps transport recovery going with the
    /// phone locked.
    @Published var isNativeHermesCallActive = false
    /// That call was answered here (not only ringing): see
    /// `isNativeCallVoiceSurfaceActive`.
    @Published var isNativeHermesCallAnswered = false
    /// Whether Conduit's phone screen is up, for a classic call's restart
    /// after an interruption (#1145). Test seam.
    var hermesCallPhoneOnScreen: @MainActor () -> Bool = { PhoneScenePresence.isInForeground }
    /// Whether the answered call's own voice runs (HermesNativeCalls). Test seam.
    var hermesCallVoiceRunning: @MainActor () -> Bool = { HermesNativeCalls.shared.isCallVoiceRunning }
    /// The call's CallKit mute: a classic voice the call opens while muted
    /// doesn't start listening on its own.
    var isNativeHermesCallMuted = false
    /// A profile's call settings on the host (AppState+HermesCalls), for
    /// the dashboard and profile in `hermesCallsStatusKey`.
    @Published var hermesCallsStatus: HermesCallsStatus?
    var hermesCallsStatusKey: String?
    /// Every read and save of `hermesCallsStatus` takes the next number;
    /// the shown status is from the highest one accepted, so a read answering
    /// late can't replace what a newer read or a save set.
    var hermesCallsStatusGeneration: UInt64 = 0
    var hermesCallsStatusAcceptedGeneration: UInt64 = 0
    /// Per dashboard and profile, the number of its last save: a read of
    /// that profile asked before it is older than what was saved. Other
    /// profiles' reads still land.
    var hermesCallsStatusSavedGeneration: [String: UInt64] = [:]
    lazy var hermesCallsClient = HermesCallsClient(request: { [weak self] path, method, body in
        guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        return try await bridge.requestJSON(path: path, method: method, body: body)
    })
    /// Calls whose closing save is still running, so the outbox doesn't
    /// save the same turns alongside it (possibly into a second new row).
    var voiceTranscriptsSaving: Set<String> = []
    /// What the live call now connecting continues, read by its session
    /// builders (reconnects included) until the call closes.
    var liveVoiceResumeContext: VoiceResumeContext?
    @Published var isPreparingVoiceResume = false
    /// Ended calls on the active dashboard and profile still waiting in the
    /// outbox, for Voice settings.
    @Published var pendingVoiceCallSaves = 0
    /// Set when the active host answered that it can't store voice calls
    /// (no plugin route, or no session store). Queued calls are kept.
    @Published var voiceCallSavesBlocked = false
    @Published var isSavingQueuedVoiceCalls = false
    /// What the last Save Now did, shown under the button until the next.
    @Published var voiceCallSaveNowResult: String?
    /// The key and waiting count the result was written for: it goes once
    /// either changes (another profile, or a later retry saved some).
    var voiceCallSaveNowResultState: (key: String, pending: Int)?

    /// Files sessions under Voice or Voice Jobs, here at once and on the
    /// host for every device.
    var voiceTagChain: Task<Void, Never>?
    var voiceTagGeneration = 0

    @Published var waitingCall: WaitingCall?

    // MARK: Minimised live voice

    /// The live call whose sheet was swiped away. The call keeps running
    /// while the conversation stays usable, and a bar above the composer
    /// brings the sheet back. Only End, a spoken goodbye, or a boundary
    /// teardown ends it.
    /// A call that fails while minimised keeps its bar on purpose: tapping
    /// it shows why and offers Try again or End. The bar clears on End (in
    /// the sheet or on the bar), a spoken goodbye, opening that mode again
    /// (from its sheet, the composer mic or Siri),
    /// another mode taking over, CarPlay releasing a stopped call, and
    /// boundary teardown (disconnect, sign-out, server or profile change).
    @Published var minimisedLiveVoice: VoiceCallEngine?

    // MARK: - Read state (#454) (AppState+Session.swift, AppState+ChatList.swift, AppState+PinSync.swift, AppState+Reconciliation.swift)

    let chatReadLedgerKey = "conduit.chatReadLedger.v1"

    // MARK: - Quoting into the composer (#385) (AppState+Composer.swift, AppState+ChatResume.swift, AppState+BotMode.swift)

#if DEBUG
    /// Cancellations `noteComposerUserEdit()` has made (tests): the latch's
    /// own evidence, since a cancellation that finds nothing published to
    /// clear publishes nothing either. Test-only; compiled out of release
    /// builds.
    var composerEditCancellationCount = 0
#endif

    /// Latch for `noteComposerUserEdit()`: set once an edit has invalidated
    /// the current generation's automatic-return intent, cleared when the
    /// next generation begins. Every automatic generation mints its token
    /// here (a cancelled token is stale, so a new one is always minted), so
    /// clearing at entry re-arms the composer for each new window.
    var composerEditClaimedAutomaticWork = false

    // MARK: - Group Chats (hosted rooms) (AppState+GroupChats.swift, AppState+ProfileSettings.swift)

    @Published var groupChatPhase: GroupChatPhase = .idle
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
    /// The open copy's opening tail read failed: its next tick reads the
    /// tail again.
    var activeRoomCopyNeedsTail = false
    /// Whether the open copy's opening tail has been read: the messages
    /// after it are new (Read replies aloud reads them).
    var activeRoomCopyTailRead = false
    /// Bumped by a copy's delete, so a copies read it overtook is dropped.
    var linkedRoomCopiesGeneration = 0
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
    @Published var groupRoomsListed = false
    /// The last `groups.list` answer was its last page: only then does a
    /// room missing from `groupRooms` prove it's gone.
    var groupRoomsComplete = false
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
    /// Whether the open chat's own sheet or prompt (Artifacts, Rename,
    /// Delete), or the open room's (its settings, info, picture, disband;
    /// issue 2064), covers it, so reading it doesn't clear its notifications
    /// yet (#1579). Set by V2ConversationScreen, RootView and GroupChatView;
    /// nothing redraws on it.
    var chatCoveredBySheet = false
    /// Bot Screen sheets open now, from any surface: one covers the open
    /// chat like `chatCoveredBySheet` (#1832). Nothing redraws on it.
    var botScreenSheetsOpen = 0

    @Published var activeRoomSurface: GroupRoomSurface? {
        // A room takes the chat's place without changing the open chat.
        didSet {
            // Another room (or none): no screen of it has left yet.
            if oldValue?.room.roomID != activeRoomSurface?.room.roomID { roomScreenLeft = false }
            // Another room straight from one: its notifications are read too (issue 2064).
            if (oldValue == nil) != (activeRoomSurface == nil) || oldValue?.room.roomID != activeRoomSurface?.room.roomID {
                updateChatOnScreen()
            }
        }
    }
    /// The open hosted room once Hermes has given its messages since it
    /// opened: until then it shows a kept or empty transcript, so its
    /// notifications haven't been read (issue 2064). Nothing redraws on it.
    var activeRoomLogRead: String? {
        didSet { if activeRoomLogRead != oldValue { updateChatOnScreen() } }
    }
    @Published var activeRoomReplay = GroupRoomReplay(roomID: "") {
        // An agent's new message may have a board kept for it (RoomBoards).
        didSet {
            roomReplayRevision &+= 1
            roomReplayChanged(from: oldValue)
        }
    }
    /// Counts every change to `activeRoomReplay`, so the header's kept
    /// statuses are read again after any replacement, even one that keeps
    /// the same range and newest event (issue 1968).
    var roomReplayRevision = 0
    /// The open room's boards on the host, oldest first (AppState+RoomBoards).
    @Published var activeRoomBoards: [RoomBoard] = []
    /// Boards replies name by line, by id, once read (LineBoards).
    @Published var lineBoards: [String: RichBoard] = [:]
    /// Boards replies name that the plugin no longer has (pruned: the
    /// newest 500, a month), or answered in a shape Conduit can't draw:
    /// not asked for again, and the reply says one was there.
    @Published var lineBoardsGone: Set<String> = []
    var lineBoardsAsked: Set<String> = []
    /// The dashboard and profile `lineBoards` were read from.
    var lineBoardsScope = ""
    /// Bumped whenever `lineBoards` is forgotten, so a read from before
    /// stores nothing (issue 2083).
    var lineBoardsGeneration = 0
    var lineBoardsReadOverride: ((String) async throws -> [String: Any])?
    var roomBoardsTask: Task<Void, Never>?
    /// Tests read a room's boards here in place of the dashboard.
    var roomBoardsReadOverride: ((String) async throws -> [String: Any])?
    /// Tests take the room messages Read replies aloud would queue here
    /// (message id, text) in place of the reader.
    var roomReadAloudQueueOverride: ((String, String) -> Void)?
    @Published var activeRoomDriverStatus: GroupDriverStatus?
    /// In a room over Links, each member by id (`GET /rooms/people`): its
    /// owner and whether it's out. Read when the room opens, when Group
    /// Info does, and after taking one out.
    @Published var activeRoomPeople: [String: RoomPerson] = [:]
    /// How the open room's other people and their agents look, as their
    /// own Conduits gave it (RoomLooks.swift).
    @Published var activeRoomLooks = RoomLooks.empty
    /// How each room over Links on Bots Home looks, by dashboard and room
    /// (RoomLooks.swift), for its tile's faces.
    @Published var homeRoomLooksByKey: [String: RoomLooks] = [:]
    var homeRoomLooksReadAt: [String: Date] = [:]
    /// The open room's host, as your Link names them, in a room someone
    /// else hosts (`GET /rooms/people`'s `home`).
    @Published var activeRoomHomeName: String?
    var activeRoomLooksReadAt: Date?
    /// When the open copy's room screen last read your agents' approvals:
    /// a quiet room's ticks read them only every
    /// `roomCopyQuietApprovalsInterval` (issue 2151).
    var activeRoomCopyApprovalsReadAt: Date?
    /// The room (epoch and id) whose looks are being read now.
    var activeRoomLooksReading: String?
    /// What was last given each dashboard's Hermes (`PUT /rooms/looks`).
    var sharedRoomLooks: [UUID: String] = [:]
    /// A looks share is on its way, and another change waits for it.
    var roomLooksSharing = false
    var roomLooksShareAgain = false
    /// Your room picture's changes so far: a read of the one Hermes keeps
    /// that started before the latest is dropped.
    var roomPersonPictureChanges = 0
    /// A change of your room picture on its way to Hermes: one at a time,
    /// so an older one can't land last (Settings waits on it).
    @Published var roomPersonPictureSaving = false
    /// Each bot's picture as sent, by the image it was made from.
    var roomLookPictures: [String: (image: UIImage, data: Data?)] = [:]
    /// The picture you show in rooms over Links, kept on this phone.
    @Published var roomPersonPicture: Data? = nil
    /// The latest people read started: an older one that answers later is
    /// dropped.
    var activeRoomPeopleRead = 0
    /// A poll's people read for posts it brought is under way.
    var activeRoomPeopleRereading = false
    /// A poll asked for another while one was under way: it runs next, so
    /// a post that came in meanwhile is named too.
    var activeRoomPeopleRereadWanted = false
    /// People reads this visit after one failed (in a copy, for your name),
    /// up to `roomCopyNameReadLimit`.
    var activeRoomPeopleRetries = 0
    /// The open room's last people read failed.
    var activeRoomPeopleReadFailed = false
    /// Whose the open room's people's posted messages are (RoomPosts.swift).
    @Published var activeRoomPostAttribution = RoomPostAttribution.none
    /// In a room someone else hosts, how your pending post stands as your
    /// Hermes last said; nil before it answers.
    @Published var activeRoomCopyPost: RoomPost? {
        didSet {
            // Another post, or none: what was asked about the last is moot.
            // The first answer about the same pending post isn't another.
            if activeRoomCopyPost == nil || (oldValue != nil && activeRoomCopyPost?.eventID != oldValue?.eventID) {
                activeRoomCopyPostAbsent = false
                activeRoomCopyPostWaits = 0
            }
        }
    }
    /// Your Hermes was asked about the pending post and doesn't have it.
    /// Published, as the waits are: either can change the pending row on a
    /// tick that changes nothing else.
    @Published var activeRoomCopyPostAbsent = false
    /// Ticks the pending post has been asked about since its copy took no
    /// more posts, or while your Hermes last said it's sending or posted,
    /// up to `roomCopyPostWaitLimit`.
    @Published var activeRoomCopyPostWaits = 0
    /// A refused post's text, for the room composer to take back.
    @Published var roomDraftHandBack: RoomDraftHandBack?
    @Published var roomApprovalAnswers: [String: RoomApprovalAnswer] = [:]
    /// Discussions whose Continue is on its way, so a second tap waits.
    @Published var continuingRoomDiscussions: Set<String> = []

    /// The last `activeRoomResponder` answer, keyed on what it reads, so a
    /// render that asks several times replays the log once.
    var roomResponderCache: (key: String, context: GroupRoomContext?, member: GroupMember?)?

    var roomMemberStatusCache: (inputs: RoomMemberStatusInputs, statuses: [String: GroupMemberStatus])?
    var roomSettledCache: (key: String, settled: Bool)?
    @Published var activeRoomSendInFlight = false
    /// A send whose outcome is unknown keeps its retry key (via the outbox):
    /// the retry reuses the SAME client event id, and the gateway's
    /// idempotent send turns the repeat into a no-op instead of a twin.
    @Published var pendingRoomMessage: GroupRoomOutbox.Pending?
    var groupRoomOutbox = GroupRoomOutbox()
    /// Pending sends of rooms that are not open, keyed by dashboard + room.
    /// Leaving a room mid-send (or with an ambiguous send) parks its retry
    /// key here; reopening restores it, so the text is never lost and a
    /// retry never mints a second id the gateway could not deduplicate.
    var parkedRoomOutboxes: [String: GroupRoomOutbox] = [:]
    /// Unsent room composer text, keyed like `parkedRoomOutboxes`.
    var groupRoomDrafts: [String: String] = [:]
    /// The events of rooms left this run, keyed like `parkedRoomOutboxes`:
    /// a room opened again shows them at once while its tail loads, and the
    /// tail replaces them (#1352).
    var keptRoomReplays: [String: GroupRoomReplay] = [:]
    /// The files staged in a room's composer, kept with its text. Their
    /// local copies are deleted when the draft is dropped.
    var groupRoomAttachments: [String: [Attachment]] = [:]
    /// The send-failure text currently shown in `errorMessage`, if any, so
    /// a settled send retires its own banner and nothing else.
    var roomSendErrorMessage: String?
    /// Rooms (keyed like `parkedRoomOutboxes`) with a `groups.send` still
    /// awaiting its answer. A room left and reopened mid-send shows its row
    /// as "Sending…", not "Not delivered", until that attempt resolves.
    /// Each send owns its entry by token, so a late send that outlived an
    /// identity teardown never retires a newer send's entry for the room.
    var inFlightRoomSendTokens: [String: UUID] = [:]

    /// Fences every in-flight room response and stops the poller. Runs at
    /// the server-identity boundary (with the rest of Bot Mode teardown), on
    /// a dashboard switch, and when a session open takes the viewport back.
    var groupRoomEpoch = 0
    /// The room the last open found gone (disbanded, or not found) as it
    /// read it, which closes back to the roster with nothing said: a
    /// notification's open says why (issue 2064). With the room epoch its
    /// close left, so a room, chat or dashboard opened since owns the screen.
    var roomFoundGoneOnOpen: (roomID: String, epoch: Int)?
    var groupRoomPollTask: Task<Void, Never>?
    /// The Group Chats probe asked again after a transient failure, so its
    /// notice clears on its own once Hermes answers (Eric 2026-11-04: it
    /// stayed after a reconnect the app never saw as a disconnect).
    var groupChatProbeRetry = TransientReadRetry()
    /// The same for the bot roster's "Could not refresh bots".
    var botRosterRetry = TransientReadRetry()

    /// The rooms in `keptRoomReplays`, the one left last at the end.
    var keptRoomReplayOrder: [String] = []
    /// Each room's reads in a row that failed.
    var talkingRoomMisses: [String: Int] = [:]
    /// A talking-rooms read is running.
    var talkingRoomsReading = false
    /// When the last talking-rooms read began.
    var talkingRoomsReadAt: Date?

    /// The room screens mounted, and whether each shows: the V2 shell
    /// keeps a hidden tab's screens mounted (#1827). Set by GroupChatView.
    var roomViewsShowing: [UUID: Bool] = [:]
    /// The open room's last screen went away while the room stayed open
    /// (a page pushed over it on one column).
    var roomScreenLeft = false

    // MARK: - Dashboard-scoped presentation (#148)

    static func dashboardPreferenceBucket(_ dashboardID: UUID?) -> String {
        dashboardID?.uuidString ?? "unscoped"
    }

    /// Re-reads everything profile-presentational for the newly selected
    /// dashboard. Runs whenever the selection changes (switch intent,
    /// adoption, removal), so dashboard B never renders A's label, photos,
    /// or hidden models, even while B is still connecting. Profile order is
    /// applied by `orderedProfiles` when B's profiles are discovered. The
    /// photo scan lists one small per-dashboard folder, only on a deliberate
    /// selection change.
    private func reloadDashboardScopedPresentation() {
        let dashboardID = activeDashboardID
        defaultProfileName = profileAppearanceStore.loadDefaultName(dashboardID: dashboardID)
        profileAvatarURLs = profileAppearanceStore.loadAvatarURLs(dashboardID: dashboardID)
        profileGlowPicks = profileAppearanceStore.loadGlowColors(dashboardID: dashboardID)
        profileDeviceNames = profileAppearanceStore.loadDeviceNames(dashboardID: dashboardID)
        profileBotTitles = profileAppearanceStore.loadBotTitles(dashboardID: dashboardID)
        profileHermesNames = profileAppearanceStore.loadHermesNames(dashboardID: dashboardID)
        modelVisibility = scopedModelVisibility(dashboardID: dashboardID)
        modelQuickPicks = storedModelQuickPicks()[Self.dashboardPreferenceBucket(dashboardID)] ?? ModelQuickPicks()
        restoreDisplayPreferences()
    }

    private static let displayPreferencesByProfileKey = "profileDisplayPreferencesByDashboard"

    private static func displayPreferencesKey(dashboardID: UUID?, profile: String) -> String {
        "\(dashboardPreferenceBucket(dashboardID)).\(profile)"
    }

    /// The preferences last read or set for this dashboard's profile.
    private func storedDisplayPreferences(dashboardID: UUID?, profile: String) -> ProfileDisplayPreferences? {
        let stored = defaults.dictionary(forKey: Self.displayPreferencesByProfileKey) as? [String: Data] ?? [:]
        guard let data = stored[Self.displayPreferencesKey(dashboardID: dashboardID, profile: profile)] else { return nil }
        return try? JSONDecoder().decode(ProfileDisplayPreferences.self, from: data)
    }

    private func rememberDisplayPreferences() {
        guard let data = try? JSONEncoder().encode(displayPreferences) else { return }
        var stored = defaults.dictionary(forKey: Self.displayPreferencesByProfileKey) as? [String: Data] ?? [:]
        stored[Self.displayPreferencesKey(dashboardID: activeDashboardID, profile: activeProfile)] = data
        defaults.set(stored, forKey: Self.displayPreferencesByProfileKey)
    }

    /// Another dashboard or profile: its last known preferences until its
    /// config is read, Hermes' defaults for one never read here.
    private func restoreDisplayPreferences() {
        displayPreferences = storedDisplayPreferences(dashboardID: activeDashboardID, profile: activeProfile)
            ?? ProfileDisplayPreferences()
    }

    /// One-time move of the pre-scoping global profile order and model
    /// visibility into the registry's first dashboard (the one they were set
    /// on). A later dashboard starts from its own defaults.
    private func adoptLegacyProfilePreferences(into primary: UUID?) {
        guard let primary else { return }
        let bucket = Self.dashboardPreferenceBucket(primary)
        if let legacyOrder = defaults.stringArray(forKey: profileOrderKey) {
            var orders = defaults.dictionary(forKey: profileOrderByDashboardKey) as? [String: [String]] ?? [:]
            if orders[bucket] == nil {
                orders[bucket] = legacyOrder
                defaults.set(orders, forKey: profileOrderByDashboardKey)
            }
            defaults.removeObject(forKey: profileOrderKey)
        }
        if let data = defaults.data(forKey: modelVisibilityKey) {
            if let legacy = try? JSONDecoder().decode(ModelVisibility.self, from: data) {
                var visibilities = storedModelVisibilities()
                if visibilities[bucket] == nil {
                    visibilities[bucket] = legacy
                    persistModelVisibilities(visibilities)
                }
            }
            defaults.removeObject(forKey: modelVisibilityKey)
        }
    }

    private func storedModelVisibilities() -> [String: ModelVisibility] {
        guard let data = defaults.data(forKey: modelVisibilityByDashboardKey),
              let stored = try? JSONDecoder().decode([String: ModelVisibility].self, from: data) else { return [:] }
        return stored
    }

    private func persistModelVisibilities(_ visibilities: [String: ModelVisibility]) {
        if let data = try? JSONEncoder().encode(visibilities) {
            defaults.set(data, forKey: modelVisibilityByDashboardKey)
        }
    }

    private func scopedModelVisibility(dashboardID: UUID?) -> ModelVisibility {
        storedModelVisibilities()[Self.dashboardPreferenceBucket(dashboardID)] ?? ModelVisibility()
    }

    private func storedModelQuickPicks() -> [String: ModelQuickPicks] {
        guard let data = defaults.data(forKey: modelQuickPicksByDashboardKey),
              let stored = try? JSONDecoder().decode([String: ModelQuickPicks].self, from: data) else { return [:] }
        return stored
    }

    private func persistModelQuickPicks(_ picks: [String: ModelQuickPicks]) {
        if let data = try? JSONEncoder().encode(picks) {
            defaults.set(data, forKey: modelQuickPicksByDashboardKey)
        }
    }

    /// Changes the active dashboard's Quick picks and keeps them.
    func updateModelQuickPicks(_ change: (inout ModelQuickPicks) -> Void) {
        var picks = modelQuickPicks
        change(&picks)
        guard picks != modelQuickPicks else { return }
        modelQuickPicks = picks
        var stored = storedModelQuickPicks()
        stored[Self.dashboardPreferenceBucket(activeDashboardID)] = picks
        persistModelQuickPicks(stored)
    }

    func rememberedActiveProfile(for dashboardID: UUID) -> String? {
        let map = defaults.dictionary(forKey: activeProfileByDashboardKey) as? [String: String] ?? [:]
        guard let profile = map[dashboardID.uuidString]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty else { return nil }
        return profile
    }

    private func rememberActiveProfile(_ profile: String, for dashboardID: UUID) {
        var map = defaults.dictionary(forKey: activeProfileByDashboardKey) as? [String: String] ?? [:]
        map[dashboardID.uuidString] = profile
        defaults.set(map, forKey: activeProfileByDashboardKey)
    }

    func forgetActiveProfile(for dashboardID: UUID) {
        var map = defaults.dictionary(forKey: activeProfileByDashboardKey) as? [String: String] ?? [:]
        guard map.removeValue(forKey: dashboardID.uuidString) != nil else { return }
        defaults.set(map, forKey: activeProfileByDashboardKey)
    }

    /// Records the active profile both as the cold-launch value and as the
    /// active dashboard's own choice, so switching back to a dashboard lands
    /// on its profile instead of whichever one the outgoing dashboard used.
    func persistActiveProfile(_ profile: String) {
        // Per-dashboard entry first, global key last: cold launch opens the
        // global key and mirrors it into the active dashboard's entry, so
        // an interrupted write can only lose the change, never split them.
        if let dashboardID = activeDashboardID {
            rememberActiveProfile(profile, for: dashboardID)
        }
        defaults.set(profile, forKey: activeProfileKey)
    }

    /// Drops every dashboard-scoped presentation choice of a removed
    /// dashboard.
    private func removeDashboardScopedPresentation(_ id: UUID) {
        profileAppearanceStore.removeAll(dashboardID: id)
        if dashboardsFinishingSetup.contains(id) { dashboardsFinishingSetup.remove(id) }
        // The Watch forgets its main profile name.
        shareWatchCallVoices()
        forgetActiveProfile(for: id)
        let bucket = Self.dashboardPreferenceBucket(id)
        var orders = defaults.dictionary(forKey: profileOrderByDashboardKey) as? [String: [String]] ?? [:]
        if orders.removeValue(forKey: bucket) != nil {
            defaults.set(orders, forKey: profileOrderByDashboardKey)
        }
        var visibilities = storedModelVisibilities()
        if visibilities.removeValue(forKey: bucket) != nil {
            persistModelVisibilities(visibilities)
        }
        var quickPicks = storedModelQuickPicks()
        if quickPicks.removeValue(forKey: bucket) != nil {
            persistModelQuickPicks(quickPicks)
        }
        forgetPulseHome(of: id)
        forgetPulseFoldedBriefs(of: id)
    }

    // MARK: Relay gateways each dashboard's host reported

    /// Per dashboard, each profile's gateway: `[dashboard id: [profile: gateway id]]`.
    private static let relayGatewayIDsByDashboardKey = "conduit.relayGatewayIDsByDashboardProfile"

    /// The relay gateway ids the active dashboard's host said its profiles
    /// pair this iPhone through. A push stamped with one of them came from
    /// that host, whatever dashboard its pairing was bound to.
    var activeDashboardRelayGatewayIDs: Set<String> {
        guard let activeDashboardID else { return [] }
        return relayGatewayIDs(of: activeDashboardID)
    }

    func relayGatewayIDs(of dashboardID: UUID) -> Set<String> {
        Set(storedRelayGatewayIDs()[dashboardID.uuidString]?.values.map { $0 } ?? [])
    }

    /// Every relay gateway a saved dashboard's host said it pairs this
    /// iPhone through.
    var knownRelayGatewayIDs: Set<String> {
        Set(storedRelayGatewayIDs().values.flatMap(\.values))
    }

    /// Nil unless every pairing of this dashboard's hosts is end-to-end
    /// encrypted with a key the host confirmed; true when every one is also
    /// quantum-safe (the details are in Settings > Notifications). Drawn on
    /// dashboard rows and shared with the Watch.
    func notificationsEncryption(of dashboardID: UUID) -> Bool? {
        let notifications = PushNotificationService.shared
        guard notifications.isEnabled else { return nil }
        let gatewayIDs = relayGatewayIDs(of: dashboardID)
        guard !gatewayIDs.isEmpty else { return nil }
        var allQuantumSafe = true
        for gatewayID in gatewayIDs {
            guard case .ensured(_, _, let quantumSafe) = notifications.encryptionAssurance(gatewayID: gatewayID) else { return nil }
            allQuantumSafe = allQuantumSafe && quantumSafe
        }
        return allQuantumSafe
    }

    /// Remembers that `dashboardID`'s host pairs `profile` with this iPhone
    /// through `gatewayID`, as that host said over its signed-in connection.
    /// The profile's last report replaces its earlier one, so a re-pairing
    /// (or another host now at that address) leaves no stale id behind.
    func recordRelayGatewayID(_ gatewayID: String, for dashboardID: UUID, profile: String) {
        let gatewayID = gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gatewayID.isEmpty, gatewayID.count <= 80 else { return }
        var stored = storedRelayGatewayIDs()
        guard stored[dashboardID.uuidString]?[profile] != gatewayID else { return }
        stored[dashboardID.uuidString, default: [:]][profile] = gatewayID
        saveRelayGatewayIDs(stored)
    }

    func forgetRelayGatewayID(for dashboardID: UUID, profile: String) {
        var stored = storedRelayGatewayIDs()
        guard stored[dashboardID.uuidString]?.removeValue(forKey: profile) != nil else { return }
        saveRelayGatewayIDs(stored)
    }

    func forgetRelayGatewayIDs(of dashboardID: UUID) {
        var stored = storedRelayGatewayIDs()
        guard stored.removeValue(forKey: dashboardID.uuidString) != nil else { return }
        saveRelayGatewayIDs(stored)
    }

    /// Settings > Notifications sorts pairings by these, so it redraws; and
    /// Pulse pushes from a host's gateways offer Quiet for today by them.
    private func saveRelayGatewayIDs(_ stored: [String: [String: String]]) {
        objectWillChange.send()
        defaults.set(stored, forKey: Self.relayGatewayIDsByDashboardKey)
        sharePulseQuiet()
    }

    private func storedRelayGatewayIDs() -> [String: [String: String]] {
        defaults.dictionary(forKey: Self.relayGatewayIDsByDashboardKey) as? [String: [String: String]] ?? [:]
    }

    /// The All pill stays fixed; the remaining session categories are local UI preference.
    func moveSessionFilters(fromOffsets: IndexSet, toOffset: Int) {
        sessionFilterOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
        defaults.set(sessionFilterOrder.map(\.rawValue), forKey: sessionFilterOrderKey)
    }

    /// The dashboard location is harmless preference data, unlike the one-time
    /// ticket stored in Keychain. Keep it after sign-out so the next login does
    /// not require re-entering a server address.
    var lastDashboardURL: String {
        defaults.string(forKey: dashboardURLKey) ?? connection?.baseUrl ?? ""
    }

    func rememberDashboardURL(_ url: String) {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(url) else { return }
        defaults.set(normalized, forKey: dashboardURLKey)
    }

    func saveModelVisibility(_ visibility: ModelVisibility) {
        let normalized = ModelVisibility(
            hiddenProviders: Array(Set(visibility.hiddenProviders.filter { !$0.isEmpty })).sorted(),
            hiddenModels: Array(Set(visibility.hiddenModels.filter { !$0.isEmpty })).sorted()
        )
        modelVisibility = normalized
        var visibilities = storedModelVisibilities()
        visibilities[Self.dashboardPreferenceBucket(activeDashboardID)] = normalized
        persistModelVisibilities(visibilities)
    }

    // MARK: - Connection Repair (Round 6)

    /// Dashboards a repair registered for a new address, by sign-in or
    /// password reconnect (`registerRepairDashboard`); cleared when a
    /// repair begins (either entry) and once one connects, so a later
    /// repair never inherits them.
    var repairRegisteredDashboardIDs: Set<UUID> = []

    // MARK: - Saved dashboards (#148)

    /// Resolves the saved dashboard reached at this URL. Normalized URLs are
    /// unique in the registry; `registerIfMissing` creates (but does not
    /// activate) an entry, for pre-connection writes such as the browser
    /// sign-in's Cloudflare token save.
    @discardableResult
    func resolveDashboardID(forNormalizedURL normalized: String, registerIfMissing: Bool) -> UUID? {
        if let existing = savedDashboardRegistry.dashboardID(atNormalizedURL: normalized) {
            return existing
        }
        guard registerIfMissing else { return nil }
        return registerDashboard(forNormalizedURL: normalized)
    }

    /// Registers a saved dashboard for this address (if missing) and returns
    /// its UUID — never optional, so adoption and pre-connection writes have
    /// one non-failable registration path.
    @discardableResult
    func registerDashboard(forNormalizedURL normalized: String) -> UUID {
        if let existing = savedDashboardRegistry.dashboardID(atNormalizedURL: normalized) {
            return existing
        }
        // The selected dashboard's own edited address is that dashboard,
        // moved, for every pre-connection write as for adoption. While it's
        // in use the move waits, and a dashboard added here is a new one.
        if let activeID = activeDashboardID,
           savedDashboardRegistry.dashboard(with: activeID)?.pendingURL == normalized,
           dashboardForSignIn(activeID)?.normalizedURL == normalized {
            return activeID
        }
        // A dashboard added here is its own, even at an address another
        // saved dashboard was moving to: that dashboard stays where it is.
        dropPendingDashboardMoves(toNormalizedURL: normalized)
        var registry = savedDashboardRegistry
        let id = UUID()
        let label = SavedDashboardLabel.derive(from: normalized, existingLabels: registry.dashboards.map(\.label))
        let isFirstDashboard = registry.dashboards.isEmpty
        registry.dashboards.append(SavedDashboard(id: id, label: label, normalizedURL: normalized))
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
        // Its first connection offers Finish setting up on Chats.
        dashboardsFinishingSetup.insert(id)
        if isFirstDashboard {
            // Pre-scoping appearance/preferences with no dashboard to own
            // them yet belong to the first one (same rule as launch).
            profileAppearanceStore.adoptLegacyAppearance(into: id)
            adoptLegacyProfilePreferences(into: id)
            // No reload: a registered dashboard is not selected yet, and
            // selecting it (adoptDashboard/switch) reloads through didSet.
        }
        return id
    }

    func resolveDashboardID(forURL baseURL: String, registerIfMissing: Bool) -> UUID? {
        let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolveDashboardID(forNormalizedURL: normalized, registerIfMissing: registerIfMissing)
    }

    /// Connection adoption: resolves the dashboard this connection belongs
    /// to (registering it when new) and makes it the active/selected target.
    /// Idempotent for reconnects. When the stored chat-resume identity still
    /// names this server by URL (the pre-adoption boundary ran before the
    /// dashboard existed), it is relabeled to the UUID so the next
    /// connection to this dashboard is recognized as same-server.
    @discardableResult
    func adoptDashboard(forNormalizedURL normalized: String) -> UUID {
        // The selected dashboard connecting at the address edited for it
        // in Settings is that dashboard, moved, not a second one.
        if savedDashboardRegistry.dashboardID(atNormalizedURL: normalized) == nil,
           let activeID = savedDashboardRegistry.activeDashboardID,
           savedDashboardRegistry.dashboard(with: activeID)?.pendingURL == normalized {
            settlePendingDashboardMove(activeID)
        }
        let id = registerDashboard(forNormalizedURL: normalized)
        if savedDashboardRegistry.activeDashboardID != id {
            var registry = savedDashboardRegistry
            registry.activeDashboardID = id
            savedDashboardRegistry = registry
            SavedDashboardRegistryStore.save(registry)
        }
        if let stored = defaults.string(forKey: Self.chatResumeServerIdentityKey),
           let normalizedStored = Self.normalizedChatResumeServerIdentity(stored),
           normalizedStored == normalized {
            defaults.set(id.uuidString, forKey: Self.chatResumeServerIdentityKey)
        }
        return id
    }

    /// Saves an address edited in Settings for the dashboard's next sign-in
    /// (`SavedDashboard.pendingURL`). Its current address cancels a move
    /// saved before; a password saved for the address it no longer moves to
    /// goes too, or its next sign-in would reach that address as a second
    /// dashboard.
    func stageDashboardMove(_ id: UUID, toNormalizedURL url: String) {
        guard let index = savedDashboardRegistry.dashboards.firstIndex(where: { $0.id == id }) else { return }
        if let previous = savedDashboardRegistry.dashboards[index].pendingURL, previous != url,
           let credentials = KeychainHelper.loadCredentials(dashboardID: id),
           Self.normalizedDashboardURL(credentials.baseURL) == previous {
            clearSavedPassword(dashboardID: id)
        }
        var registry = savedDashboardRegistry
        registry.dashboards[index].pendingURL = url == registry.dashboards[index].normalizedURL ? nil : url
        guard registry != savedDashboardRegistry else { return }
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
    }

    /// The saved dashboard as its next sign-in reaches it: an address edited
    /// in Settings takes effect now, unless it's the dashboard in use.
    func dashboardForSignIn(_ id: UUID) -> SavedDashboard? {
        if id == activeDashboardID && (isConnected || isConnecting) {
            return savedDashboardRegistry.dashboard(with: id)
        }
        return settlePendingDashboardMove(id)
    }

    /// Moves the dashboard to the address saved for it in Settings. What the
    /// old address signed in with can't reconnect at the new one: its ticket
    /// and cookie mirror go, so does a password saved for it, and a browser
    /// grant from another origin. A same-origin Cloudflare token follows
    /// (the plan's path-move rule). Keychain first, registry last: a move
    /// cut short is retried. An address another dashboard took meanwhile
    /// keeps it, and this one stays where it is.
    @discardableResult
    func settlePendingDashboardMove(_ id: UUID) -> SavedDashboard? {
        guard let dashboard = savedDashboardRegistry.dashboard(with: id) else { return nil }
        guard let newURL = dashboard.pendingURL else { return dashboard }
        if savedDashboardRegistry.dashboard(atNormalizedURL: newURL) != nil {
            dropPendingDashboardMoves(toNormalizedURL: newURL)
            return savedDashboardRegistry.dashboard(with: id)
        }
        let oldURL = dashboard.normalizedURL
        let sameOrigin = LoginCloudflareHandoff.sameOrigin(oldURL, newURL)
        KeychainHelper.clearSavedSession(dashboardID: id)
        if !sameOrigin {
            KeychainHelper.clearNativeOAuthTokens(dashboardID: id)
        }
        if let credentials = KeychainHelper.loadCredentials(dashboardID: id),
           Self.normalizedDashboardURL(credentials.baseURL) != newURL {
            clearSavedPassword(dashboardID: id)
        }
        if sameOrigin,
           let access = KeychainHelper.loadCloudflareAccess(dashboardID: id, for: oldURL), access.isConfigured {
            KeychainHelper.saveCloudflareAccess(access, origin: newURL, dashboardID: id)
        }
        guard let index = savedDashboardRegistry.dashboards.firstIndex(where: { $0.id == id }) else { return nil }
        var registry = savedDashboardRegistry
        registry.dashboards[index].normalizedURL = newURL
        registry.dashboards[index].pendingURL = nil
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
        // The old address's host reported them; the new one reports its own.
        forgetRelayGatewayIDs(of: id)
        // Who manages the plugin goes with the host: a moved entry's new host
        // says for itself. Signing out keeps it (same host).
        NotifierPluginStatus.Remembered.remember(nil, for: id, in: defaults)
        return registry.dashboards[index]
    }

    /// Cancels the moves saved for this address. The password saved for a
    /// move would send that dashboard's next sign-in here: it goes too.
    private func dropPendingDashboardMoves(toNormalizedURL url: String) {
        var registry = savedDashboardRegistry
        for index in registry.dashboards.indices where registry.dashboards[index].pendingURL == url {
            let id = registry.dashboards[index].id
            if let credentials = KeychainHelper.loadCredentials(dashboardID: id),
               Self.normalizedDashboardURL(credentials.baseURL) == url {
                clearSavedPassword(dashboardID: id)
            }
            registry.dashboards[index].pendingURL = nil
        }
        guard registry != savedDashboardRegistry else { return }
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
    }

    private static func normalizedDashboardURL(_ url: String) -> String {
        (try? ConnectionURLPolicy.normalizedBaseURL(url)) ?? url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The origin-matched Cloudflare token for the dashboard reached at this
    /// URL, read from that dashboard's scoped record only.
    func dashboardScopedCloudflareAccess(for baseURL: String?) -> CloudflareAccessCredentials? {
        guard let baseURL else { return nil }
        let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dashboardID = resolveDashboardID(forNormalizedURL: normalized, registerIfMissing: false) else { return nil }
        return KeychainHelper.loadCloudflareAccess(dashboardID: dashboardID, for: baseURL)
    }

    /// Saved password credentials for the dashboard reached at this URL.
    func savedCredentialsForDashboard(at baseURL: String) -> DashboardCredentials? {
        guard let dashboardID = resolveDashboardID(forURL: baseURL, registerIfMissing: false) else { return nil }
        return KeychainHelper.loadCredentials(dashboardID: dashboardID)
    }

    /// How a saved dashboard can sign in without typing, for the sign-in
    /// screen's list. Reads the Keychain: call it off the render path.
    func savedSignIn(for id: UUID) -> SavedSignInKind {
        if let credentials = KeychainHelper.loadCredentials(dashboardID: id) {
            return credentials.requiresFaceID ? .biometric : .password
        }
        if KeychainHelper.loadConnection(dashboardID: id) != nil
            || KeychainHelper.loadNativeOAuthTokens(dashboardID: id) != nil {
            return .session
        }
        return .signInNeeded
    }

    /// Records the username that just signed in to this dashboard, so a
    /// later sign-in starts with it filled in.
    func rememberDashboardUsername(_ username: String, dashboardID: UUID) {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = savedDashboardRegistry.dashboards.firstIndex(where: { $0.id == dashboardID }),
              savedDashboardRegistry.dashboards[index].username != trimmed else { return }
        var registry = savedDashboardRegistry
        registry.dashboards[index].username = trimmed
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
    }

    /// Sign Out deletes the saved password but keeps its username on the
    /// dashboard, for sign-ins saved before the registry recorded it.
    func keepUsernameForNextSignIn(dashboardID: UUID) {
        guard let credentials = KeychainHelper.loadCredentials(dashboardID: dashboardID) else { return }
        rememberDashboardUsername(credentials.username, dashboardID: dashboardID)
    }

    /// Bumped on every dashboard switch; a restore that started under an
    /// older generation must not install its connection underneath a newer
    /// switch.
    var dashboardSwitchGeneration: UInt64 = 0

    /// Switch to a saved dashboard. Switching is NOT disconnecting: the
    /// outgoing dashboard stays saved with its auth intact, but its runtime
    /// ownership (client, sessions, speech) is retired IMMEDIATELY through
    /// the authoritative `prepareChatResumeForConnection` boundary — a
    /// switch that then fails to authenticate must not leave the outgoing
    /// server streaming behind the new target's sign-in surface. The target
    /// becomes the selected dashboard BEFORE connecting, so a failed switch
    /// leaves it selected; no other dashboard is auto-connected.
    ///
    /// A switch runs to its end even when the task that asked for it is
    /// cancelled: by the time it signs in to the target it has already
    /// retired the outgoing connection, so stopping there leaves neither
    /// dashboard connected. A newer switch supersedes it by generation,
    /// never by cancellation. A notification's tap is the case in point:
    /// its route restarts when `isConnected` flips, which the retirement
    /// does, and that cancelled the target's sign-in halfway, leaving
    /// Conduit on the login screen "connecting" to it (issue 1888).
    func switchDashboard(to id: UUID, widgetLease: WidgetLaunchLease? = nil) async {
        await Task { @MainActor in
            await self.runDashboardSwitch(to: id, widgetLease: widgetLease)
        }.value
    }

    private func runDashboardSwitch(to id: UUID, widgetLease: WidgetLaunchLease?) async {
        // A pick from the list, or a launch's own switch (a widget, a draft).
        endLaunchDashboardChoice()
        if widgetLease == nil { widgetLaunchCoordinator.supersede() }
        guard widgetLease?.isCurrent != false else { return }
        widgetAwaitingInteractiveAuthenticationDashboardID = nil
        guard savedDashboardRegistry.dashboard(with: id) != nil else { return }
        if id == activeDashboardID && (isConnected || isConnecting) {
            // Already there: a same-dashboard reconnect is not a switch.
            return
        }
        guard let dashboard = dashboardForSignIn(id) else { return }
        // Another dashboard's waits never show on this one's chips.
        needsYou.reset(dashboardID: id)
        dashboardSwitchGeneration &+= 1
        let generation = dashboardSwitchGeneration
        let previousDashboardID = activeDashboardID
        // The outgoing dashboard's chat and Chats list as they show now are
        // what the next visit there opens to.
        recordOfflineChatCopy()
        keepBotChatCopy()
        // The owner taken for the chat on screen is this dashboard's.
        outgoingBotChatCopyOwner = nil
        recordSavedChatList()
        selectDashboardTarget(id)
        // Pulse's badge, marks and chat are the outgoing dashboard's.
        pulseUnseen = 0
        pulseSources = [:]
        pulseHomeChatID = nil
        // The Pulse widget stops reading the outgoing dashboard's feed; this
        // one's pass comes once it has connected.
        if let previousDashboardID, previousDashboardID != id { removePulseWidget(dashboardID: previousDashboardID) }
        rememberDashboardURL(dashboard.normalizedURL)
        let crossedServer = prepareChatResumeForConnection(to: dashboard.normalizedURL, dashboardID: id)
        retireConnectionRuntimeForDashboardSwitch()
        if crossedServer || previousDashboardID != id {
            // Resume on the target's own profile, not the outgoing
            // dashboard's: profile names are not shared between servers.
            // The boundary above already retired the outgoing profile's
            // speech, transcript, and catalogs. Checked against the
            // selection too: with no stored server identity (first switch
            // after a fresh install) the boundary reports no change.
            let targetProfile = rememberedActiveProfile(for: id) ?? "default"
            setActiveProfile(targetProfile)
            persistActiveProfile(targetProfile)
            restoreActiveSessionState(for: targetProfile)
            restorePinnedSessions(for: targetProfile)
        }
        // Mirrors cold launch: the target's own saved copy and Chats list,
        // kept while another dashboard was in use, show until it answers.
        // A browser sign-in's OAuth grant comes first, as it does there: it
        // mints a fresh ticket, where a saved one may already be spent, and
        // it is all a dashboard has left once a refused session was cleared.
        if KeychainHelper.loadNativeOAuthTokens(dashboardID: id) != nil {
            presentOfflineChatIfAvailable(dashboardID: id)
            showLogin = false
            isConnecting = true
            turnState = .synchronizing
            await restoreNativeOAuthConnection(
                baseURL: dashboard.normalizedURL,
                dashboardID: id,
                switchGeneration: generation,
                widgetLease: widgetLease
            )
            settleExpiredWidgetDashboardSwitch(generation: generation, widgetLease: widgetLease)
            return
        }
        if let credentials = KeychainHelper.loadCredentials(dashboardID: id) {
            if !credentials.requiresFaceID {
                presentOfflineChatIfAvailable(dashboardID: id)
                if offlineChatPresentation != nil {
                    showLogin = false
                    isConnecting = true
                }
            }
            await restoreSavedCredentials(credentials, dashboardID: id, switchGeneration: generation, widgetLease: widgetLease)
            settleExpiredWidgetDashboardSwitch(generation: generation, widgetLease: widgetLease)
            return
        }
        if let saved = KeychainHelper.loadConnection(dashboardID: id) {
            presentOfflineChatIfAvailable(dashboardID: id)
            // Cookie/ticket-based resume: keep the app shell up while the
            // bridge restores the dashboard's own cookie mirror.
            connection = saved
            showLogin = false
            isConnecting = true
            turnState = .synchronizing
            await restoreSavedConnection(saved, switchGeneration: generation, widgetLease: widgetLease)
            settleExpiredWidgetDashboardSwitch(generation: generation, widgetLease: widgetLease)
            return
        }
        // No reusable auth: present the sign-in surface seeded for this
        // dashboard's address.
        turnState = .idle
        if widgetLease != nil { widgetAwaitingInteractiveAuthenticationDashboardID = id }
        showLogin = true
    }

    /// A widget launch that expired while its dashboard switch was restoring
    /// stopped before connecting. The target is already selected and the
    /// outgoing connection retired, so it gets the sign-in surface a failed
    /// restore shows, not a connecting state nothing will finish.
    private func settleExpiredWidgetDashboardSwitch(generation: UInt64, widgetLease: WidgetLaunchLease?) {
        guard widgetLease?.isCurrent == false,
              switchGenerationIsCurrent(generation),
              !isConnected, client == nil else { return }
        isConnecting = false
        turnState = .idle
        showLogin = true
    }

    /// Runtime-only teardown of the live connection when switching
    /// dashboards. `prepareChatResumeForConnection` (called just before) owns
    /// the server-replacement state retirement; this retires the transport
    /// and connection-scoped surfaces it does not touch. Deliberately NOT
    /// disconnect(): no saved auth, cookie mirror, or registry state is
    /// cleared — the outgoing dashboard stays signed in while saved.
    private func retireConnectionRuntimeForDashboardSwitch() {
        // A plugin update follows one dashboard; Hermes finishes it alone.
        stopFollowingNotifierPluginUpdate()
        cancelChatResumeTransportRecovery()
        cancelScenePhaseAttempt()
        cancelScheduledReconnect()
        owedPostConnectBootstrap = nil
        lastConnectionFailure = nil
        pendingLoginFailure = nil
        errorMessage = nil
        client?.disconnect()
        client = nil
        // Fence already-queued callbacks from the outgoing server: they are
        // epoch-gated, and no new client is created on the authless path.
        activeClientEpoch = UUID()
        connection = nil
        isConnected = false
        isConnecting = false
        connectedAt = nil
        dashboardTicketBridge?.invalidate()
        dashboardTicketBridge = nil
        notifierPlugin = freshNotifierPluginStatus
        // A flush scheduled under the outgoing server must not write through
        // after the switch; the boundary already cleared the cache it would
        // resurrect content into.
        presentationCacheFlushTask?.cancel()
        presentationCacheFlushTask = nil
        messageReadAloudController.setGateway(nil)
        readAloudGatewayBridge = nil
        readAloudSpeaker = nil
        voiceConversationController.setGateway(nil)
        voiceCapabilitySnapshot = .unavailable
        isVoiceEnabled = false
        retireCapabilitySnapshot()
        retireOutstandingPreferredReturnSurfaceRequests()
        // An open call transcript is the outgoing dashboard's, and its fetch
        // still in flight must not open one over the next.
        dismissChatCallTranscript()
        retireCronJobsForDashboardSwitch()
    }

    /// The dashboard a request was sent to, through which bridge. Its
    /// result is applied only while both are still the current ones: a
    /// switch replaces the bridge, so a late answer from the dashboard
    /// switched away from changes nothing on the one now showing.
    struct DashboardRuntimeOwner {
        let dashboardID: UUID?
        let bridge: DashboardTicketBridge
    }

    /// The current dashboard and its bridge; nil without a bridge.
    func currentDashboardRuntimeOwner() -> DashboardRuntimeOwner? {
        dashboardTicketBridge.map { DashboardRuntimeOwner(dashboardID: activeDashboardID, bridge: $0) }
    }

    func ownsDashboardRuntime(_ owner: DashboardRuntimeOwner) -> Bool {
        owner.bridge === dashboardTicketBridge && owner.dashboardID == activeDashboardID
    }

    func switchGenerationIsCurrent(_ generation: UInt64) -> Bool {
        generation == dashboardSwitchGeneration
    }

    /// Marks a dashboard as the selected target without connecting. A failed
    /// switch leaves the target selected — retry/repair is presented for it,
    /// and no other dashboard is auto-connected.
    func selectDashboardTarget(_ id: UUID) {
        guard savedDashboardRegistry.dashboard(with: id) != nil else { return }
        guard savedDashboardRegistry.activeDashboardID != id else { return }
        var registry = savedDashboardRegistry
        registry.activeDashboardID = id
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
    }

    /// Sign Out of This Dashboard: clears the dashboard's reusable
    /// auth/session/cookie material — and nothing else. SavedDashboard
    /// metadata and every other dashboard's state are untouched. For the
    /// active dashboard this is the full Disconnect teardown, scoped.
    func signOutDashboard(_ id: UUID) {
        guard let dashboard = savedDashboardRegistry.dashboard(with: id) else { return }
        // The host signed in next reports its own gateways.
        forgetRelayGatewayIDs(of: id)
        // Drafts shared for this dashboard belong to the signed-out user.
        discardSharedDrafts(forDashboard: id)
        if id == activeDashboardID {
            // The signed-out user's waits leave the chips with them.
            needsYou.reset(dashboardID: nil)
            disconnect()
            return
        }
        removeWidgetSnapshot(dashboardID: id)
        liveTurnActivitiesEndDashboard(id.uuidString, false)
        endServerSignIn(dashboardID: id, baseURL: dashboard.normalizedURL)
        KeychainHelper.clearConnection(dashboardID: id)
        keepUsernameForNextSignIn(dashboardID: id)
        clearSavedPassword(dashboardID: id)
        wipeOfflineChatCache(dashboardID: id)
        ShortcutInboxQueue.forgetDashboard(id)
        // The dashboard is not connected, but its OWN web session may still
        // hold live cookies from an earlier session; sign-out removes the
        // identified WebKit store and the dashboard's native jar (plus
        // exact-host shared-jar residue). Sibling dashboards sharing a parent
        // domain are untouched.
        DashboardCookiePersistence.scheduleWebKitSessionClear(for: id)
        DashboardCookiePersistence.clearNativeCookies(dashboardID: id, baseURL: dashboard.normalizedURL)
    }

    /// Hands the dashboard's refresh tokens to Hermes' logout before its
    /// sign-in is deleted, so the server ends it too (#889). Call before
    /// `KeychainHelper.clearConnection`: it reads the native grant and the
    /// cookie mirror.
    func endServerSignIn(dashboardID: UUID, baseURL: String?) {
        guard let baseURL else { return }
        let cookies = DashboardCookiePersistence.mirroredCookies(dashboardID: dashboardID)
            + (DashboardCookiePersistence.nativeCookieStorage(for: dashboardID).cookies ?? [])
        serverSignOutQueue.signOut(
            dashboardID: dashboardID,
            baseURL: baseURL,
            refreshTokens: ServerSignOut.refreshTokens(
                native: KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID),
                cookies: cookies,
                baseURL: baseURL
            ),
            cloudflare: KeychainHelper.loadCloudflareAccess(dashboardID: dashboardID, for: baseURL)
        )
    }

    /// Remove Dashboard: deletes the SavedDashboard and clears ONLY its
    /// secure state. Removing the active dashboard leaves Conduit
    /// disconnected with the dashboard selection/add flow presented — no
    /// other saved dashboard is auto-connected.
    func removeDashboard(_ id: UUID) {
        guard let removed = savedDashboardRegistry.dashboard(with: id) else { return }
        let wasActive = id == activeDashboardID
        if wasActive {
            // Full scoped teardown of the active dashboard's auth and live
            // session (including its origin's cookies).
            disconnect()
        } else {
            signOutDashboard(id)
        }
        // Sign Out keeps the Cloudflare token; forgetting the dashboard
        // doesn't.
        KeychainHelper.clearCloudflareAccess(dashboardID: id)
        var registry = savedDashboardRegistry
        registry.dashboards.removeAll { $0.id == id }
        if registry.activeDashboardID == id { registry.activeDashboardID = nil }
        // Extra proxy headers are server configuration, not session auth:
        // sign-out keeps them, forgetting the server drops them — unless
        // another saved dashboard is still reached through the same origin.
        let removedOrigin = CustomHeaderPolicy.origin(forServerURL: removed.normalizedURL)
        if removedOrigin != nil,
           !registry.dashboards.contains(where: { CustomHeaderPolicy.origin(forServerURL: $0.normalizedURL) == removedOrigin }) {
            CustomHeaderStore.shared.removeHeaders(forServerURL: removed.normalizedURL)
        }
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
        removeDashboardScopedPresentation(id)
        forgetRelayGatewayIDs(of: id)
        // Who manages the plugin goes with the host: a moved entry's new host
        // says for itself. Signing out keeps it (same host).
        NotifierPluginStatus.Remembered.remember(nil, for: id, in: defaults)
        // Log to Hermes events waiting for it, and its inbox keys.
        ShortcutInboxQueue.forgetDashboard(id)
        // Location, health and phone sharing bound to it.
        endSharingWithRemovedDashboards()
        if wasActive {
            showLogin = true
        }
    }

    /// Location, health and phone sharing each go only to the dashboard they
    /// were turned on for. Once it's no longer saved, nothing can switch back
    /// to it, so sharing with it ends here, as turning it off without
    /// deleting would, and the next turn-on binds to the dashboard in use
    /// (issue 1800). Run when a dashboard is removed, and on each connect for
    /// one removed before this ran: connected, the saved dashboards were
    /// read for sure (before the first unlock they may not be, and an empty
    /// list then isn't a removal).
    func endSharingWithRemovedDashboards(saved: Set<UUID>? = nil) {
        let saved = saved ?? Set(savedDashboardRegistry.dashboards.map(\.id))
        LocationSharingController.shared.endSharing(unlessBoundTo: saved)
        // Each turn-off checks that sharing still goes there when it runs:
        // a turn-on for the dashboard in use may have come first.
        if let destination = healthSyncPreferences.destination, !saved.contains(destination.dashboardID) {
            Task {
                guard healthSyncPreferences.destination == destination else { return }
                await turnOffHealthSync(deleteFromHost: false)
            }
        }
        if let destination = phoneSync.preferences.destination, !saved.contains(destination.dashboardID) {
            Task {
                guard phoneSync.preferences.destination == destination else { return }
                await turnOffPhoneSync(deleteFromHost: false)
            }
        }
    }

    func makeClient(connection: HermesConnection, profile: String) -> HermesClient {
        let transportFactory: @MainActor () -> any HermesWebSocketTransport = chatResumeLifecycleOperations.makeTransport ?? { URLSessionWebSocketTransport() }
        let client = HermesClient(
            connection: connection,
            profile: profile,
            cloudflareAccess: dashboardScopedCloudflareAccess(for: connection.baseUrl),
            // The current bridge's authorizer: it attaches its session
            // cookies only to its own dashboard's address.
            requestAuthorizer: dashboardTicketBridge?.requestAuthorizer,
            transportFactory: transportFactory
        )
        // A reconnect off screen (CarPlay, a locked listen) keeps the
        // background keepalive.
        client.setKeepaliveBackgrounded(!isSceneActive && hasEnteredBackgroundScenePhase)
        let epoch = UUID()
        activeClientEpoch = epoch
        client.onEvent = { [weak self, weak client] event in
            // Read while the client delivers this event: the turn it names,
            // and the queued message it ran from.
            let turnGeneration = client?.deliveringEventGeneration
            let admissionID = client?.deliveringEventAdmissionID
            Task { @MainActor in
                guard let self, self.activeClientEpoch == epoch else { return }
                self.handleStreamEvent(event, turnGeneration: turnGeneration)
                if case .messageStart(let sessionID) = event, let admissionID {
                    self.noteQueuedTurnStarted(sessionID: sessionID, admissionID: admissionID)
                }
            }
        }
        client.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.activeClientEpoch == epoch else { return }
                self.handleDisconnect()
            }
        }
        return client
    }

    /// Cold-start restore of the saved connection. Its ticket was spent when
    /// it last opened the socket, so the dashboard bridge mints a fresh one
    /// first; the saved record is only the fallback when that mint fails.
    /// A failed mint alone never sends the user to login (requiring a freshly
    /// restored WebKit cookie before every launch was what turned a healthy
    /// saved Hermes session into login), but the fallback handshake can still
    /// be refused: `stopRecoveryForRefusedSocket` then stops recovery at the
    /// sign-in screen, while any other connect failure schedules a reconnect.
    func restoreSavedConnection(_ saved: HermesConnection, switchGeneration: UInt64? = nil, widgetLease: WidgetLaunchLease? = nil) async {
        guard widgetLease?.isCurrent != false else { return }
        // Early reads its connect didn't take (or that a restore given up
        // left) end with it.
        defer { startupReads.clear() }
        if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
            return
        }
        prepareDashboardBridge(for: saved.baseUrl)
        // Re-fence after the bridge's async setup window: never install a
        // stale switch's connection.
        if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
            return
        }
        guard widgetLease?.isCurrent != false else { return }
        // The saved ticket was spent when it last opened the socket (Hermes'
        // tickets are single-use and last 30 seconds), so a fresh one is
        // minted with the dashboard's cookies first, as the OAuth restore
        // does. A mint that fails leaves the saved record, which `connect`
        // handles like any other: a refused handshake goes to sign-in, any
        // other failure schedules a reconnect. A cancelled one (the bridge
        // torn down by a switch or a sign-out) ends this restore, as it
        // does the OAuth restore's: the spent ticket is never tried.
        var connection = saved
        do {
            let ticket = try await mintChatResumeTicket(for: saved)
            connection = HermesConnection(baseUrl: saved.baseUrl, ticket: ticket)
        } catch is CancellationError {
            if restoreOwnsFlow(switchGeneration), widgetLease?.isCurrent != false {
                isConnecting = false
                // The synchronizing state loadSavedConnection set goes too,
                // as a foreground boundary leaves an aborted recovery's: it
                // would keep the composer off with nothing left to clear it.
                if turnState == .synchronizing { setRunning(false) }
            }
            return
        } catch {}
        // Re-fence after the mint await.
        if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
            return
        }
        guard widgetLease?.isCurrent != false else { return }
        await connect(with: connection, profile: activeProfile)
        guard widgetLease?.isCurrent != false else { return }
    }

    func restoreSavedCredentials(
        _ credentials: DashboardCredentials,
        dashboardID: UUID? = nil,
        switchGeneration: UInt64? = nil,
        widgetLease: WidgetLaunchLease? = nil
    ) async {
        // A superseded dashboard switch owns the flow; this stale restore
        // must not prompt, spend network, or install its connection — and it
        // must not touch presentation state the newer switch now owns.
        if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
            return
        }
        guard widgetLease?.isCurrent != false else { return }
        let scopedDashboardID = dashboardID ?? activeDashboardID
        rememberDashboardURL(credentials.baseURL)

        // One Face ID unlock holds for the dashboard while Conduit runs: the
        // offline retries (each return from the Face ID sheet makes the scene
        // active again) must not ask again, or the sheet loops until the
        // server answers.
        let faceIDUnlockHeld = scopedDashboardID.map {
            faceIDUnlockedDashboards[$0] == Self.faceIDUnlockFingerprint(credentials)
        } ?? false
        if credentials.requiresFaceID, faceIDUnlockHeld {
            if let scopedDashboardID {
                // A retry keeps the copy already on screen.
                if offlineChatPresentation == nil {
                    presentOfflineChatIfAvailable(dashboardID: scopedDashboardID)
                }
                if offlineChatPresentation != nil {
                    showLogin = false
                    isConnecting = true
                }
            }
        } else if credentials.requiresFaceID {
            guard await unlockWithFaceID() else {
                // A superseded switch owns the flow: present nothing.
                guard restoreOwnsFlow(switchGeneration) else { return }
                guard widgetLease?.isCurrent != false else { return }
                // Face ID or Touch ID can't show off the phone screen (a call from Hermes
                // woke Conduit, or only CarPlay shows it): the saved session
                // connects, as it does when a locked phone keeps the
                // password unreadable.
                if widgetLease == nil, phoneScreenIsAway(), let scopedDashboardID,
                   restoreSavedSessionOffScreen(
                    dashboardID: scopedDashboardID,
                    baseURL: credentials.baseURL,
                    switchGeneration: switchGeneration
                   ) {
                    return
                }
                guard widgetLease?.isCurrent != false else { return }
                showLogin = true
                widgetLease?.fail(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
                return
            }
            // Re-fence after the biometric await: a superseded switch owns
            // the flow now.
            if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
                return
            }
            if let scopedDashboardID {
                faceIDUnlockedDashboards[scopedDashboardID] = Self.faceIDUnlockFingerprint(credentials)
            }
            // The user just unlocked the saved password for the selected
            // dashboard: the sign-in finishes even if the widget launch
            // expired meanwhile.
            if let scopedDashboardID {
                presentOfflineChatIfAvailable(dashboardID: scopedDashboardID)
                if offlineChatPresentation != nil {
                    showLogin = false
                    isConnecting = true
                }
            }
        }

        let signInStartedAt = Date()
        do {
            let access = scopedDashboardID.flatMap {
                KeychainHelper.loadCloudflareAccess(dashboardID: $0, for: credentials.baseURL)
            }
            let authenticatedConnection: NativeAuthConnection
            do {
                authenticatedConnection = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: access).connect(
                    username: credentials.username,
                    password: credentials.password
                )
                noteConnectionStep("Password sign-in and ticket", since: signInStartedAt)
            } catch {
                noteConnectionStep("Password sign-in and ticket", since: signInStartedAt, error: error)
                throw error
            }
            // Re-fence after the network await: never install a stale
            // switch's connection (its adoptDashboard would flip selection).
            if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
                return
            }
            if let scopedDashboardID {
                authenticatedConnection.commitCookies(dashboardID: scopedDashboardID)
            }
            await connect(with: HermesConnection(baseUrl: credentials.baseURL, ticket: authenticatedConnection.ticket), profile: activeProfile)
        } catch is CancellationError {
            // A superseded connect owns the flow from here; fall back to the
            // login screen silently — but only if THIS restore still owns
            // the flow. A stale restore (a newer switch won) writes nothing.
            if restoreOwnsFlow(switchGeneration) { showLogin = true }
        } catch {
            // A rejected saved password falls back to the native login screen
            // without erasing it, allowing the user to correct the account.
            // The typed classified handoff replaces the old string write, so
            // the composer banner never inherits a stale sign-in message.
            presentCredentialRestoreFailure(
                ConnectionFailureClassifier.classify(error),
                switchGeneration: switchGeneration
            )
        }
    }

    /// Dashboards whose saved password Face ID or Touch ID unlocked since
    /// launch, with a fingerprint of the password it unlocked: a different
    /// password saved later for the same dashboard asks again. Clearing the
    /// saved password (sign-out, removal, a switch to browser sign-in) drops
    /// it. The unlock holds while Conduit runs, also after a long time away,
    /// as a connected Conduit never asks again on return; a cold launch
    /// asks.
    var faceIDUnlockedDashboards: [UUID: SHA256.Digest] = [:]

    /// Clears the dashboard's saved password and the Face ID unlock that
    /// held for it: a password saved for it again asks again.
    func clearSavedPassword(dashboardID: UUID) {
        KeychainHelper.clearCredentials(dashboardID: dashboardID)
        faceIDUnlockedDashboards[dashboardID] = nil
    }

    private static func faceIDUnlockFingerprint(_ credentials: DashboardCredentials) -> SHA256.Digest {
        SHA256.hash(data: Data([credentials.baseURL, credentials.username, credentials.password].joined(separator: "\u{1f}").utf8))
    }

    /// Face ID or Touch ID for a saved password. Test seam.
    var unlockWithFaceID: @MainActor () async -> Bool = {
        guard BiometricAuth.isAvailable else { return false }
        return await BiometricAuth.authenticate(reason: AppLocalization.string("Unlock Conduit"))
    }

    /// Connects with the dashboard's saved session (its ticket, renewed with
    /// its cookies) instead of the Face ID-protected password, for a restore
    /// running off the phone screen. False when there is no saved session
    /// for that address.
    private func restoreSavedSessionOffScreen(
        dashboardID: UUID,
        baseURL: String,
        switchGeneration: UInt64?
    ) -> Bool {
        guard let saved = KeychainHelper.loadConnection(dashboardID: dashboardID),
              saved.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            return false
        }
        HermesCallTrace.shared.note("Face ID can't show off screen: using the saved session")
        noteConnectionStep("Saved session (Face ID can't show off screen)")
        connection = saved
        showLogin = false
        isConnecting = true
        turnState = .synchronizing
        Task { await restoreSavedConnection(saved, switchGeneration: switchGeneration) }
        return true
    }

    /// The saved sign-in, again, now that Conduit is on screen: the attempt
    /// made in the background couldn't show Face ID or read a password the
    /// locked phone kept. A dashboard with nothing saved left just shows its
    /// sign-in, as before.
    func retrySignInFromBackground() {
        signInWaitsForForeground = false
        // Launched before the first unlock after a restart, the Keychain
        // couldn't give the saved dashboards: read them again now. An
        // upgrade that ran on a locked phone couldn't read the old saved
        // password: it joins its dashboard now.
        if savedDashboardRegistry.dashboards.isEmpty {
            let stored = SavedDashboardMigrator.loadRegistry(defaults: defaults)
            if let primary = stored.dashboards.first?.id {
                // Pre-scoping appearance and preferences belong to the first
                // dashboard (same rule as launch). Adopted before selecting
                // it, so the selection's reload reads them.
                profileAppearanceStore.adoptLegacyAppearance(into: primary)
                adoptLegacyProfilePreferences(into: primary)
                savedDashboardRegistry = stored
                // Launch ordered the cached profiles with no dashboard's order.
                profiles = orderedProfiles(profiles)
            }
        } else {
            SavedDashboardMigrator.adoptLeftoverCredentials(into: savedDashboardRegistry)
        }
        // Nothing saved to sign in with (an off-screen switch to a dashboard
        // with no reusable auth): the sign-in card keeps its explanation.
        guard let dashboardID = activeDashboardID, hasSavedSignIn(dashboardID: dashboardID) else { return }
        HermesCallTrace.shared.note("Signing in again on screen (signed out in the background)")
        // The failure belongs to the background attempt; the retry reports
        // its own.
        pendingLoginFailure = nil
        lastConnectionFailure = nil
        errorMessage = nil
        loadSavedConnection(trigger: "retry on screen")
    }

    /// Whether the dashboard has anything `loadSavedConnection` signs in
    /// with: an OAuth grant, a saved password or a saved session.
    func hasSavedSignIn(dashboardID: UUID) -> Bool {
        KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) != nil
            || KeychainHelper.loadCredentials(dashboardID: dashboardID) != nil
            || KeychainHelper.loadConnection(dashboardID: dashboardID) != nil
    }

    /// Whether a restore that started under this switch generation may still
    /// write state. Nil generations (non-switch restore paths) always own.
    func restoreOwnsFlow(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return switchGenerationIsCurrent(generation)
    }

    /// The fenced failure presentation for a saved-credential restore: a
    /// superseded restore (a newer dashboard switch won) must not set
    /// `showLogin`, `pendingLoginFailure`, or `lastConnectionFailure` over
    /// the winner's state. Returns whether anything was written (test seam).
    @discardableResult
    func presentCredentialRestoreFailure(
        _ failure: ConnectionFailure,
        switchGeneration: UInt64?
    ) -> Bool {
        guard restoreOwnsFlow(switchGeneration) else { return false }
        if keepOfflineChatInsteadOfSignIn(failure) { return true }
        wipeOfflineChatCacheForSignIn(after: failure, dashboardID: activeDashboardID)
        lastConnectionFailure = failure
        showLogin = true
        pendingLoginFailure = .presenting(failure)
        // The saved-password restore never resets the plugin status.
        endLockScreenTurnsForSignIn(plugin: notifierPlugin.state)
        return true
    }

    /// Server-unreachable failures that leave the saved offline copy on
    /// screen instead of sending the user to sign-in. Authentication
    /// failures always go to sign-in. A server that refuses this network
    /// (an IP allowlist, issue #2092) is unreachable from here too: signing
    /// in again can't get past it.
    static func failureKeepsOfflineChat(_ failure: ConnectionFailure) -> Bool {
        switch failure {
        case .hostNotFound, .unreachable, .connectionRefused, .timedOut, .offline, .dashboardUnavailable, .accessDenied:
            return true
        default:
            return false
        }
    }

    /// Cold-launch restore failed because the server could not be reached:
    /// keep the read-only saved copy up (composer disabled) and retry on the
    /// next foreground or explicit Retry. Returns false when there is no
    /// copy or the failure needs sign-in.
    func keepOfflineChatInsteadOfSignIn(_ failure: ConnectionFailure) -> Bool {
        guard offlineChatPresentation != nil, Self.failureKeepsOfflineChat(failure) else { return false }
        lastConnectionFailure = failure
        isConnecting = false
        isConnected = false
        // Same state the saved-ticket path reaches through connect's failure:
        // recovery is pending, not synchronizing.
        turnState = .reconnecting
        showLogin = false
        return true
    }

    /// Retry from the offline copy. With no connection yet (the cold-launch
    /// restore never completed) this re-runs the saved-dashboard restore;
    /// otherwise the normal reconnect path owns recovery.
    func retryFromOfflineChat() {
        guard offlineChatPresentation != nil, !isConnecting else { return }
        if connection == nil {
            loadSavedConnection(trigger: "retry from offline copy")
        } else {
            // Same purpose rule as a foreground recovery: with no conversation
            // selected yet (a cold launch), the automatic resume picks it.
            let purpose = foregroundRecoveryPurpose
            Task {
                cancelChatResumeTransportRecovery()
                await executeReconnect(purpose: purpose)
            }
        }
    }

    /// An authentication failure means the saved copy can no longer be tied
    /// to a signed-in account: the next sign-in may be a DIFFERENT account on
    /// the same dashboard, so the dashboard's files go too — not just the
    /// in-memory copy. Unreachable-server failures keep them (they are what
    /// the copy exists for).
    func wipeOfflineChatCacheForSignIn(after failure: ConnectionFailure, dashboardID: UUID?) {
        guard !Self.failureKeepsOfflineChat(failure), let dashboardID else { return }
        wipeOfflineChatCache(dashboardID: dashboardID)
    }

    /// Every interactive sign-in (password, dashboard web login, native
    /// OAuth) starts from no saved copy for that dashboard: the account
    /// signing in may not be the one whose conversations were saved.
    func prepareInteractiveSignIn(baseURL: String) {
        prepareInteractiveSignIn(dashboardID: resolveDashboardID(forURL: baseURL, registerIfMissing: false))
    }

    func prepareInteractiveSignIn(dashboardID: UUID?) {
        guard let dashboardID else { return }
        wipeOfflineChatCache(dashboardID: dashboardID)
    }

    /// Opens sign-in from the offline copy. The copy leaves the screen (and
    /// memory) with it; the files stay on disk.
    func signInFromOfflineChat() {
        showLogin = true
    }

    func prepareDashboardBridge(for baseUrl: String) {
        let normalized = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let access = dashboardScopedCloudflareAccess(for: normalized)
        let dashboardID = resolveDashboardID(forURL: normalized, registerIfMissing: false)
        let storedNativeOAuthTokens = dashboardID.flatMap {
            KeychainHelper.loadNativeOAuthTokens(dashboardID: $0)
        }
        if dashboardTicketBridge?.baseURL != normalized
            || dashboardTicketBridge?.cloudflareAccess != access
            || dashboardTicketBridge?.extraHeaders != CustomHeaderPolicy.sendable(CustomHeaderStore.shared.headers(forServerURL: normalized))
            || dashboardTicketBridge?.matchesNativeOAuthTokens(storedNativeOAuthTokens) != true {
            // Header or sign-in changes keep the host, so its plugin status
            // still holds; a new host is asked again on connect.
            if dashboardTicketBridge?.baseURL != normalized {
                notifierPlugin = freshNotifierPluginStatus
            }
            dashboardTicketBridge?.invalidate()
            // The selected dashboard's request authority: its native grant
            // (or cookie mode), its origin and base path, and the other saved
            // dashboards it must never authorize for, read live so adding or
            // removing one applies at once.
            let requestAuthorizer = DashboardRequestAuthorizer.forDashboard(
                baseURL: normalized,
                dashboardID: dashboardID,
                cloudflareAccess: access,
                otherDashboardURLs: { [weak self] in
                    self?.savedDashboardRegistry.dashboards
                        .filter { $0.id != dashboardID }
                        .map(\.normalizedURL) ?? []
                }
            )
            let bridge = DashboardTicketBridge(
                baseURL: normalized,
                cloudflareAccess: access,
                dashboardID: dashboardID,
                requestAuthorizer: requestAuthorizer
            )
            bridge.onPageEvent = { [weak self, weak bridge] event in
                guard let self, let bridge, self.dashboardTicketBridge === bridge else { return }
                self.noteConnectionStep(event)
            }
            // Early reads through the bridge this replaces are no one's now.
            startupReads.clear()
            dashboardTicketBridge = bridge
        } else if let bridge = dashboardTicketBridge, bridge.requiresSignIn {
            // The same dashboard's page settled on sign-in, and a connection
            // is starting again: a browser sign-in just put a fresh session
            // in this dashboard's WebKit store. Load the page again so the
            // next ticket is minted with it, not refused by the old verdict.
            bridge.reload()
        }
    }

    /// Classification seam for the silent-renewal sign-in handoff: when a
    /// saved-password re-auth was attempted and failed, that error (429
    /// throttle, 401 rejection, 503 outage) explains far more than the bare
    /// bridge signInRequired. The winning error is classified — never
    /// rendered via errorDescription. Internal for unit testing.
    static func silentRenewalSignInFailure(
        reauthError: Error?,
        bridgeError: DashboardTicketBridgeError
    ) -> ConnectionFailurePresentation {
        .presenting(reauthError.map(ConnectionFailureClassifier.classify)
            ?? ConnectionFailureClassifier.classify(bridgeError))
    }

    /// Forces the sign-in screen with a classified failure presentation.
    /// Prefer this overload whenever the failure derives from an Error — the
    /// full presentation (title, actions, help routing) reaches the login
    /// card untouched.
    func requireSignIn(failure: ConnectionFailurePresentation) {
        performSignInRequired(pendingFailure: failure)
    }

    /// Forces the sign-in screen with a human-authored notice message. Only
    /// for genuinely hand-written strings — Error-derived text must go
    /// through requireSignIn(failure:) so it is classified, never rendered
    /// raw.
    func requireSignIn(message: String) {
        performSignInRequired(pendingFailure: .notice(title: AppLocalization.string("Sign-in didn’t complete"), message: message))
    }

    /// Which of the dashboard's Lock Screen turns a required sign-in ends.
    enum SignInLockScreenTurnsEnd: Equatable {
        /// None: off the phone screen the refusal is weak evidence, retried
        /// once Conduit is on screen.
        case keepAll
        /// Those whose push token this iPhone's current relay installation
        /// didn't take: the Conduit plugin still ends the others by push,
        /// whatever Conduit's own sign-in.
        case endNotOnRelay
        /// All of them: without the plugin nothing else will.
        case endAll

        /// `liveTurnActivitiesEndDashboard`'s `keepingThoseOnRelay`, or nil
        /// when none end.
        var keepingThoseOnRelay: Bool? {
            switch self {
            case .keepAll: nil
            case .endNotOnRelay: true
            case .endAll: false
            }
        }
    }

    /// What a required sign-in does to the dashboard's Lock Screen turns.
    /// What stays open: a plugin too old to push Live Activity updates,
    /// which no capability reports yet; a turn the relay took a token for
    /// then keeps counting until the system's own limit.
    nonisolated static func signInEndsLockScreenTurns(
        screenAway: Bool,
        plugin: NotifierPluginStatus.State
    ) -> SignInLockScreenTurnsEnd {
        guard !screenAway else { return .keepAll }
        if case .reported = plugin { return .endNotOnRelay }
        return .endAll
    }

    func performSignInRequired(
        pendingFailure: ConnectionFailurePresentation,
        keepingNativeGrant: Bool = false
    ) {
        cancelChatResumeTransportRecovery()
        invalidateReconciliation()
        invalidateGroupChatState()
        cancelSecondaryProfileTitleRecovery()
        client?.disconnect()
        client = nil
        owedPostConnectBootstrap = nil
        isConnected = false
        isConnecting = false
        connectedAt = nil
        connection = nil
        dashboardTicketBridge?.invalidate()
        dashboardTicketBridge = nil
        let pluginStateBeforeSignIn = notifierPlugin.state
        notifierPlugin = freshNotifierPluginStatus
        // A forced sign-out kills the bridge mid-playback; stop the read
        // aloud and drop its gateway the same way Disconnect does.
        messageReadAloudController.stop()
        messageReadAloudController.setGateway(nil)
        readAloudGatewayBridge = nil
        readAloudSpeaker = nil
        // Forced sign-out supersedes any suspended Voice conversation (the
        // restore-time connection identity check would fail closed anyway);
        // stop the controller and drop the sheet immediately like
        // Disconnect does instead of waiting for the next scene cycle.
        suspendedVoiceConversation = nil
        voiceSheetShouldAutoListen = false
        voiceControllerSessionProfile = nil
        voiceConversationController.stop()
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        showVoiceSheet = false
        clearClassicVoiceCards()
        projects = []
        supportsProjects = false
        projectsLoading = false
        projectsLoadFailed = false
        // Off the phone screen, a renewal is refused on thinner evidence: no
        // page retries, and a locked phone can't re-sign in with the saved
        // password. The saved session and copy stay for the retry on screen
        // (signInWaitsForForeground), which retires them if the dashboard
        // refuses it there too.
        if !phoneScreenIsAway() {
            if let dashboardID = activeDashboardID {
                // Forced sign-out is scoped like Disconnect: only the active
                // dashboard's saved ticket (and cookie mirror) is retired. A
                // refused socket keeps the native grant: a refusal is never
                // a sign-out.
                if keepingNativeGrant {
                    KeychainHelper.clearSavedSession(dashboardID: dashboardID)
                } else {
                    KeychainHelper.clearConnection(dashboardID: dashboardID)
                }
            }
            wipeOfflineChatCache(dashboardID: activeDashboardID)
        }
        turnState = .idle
        retireOutstandingPreferredReturnSurfaceRequests()
        // The banner content belonged to the session being torn down; with
        // the LoginView onAppear consume gone, this is what keeps a
        // connected-era error from resurfacing stale after re-login.
        errorMessage = nil
        showLogin = true
        pendingLoginFailure = pendingFailure
        endLockScreenTurnsForSignIn(plugin: pluginStateBeforeSignIn)
    }

    /// A refused or expired sign-in of the active dashboard (required,
    /// saved password, native OAuth restore): a turn of it nothing can end
    /// now stops counting up on the Lock Screen. A cancelled Face ID isn't
    /// a refusal, and leaves them for the retry. `plugin` is the notifier
    /// plugin's state before the sign-in reset it.
    func endLockScreenTurnsForSignIn(plugin: NotifierPluginStatus.State) {
        if let keepingThoseOnRelay = Self.signInEndsLockScreenTurns(
            screenAway: phoneScreenIsAway(),
            plugin: plugin
        ).keepingThoseOnRelay {
            liveTurnActivitiesEndDashboard(activeDashboardID?.uuidString, keepingThoseOnRelay)
        }
    }

    // MARK: - Session management (AppState+Session.swift)

    var isReadingNewestCatalogPage = false

    // MARK: - Bot management (create / edit / delete / avatars) (AppState+BotMode.swift)

    var keptBotRosterMemo: (key: String, roster: KeptBotRoster?)?

    /// Whether Hermes can generate pictures, as last asked
    /// (`refreshPictureGeneration`).
    @Published var canGeneratePictures = false

    // MARK: - New Chat (AppState+Session.swift)

    /// A New Chat on its way: the app's own, tapped while Conduit connects or
    /// synchronizes, or a widget's. Its chat shows at once as the new, empty
    /// one it will be, and Hermes creates it once it can.
    @Published var pendingNewChat: WidgetWorkspaceID? {
        didSet {
            guard oldValue != pendingNewChat else { return }
            // A chat an earlier New Chat created isn't this one: the New
            // Chat draft is this chat's from here.
            if pendingNewChat != nil { newChatOpenedSessionID = nil }
            schedulePendingComposerSendCheck()
            updateChatOnScreen()
        }
    }
    /// The app's own New Chat is creating its chat right now.
    @Published var isStartingNewChat = false

    // MARK: - Reactions (AppState+Reactions.swift)

    /// Test seam for the `message.react` transport; production leaves it
    /// nil and uses the live client.
    var messageReactionSender: (@MainActor (_ sessionId: String, _ target: MessageReactionTarget, _ emoji: String?) async throws -> MessageReactionResult)?
    /// Latest in-flight tapback per message id, so an older reply to a
    /// quick re-tap can't overwrite the newer one. Generations come from one
    /// counter that only grows, so a settled entry can be dropped without a
    /// later tap reusing a number an older request still holds.
    var reactionRequestGenerations: [String: Int] = [:]
    var lastReactionRequestGeneration = 0

    // MARK: - Chat takeover (AppState+NotifierPlugin.swift, AppState+ChatTakeover.swift, AppState+SendMessage.swift, AppState+YoloAndReasoning.swift)
    //
    // A send refused because Hermes Desktop or a terminal owns the chat
    // (SESSION_NOT_OWNED) offers "Take over"; see ChatTakeover.swift.

    /// Each bot's work, for the Bot Chat's Work strip and panel
    /// (AppState+BotWorkstreams.swift).
    /// Which bots' hosts can have a Bot Screen, as read (BotScreen.swift).
    let botScreens = BotScreenSupport()

    lazy var botWork: BotWorkStore = {
        let store = BotWorkStore()
        store.onWorkstreamsChanged = { [weak self] in self?.workstreamsChanged() }
        return store
    }()

    /// What the host's notifier plugin serves; Settings nudges an update.
    @Published var notifierPlugin = NotifierPluginStatus() {
        // A plugin that just said it takes on-screen reports gets the turn
        // already running; one that answered without Pulse ends the Pulse
        // this dashboard remembered.
        didSet {
            // Before the host has answered, the manager it last reported.
            let askedBefore = PluginUpdateAsk.managedAsk
            PluginUpdateAsk.setActive(managedBy: notifierPlugin.managedBy ?? (notifierPlugin.state == .unknown
                ? NotifierPluginStatus.Remembered.managedBy(for: activeDashboardID, in: defaults) : nil))
            // The Watch words its plugin failures from the phone's shared context.
            if PluginUpdateAsk.managedAsk != askedBefore { shareWatchCallVoices() }
            if oldValue.state != notifierPlugin.state {
                updateChatOnScreen()
                forgetPulseHomeIfGone()
                readPulseHomeIfUnknown()
                sharePulseQuiet()
            }
            // An open room's boards, once the plugin says it keeps them.
            if oldValue.reports(RoomBoard.capability) != notifierPlugin.reports(RoomBoard.capability) {
                refreshActiveRoomBoards()
            }
            // Each bot's workstreams, once the plugin says it keeps them, so
            // a resolved one leaves the Chats list.
            if !oldValue.reports(BotWorkstreamsClient.capability), servesBotWorkstreams {
                readUnreadBotsWork()
            }
        }
    }
    /// The plugin on its repository's main branch, once read. A reset for
    /// another host keeps it (`freshNotifierPluginStatus`).
    var latestNotifierPluginVersion: String?
    /// The stable plugin version, once read; kept like the latest.
    var stableNotifierPluginVersion: String?
    /// What each plugin version brings, once read (NotifierPluginChangelog).
    @Published var notifierPluginChangelog: NotifierPluginChangelog?
    /// Which plugin versions the update notice asks for (Settings >
    /// Conduit plugin > Update notices).
    @Published var notifierPluginNoticeChannel: NotifierPluginNoticeChannel
    /// Apple Health sharing with one Hermes profile.
    /// Off until the user turns it on in Settings > Health.
    @Published var healthSyncPreferences = HealthSyncPreferences.load()
    lazy var healthSync = HealthSyncEngine(source: HealthKitDataSource(), deviceName: { UIDevice.current.name })
    /// Calendar, Reminders, Focus and phone status shared with one Hermes
    /// profile, and the calendar changes Hermes asks for (AppState+PhoneSync).
    lazy var phoneSync: PhoneSyncEngine = {
        let engine = PhoneSyncEngine(calendarSource: EventKitPhoneSource(), statusSource: DevicePhoneStatusSource(),
                                     deviceName: { UIDevice.current.name })
        engine.onRanWithoutAsking = { [weak self] in _ = await self?.runPhoneSync(reason: .answered) }
        return engine
    }()

    /// The settings Hermes may change, and the changes it asked for
    /// (AgentSettings.swift).
    lazy var agentSettings = AgentSettingsSync(defaults: defaults)
    /// Preferences shared with this profile's other devices through the
    /// plugin (SyncedPreferences.swift, #1089).
    lazy var syncedPreferences = SyncedPreferencesController(defaults: defaults)
    /// Confirmations Hermes asks this iPhone to present (PresentedScreens.swift),
    /// and the cards it shows on a voice conversation's screen.
    lazy var presentedScreens: PresentedScreensSync = {
        let sync = PresentedScreensSync(defaults: defaults)
        sync.onCards = { [weak self] cards in self?.showPresentedCards(cards) }
        return sync
    }()
    /// A card Hermes showed during a Classic voice conversation, open over it.
    @Published var classicVoiceCard: PresentedCard?
    /// The cards `classicVoiceCard` holds, so ones arriving while it's open
    /// join it instead of replacing it.
    var classicVoiceCardParts: [PresentedCard] = []
    /// The Go confirmation for Apple Maps that opens without a tap, and
    /// until when: Hermes was just seen asking for it in the chat on screen.
    var mapsNavigateExpected: (promptID: String, until: Date)?

    lazy var chatTakeoverClient = ChatTakeoverClient(request: { [weak self] path, method, body in
        guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        return try await bridge.requestJSON(path: path, method: method, body: body)
    }, profileParameter: { [weak self] in
        self?.notifierPlugin.dashboardProfileParameter ?? "profile"
    })

    /// The refused chat's takeover offer or progress. The composer shows it
    /// only while that chat is the active one.
    @Published var chatTakeover: ChatTakeoverState? {
        didSet { returnHeldTakeoverMessageIfEnded() }
    }
    var chatTakeoverTask: Task<Void, Never>?
    /// The refused typed message an automatic takeover keeps and sends
    /// itself once the chat is Conduit's (issue 2140).
    var chatTakeoverHeldMessage: ChatTakeoverHeldMessage?
    /// The automatic takeover a typed send's refusal just started: the
    /// words that come back from that send are kept for it rather than put
    /// back in the composer.
    var chatTakeoverKeepsRefusedWords: String?
    var chatTakeoverReadyCount = 0

    /// The chat Conduit last took over automatically. A send refused again
    /// right after that offers the button instead of looping; a successful
    /// send clears it.
    var chatTakeoverAutomaticSessionID: String?
    /// The call requests `submitComposerForCall` is sending, while it is:
    /// their takeover waits in the call, not in the composer. A list, so
    /// calls overlapping on another text keep their own marks.
    var callSubmissionTexts: [String] = []

    /// The failed send's error under the composer, which leaving its chat
    /// clears: the composer shows `errorMessage` unlocked too.
    var sendFailureShown: String?

    // MARK: - Slash Commands (AppState+SlashCommands.swift)

    var lastSlashCatalogPayload: AnyCodable?

    // MARK: - Profiles and preferences

    /// Reads the older pages a chat sync left out, after it. Quiet on
    /// failure: the drawer keeps the newest page, and the next list load
    /// tries the full read again.
    func loadDeferredCatalogPages(after client: HermesClient, profile: String, dashboardID: UUID?) {
        Task { @MainActor [weak self] in
            // A sync abandoned for another profile or dashboard leaves the
            // read to that workspace's own sync.
            guard let self, self.client === client,
                  self.activeProfile == profile,
                  self.activeDashboardID == dashboardID else { return }
            await self.loadSessions(
                forceRefresh: false,
                requiredViewportTransitionGeneration: nil,
                reportsFailure: false,
                yieldsToNewerReads: true
            )
        }
    }

    /// The dashboard endpoint is authoritative. `session.list` is only a
    /// legacy fallback because it is backed by the gateway's current runtime
    /// database and can otherwise leak or omit profile history.
    func profileCatalog(
        using client: HermesClient,
        forceRefresh: Bool = false,
        deferringOlderPages: Bool = false,
        yieldsToNewerReads: Bool = false
    ) async throws -> ProfileCatalogLoad {
        catalogReadSequence &+= 1
        let readSequence = catalogReadSequence
        if let loadCatalog = chatResumeLifecycleOperations.loadCatalog {
            return ProfileCatalogLoad(
                sessions: try await loadCatalog(client, forceRefresh),
                olderPagesDeferred: false
            )
        }
        let profile = activeProfile
        if let dashboardTicketBridge {
            do {
                let cacheKey = "\(profile):exclude"
                let cronKey = "\(profile):cron"
                let maximumCatalogRetries = 3
                var catalogRetryCount = 0
                while true {
                    let generation = sessionCatalogCache.mutationGeneration
                    let shouldLoadHistory = sessionCatalogCache.shouldLoadFullHistory(
                        forKey: cacheKey,
                        forceRefresh: forceRefresh
                    )
                    // Cron sessions come from a separate request (the main
                    // query excludes them). Decide now and send it alongside
                    // the live list rather than after it (#417): the two are
                    // independent, and every round trip counts on a slow link.
                    // The commit below still rejects the pair if the cache
                    // changed while either was in flight.
                    let reusesCachedCron = !sessionCatalogCache.shouldLoadFullHistory(
                        forKey: cronKey,
                        forceRefresh: forceRefresh
                    ) && sessionCatalogCache.cachedSessions(forKey: cronKey) != nil
                    async let cronFetch: [SessionSummary]? = reusesCachedCron
                        ? nil
                        : timedCronCatalogFetch(profile: profile, using: dashboardTicketBridge)
                    let liveStartedAt = Date()
                    let scopedResult: DashboardSessionCatalog
                    do {
                        scopedResult = try await dashboardSessions(
                            profile: profile,
                            maximumPages: SessionCatalogCache.pageBudget(
                                fullHistoryDue: shouldLoadHistory,
                                deferringOlderPages: deferringOlderPages
                            ),
                            using: dashboardTicketBridge
                        )
                    } catch {
                        noteConnectionStep("Chat list", since: liveStartedAt, error: error)
                        throw error
                    }
                    let scoped = scopedResult.sessions.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    let olderPagesDeferred = shouldLoadHistory
                        && deferringOlderPages
                        && !scopedResult.isAuthoritative
                    noteConnectionStep(
                        olderPagesDeferred
                            ? "Chat list, newest \(scoped.count) rows"
                            : "Chat list, \(scoped.count) rows",
                        since: liveStartedAt
                    )

                    let cached = sessionCatalogCache.cachedSessionsToMerge(
                        remoteSessions: scoped,
                        isAuthoritative: scopedResult.isAuthoritative,
                        forKey: cacheKey
                    ).filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    let merged = uniqueSessions(scoped + cached)

                    let fetchedCronSessions = await cronFetch
                    let cachedCronSessions = sessionCatalogCache.cachedSessions(forKey: cronKey)?.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    let publishedCronSnapshot = self.cronSessions.filter {
                        sessionBelongsToProfile($0, profile: profile)
                    }
                    var didFetchCronSessions = false
                    let cronSessions: [SessionSummary]?
                    if reusesCachedCron, let cachedCronSessions {
                        cronSessions = cachedCronSessions
                    } else if let fetchedCronSessions {
                        cronSessions = fetchedCronSessions
                        didFetchCronSessions = true
                    } else {
                        // Keep a previous cron snapshot if one exists, but
                        // do not cache an empty result for a failed request.
                        cronSessions = nil
                    }

                    // A delete/archive/disconnect can run while either request
                    // is suspended. Never let this attempt overwrite the
                    // newer cache state; retry from the authoritative source.
                    guard profile == activeProfile,
                          self.dashboardTicketBridge === dashboardTicketBridge,
                          self.client === client else {
                        throw DashboardTicketBridgeError.notReady
                    }
                    // Up to 25 pages take a while: a read started meanwhile
                    // saw newer rows, so this one must not land after it.
                    if yieldsToNewerReads, readSequence != catalogReadSequence {
                        throw CatalogReadSuperseded()
                    }

                    let combined = uniqueSessions(
                        merged + (cronSessions ?? cachedCronSessions ?? publishedCronSnapshot)
                    )
                    if !combined.isEmpty || shouldLoadHistory == false {
                        var historyMarkers: [String: Date] = [:]
                        if scopedResult.isAuthoritative && !scoped.isEmpty {
                            historyMarkers[cacheKey] = Date()
                        }
                        if didFetchCronSessions {
                            historyMarkers[cronKey] = Date()
                        }
                        guard sessionCatalogCache.commit(
                            liveSessions: combined,
                            liveKey: cacheKey,
                            cronSessions: cronSessions,
                            cronKey: cronKey,
                            historyMarkers: historyMarkers,
                            at: generation
                        ) else {
                            catalogRetryCount += 1
                            guard catalogRetryCount < maximumCatalogRetries else {
                                sessionCatalogLog.warning(
                                    "Dashboard catalog mutation retry budget exhausted for \(profile, privacy: .public); using gateway fallback."
                                )
                                break
                            }
                            continue
                        }
                        sessionCatalogLog.notice("Dashboard catalog for \(profile, privacy: .public): \(combined.count, privacy: .public) sessions; \(self.sourceSummary(combined), privacy: .public)")
                        // Only rows fetched just now carry the host's current
                        // pin flags; cached ones may predate a change.
                        applyHostPins(scoped + (fetchedCronSessions ?? []), profile: profile, using: dashboardTicketBridge)
                        return ProfileCatalogLoad(
                            sessions: combined,
                            // A newest page that turned out to be the whole
                            // list is authoritative and already marked loaded.
                            olderPagesDeferred: olderPagesDeferred
                        )
                    }
                    break
                }
            } catch {
                guard profile == activeProfile,
                      self.dashboardTicketBridge === dashboardTicketBridge,
                      self.client === client else {
                    throw DashboardTicketBridgeError.notReady
                }
                // The deferred read only tops up a list the dashboard already
                // gave; the gateway's list must not replace it.
                if yieldsToNewerReads { throw error }
                sessionCatalogLog.error("Dashboard history failed; using gateway fallback: \(LogRedaction.message(error), privacy: .public)")
                // Keep older dashboard installations usable; the gateway is
                // still an authoritative fallback when the history endpoint is
                // unavailable.
            }
        }
        // A retry budget or an empty page can also land here. The deferred
        // read only tops up the dashboard's list, so it never takes the
        // gateway's instead.
        if yieldsToNewerReads {
            throw CatalogReadSuperseded()
        }
        let fallbackStartedAt = Date()
        do {
            let fallbackSessions = try await client.sessions().filter {
                sessionBelongsToProfile($0, profile: profile) && $0.messageCount != 0
            }
            noteConnectionStep(
                "Chat list from the gateway, \(fallbackSessions.count) rows",
                since: fallbackStartedAt
            )
            return ProfileCatalogLoad(sessions: fallbackSessions, olderPagesDeferred: false)
        } catch {
            noteConnectionStep("Chat list from the gateway", since: fallbackStartedAt, error: error)
            throw error
        }
    }

    /// The cron half of the catalog, run concurrently with the live list,
    /// already scoped to `profile`. A failure is nil, never an empty list: the
    /// caller keeps the previous cron snapshot rather than caching "no cron
    /// runs".
    ///
    /// Both requests share one dashboard page, so they share its fate: a
    /// request that stalls the page fails the other one too, and the live list
    /// then takes the gateway fallback. They start together with the same
    /// deadline, so a cron stall can only catch a live request that is about
    /// to time out anyway.
    private func timedCronCatalogFetch(
        profile: String,
        using bridge: DashboardTicketBridge
    ) async -> [SessionSummary]? {
        let startedAt = Date()
        do {
            let sessions = try await dashboardCronSessions(profile: profile, using: bridge).filter {
                sessionBelongsToProfile($0, profile: profile)
            }
            noteConnectionStep("Cron runs, \(sessions.count) rows", since: startedAt)
            return sessions
        } catch {
            // Cancelled because the live list failed (leaving the scope
            // cancels this child) or the whole sync was abandoned. That is
            // not a cron failure, so the timeline doesn't list it as one.
            if !(error is CancellationError) && !Task.isCancelled {
                noteConnectionStep("Cron runs", since: startedAt, error: error)
            }
            return nil
        }
    }

    /// A profile-scoped request may still return rows from another profile on
    /// older dashboards. Never let an explicitly tagged foreign session enter
    /// this profile's catalog or become selectable through its socket.
    func sessionBelongsToProfile(_ session: SessionSummary, profile: String) -> Bool {
        guard let owner = session.profile,
              !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return profilesMatch(owner, profile)
    }

    func profilesMatch(_ lhs: String, _ rhs: String) -> Bool {
        Self.profilesMatch(lhs, rhs)
    }

    nonisolated static func profilesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// Mirrors Hermes Desktop's `/api/sessions/{id}/messages` prefetch:
    /// fetches the session's persisted transcript through the dashboard
    /// history route (or the test seam standing in for it) and parses it with
    /// the production normalizer path. The typed outcome lets the resume
    /// reconciliation distinguish a missing history source — which triggers
    /// the legacy full-transcript resume — from an unrelated failure, which
    /// must surface instead of silently degrading.
    ///
    /// The request is explicitly bounded (tail-anchored page of
    /// `PersistedTranscriptPagination.pageSize` rows) so the transport and
    /// normalization cost of opening a conversation is bounded no matter how
    /// large the session grew. A response that carries the `order=latest`
    /// pagination echo answers under the paginated tail contract; one
    /// without it is a legacy one-shot full transcript and hydrates as
    /// before.
    /// Result of the foreground freshness tail read. Only the newest bounded
    /// `order=latest` page is ever requested. Unlike `persistedTranscriptOutcome`
    /// this deliberately has NO legacy one-shot fallback: a freshness check
    /// must never escalate into a full-transcript transfer just to prove
    /// currency — a backend that cannot serve the tail contract yields
    /// inconclusive evidence instead, and the authoritative resume/reconcile
    /// path owns any full hydration. (Gateway-only deployments without any
    /// history source therefore re-attach authoritatively on each armed
    /// return — the designed fallback, not a regression to optimize away.)
    enum ForegroundPersistedTailOutcome {
        /// Validated tail page with positively durable row ids.
        case hydrated(PersistedSessionTranscript)
        /// The response did not honor the `order=latest` + durable-identity
        /// contract — including a body with no message-rows array at all,
        /// which the authoritative resume path re-classifies and SURFACES as
        /// `HermesError.invalidResponse` (never silently absorbed here).
        case unsupportedTailContract
        /// The history source is structurally absent (no bridge/endpoint, or
        /// the endpoint answered 404/410/501): no bounded capability exists.
        case unavailable
        /// Transient trouble (timeout, 429/5xx, bridge not ready, network).
        case failed(Error)
    }

    /// Bounded tail-only read for the foreground freshness check: exactly one
    /// `order=latest offset=0` page request, parsed with the shared
    /// extraction/pagination/identity helpers, and stopping deliberately
    /// before `persistedTranscriptOutcome`'s legacy one-shot re-read.
    func foregroundPersistedTailOutcome(
        sessionId: String,
        profile: String,
        using bridge: DashboardTicketBridge?
    ) async -> ForegroundPersistedTailOutcome {
        let fetchOutcome = await fetchPersistedHistoryPayload(
            sessionId: sessionId,
            profile: profile,
            query: PersistedTranscriptPagination.tailQuery(offset: 0),
            using: bridge
        )
        switch fetchOutcome {
        case .unavailable:
            return .unavailable
        case .failed(let error):
            if Self.historySourceIsUnavailable(error) {
                // Structural endpoint absence: no bounded capability exists.
                return .unavailable
            }
            return .failed(error)
        case .payload(let response):
            guard let rawMessages = Self.persistedMessageRows(in: response) else {
                return .unsupportedTailContract
            }
            guard let page = PersistedTranscriptPagination.parse(response, rawRowCount: rawMessages.count),
                  page.honorsTailContract,
                  PersistedTranscriptWindow.rowsHaveDurableIdentity(rawMessages) else {
                return .unsupportedTailContract
            }
            return .hydrated(PersistedSessionTranscript(
                resolvedSessionId: Self.resolvedSessionId(in: response),
                messages: await Self.normalizeTranscriptRows(
                    rawMessages,
                    imageScope: Self.transcriptImageScope(in: response, sessionId: sessionId, profile: profile)
                ),
                page: page,
                durableRowIDs: Set(rawMessages.compactMap(Self.durablePersistedRowID(from:)))
            ))
        }
    }

    func persistedTranscriptOutcome(
        sessionId: String,
        profile: String,
        using bridge: DashboardTicketBridge?
    ) async -> PersistedTranscriptOutcome {
        let fetchStartedAt = Date()
        let fetchOutcome = await fetchPersistedHistoryPayload(
            sessionId: sessionId,
            profile: profile,
            query: PersistedTranscriptPagination.tailQuery(offset: 0),
            using: bridge
        )
        switch fetchOutcome {
        case .payload: noteConnectionStep("Chat history", since: fetchStartedAt)
        case .unavailable: noteConnectionStep("Chat history endpoint unavailable", since: fetchStartedAt)
        case .failed(let error): noteConnectionStep("Chat history", since: fetchStartedAt, error: error)
        }

        switch fetchOutcome {
        case .unavailable:
            return .unavailable
        case .failed(let error):
            // Only STRUCTURAL endpoint absence degrades to the single legacy
            // resume. Transient trouble (429, 5xx, status-0 WebKit/network
            // failures, request timeouts, a bridge that never became ready)
            // surfaces instead: a slow or failing BOUNDED read must never
            // silently become a full-transcript WebSocket transport (the
            // giant-payload path compact resume exists to eliminate).
            if Self.historySourceIsUnavailable(error) {
                sessionCatalogLog.debug("Persisted transcript unavailable for \(sessionId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                return .unavailable
            }
            sessionCatalogLog.debug("Persisted transcript failed for \(sessionId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return .failed(error)
        case .payload(let response):
            guard let rawMessages = Self.persistedMessageRows(in: response) else {
                return .failed(HermesError.invalidResponse)
            }
            let page = PersistedTranscriptPagination.parse(response, rawRowCount: rawMessages.count)

            // A pagination echo WITHOUT the `order=latest` tail contract
            // describes a backend that pages from the oldest end: honoring
            // its offsets would walk the transcript forward from row zero
            // and never reach the newest rows. A paginated-contract page
            // whose rows lack durable identity is equally unpageable —
            // overlap dedup and the graft key on the persisted row ID, and
            // id-less rows would normalize to page-local positional IDs.
            // Either way, re-read one-shot — the exact request
            // pre-pagination Conduit made — and treat the response as the
            // legacy full transcript. Shape-detected from the response,
            // never version-sniffed, and performed at most once.
            if let page, !(page.honorsTailContract
                && PersistedTranscriptWindow.rowsHaveDurableIdentity(rawMessages)) {
                let oneShotOutcome = await fetchPersistedHistoryPayload(
                    sessionId: sessionId,
                    profile: profile,
                    query: PersistedTranscriptPagination.legacyQuery,
                    using: bridge
                )
                switch oneShotOutcome {
                case .payload(let fullResponse):
                    guard let fullRows = Self.persistedMessageRows(in: fullResponse) else {
                        return .failed(HermesError.invalidResponse)
                    }
                    return .hydrated(PersistedSessionTranscript(
                        resolvedSessionId: Self.resolvedSessionId(in: fullResponse) ?? Self.resolvedSessionId(in: response),
                        messages: await Self.normalizeTranscriptRows(
                            fullRows,
                            imageScope: Self.transcriptImageScope(in: fullResponse, sessionId: sessionId, profile: profile)
                        ),
                        page: nil
                    ))
                case .unavailable:
                    return .unavailable
                case .failed(let error):
                    if case DashboardTicketBridgeError.oversizedResponse = error {
                        // The legacy one-shot transcript outgrew the safe
                        // bound: an old backend attempted the entire
                        // transcript. Surface the transcript-specific
                        // compatibility copy.
                        return .failed(LegacyTranscriptOversizedError(limit: DataURLLimits.maxJSONResponseBytes))
                    }
                    if Self.historySourceIsUnavailable(error) {
                        return .unavailable
                    }
                    return .failed(error)
                }
            }

            // The dashboard server returns `messages`; the API-server variant
            // returns `data`, so accept both public Hermes response shapes.
            return .hydrated(PersistedSessionTranscript(
                resolvedSessionId: Self.resolvedSessionId(in: response),
                messages: await Self.normalizeTranscriptRows(
                    rawMessages,
                    imageScope: Self.transcriptImageScope(in: response, sessionId: sessionId, profile: profile)
                ),
                page: page,
                durableRowIDs: Set(rawMessages.compactMap(Self.durablePersistedRowID(from:)))
            ))
        }
    }

    private func fetchPersistedHistoryPayload(
        sessionId: String,
        profile: String,
        query: String,
        using bridge: DashboardTicketBridge?
    ) async -> PersistedTranscriptFetchOutcome {
        if let persistedTranscript = chatResumeLifecycleOperations.persistedTranscript {
            return await persistedTranscript(sessionId, profile, query)
        }
        guard let bridge else { return .unavailable }
        if let page = await historyPagePayload(sessionId: sessionId, profile: profile, query: query, using: bridge) {
            return page
        }
        do {
            return .payload(try await bridge.requestJSON(
                path: Self.sessionMessagesPath(sessionId: sessionId, profile: profile, query: query)
            ))
        } catch {
            // requestJSON's readiness poll is the bounded wait for a cold
            // or reloading bridge; whatever it raises is classified with
            // the seam-sourced failures below. Note the bridge caps REST
            // response size (DataURLLimits.maxJSONResponseBytes), so an
            // oversized transcript also lands here rather than silently
            // degrading the resume.
            return .failed(error)
        }
    }

    /// A voice read's page: the newest one through the history page when the
    /// plugin serves it (the rows a chat open kept stand in), any other page
    /// or a refused one through Hermes' route as before.
    func voiceHistoryPage(
        sessionId: String,
        profile: String,
        query: String,
        using bridge: DashboardTicketBridge
    ) async -> [String: Any]? {
        if query == PersistedTranscriptPagination.tailQuery(offset: 0) {
            switch await historyPagePayload(sessionId: sessionId, profile: profile, query: query, using: bridge) {
            case .payload(let page)?: return page
            // The link's own trouble: no second wait on Hermes' route.
            case .failed?: return nil
            case .unavailable?, nil: break
            }
        }
        return try? await bridge.requestJSON(
            path: Self.sessionMessagesPath(sessionId: sessionId, profile: profile, query: query)
        )
    }

    /// Dashboard and profile scopes whose plugin refused the history page
    /// route this run (`HistoryPage.isRefusedForScope`).
    private var historyPageRefusedScopes: Set<String> = []

    /// The page through the plugin's history page route (#1525), with the
    /// rows this phone kept from the last read of the chat's newest page
    /// sent as their fingerprints; nil when the plugin doesn't serve it or
    /// refused it, and Hermes' own route reads the page instead. A tail page
    /// read through it is kept for the next read.
    private func historyPagePayload(
        sessionId: String,
        profile: String,
        query: String,
        using bridge: DashboardTicketBridge
    ) async -> PersistedTranscriptFetchOutcome? {
        guard case .reported(_, let capabilities) = notifierPlugin.state,
              capabilities.contains(HistoryPage.capability),
              let dashboardID = activeDashboardID,
              !historyPageRefusedScopes.contains(HistoryPage.scopeKey(dashboardID: dashboardID, profile: profile)) else { return nil }
        // Kept under the chat's durable id: a new chat opens by its runtime
        // id, and the same chat by its stored one after a relaunch.
        // A query the route doesn't carry reads no held rows.
        guard HistoryPage.body(sessionId: sessionId, query: query, known: []) != nil else { return nil }
        let heldID = canonicalSessionID(for: sessionId) ?? sessionId
        let heldURL = offlineChatCache.heldRowsFileURL(heldID, dashboardID: dashboardID, profile: profile)
        let removals = offlineChatCache.removals
        let held = await Task.detached(priority: .userInitiated) {
            OfflineChatCacheStore.loadHeldRows(at: heldURL, sessionID: heldID)
        }.value
        guard let body = HistoryPage.body(sessionId: sessionId, query: query, known: held?.digests ?? []) else { return nil }
        let isTail = (body["offset"] as? Int) == 0 && (body["order"] as? String) == "latest"
        let path = DashboardPath.withProfile(HistoryPage.path, profile: profile)
        let startedAt = Date()
        let response: [String: Any]
        do {
            response = try await bridge.requestJSON(path: path, method: "POST", body: body, readsOnly: true)
        } catch {
            // A route this host can't serve for the profile is left for the
            // run, so later opens don't pay its round trip first.
            if HistoryPage.isRefusedForScope(error) {
                historyPageRefusedScopes.insert(HistoryPage.scopeKey(dashboardID: dashboardID, profile: profile))
            }
            return HistoryPage.readsHermesRouteInstead(after: error) ? nil : .failed(error)
        }
        guard let rebuilt = HistoryPage.rebuild(response, held: held?.byDigest ?? [:], sessionID: heldID) else {
            // The answer didn't match the fingerprints sent: Hermes' own
            // route reads the page whole.
            return nil
        }
        let sentRows = (response["messages"] as? [Any])?.filter { ($0 as? [String: Any])?[HistoryPage.knownKey] == nil }.count ?? 0
        noteConnectionStep("History page: \(sentRows) of \(rebuilt.kept.rows.count) rows sent", since: startedAt)
        // Only while nothing was removed from the saved chats during the read
        // (a sign-out, a removed dashboard, Delete saved chats, a deleted
        // chat) and the same sign-in still holds: these rows went too. The
        // store writes them on its queue, and a removal from now on waits
        // for them and takes them as well.
        if isTail, offlineChatCache.removals == removals, dashboardTicketBridge === bridge,
           activeDashboardID == dashboardID {
            offlineChatCache.recordHeldRows(rebuilt.kept, to: heldURL)
        }
        return .payload(rebuilt.page)
    }

    /// Where a page of persisted rows lives, for fetching a picture stored
    /// inside one of them later (#652): the stored session the response
    /// echoed (else the one asked for) in `profile`'s database.
    nonisolated static func transcriptImageScope(
        in response: [String: Any],
        sessionId: String,
        profile: String
    ) -> TranscriptImageScope {
        let echoed = resolvedSessionId(in: response)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptImageScope(
            sessionId: echoed.flatMap { $0.isEmpty ? nil : $0 } ?? sessionId,
            profile: profile
        )
    }

    /// Normalizes a transcript page off the main actor: a long chat's
    /// rows take tens of milliseconds, and the launch sync runs while the
    /// Chats list is drawing its first frames.
    private static func normalizeTranscriptRows(
        _ rows: [Any],
        imageScope: TranscriptImageScope?
    ) async -> [ChatMessage] {
        // Detached, so the hop off the main actor never depends on how a
        // nonisolated async function is scheduled.
        await Task.detached(priority: .userInitiated) {
            MessageNormalizer.normalizeMessages(rows.map(AnyCodable.from), imageScope: imageScope)
        }.value
    }

    /// The dashboard server returns `messages`; the API-server variant
    /// returns `data`, so accept both public Hermes response shapes.
    nonisolated static func persistedMessageRows(in response: [String: Any]) -> [Any]? {
        ["messages", "data", "_array"]
            .compactMap { response[$0] as? [Any] }
            .first
    }

    /// Positively extracts the durable persisted row id from a raw `/messages`
    /// row — the id the row actually persisted under — or nil when the row
    /// carries no durable identity (the normalizer would fall back to a
    /// positional index, which is presentation identity, not provenance).
    ///
    /// Keep the envelope merge and id-key order in sync with
    /// `MessageNormalizer.normalizeMessages`, which consumes the same rows.
    /// A row's `row_id` comes first, as in the normalizer; `/messages` rows
    /// carry `id` itself.
    nonisolated static func durablePersistedRowID(from rawRow: Any) -> String? {
        guard let envelope = rawRow as? [String: Any] else { return nil }
        // Same envelope merge as normalizeMessages: `message` / `payload` /
        // message-shaped `data` override the envelope, nested values win.
        let dataMessage = envelope["data"] as? [String: Any]
        let dataMessageIsCarrier = dataMessage.map { $0["role"] != nil || $0["type"] != nil } ?? false
        let nested = (envelope["message"] as? [String: Any])
            ?? (envelope["payload"] as? [String: Any])
            ?? (dataMessageIsCarrier ? dataMessage : nil)
            ?? [:]
        var obj = envelope
        for (key, value) in nested {
            obj[key] = value
        }
        // A row naming its stored row (`row_id`) has that row's id first,
        // as the normalizer gives it.
        if let rowID = obj["row_id"] as? NSNumber,
           CFGetTypeID(rowID) != CFBooleanGetTypeID(),
           let exactRowID = Int(exactly: rowID.doubleValue), exactRowID > 0 {
            return String(Double(exactRowID))
        }
        for key in ["id", "message_id"] {
            switch obj[key] {
            case let string as String where !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                return string
            case let number as NSNumber where number.doubleValue != 0:
                // Match AnyCodable's number rendering so the extracted id is
                // byte-identical to the normalized ChatMessage.id.
                return String(number.doubleValue)
            default:
                continue
            }
        }
        return nil
    }

    nonisolated static func resolvedSessionId(in response: [String: Any]) -> String? {
        (response["session_id"] as? String) ?? (response["sessionId"] as? String)
    }

    /// Classifies a history-fetch failure as STRUCTURAL ENDPOINT ABSENCE —
    /// the only condition that degrades the initial hydration to the single
    /// legacy full-transcript resume, and the only one that retires the
    /// backfill affordance:
    ///
    ///  - 404/410 — the gateway predates the messages route (or the session
    ///    is gone from it);
    ///  - 501 — the endpoint is explicitly unimplemented.
    ///
    /// Everything else must NOT silently escalate to the unbounded legacy
    /// transport: transient trouble (408/429, any other 5xx, status-0
    /// WebKit/network failures), a bridge that did not become ready or a
    /// request that outlived its deadline (both `.notReady`), an oversized
    /// response, authentication, and every unlisted error surfaces instead.
    /// This is the giant-session safety property: current Hermes can serve
    /// the bounded `include_compacted=true` page slowly for heavily
    /// compacted sessions until upstream bounding lands (#97440), so a slow
    /// bounded read must fail boundedly and retry through reconnect — never
    /// silently become "load the entire transcript over the WebSocket".
    nonisolated static func historySourceIsUnavailable(_ error: Error) -> Bool {
        guard case let DashboardTicketBridgeError.http(status, _) = error else { return false }
        switch status {
        case 404, 410, 501: return true
        default: return false
        }
    }

    nonisolated static func sessionMessagesPath(
        sessionId: String,
        profile: String,
        query: String
    ) -> String {
        let encodedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        return DashboardPath.withProfile(
            "/api/sessions/\(encodedSessionId)/messages\(query)",
            profile: profile
        )
    }

    /// Whether a persisted-history window from the previous reconciliation
    /// belongs to the conversation this reconcile just accepted. Identity is
    /// compared through the ONE centralized rule with the new transaction's
    /// full identity set (requested, resolved stored, runtime), so a
    /// reconnect keeps the backfilled prefix even when the catalog is
    /// temporarily stale about the stored↔runtime alias.
    func priorWindowOwnsThisConversation(
        _ window: PersistedTranscriptWindowState?,
        requestedSessionId: String,
        resolvedSessionId: String?,
        runtimeSessionId: String?,
        profile: String
    ) -> Bool {
        guard let window else { return false }
        let conversationIds = PersistedTranscriptWindow.normalizingSessionIDs([
            requestedSessionId, resolvedSessionId, runtimeSessionId
        ])
        return PersistedTranscriptWindow.ownershipHolds(
            window: window,
            conversationSessionIds: conversationIds,
            profile: profile,
            windowAliasIds: catalogAliasIDs(for: window.trustedSessionIDs),
            conversationAliasIds: catalogAliasIDs(for: conversationIds)
        )
    }

    /// Fetches the next older persisted-history page for the active
    /// conversation and prepends it, keeping the user's visible position
    /// stable (ChatView anchors the prepend through the viewport controller).
    /// Strictly user-driven and single-flight: one explicit request at a
    /// time, owned by the window identity captured at request time, and a
    /// response from a session/profile that is no longer current is
    /// discarded without touching state.
    ///
    /// Returns whether a prepend actually published — the view discharges
    /// its viewport anchor when nothing landed, so an armed anchor can never
    /// re-pin on some later unrelated transcript change.
    @discardableResult
    func loadEarlierMessages() async -> Bool {
        guard let window = persistedTranscriptWindow,
              window.canLoadEarlier,
              !window.isLoadingEarlier else {
            return false
        }
        guard persistedTranscriptWindowOwnershipIsCurrent(window) else {
            // No user-facing error for an already-departed conversation —
            // and normally unreachable from a tap, because the affordance
            // exposes this exact ownership truth. The debug capture below
            // is purely diagnostic (it also fires on the legitimate
            // render-to-tap race during a session switch).
            sessionCatalogLog.debug("""
                Older-page backfill rejected ownership of an otherwise-actionable window: \
                requested=\(window.requestedSessionID, privacy: .private(mask: .hash)) \
                resolved=\(window.resolvedSessionID ?? "none", privacy: .private(mask: .hash)) \
                runtime=\(window.runtimeSessionID ?? "none", privacy: .private(mask: .hash)) \
                active=\(self.activeSessionId ?? "none", privacy: .private(mask: .hash)) \
                windowProfile=\(window.profile, privacy: .public) \
                activeProfile=\(self.activeProfile, privacy: .public)
                """)
            return false
        }
        // Older pages are persisted transcript history: continue against
        // the durable stored identity the hydration resolved (Desktop's
        // `BackfillRequest.storedSessionId` contract) — never the runtime
        // WebSocket ID, and never re-derived from a later catalog refresh.
        let wireSessionId = window.resolvedSessionID ?? window.requestedSessionID
        let requestedSessionId = window.requestedSessionID
        let profile = window.profile
        let offset = window.nextOffset
        var arming = window
        arming.isLoadingEarlier = true
        persistedTranscriptWindow = arming

        let outcome = await fetchOlderTranscriptPage(
            sessionId: wireSessionId,
            profile: profile,
            offset: offset
        )

        // Stale-response guard: the window must still be this exact
        // request's window (same session, same profile, still loading, and
        // no other fetch advanced it meanwhile). Anything else — session
        // switch, profile switch, disconnect re-home — discards the page.
        // The first four conditions identify THIS armed window; only then
        // may the bookkeeping below touch it.
        guard var current = persistedTranscriptWindow,
              current.requestedSessionID == requestedSessionId,
              current.profile == profile,
              current.nextOffset == offset,
              current.isLoadingEarlier else {
            return false
        }
        guard persistedTranscriptWindowOwnershipIsCurrent(current) else {
            // The armed window survived untouched but the conversation
            // moved on underneath it (e.g. activeSessionId cleared by a
            // disconnect). Discard the response whole AND release the
            // single-flight flag so the affordance can re-arm later — a
            // replaced window never reaches this branch.
            current.isLoadingEarlier = false
            persistedTranscriptWindow = current
            return false
        }
        current.isLoadingEarlier = false
        defer { persistedTranscriptWindow = current }

        switch outcome {
        case .payload(let response):
            guard let rawRows = Self.persistedMessageRows(in: response) else {
                // A malformed page is a backfill dead end, not a chat
                // failure: stop offering older pages rather than erroring
                // the already-hydrated conversation.
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .private(mask: .hash)) returned a malformed payload; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            // Response ownership: the page must still describe THIS
            // conversation. The SAME centralized identity rule decides —
            // the echoed session_id plays the role of the checked
            // conversation — so an echo is accepted exactly when it is a
            // transaction-captured identity of this window or a
            // catalog-proven alias of one. Never a foreign session's rows;
            // a foreign response neither normalizes into the transcript
            // nor advances coverage.
            if let returnedId = Self.resolvedSessionId(in: response),
               !returnedId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !PersistedTranscriptWindow.ownershipHolds(
                 window: current,
                 conversationSessionIds: [returnedId],
                 profile: current.profile,
                 windowAliasIds: catalogAliasIDs(for: current.trustedSessionIDs),
                 conversationAliasIds: knownSessionIDs(for: returnedId)
               ) {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .private(mask: .hash)) returned foreign session \(returnedId, privacy: .private(mask: .hash)); discarding and retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            let fetchedRowCount = rawRows.count
            let page = PersistedTranscriptPagination.parse(response, rawRowCount: fetchedRowCount)
            // Only pages still answering under the tail contract may splice
            // into the transcript: a response whose echo lost `order=latest`
            // carries oldest-anchored rows with unknown window semantics,
            // and prepending them would break chronology. That response
            // retires the affordance instead.
            guard let page, page.honorsTailContract else {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .private(mask: .hash)) lost the tail contract; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            // Overlap dedup keys on the durable persisted row ID. A page
            // whose rows lack one would normalize to page-local positional
            // IDs that cannot survive across pages — refuse it before it can
            // silently corrupt dedup.
            guard PersistedTranscriptWindow.rowsHaveDurableIdentity(rawRows) else {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .private(mask: .hash)) returned rows without durable IDs; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            var didPrepend = false
            var foldedPageStart: (heldIDs: Set<String>, callCardID: String)?
            let startBeforePage = messages.first.map {
                PersistedTranscriptWindowState.LoadedPageStart(
                    firstRowID: $0.id,
                    nextOffset: offset,
                    hasBackfilledPrefix: current.hasBackfilledPrefix
                )
            }
            if fetchedRowCount > 0 {
                let normalizedPage = MessageNormalizer.normalizeMessages(
                    rawRows.map(AnyCodable.from),
                    imageScope: Self.transcriptImageScope(in: response, sessionId: wireSessionId, profile: profile)
                )
                // A page boundary can split a tool call from its result row.
                // Fold any trailing call cards back together with the
                // matching held result cards by durable tool-call identity
                // before prepending, so one logical tool run never renders
                // as an orphan call card plus a duplicate standalone result.
                let (olderPage, foldedFromHeld) = PersistedTranscriptWindow.reconcilingToolCallsAcrossBoundary(
                    olderPage: normalizedPage,
                    held: messages
                )
                let merged: [ChatMessage]?
                if foldedFromHeld > 0 {
                    // The folded result rows go; a page start on one moves
                    // to the call card that took it in (issue 1828).
                    foldedPageStart = PersistedTranscriptWindow.foldedPageStart(
                        olderPage: olderPage,
                        foldedHeld: messages.prefix(foldedFromHeld)
                    )
                    let remainingHeld = messages.dropFirst(foldedFromHeld)
                    if remainingHeld.isEmpty {
                        // Every held row folded into the adjusted page (the
                        // stale-response guard already proved this window is
                        // current): the folded page itself is the whole
                        // transcript. Never fall back to the unfolded page
                        // here — that would resurrect the duplicate the fold
                        // just removed.
                        merged = olderPage.isEmpty ? nil : olderPage
                    } else {
                        merged = PersistedTranscriptWindow.prepending(olderPage, onto: Array(remainingHeld))
                    }
                } else {
                    merged = nil
                }
                if let merged {
                    messages = merged
                    didPrepend = true
                } else if let plain = PersistedTranscriptWindow.prepending(normalizedPage, onto: messages) {
                    messages = plain
                    didPrepend = true
                }
            }
            if didPrepend {
                if let replaced = Self.replacingSavedReviews(in: messages) {
                    messages = replaced
                }
                // The visible transcript now starts with backfilled rows.
                // The reconcile graft relies on this explicit fact to keep
                // preserving the prefix across repeated reconciles — the
                // network coverage reset below erases the offset evidence
                // after the first one.
                current.hasBackfilledPrefix = true
            }
            // A full page means older history may still exist; a short or
            // empty page marks the transcript fully backfilled and retires
            // the affordance. The offset advances by the fetched row count
            // either way, which self-corrects drift: a page that deduped to
            // nothing still moves the next request past the already-held
            // rows.
            current.nextOffset = offset + fetchedRowCount
            current.canLoadEarlier = fetchedRowCount > 0
                && page.mayHaveOlderRows(fetchedRowCount: fetchedRowCount)
            if didPrepend, let first = messages.first {
                if current.loadedPageStarts.isEmpty, let startBeforePage {
                    current.loadedPageStarts.append(startBeforePage)
                }
                if let foldedPageStart {
                    current.loadedPageStarts = PersistedTranscriptWindow.movingPageStarts(
                        current.loadedPageStarts,
                        off: foldedPageStart.heldIDs,
                        onto: foldedPageStart.callCardID
                    )
                }
                current.loadedPageStarts.append(.init(
                    firstRowID: first.id,
                    nextOffset: current.nextOffset,
                    hasBackfilledPrefix: true
                ))
            }
            return didPrepend
        case .unavailable:
            // The history source went away mid-conversation; there is no
            // older page to offer.
            current.canLoadEarlier = false
            return false
        case .failed(let error):
            // Only a structurally gone history source retires the
            // affordance; transient trouble — rate limits, slow bounded
            // reads, a temporarily cold bridge — stays retryable through
            // another explicit tap. A failed backfill never loops on its
            // own.
            sessionCatalogLog.debug("Older-page backfill failed for \(wireSessionId, privacy: .private(mask: .hash)): \(LogRedaction.message(error), privacy: .public)")
            current.canLoadEarlier = !Self.historySourceIsUnavailable(error)
            return false
        }
    }

    private func fetchOlderTranscriptPage(
        sessionId: String,
        profile: String,
        offset: Int
    ) async -> PersistedTranscriptFetchOutcome {
        if let loadEarlierTranscriptPage = chatResumeLifecycleOperations.loadEarlierTranscriptPage {
            return await loadEarlierTranscriptPage(sessionId, profile, offset)
        }
        // Backfill never falls through to the initial-hydration seam: that
        // seam cannot carry the offset, and a test wiring mistake would
        // otherwise become a silent always-duplicate affordance.
        guard let bridge = dashboardTicketBridge else { return .unavailable }
        do {
            return .payload(try await bridge.requestJSON(path: Self.sessionMessagesPath(
                sessionId: sessionId,
                profile: profile,
                query: PersistedTranscriptPagination.tailQuery(offset: offset)
            )))
        } catch {
            return .failed(error)
        }
    }

    /// Catalog alias knowledge for a set of session identities: every ID
    /// the live catalog groups with any of them (an unknown ID expands to
    /// just itself).
    private func catalogAliasIDs(for sessionIds: Set<String>) -> Set<String> {
        sessionIds.reduce(into: Set<String>()) { expanded, sessionId in
            expanded.formUnion(knownSessionIDs(for: sessionId))
        }
    }

    /// Ownership gate for the persisted-history window: the window must
    /// belong to the conversation that is actually active. The window's
    /// transaction-captured identities (requested, resolved stored, runtime)
    /// are the primary truth — `applyChatResume` re-homes `activeSessionId`
    /// to the runtime ID long before the catalog learns the alias — while
    /// catalog alias knowledge remains a compatibility source only.
    func persistedTranscriptWindowOwnershipIsCurrent(
        _ window: PersistedTranscriptWindowState
    ) -> Bool {
        guard let activeId = activeSessionId else { return false }
        // The ownership comparison uses the ACTIVE CONVERSATION's profile
        // scope, not the dashboard's: a canonical Bot Chat's window is
        // stamped with the bot profile, and must stay actionable (for
        // "Load earlier messages") while that chat is on screen.
        return PersistedTranscriptWindow.ownershipHolds(
            window: window,
            conversationSessionIds: [activeId],
            profile: persistedTailProfile(for: activeId),
            windowAliasIds: catalogAliasIDs(for: window.trustedSessionIDs),
            conversationAliasIds: knownSessionIDs(for: activeId)
        )
    }

    /// Whether "Load earlier messages" may be offered AND executed right
    /// now: a hydrated, non-empty transcript whose persisted-history window
    /// still has an older page and belongs to the conversation that is
    /// actually active. The single ownership truth for the ChatView
    /// affordance and the `loadEarlierMessages` action, so the control can
    /// never render for a window the action would reject (the production
    /// no-op regression).
    var canLoadEarlierMessagesForActiveConversation: Bool {
        guard let window = persistedTranscriptWindow,
              window.canLoadEarlier,
              !messages.isEmpty,
              persistedTranscriptWindowOwnershipIsCurrent(window) else {
            return false
        }
        return true
    }

    /// The endpoint may resolve a runtime ID to its stored session ID. Accept
    /// any identifier already known for the selected session, just as Desktop
    /// verifies its REST prefetch before using it for a resumed transcript.
    func transcriptMatchesSession(
        _ transcript: PersistedSessionTranscript,
        requestedSessionId: String,
        resumedSessionId: String
    ) -> Bool {
        guard let returnedId = transcript.resolvedSessionId,
              !returnedId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        var knownIds = Set([requestedSessionId, resumedSessionId])
        if let session = sessions.first(where: { session in
            let ids = [session.id] + session.alternateIds
            return ids.contains(requestedSessionId) || ids.contains(resumedSessionId)
        }) {
            knownIds.insert(session.id)
            knownIds.formUnion(session.alternateIds)
        }
        return knownIds.contains(returnedId)
    }

    private func dashboardSessions(
        profile: String,
        maximumPages: Int,
        using bridge: DashboardTicketBridge
    ) async throws -> DashboardSessionCatalog {
        var sessions: [SessionSummary] = []
        var isAuthoritative = false
        // Sent alongside the live list: the plugin archives a standalone
        // call when it ends, which Conduit still lists with its calls.
        async let archivedCalls = archivedVoiceCallSessions(profile: profile, maximumPages: maximumPages, using: bridge)

        for page in 0..<maximumPages {
            let offset = page * 200
            let response = try await startupReads.read(
                profileSessionsPath(profile, offset: offset),
                through: bridge,
                fence: startupReadFence(for: bridge, chatList: true)
            )
            let batch = response["sessions"] as? [Any] ?? []
            let normalizedBatch = await dashboardOwnedSessions(batch, profile: profile)
            sessions += normalizedBatch

            let rawHasMore = response["has_more"] ?? response["hasMore"]
            let explicitHasMore = rawHasMore.map { booleanValue($0) }
            let nextOffset = Self.integerValue(response["next_offset"] ?? response["nextOffset"])
            let total = Self.integerValue(response["total"])
            let hasExplicitTerminalSignal = explicitHasMore == false
                || (nextOffset.map { $0 <= offset } ?? false)
                || (total.map { offset + batch.count >= $0 } ?? false)
            let hasMore = !hasExplicitTerminalSignal && (
                explicitHasMore == true
                    || (nextOffset ?? 0) > offset
                    || (total.map { offset + batch.count < $0 } ?? false)
                    || batch.count == 200
            )
            if batch.isEmpty {
                // An empty page after a non-empty prefix is not proof that
                // the full catalog was read. Preserve older rows and retry a
                // complete load later instead of evicting the cached suffix.
                break
            }
            if !hasMore {
                isAuthoritative = hasExplicitTerminalSignal && !normalizedBatch.isEmpty
                break
            }
        }

        // A failed read keeps the call rows the list showed before, so the
        // live list's authority doesn't hang on this one.
        let tags = voiceSessionTagsByKey[voiceHistoryKey(profile: profile)] ?? [:]
        let listedIDs = Set(sessions.map(\.id))
        let calls = await archivedCalls ?? (self.sessions + self.cronSessions).filter {
            var archived = $0
            archived.isArchived = true
            return Self.isArchivedVoiceChat(archived, tags: tags) && sessionBelongsToProfile($0, profile: profile)
                && !listedIDs.contains($0.id)  // used since: the live read has it fresh
        }
        return DashboardSessionCatalog(
            sessions: V2FilterSelection.mergedByRecency(sessions, calls),
            isAuthoritative: isAuthoritative
        )
    }

    /// What a saved call row ends with: the plugin ends the rows it writes.
    nonisolated static let voiceCallEndReason = "conduit_voice"

    /// A call row, a chat a Classic voice call started, or a voice job's
    /// chat, archived by the plugin when the call ended or once Hermes
    /// answered the job (#1124): Hermes Desktop's list leaves it out,
    /// Conduit keeps listing it with its calls. One the user archived, or
    /// one used since, isn't one.
    nonisolated static func isArchivedVoiceChat(_ session: SessionSummary, tags: [String: VoiceSessionTag]) -> Bool {
        guard session.isArchived, session.isAutoArchived == true else { return false }
        if session.endReason == voiceCallEndReason { return true }
        let ids = [session.id, session.storedSessionId].compactMap { $0 } + session.alternateIds
        return ids.contains { id in tags[id].map { $0.kind == .classic || $0.kind == .job } ?? false }
    }

    /// The archived pages' voice chats, as deep as the live list reads,
    /// listed as unarchived. Nil when a read failed or wasn't a listing.
    private func archivedVoiceCallSessions(
        profile: String,
        maximumPages: Int,
        using bridge: DashboardTicketBridge
    ) async -> [SessionSummary]? {
        var calls: [SessionSummary] = []
        let tags = voiceSessionTagsByKey[voiceHistoryKey(profile: profile)] ?? [:]
        do {
            for page in 0..<maximumPages {
                let response = try await bridge.requestJSON(path: archivedSessionsPath(profile, offset: page * 200))
                guard let batch = response["sessions"] as? [Any] else { return nil }
                calls += await dashboardOwnedSessions(batch, profile: profile)
                    .filter { Self.isArchivedVoiceChat($0, tags: tags) }
                    .map { session in
                        var listed = session
                        listed.isArchived = false
                        return listed
                    }
                let offset = page * 200
                let nextOffset = Self.integerValue(response["next_offset"] ?? response["nextOffset"])
                let total = Self.integerValue(response["total"])
                let done = (nextOffset.map { $0 <= offset } ?? false) || (total.map { offset + batch.count >= $0 } ?? false)
                let hasMore = !done && (booleanValue(response["has_more"] ?? response["hasMore"]) || batch.count == 200)
                if !hasMore || batch.isEmpty { break }
            }
        } catch {
            return nil
        }
        return calls
    }

    func dashboardArchivedSessions(
        profile: String,
        using bridge: DashboardTicketBridge
    ) async throws -> [SessionSummary] {
        var sessions: [SessionSummary] = []
        let tags = voiceSessionTagsByKey[voiceHistoryKey(profile: profile)] ?? [:]
        for page in 0..<SessionCatalogCache.maximumHistoryPages {
            let offset = page * 200
            let response = try await bridge.requestJSON(path: archivedSessionsPath(profile, offset: offset))
            let batch = response["sessions"] as? [Any] ?? []
            // Archived calls are listed with the chats instead.
            sessions += await dashboardOwnedSessions(batch, profile: profile)
                .filter { !Self.isArchivedVoiceChat($0, tags: tags) }

            let nextOffset = Self.integerValue(response["next_offset"] ?? response["nextOffset"])
            let total = Self.integerValue(response["total"])
            let hasMore = booleanValue(response["has_more"] ?? response["hasMore"])
                || (nextOffset ?? 0) > offset
                || (total.map { offset + batch.count < $0 } ?? false)
                || batch.count == 200
            if !hasMore || batch.isEmpty { break }
        }
        return sessions
    }

    private func profileSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=exclude&order=recent&exclude_sources=\(SessionSource.chatListExcludedSources)",
            profile: profile
        )
    }

    private func archivedSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=only&order=recent&exclude_sources=\(SessionSource.chatListExcludedSources)",
            profile: profile
        )
    }

    /// Fetch cron sessions separately. The main profileSessionsPath excludes
    /// cron (and Kanban workers), so cron sessions never appear in the normal
    /// dashboard query. This dedicated path uses source=cron to populate
    /// the cron tab in the sidebar.
    private func dashboardCronSessions(
        profile: String,
        using bridge: DashboardTicketBridge
    ) async throws -> [SessionSummary] {
        let response = try await bridge.requestJSON(path: cronSessionsPath(profile, offset: 0))
        let batch = response["sessions"] as? [Any] ?? []
        return await dashboardOwnedSessions(batch, profile: profile)
    }

    /// The official profile-session endpoint always tags every row with its
    /// owning profile. Do not substitute the requested profile here: doing so
    /// can relabel a foreign or malformed aggregate row and leak it into the
    /// selected workspace. The socket fallback remains profile-scoped and may
    /// still supply its known client profile to the normalizer.
    ///
    /// A page is up to 200 rows, and converting it took up to 26 ms on main
    /// at launch, while the Chats list was scrolling: it runs off the main
    /// actor, in order, like large socket frames (`decodeInBackground`).
    private func dashboardOwnedSessions(_ batch: [Any], profile: String) async -> [SessionSummary] {
        await Self.convertDashboardPage(batch, profile: profile)
    }

    /// Nonisolated and async: runs on the generic executor, off main.
    nonisolated private static func convertDashboardPage(_ batch: [Any], profile: String) async -> [SessionSummary] {
        dashboardOwnedSessions(batch, profile: profile)
    }

    nonisolated static func dashboardOwnedSessions(_ batch: [Any], profile: String) -> [SessionSummary] {
        MessageNormalizer.normalizeSessions(
            AnyCodable.from(["sessions": batch]),
            profile: nil
        ).filter { session in
            guard let owner = session.profile else { return false }
            // Hermes Desktop's sidebar uses min_messages=1. Keep the explicit
            // client-side guard as well for older servers that ignore the
            // query parameter; malformed empty shadow rows must not leak into
            // a profile's visible catalog.
            return profilesMatch(owner, profile) && session.messageCount != 0
        }
    }

    private func cronSessionsPath(_ profile: String, offset: Int = 0) -> String {
        DashboardPath.withExplicitProfile(
            "/api/profiles/sessions?limit=200&offset=\(offset)&min_messages=1&archived=exclude&order=recent&source=cron",
            profile: profile
        )
    }

    /// Hermes Desktop requests only persisted sessions with at least one
    /// message, but keeps a first turn visible while it is still in flight and
    /// the database row has not caught up yet. Retain only that live row; idle
    /// zero-message drafts and malformed profile shadows stay hidden.
    func activeTurnCatalogSession() -> SessionSummary? {
        guard turnState.isRunning, let activeSessionId else { return nil }
        return (sessions + cronSessions).first { session in
            sessionBelongsToProfile(session, profile: activeProfile)
                && (session.id == activeSessionId || session.alternateIds.contains(activeSessionId))
        }
    }

    func uniqueSessions(_ values: [SessionSummary]) -> [SessionSummary] {
        var seen = Set<String>()
        return values.filter { session in
            seen.insert("\(session.profile ?? activeProfile):\(session.id)").inserted
        }
    }

    private func sourceSummary(_ values: [SessionSummary]) -> String {
        Dictionary(grouping: values, by: \.source)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
    }

    func switchProfile(to profile: String) async {
        _ = await switchProfile(to: profile, reusing: nil)
    }

    func switchProfileForWidget(to profile: String, lease: WidgetLaunchLease) async -> Bool {
        await switchProfile(to: profile, reusing: nil, widgetLease: lease)
    }

    @discardableResult
    func switchProfile(
        to profile: String,
        reusing viewportTransitionGeneration: UInt64?,
        refusingCallsWith callRefusal: String? = nil,
        widgetLease: WidgetLaunchLease? = nil,
        navigationSeenAt seenGeneration: UInt64? = nil
    ) async -> Bool {
        let signposter = ResponsivenessSignposts.signposter
        let switching = signposter.beginInterval("Profile switch", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Profile switch", switching) }
        // The early reads the switch's ticket sent are its own steps'; what
        // they didn't take is dropped when it ends, as connect's are.
        defer { startupReads.clear() }
        let target = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != activeProfile, let savedConnection = connection else {
            return false
        }
        guard !isProfileSwitching else { return false }
        // What the switch shows first (the profile's saved list and the chat
        // it opens on) is read ahead off the main thread while it waits on
        // its ticket and teardown, if the read-ahead after the live list
        // hasn't already (issue 1963).
        if let dashboardID = savedDashboardRegistry.activeDashboardID {
            offlineChatCache.prefetch(dashboardID: dashboardID, profile: target, transcripts: 1)
        }
        // A switch that spares calls (a notification's or a chat link's)
        // mints its ticket before anything changes, so nothing waits between
        // its call check and the voice teardown below; it refuses while a
        // call runs, saying `callRefusal`. One that will keep the open
        // socket needs no ticket, so it neither waits nor fails on one.
        var sparedCallTicket: String?
        if let callRefusal {
            var mintError: Error?
            if socketToKeepForProfileSwitch(within: savedConnection) == nil {
                do {
                    sparedCallTicket = try await mintChatResumeTicket(for: savedConnection, readsFor: profile)
                } catch {
                    mintError = error
                }
            }
            // A newer navigation or switch that started meanwhile owns the
            // screen now.
            if let viewportTransitionGeneration,
               !chatViewportTransitionIsCurrent(generation: viewportTransitionGeneration) {
                return false
            }
            // A tap that began no transition of its own (New conversation
            // in another profile) gives way to one that began meanwhile.
            if let seenGeneration, !chatViewportTransitionIsCurrent(generation: seenGeneration) {
                return false
            }
            guard widgetLease?.isCurrent != false else {
                if let viewportTransitionGeneration {
                    cancelChatViewportTransitionIfNoReplacement(generation: viewportTransitionGeneration)
                }
                return false
            }
            guard !isProfileSwitching, target != activeProfile, connection == savedConnection else { return false }
            // A call that rang in meanwhile says so, whether or not the
            // ticket came: the call alone stops the switch.
            guard !isVoiceCallInProgress else {
                showCallRefusal(callRefusal)
                return false
            }
            if let mintError {
                let message = AppLocalization.string("Could not switch workspace: \(UserFacingError.message(for: mintError))")
                errorMessage = message
                // The composer shows errorMessage only while it's locked, so
                // a notice says it too, or the tap looks ignored: once while
                // it's up, since the route retries the open for its window.
                // Only V2 draws the notice.
                if V2ShellPreference.isOn, pinSyncNotice?.message != message {
                    showNotice(message, systemImage: "exclamationmark.circle")
                }
                return false
            }
        }
        // A profile change replaces the voice gateway; any in-flight read
        // aloud belongs to the outgoing profile.
        messageReadAloudController.stop()
        let transitionGeneration: UInt64
        if let viewportTransitionGeneration {
            guard chatViewportTransitionIsCurrent(
                generation: viewportTransitionGeneration
            ) else { return false }
            transitionGeneration = viewportTransitionGeneration
        } else {
            transitionGeneration = beginExplicitChatViewportTransition(ownedBy: widgetLease)
        }
        cancelChatResumeTransportRecovery()
        // Hard profile boundary for this forward transition: cancel the
        // debounced stream flush and write synchronously while the outgoing
        // profile still owns the in-memory transcript. No parked task
        // survives the identity changes below (success or rollback).
        flushPendingPresentationCache()
        cancelSecondaryProfileTitleRecovery()

        // Dismiss keyboard before switching profiles
        DispatchQueue.main.async {
            ReturnKeyTextView.putAwayFocus()
        }

        let previousProfile = activeProfile
        let previousApprovalsMode = runtime.approvalsMode
        let previousYolo = runtime.yolo
        let previousLastReportedSessionYolo = lastReportedSessionYolo
        let previousSessions = sessions
        let previousCronSessions = cronSessions
        let previousArchivedSessions = archivedSessions
        let previousProjects = projects
        let previousSupportsProjects = supportsProjects
        let previousTurnState = turnState
        isProfileSwitching = true
        defer { isProfileSwitching = false }
        invalidateReconciliation()
        turnState = .synchronizing
        // The next profile's approval mode is unknown until its first session
        // snapshot arrives; don't let the previous profile's floor leak across
        // the switch, and neutralize the indicator to the safe display
        // (approvals required) until the new profile resolves it.
        runtime.approvalsMode = nil
        runtime.yolo = false
        lastReportedSessionYolo = nil
        func restorePreviousApprovalState() {
            runtime.approvalsMode = previousApprovalsMode
            runtime.yolo = previousYolo
            lastReportedSessionYolo = previousLastReportedSessionYolo
        }
        // Set once the target's client and identity are installed: from
        // then on a superseded switch still finishes or rolls back.
        var adoptedTarget = false
        var previousClient: HermesClient?
        // The outgoing transcript as the profile changes over, for a switch
        // that fails after it.
        var previousMessages: [ChatMessage] = []
        var previousOfflineChatPresentation: OfflineChatPresentation?
        var previousTranscriptDashboardID: UUID?

        do {
            // The open socket isn't tied to a profile, so the new profile's
            // client takes it over instead of a new ticket and socket, about
            // two seconds on a slow path (#1442). Nothing awaits between
            // here and the hand-off, so the socket checked here is the one
            // handed on.
            let keptSocketClient = socketToKeepForProfileSwitch(within: savedConnection)
            let ticket: String
            if keptSocketClient != nil {
                ticket = savedConnection.ticket
            } else if let sparedCallTicket {
                ticket = sparedCallTicket
            } else {
                ticket = try await mintChatResumeTicket(for: savedConnection, readsFor: profile)
            }
            guard widgetLease?.isCurrent != false else {
                // Nothing has changed over yet: the previous profile keeps
                // its approval state and, unless a newer navigation owns the
                // chat, its turn state.
                restorePreviousApprovalState()
                if chatViewportTransitionIsCurrent(generation: transitionGeneration),
                   turnState == .synchronizing {
                    turnState = previousTurnState == .synchronizing ? .idle : previousTurnState
                }
                cancelChatViewportTransitionIfNoReplacement(generation: transitionGeneration)
                return false
            }
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                // A newer navigation owns the chat, and nothing has changed
                // over yet: the previous profile keeps its approval state.
                restorePreviousApprovalState()
                return false
            }
            let freshConnection = HermesConnection(baseUrl: savedConnection.baseUrl, ticket: ticket)
            previousClient = client
            let nextClient = makeClient(connection: freshConnection, profile: target)
            if let previousClient { nextClient.inheritSessionProfiles(from: previousClient) }
            previousMessages = messages
            previousOfflineChatPresentation = offlineChatPresentation
            previousTranscriptDashboardID = activeDashboardID

            markChatViewportReplacement()
            adoptedTarget = true
            connection = freshConnection
            client = nextClient
            clearPendingDecisionRestorationGuard()
            // A profile switch ends any live or suspended Voice conversation
            // from the outgoing profile. Persist the outgoing mute and tear
            // down BEFORE the identity flip: the sheet's deferred onDismiss
            // re-enters closeVoiceConversation after the switch, and its
            // hasLiveVoiceSession guard makes that a no-op so the outgoing
            // mute can never be persisted under the target profile.
            if showVoiceSheet {
                var preferences = loadVoiceProfilePreferences(profile: activeProfile)
                preferences.outputMuted = voiceConversationController.isOutputMuted
                saveVoiceProfilePreferences(preferences, profile: activeProfile)
            }
            voiceConversationController.stop()
            stopQwenLiveConversation()
        stopGeminiLiveConversation()
            stopGPTLiveConversation()
            stopGrokLiveConversation()
            stopLocalLiveConversation()
            retireVoiceBackgroundJobs()
            showVoiceSheet = false
            clearClassicVoiceCards()
            suspendedVoiceConversation = nil
            voiceSheetShouldAutoListen = false
            voiceControllerSessionProfile = nil
            // The outgoing profile's list as it shows now, for switching back.
            recordSavedChatList()
            // And its chat, when Load earlier brought in older rows.
            keepLeftBackfilledTranscript()
            // Fence any residual deferred cache write scheduled under the
            // outgoing profile before identities and namespaces change over.
            setActiveProfile(target)
            sessions = []
            cronSessions = []
            archivedSessions = []
            projects = []
            supportsProjects = false
            projectsLoading = false
            projectsLoadFailed = false
            slashCommands = Self.builtInSlashCommands
            slashSubcommands = Self.conduitSlashSubcommands
            restoreActiveSessionState(for: target)
            restorePinnedSessions(for: target)
            // The target's list as it showed last time, until its own lands.
            if let dashboardID = activeDashboardID {
                presentSavedChatListIfAvailable(dashboardID: dashboardID)
            }
            presentRestoredChatAfterProfileChange()
            // handOffSocket checks what socketToKeepForProfileSwitch did,
            // plus that nextClient is new, so with nothing awaited between
            // them it can't refuse here; the fallback below is for a switch
            // that kept no socket and so holds a fresh ticket.
            if let keptSocketClient, keptSocketClient.handOffSocket(to: nextClient) {
                noteConnectionStep("Socket kept for the switch")
            } else {
                try await connectChatResumeClient(nextClient)
            }
            // The new profile is connected and already active: an expired
            // widget launch or a newer navigation still finishes the switch
            // (only the chat is theirs), or the old socket and a
            // half-switched profile would be left behind.
            guard self.client === nextClient else {
                previousClient?.disconnect()
                return false
            }
            // Keep the previous socket alive until the new profile has
            // actually connected, so a failed switch has a recovery path.
            previousClient?.disconnect()
            // An owed bootstrap belongs to the outgoing client; it can never
            // match the new one, so retire it rather than pin a dead socket.
            if let previousClient, owedPostConnectBootstrap?.client === previousClient {
                owedPostConnectBootstrap = nil
            }
            isConnected = true
            connectedAt = Date()
            if let dashboardID = activeDashboardID {
                KeychainHelper.saveConnection(freshConnection, dashboardID: dashboardID)
            }
            persistActiveProfile(target)
            // The profile's busy mode and display settings are read in the
            // background: both already show what this profile last said
            // (restoreDisplayPreferences, the busy mode's cache), and the
            // display read alone took over two seconds on a real dashboard,
            // which the switch and a chat opened in the other profile waited
            // on (#1442).
            Task {
                await loadChatResumeBusyInputMode(using: nextClient)
                guard self.client === nextClient else { return }
                await loadChatResumeProfileDisplayPreferences()
            }
            // A newer navigation opens and syncs its own chat.
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }

            await syncSession(
                purpose: .preserveCurrent,
                using: nil,
                automaticWorkToken: nil,
                requiredViewportTransitionGeneration: transitionGeneration
            )
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }
            // A transition borrowed from an open that goes on (a
            // notification) stays with it: the chat it opens next lays out
            // under it.
            if viewportTransitionGeneration == nil {
                finishChatViewportTransitionIfNoTranscriptReplacement(
                    generation: transitionGeneration
                )
            }
            Task { await loadChatResumeSlashCommands() }
            return true
        } catch {
            let ownsChat = chatViewportTransitionIsCurrent(generation: transitionGeneration)
            // Superseded before anything changed over: only the approval
            // state was neutralized. Once the target was installed, its
            // failed client is rolled back even when a newer navigation owns
            // the chat; only the error is left to that one, and the outgoing
            // chat and its transcript come back over it until the reconnect
            // resolves it.
            guard ownsChat || adoptedTarget else {
                restorePreviousApprovalState()
                return false
            }
            if ownsChat {
                errorMessage = AppLocalization.string("Could not switch workspace: \(UserFacingError.message(for: error))")
            }
            clearPendingDecisionRestorationGuard()
            // The pre-switch reset neutralized the approval state; restore it
            // with the rest of the previous profile or a failed switch loses
            // the floor while the previous profile is still the active one.
            restorePreviousApprovalState()
            sessions = previousSessions
            cronSessions = previousCronSessions
            archivedSessions = previousArchivedSessions
            projects = previousProjects
            supportsProjects = previousSupportsProjects
            projectsLoading = false
            restoreActiveSessionState(for: previousProfile)
            restorePinnedSessions(for: previousProfile)
            // restoreActiveSessionState/restorePinnedSessions are
            // synchronous and cache-write-free; the pre-flight boundary
            // flush (above) already persisted the outgoing transcript under
            // the previous profile's namespace. setActiveProfile(_:)
            // deliberately does NOT flush: flipping the identity back only
            // re-arms the namespace and bumps the fence epoch, making any
            // flush scheduled under the failed target during the aborted
            // attempt stale.
            setActiveProfile(previousProfile)
            // The previous profile's transcript left with it: it comes back
            // as it was, with its chat (restored above), over any newer
            // navigation's, which the reconnect then resolves. Never onto
            // another dashboard a switch moved to meanwhile.
            if adoptedTarget, activeDashboardID == previousTranscriptDashboardID {
                messages = previousMessages
                offlineChatPresentation = previousOfflineChatPresentation
            }
            connection = savedConnection
            previousClient?.disconnect()
            client?.disconnect()
            client = nil
            isConnected = false
            turnState = .reconnecting
            if ownsChat { finishChatViewportTransition(generation: transitionGeneration) }
            await reconnect()
            return false
        }
    }

    func loadProfiles() async {
        await readProfiles()
    }

    /// Reads the host's profile list. False when it wasn't read for this
    /// connection (no bridge, a failed or empty reply, or a reply from a
    /// replaced connection): the list then says nothing about a profile.
    /// True when a list sent after this one was taken first, which stands.
    @discardableResult
    func readProfiles() async -> Bool {
        guard let bridge = dashboardTicketBridge else { return false }
        let dashboardID = activeDashboardID
        profileListReadsSent &+= 1
        let read = profileListReadsSent
        do {
            let response: [String: Any]
            if let profileDiscoveryLoaderOverride {
                response = try await profileDiscoveryLoaderOverride()
            } else {
                response = try await startupReads.read("/api/profiles", through: bridge, fence: startupReadFence(for: bridge))
            }
            // Commit gate, same identity pattern as the dashboard catalog
            // loader: a bridge swapped mid-request (server change, re-login,
            // disconnect) makes this response foreign. A late reply from an
            // old connection must not overwrite the live list, and must not
            // repopulate a persisted cache that
            // prepareChatResumeForConnection(to:) already cleared with the
            // previous server's profile names. Discarded silently — profile
            // discovery has no retry loop to feed an error into.
            guard dashboardTicketBridge === bridge, activeDashboardID == dashboardID else { return false }
            let values = response["profiles"] as? [Any] ?? []
            let names = values.compactMap { value -> String? in
                if let name = value as? String { return name }
                return (value as? [String: Any])?["name"] as? String
            }
            // Two reads through the same bridge can land out of order (one
            // native, one through the page or read again): one sent after
            // this that already landed is newer, so this older list must not
            // undo a bot just made or deleted, nor re-home the profile in use.
            // Only a list with names takes the place: a degraded empty one
            // leaves it to an older complete one. A list that lost it was
            // read all the same, and a newer one stands.
            guard read > profileListReadCommitted else { return true }
            if !names.isEmpty { profileListReadCommitted = read }
            // Rows as objects carry `display_name`; a plain-name listing
            // says nothing about it, and the bot roster fills it in.
            let rows = values.compactMap { $0 as? [String: Any] }
            if !rows.isEmpty, rows.count == values.count {
                adoptProfileHermesNames(rows.compactMap { row in
                    (row["name"] as? String).map { (profile: $0, displayName: row["display_name"] as? String ?? "") }
                })
            }
            // A 200 with no profile names is a degraded payload (dashboard
            // mid-restart, partial deploy, proxy), not authoritative evidence
            // that every profile vanished — Hermes always has `default`. The
            // next line would otherwise collapse the picker and persist that
            // degraded list over the complete cache, the exact bug this
            // function exists to prevent, just via a 200 instead of an error.
            let nextProfiles = names.isEmpty
                ? orderedProfiles(profiles + [activeProfile, "default"])
                : orderedProfiles(names + ["default"])
            profiles = nextProfiles
            persistKnownProfiles(nextProfiles)
            if !names.isEmpty, let dashboardID {
                retainWidgetProfiles(Set(nextProfiles), dashboardID: dashboardID)
            }
            // A deleted profile's glow pick goes with it, so a new profile
            // given the same name later starts from its photo's color.
            if !names.isEmpty {
                let stale = profileGlowPicks.keys.filter { !nextProfiles.contains($0) }
                for profile in stale {
                    setProfileGlowColor(nil, for: profile)
                }
                // So do its pinned replies, which keep reply text.
                for profile in pinnedRepliesByProfile.keys where !nextProfiles.contains(profile) {
                    forgetPinnedReplies(profile: profile)
                }
            }
            // A non-empty response is authoritative: if the server no longer
            // knows the active profile (deleted externally), re-home onto a
            // valid fallback instead of leaving `activeProfile ∉ profiles` —
            // a state the profile picker cannot represent. The degraded and
            // empty-payload paths already union `activeProfile` in, so only
            // this branch can need the correction.
            if !names.isEmpty, !nextProfiles.contains(activeProfile) {
                // orderedProfiles always unions "default" into a non-empty
                // names list, so the fallback is unconditionally "default";
                // the contains-check stays as cheap defense-in-depth against
                // a future change to that union invariant.
                adoptAuthoritativeFallbackProfile(
                    nextProfiles.contains("default") ? "default" : nextProfiles[0]
                )
                // The abandoned profile-scoped connect/reconnect work can no
                // longer commit (its identity fences now fail), so converge
                // the transport onto the corrected profile. Fire-and-forget:
                // never awaited inside discovery, and idempotent — the next
                // discovery contains the fallback and will not re-adopt.
                if isConnected {
                    Task { await reconnect() }
                }
            }
            return !names.isEmpty
        } catch {
            guard dashboardTicketBridge === bridge, activeDashboardID == dashboardID else { return false }
            // Profile discovery is additive and monotonic. A failed refresh
            // (bridge still loading, dashboard restart, transient 5xx) must
            // never shrink the visible list or overwrite a complete persisted
            // cache with a degraded fallback — that degradation is exactly
            // how a known profile "disappeared" from the picker until the
            // next successful discovery or a logout/login cycle. Union with
            // the current list so the active profile and the `default`
            // invariant are always represented, then persist the union (a
            // no-op write when the cache is already complete).
            let merged = orderedProfiles(profiles + [activeProfile, "default"])
            profiles = merged
            persistKnownProfiles(merged)
            // A list sent after this one was read and taken meanwhile.
            return read <= profileListReadCommitted
        }
    }

    /// Profile list reads sent, and the newest of them whose list (with
    /// names) was taken, so an older answer landing after it doesn't commit.
    private var profileListReadsSent: UInt64 = 0
    private var profileListReadCommitted: UInt64 = 0

    /// Caches the profile list and, when it changed, tells Siri so the
    /// "Start <profile> voice in Conduit" phrases can match the new names.
    private func persistKnownProfiles(_ names: [String]) {
        guard defaults.stringArray(forKey: knownProfilesKey) != names else { return }
        defaults.set(names, forKey: knownProfilesKey)
        persistSiriProfileNames()
        refreshSiriProfileShortcuts()
    }

    /// Siri and Shortcuts name each profile as the rest of Conduit does,
    /// and follow a rename.
    private func persistSiriProfileNames() {
        let ids = defaults.stringArray(forKey: knownProfilesKey) ?? ["default"]
        var names: [String: String] = [:]
        for id in ids { names[id] = profileDisplayName(id) }
        guard defaults.dictionary(forKey: knownProfileNamesKey) as? [String: String] != names else { return }
        defaults.set(names, forKey: knownProfileNamesKey)
        refreshSiriProfileShortcuts()
    }

    /// Siri re-reads the cached profile list in a later task; discovery and
    /// the server-switch wipe never wait on it.
    func refreshSiriProfileShortcuts() {
        Task {
            SiriProfileShortcuts.refresh()
        }
    }

    /// Authoritative discovery reported a server that no longer contains the
    /// active profile (e.g. it was deleted externally). Re-home onto a valid
    /// fallback using the same local hard-boundary sequence as the forward
    /// profile transition in `connect(with:profile:)`: flush the outgoing
    /// transcript under its presentation-cache namespace, clear the
    /// profile-scoped catalogs and transcript, fence-flip the identity,
    /// prune the deleted profile's persisted bookkeeping, restore the
    /// fallback's remembered session/pinned state, and persist the
    /// correction under `activeProfileKey`.
    ///
    /// Deliberately NOT the interactive `switchProfile(to:reusing:)` flow:
    /// that re-resolves the whole connection and would nest reconnects and
    /// capability loads inside this discovery call site. Callers schedule a
    /// fire-and-forget `reconnect()` when the transport is live so the
    /// client converges onto the corrected profile; every catalog read is
    /// filtered and path-prefixed by the explicit profile, so no
    /// cross-profile transcript or cache state leaks in the window before
    /// that reconnect lands.
    ///
    /// Internal for tests: the fallback adoption is a real destructive Voice
    /// boundary and the cross-profile fail-closed restore contract is pinned
    /// through it.
    func adoptAuthoritativeFallbackProfile(_ fallback: String) {
        guard fallback != activeProfile else { return }
        // A profile change replaces the voice gateway; any in-flight read
        // aloud belongs to the outgoing profile (same as switchProfile).
        messageReadAloudController.stop()
        // A profile re-home ends any live or suspended Voice conversation
        // from the outgoing profile. Persist the outgoing mute and tear down
        // BEFORE the identity flip so it lands in the outgoing profile's
        // blob, never the fallback's (same contract as switchProfile).
        if showVoiceSheet {
            var preferences = loadVoiceProfilePreferences(profile: activeProfile)
            preferences.outputMuted = voiceConversationController.isOutputMuted
            saveVoiceProfilePreferences(preferences, profile: activeProfile)
        }
        voiceConversationController.stop()
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        retireVoiceBackgroundJobs()
        showVoiceSheet = false
        clearClassicVoiceCards()
        suspendedVoiceConversation = nil
        voiceSheetShouldAutoListen = false
        voiceControllerSessionProfile = nil
        flushPendingPresentationCache()
        sessions = []
        cronSessions = []
        archivedSessions = []
        projects = []
        supportsProjects = false
        projectsLoading = false
        projectsLoadFailed = false
        slashCommands = Self.builtInSlashCommands
        slashSubcommands = Self.conduitSlashSubcommands
        messages = []
        persistedTranscriptWindow = nil
        resetTranscriptLifecycleEvidence()
        clearStreamingText()
        resetReasoningTurn()
        // The next profile's approval mode is unknown until its first session
        // snapshot arrives; don't let the deleted profile's approval floor or
        // YOLO state leak across the re-home — neutralize to the safe display
        // until the fallback profile resolves them (same neutralization as
        // switchProfile).
        runtime.approvalsMode = nil
        runtime.yolo = false
        lastReportedSessionYolo = nil
        // Drop the deleted profile's persisted local bookkeeping so a later
        // re-creation with the same name starts fresh instead of
        // resurrecting obsolete titles and pins.
        activeSessionTitlesByProfile.removeValue(forKey: activeProfile)
        pinnedSessionIDsByProfile.removeValue(forKey: activeProfile)
        sessionPinSync.forget(profile: activeProfile)
        persistHostPinSyncState()
        sessionStars.forget(profile: activeProfile)
        sessionStars.save(to: defaults)
        pinnedChatOrder.forget(profile: activeProfile)
        pinnedChatOrder.save(to: defaults)
        voiceJobSessionIDsByProfile.removeValue(forKey: activeProfile)
        forgetPinnedReplies(profile: activeProfile)
        persistActiveSessionTitles()
        persistPinnedSessions()
        persistVoiceJobSessions()
        setActiveProfile(fallback)
        restoreActiveSessionState(for: fallback)
        restorePinnedSessions(for: fallback)
        persistActiveProfile(fallback)
    }

    /// Hermes blocks a clarify/approval prompt for only ~5 minutes server-side
    /// (JSON-RPC error 4009, "no pending … request"), while a restored or
    /// push-delivered card can legitimately outlive it — a notification opened
    /// an hour later is the feature's ordinary case, not an error. Treat that
    /// outcome as "the decision is no longer active" instead of a generic
    /// failure the user can retry forever.
    static func isExpiredPromptError(_ error: Error) -> Bool {
        if let rpcError = error as? RpcError {
            if rpcError.code == 4009 { return true }
            return rpcError.message.lowercased().contains("no pending")
        }
        return error.localizedDescription.lowercased().contains("no pending")
    }

    /// Where an answer to a card without a request id goes.
    enum LegacyApprovalTarget: Equatable {
        /// The gateway names no request ids: it answers the session's queue.
        case sessionQueue
        /// The queued request that asks what the card shows.
        case request(String)
        /// Nothing queued asks what the card shows any more.
        case noLongerPending
        /// A card without its command matches queued requests that run
        /// different commands: the queue's own cards are shown instead.
        case ambiguous
        /// The queue could not be read; nothing is sent. Carries why, for
        /// the card.
        case unknown(String)
    }

    /// A card without a request id (one a push restored, or one from a
    /// gateway before request ids) is answered by session, and Hermes then
    /// settles the oldest queued approval, which need not be the command
    /// the card shows. So read the queue first: a gateway that names its
    /// requests is answered on the one whose command and explanation the
    /// card shows (a push card carries no command, so only the
    /// explanation is compared, as the notifier sends it: collapsed, cut,
    /// or redacted), and nothing is sent when none does. Only
    /// a gateway that names no requests, or has no `approval.pending`,
    /// keeps the session-wide answer.
    private func legacyApprovalTarget(
        for card: ApprovalActivity,
        using client: HermesClient,
        profile: String?
    ) async -> LegacyApprovalTarget {
        let queued: [ApprovalActivity]
        do {
            if let pendingApprovalsWithProfile = chatResumeLifecycleOperations.pendingApprovalsWithProfile {
                queued = try await pendingApprovalsWithProfile(client, card.sessionId, profile)
            } else if let pendingApprovals = chatResumeLifecycleOperations.pendingApprovals {
                queued = try await pendingApprovals(client, card.sessionId)
            } else {
                queued = try await client.pendingApprovals(sessionId: card.sessionId, profile: profile)
            }
        } catch {
            if HermesClient.isMissingRPCMethod(error) { return .sessionQueue }
            // The card's runtime is gone, and with it the wait.
            if HermesClient.isSessionNotFoundError(error) { return .noLongerPending }
            return .unknown(UserFacingError.message(for: error))
        }
        return Self.legacyApprovalTarget(for: card, in: queued)
    }

    /// The explanation a redacted push carries in place of the real one
    /// (conduit-push-notifier `events.py`, `REDACTED_APPROVAL_TEXT`, used by
    /// `redact_event` for profiles with `hermes conduit-push redact on`).
    /// Keep it in step with the notifier.
    static let redactedApprovalPushDescription = "Hermes needs your approval. Open Conduit for details."

    /// How long a push's explanation can be: the notifier collapses its
    /// whitespace and cuts it at 500 code points, with no ellipsis
    /// (`sanitize_decision` / `_clean` in its `events.py`).
    static let approvalPushDescriptionLimit = 500

    static func legacyApprovalTarget(
        for card: ApprovalActivity,
        in queued: [ApprovalActivity]
    ) -> LegacyApprovalTarget {
        if queued.isEmpty { return .noLongerPending }
        let identified = queued.filter { $0.requestId != nil }
        if identified.isEmpty { return .sessionQueue }
        let description = collapsedWhitespace(card.description)
        if card.command.isEmpty, description == redactedApprovalPushDescription {
            // A redacted push names nothing to match: answerable only when
            // one request is queued; with more, the queue's own cards show.
            guard identified.count == 1, let requestId = identified[0].requestId else { return .ambiguous }
            return .request(requestId)
        }
        let command = card.command.trimmingCharacters(in: .whitespacesAndNewlines)
        // The parser trims the push text, so a cut that ended on a space
        // arrives one shorter than the limit.
        let clipped = card.command.isEmpty
            && description.unicodeScalars.count >= approvalPushDescriptionLimit - 1
        let matches = identified.filter { entry in
            let queuedDescription = collapsedWhitespace(entry.description)
            let sameDescription = queuedDescription == description
                || (clipped && queuedDescription.unicodeScalars.starts(with: description.unicodeScalars))
            return sameDescription
                && (command.isEmpty
                    || entry.command.trimmingCharacters(in: .whitespacesAndNewlines) == command)
        }
        guard let requestId = matches.first?.requestId else { return .noLongerPending }
        if Set(matches.map(\.command)).count > 1 { return .ambiguous }
        return .request(requestId)
    }

    /// Text as the notifier sends it: whitespace runs collapsed to one
    /// space, ends trimmed.
    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `shown` is the approval as the card drew it when the person tapped.
    /// When the card has since changed to ask something else (a legacy card
    /// is updated in place by the next command), nothing is sent: the card
    /// on screen already shows the new question to answer.
    func respondToApproval(messageId: String, choice: String, shown: ApprovalActivity? = nil) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              let current = messages[index].approval,
              current.status == .pending || current.status == .error else { return }
        if let shown, !current.asksSameAs(shown) { return }
        let decisionKey = SessionPresentationCache.decisionKey(for: messages[index])

        let submissionIdentity = current.requestId.map { ApprovalSubmissionIdentity.identified($0) }
            ?? ApprovalSubmissionIdentity.legacy(current.sessionId)
        liveApprovalSubmissions.insert(submissionIdentity)
        defer {
            liveApprovalSubmissions.remove(submissionIdentity)
        }

        messages[index].approval?.status = .submitting
        messages[index].approval?.choice = choice
        messages[index].approval?.error = nil
        setRunning(true)
        cacheMessagePresentation()

        guard let client else {
            messages[index].approval?.status = .error
            messages[index].approval?.choice = nil
            messages[index].approval?.error = AppLocalization.string("Gateway connection is unavailable.")
            cacheMessagePresentation()
            return
        }
        // Ownership snapshot: the completion below may only land while this
        // exact client (and profile) still owns AppState. A client/server
        // replacement while the RPC is suspended must turn the stale
        // continuation inert — success and failure alike — even when profile,
        // session, and message ids collide across the two connections. This
        // is the same fence `loadProjects`/`synchronizeTransportContinuation`
        // use; only client ownership changed here, so no epoch beyond the
        // pointer identity is needed.
        let profile = activeProfile
        let conversationProfile = presentationProfile(for: current.sessionId)
        var answeredRequestId = current.requestId
        if current.requestId == nil {
            let target = await legacyApprovalTarget(for: current, using: client, profile: conversationProfile)
            guard profile == activeProfile, self.client === client,
                  let updatedIndex = messages.firstIndex(where: { $0.id == messageId }),
                  SessionPresentationCache.decisionKey(for: messages[updatedIndex]) == decisionKey else { return }
            // The next command replaced the card while the queue was read:
            // a session-queue answer would go to it. Nothing is sent.
            if rearmIfReplaced(at: updatedIndex, asking: current) { return }
            switch target {
            case .sessionQueue:
                break
            case .request(let requestId):
                answeredRequestId = requestId
            case .noLongerPending:
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active.")
                cacheMessagePresentation()
                schedulePendingApprovalsRefresh(sessionId: current.sessionId, using: client)
                return
            case .ambiguous:
                // Back to pending, so the queue's identified cards, each
                // with its command, replace this one.
                messages[updatedIndex].approval?.status = .pending
                messages[updatedIndex].approval?.choice = nil
                cacheMessagePresentation()
                schedulePendingApprovalsRefresh(sessionId: current.sessionId, using: client)
                return
            case .unknown(let reason):
                // Nothing was sent, so not "Hermes did not accept": why
                // the queue couldn't be read, and another read to recover.
                messages[updatedIndex].approval?.status = .error
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = reason
                cacheMessagePresentation()
                schedulePendingApprovalsRefresh(
                    sessionId: current.sessionId,
                    using: client,
                    replacingLegacyErrorMessageID: messageId
                )
                return
            }
        }
        do {
            let outcome: HermesClient.ApprovalResponseOutcome
            if let respondToApproval = chatResumeLifecycleOperations.respondToApproval {
                outcome = try await respondToApproval(
                    client,
                    current.sessionId,
                    answeredRequestId,
                    choice,
                    conversationProfile
                ) ? .accepted : .noLongerWaiting
            } else {
                outcome = try await client.respondToApprovalOutcome(
                    sessionId: current.sessionId,
                    requestId: answeredRequestId,
                    choice: choice,
                    profile: conversationProfile
                )
            }
            guard profile == activeProfile, self.client === client else { return }
            guard let updatedIndex = messages.firstIndex(where: { $0.id == messageId }),
                  SessionPresentationCache.decisionKey(for: messages[updatedIndex]) == decisionKey else { return }
            // A legacy card the next command replaced in flight asks
            // something this answer never saw.
            if rearmIfReplaced(at: updatedIndex, asking: current) {
                schedulePendingApprovalsRefresh(sessionId: current.sessionId, using: client)
                return
            }
            switch outcome {
            case .accepted:
                messages[updatedIndex].approval?.status = choice == "deny" ? .rejected : .approved
            case .noLongerWaiting:
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active — Hermes timed it out and continued.")
            case .ended:
                // Its turn ended (stopped, or the chat moved on): not a timeout.
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active.")
            case .answeredElsewhere:
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval was answered elsewhere.")
            }
            cacheMessagePresentation()
            schedulePendingApprovalsRefresh(sessionId: current.sessionId, using: client)
        } catch {
            guard profile == activeProfile, self.client === client else { return }
            guard let updatedIndex = messages.firstIndex(where: { $0.id == messageId }),
                  SessionPresentationCache.decisionKey(for: messages[updatedIndex]) == decisionKey else { return }
            if rearmIfReplaced(at: updatedIndex, asking: current) { return }
            messages[updatedIndex].approval?.status = .error
            messages[updatedIndex].approval?.choice = nil
            if Self.isExpiredPromptError(error) {
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active — Hermes timed it out and continued.")
            } else if HermesClient.isSessionNotFoundError(error) {
                // The card's runtime is gone (reaped, or re-opened
                // elsewhere), so nothing waits on this answer any more.
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active.")
            } else if let unsent = error as? HermesClient.AnswerNotSent {
                // Never sent: why Hermes couldn't be reached, and the card
                // can be answered again.
                messages[updatedIndex].approval?.error = UserFacingError.message(for: unsent.underlying)
            } else {
                messages[updatedIndex].approval?.error = AppLocalization.string("Hermes did not accept that decision.")
                errorMessage = UserFacingError.message(for: error)
            }
            cacheMessagePresentation()
            if current.requestId == nil {
                switch messages[updatedIndex].approval?.status {
                case .error:
                    schedulePendingApprovalsRefresh(
                        sessionId: current.sessionId,
                        using: client,
                        replacingLegacyErrorMessageID: messageId
                    )
                case .expired:
                    // The legacy request is definitively terminal, so fresh
                    // identified queued rows can be added without replacing
                    // or re-arming its expired presentation.
                    schedulePendingApprovalsRefresh(
                        sessionId: current.sessionId,
                        using: client
                    )
                default:
                    break
                }
            }
        }
    }

    /// When the legacy card at `index` no longer asks what `answered`
    /// asked (it is updated in place by the next command), it goes back to
    /// pending for the new question, and true is returned. An identified
    /// card is the same request whatever its text says now.
    private func rearmIfReplaced(at index: Int, asking answered: ApprovalActivity) -> Bool {
        guard answered.requestId == nil,
              let approval = messages[index].approval, !approval.asksSameAs(answered) else { return false }
        messages[index].approval?.status = .pending
        messages[index].approval?.choice = nil
        messages[index].approval?.error = nil
        cacheMessagePresentation()
        return true
    }

    /// Project navigation is always present in the drawer because every current
    /// Hermes profile has the immutable Home project. Load its authoritative
    /// tree independently of the session catalog so opening the drawer never
    /// depends on a manual Session refresh.
    func refreshProjects() async {
        guard let client else { return }
        await loadProjects(using: client, profile: activeProfile)
    }

    /// True when Hermes' list came in and is the one shown.
    @discardableResult
    func loadProjects(using client: HermesClient, profile: String) async -> Bool {
        projectsRequestGeneration += 1
        let generation = projectsRequestGeneration
        projectsLoading = true
        defer {
            if generation == projectsRequestGeneration,
               profile == activeProfile,
               self.client === client {
                projectsLoading = false
            }
        }
        do {
            let loaded = try await client.projects()
            guard generation == projectsRequestGeneration,
                  profile == activeProfile,
                  self.client === client else { return false }
            projects = loaded.sorted {
                if $0.isHome != $1.isHome { return $0.isHome }
                if $0.sessionCount != $1.sessionCount { return $0.sessionCount > $1.sessionCount }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            supportsProjects = true
            projectsLoadFailed = false
            return true
        } catch {
            guard generation == projectsRequestGeneration,
                  profile == activeProfile,
                  self.client === client else { return false }
            // A view's load cancelled by leaving it didn't fail.
            if error is CancellationError || Task.isCancelled { return false }
            guard isProjectsUnavailable(error) else {
                projectsLoadFailed = projects.isEmpty
                return false
            }
            projects = []
            supportsProjects = false
            projectsLoadFailed = false
            return false
        }
    }

    private func isProjectsUnavailable(_ error: Error) -> Bool {
        guard let rpcError = error as? RpcError else { return false }
        let message = rpcError.message.lowercased()
        return isMethodUnavailable(error)
            || message.contains("projects.tree") && message.contains("not found")
    }

    func isMethodUnavailable(_ error: Error) -> Bool {
        guard let rpcError = error as? RpcError else { return false }
        let message = rpcError.message.lowercased()
        return rpcError.code == -32601
            || message.contains("method not found")
            || message.contains("unknown method")
    }

    func loadProjectSessions(_ project: ProjectSummary) async -> ProjectSessionDetail? {
        guard let client, supportsProjects else { return nil }
        let profile = activeProfile
        do {
            let detail = try await client.projectSessions(project.id)
            guard profile == activeProfile, self.client === client else { return nil }
            return detail
        } catch {
            guard profile == activeProfile, self.client === client else { return nil }
            // A page's read cancelled by a newer one (the list changed) or
            // by leaving the page didn't fail.
            if error is CancellationError || Task.isCancelled { return nil }
            if isProjectsUnavailable(error) {
                projects = []
                supportsProjects = false
            } else {
                errorMessage = AppLocalization.string("Could not load \(project.title): \(UserFacingError.message(for: error))")
            }
            return nil
        }
    }

    /// What a New Project create came to, for the sheet, which stays open
    /// with the message unless the project was made with all it was given.
    enum ProjectCreateOutcome: Equatable {
        case created
        /// Made (its id), but the idea isn't in IDEA.md: the sheet keeps it
        /// on screen and Save Idea tries the write again.
        case ideaUnsaved(projectID: String, message: String)
        case failed(String?)
    }

    @discardableResult
    func createProject(name: String, folders: [String], idea: String) async -> ProjectCreateOutcome {
        guard let client, supportsProjects else { return .failed(nil) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueFolders = folders.reduce(into: [String]()) { result, folder in
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
        }
        guard !trimmedName.isEmpty, !uniqueFolders.isEmpty else { return .failed(nil) }

        let profile = activeProfile
        let dashboard = activeDashboardID
        // Checked again on Hermes' list as it is now: another device may
        // have made the same project since the list was read, and Hermes
        // would take a second one. A list that didn't come in checks nothing.
        guard await loadProjects(using: client, profile: profile) else {
            return .failed(AppLocalization.string("Couldn’t check Hermes’ projects. Try again."))
        }
        guard profile == activeProfile, self.client === client else { return .failed(nil) }
        if let problem = projectCreationProblem(name: trimmedName, folders: uniqueFolders) { return .failed(problem) }
        let knownIDs = Set(projects.map(\.id))
        // The idea goes to the first folder of a project that was made.
        func finish(_ created: ProjectSummary) async -> ProjectCreateOutcome {
            let trimmedIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
            var ideaSaved = true
            if !trimmedIdea.isEmpty {
                ideaSaved = await writeProjectIdea(trimmedIdea, in: uniqueFolders[0], profile: profile,
                                                   dashboard: dashboard)
            }
            // Hermes made it, so what's left only reports that: a reconnect
            // that replaced the client mid-create reads the list through
            // the new one, and an answered create is never a failure, which
            // a retry would then find as a clash (issue 1688).
            if dashboard == activeDashboardID, profile == activeProfile, let current = self.client {
                await loadProjects(using: current, profile: profile)
            }
            return ideaSaved
                ? .created
                : .ideaUnsaved(projectID: created.id,
                               message: AppLocalization.string("\(created.title) is made, but its idea couldn’t be saved as IDEA.md."))
        }
        do {
            guard let created = try await client.createProject(name: trimmedName, folders: uniqueFolders) else {
                throw HermesError.invalidResponse
            }
            // The same Hermes and profile take the row, across a reconnect.
            if dashboard == activeDashboardID, profile == activeProfile {
                projects = [created] + projects.filter { $0.id != created.id }
                supportsProjects = true
            }
            return await finish(created)
        } catch {
            guard dashboard == activeDashboardID, profile == activeProfile,
                  let current = self.client else { return .failed(nil) }
            if current === client, isProjectsUnavailable(error) {
                projects = []
                supportsProjects = false
                return .failed(nil)
            }
            // Hermes may have made it anyway (an answer Conduit couldn't
            // read, or a reconnect mid-create, read through the new client):
            // a new project with this name on this first folder is this one,
            // and takes the idea; anything else read again lets a retry see
            // the clash.
            if await loadProjects(using: current, profile: profile),
               dashboard == activeDashboardID, profile == activeProfile, self.client === current,
               let made = Self.projectMadeAnyway(name: trimmedName, firstFolder: uniqueFolders[0],
                                                 knownIDs: knownIDs, in: projects) {
                return await finish(made)
            }
            return .failed(AppLocalization.string("Could not create the project: \(UserFacingError.message(for: error))"))
        }
    }

    /// Only projects someone created can be renamed or deleted: Home is
    /// immutable, and auto-discovered repos have no project record.
    func isProjectEditable(_ project: ProjectSummary) -> Bool {
        guard let client, supportsProjects, isConnected,
              client !== projectEditingUnsupportedClient else { return false }
        return !project.isHome && !project.isAuto
    }

    /// The project a rename or delete is running for; a second one waits.
    @Published private(set) var projectMutationID: String?

    /// Project rename and delete controls stay disabled while one runs.
    var isProjectMutationInFlight: Bool { projectMutationID != nil }

    @discardableResult
    func renameProject(_ project: ProjectSummary, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, projectMutationID == nil else { return false }
        guard let client, isProjectEditable(project) else {
            errorMessage = AppLocalization.string("Could not rename \(project.title): Conduit is not connected to Hermes.")
            return false
        }
        let profile = activeProfile
        projectMutationID = project.id
        defer { projectMutationID = nil }
        do {
            try await client.renameProject(project.id, name: trimmed)
            guard profile == activeProfile, self.client === client else { return false }
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index].title = trimmed
            }
            await loadProjects(using: client, profile: profile)
            return true
        } catch {
            guard profile == activeProfile, self.client === client else { return false }
            if isMethodUnavailable(error) {
                // Only this action is missing; keep the project list.
                projectEditingUnsupportedClient = client
                errorMessage = AppLocalization.string("This Hermes version can't rename or delete projects.")
            } else {
                errorMessage = AppLocalization.string("Could not rename \(project.title): \(UserFacingError.message(for: error))")
            }
            return false
        }
    }

    @discardableResult
    func deleteProject(_ project: ProjectSummary) async -> Bool {
        guard projectMutationID == nil else { return false }
        guard let client, isProjectEditable(project) else {
            errorMessage = AppLocalization.string("Could not delete \(project.title): Conduit is not connected to Hermes.")
            return false
        }
        let profile = activeProfile
        projectMutationID = project.id
        defer { projectMutationID = nil }
        do {
            try await client.deleteProject(project.id)
            guard profile == activeProfile, self.client === client else { return false }
            projects.removeAll { $0.id == project.id }
            await loadProjects(using: client, profile: profile)
            return true
        } catch {
            guard profile == activeProfile, self.client === client else { return false }
            if isMethodUnavailable(error) {
                // Only this action is missing; keep the project list.
                projectEditingUnsupportedClient = client
                errorMessage = AppLocalization.string("This Hermes version can't rename or delete projects.")
            } else {
                errorMessage = AppLocalization.string("Could not delete \(project.title): \(UserFacingError.message(for: error))")
            }
            return false
        }
    }

    /// Projects a conversation can be moved into: every project with a root
    /// folder except Home, which has no folder to move into. Mirrors the
    /// Hermes Desktop "Move to project" submenu.
    var projectMoveTargets: [ProjectSummary] {
        guard supportsProjects, supportsSessionWorkspaceMove else { return [] }
        return projects.filter { project in
            !project.isHome
                && project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// The project a conversation is known to live in, from the tree's
    /// preview rows. The session catalog carries no folder, so this is only a
    /// best-effort hint for hiding the no-op "move here" target; nil means
    /// unknown, not "in no project".
    func knownProjectID(for session: SessionSummary) -> String? {
        // A new chat Hermes doesn't list yet belongs to the project it was
        // started in, so the Chats list sorts it as it will once listed.
        if let awaiting = openNewChatAwaitingListing, awaiting.matches(session) {
            return projects.first { !$0.isHome && awaiting.isIn($0) }?.id
        }
        let index = projectPositionsIndex()
        guard !index.isEmpty else { return nil }
        // The first listed project holding any id the conversation answers to.
        var first: Int?
        for id in [session.id, session.storedSessionId].compactMap({ $0 }) + session.alternateIds {
            if let position = index[id], position < (first ?? .max) { first = position }
        }
        return first.map { projects[$0].id }
    }

    /// The catalog's copy of a chat another list carries (a project tree's
    /// preview), which a reply or a read updates between loads of that list.
    /// A row's own ids (`id`, `storedSessionId`) win over the ids it shares
    /// with others (a branch's lineage root is its parent's id), so a parent
    /// never reads a newer branch's copy; the shared ones still find a chat
    /// compressed since the list loaded.
    func catalogRow(answeringTo session: SessionSummary) -> SessionSummary? {
        let index: [String: SessionSummary]
        if let cached = catalogRowsByAnyID {
            index = cached
        } else {
            var built: [String: SessionSummary] = [:]
            for row in sessions {
                for id in Self.ownIDs(row) where built[id] == nil { built[id] = row }
            }
            for row in sessions {
                for id in Self.sharedIDs(row) where built[id] == nil { built[id] = row }
            }
            catalogRowsByAnyID = built
            index = built
        }
        return (Self.ownIDs(session) + Self.sharedIDs(session)).lazy.compactMap { index[$0] }.first
    }

    static func ownIDs(_ session: SessionSummary) -> [String] {
        [session.id, session.storedSessionId].compactMap { $0 }.filter { !$0.isEmpty }
    }

    private static func sharedIDs(_ session: SessionSummary) -> [String] {
        ([session.lineageRootId].compactMap { $0 } + session.alternateIds).filter { !$0.isEmpty }
    }

    private func projectPositionsIndex() -> [String: Int] {
        if let index = projectPositionsBySessionID { return index }
        var index: [String: Int] = [:]
        for (position, project) in projects.enumerated() where !project.isHome {
            for preview in project.previewSessions {
                for id in [preview.id, preview.storedSessionId].compactMap({ $0 }) where index[id] == nil {
                    index[id] = position
                }
            }
        }
        projectPositionsBySessionID = index
        return index
    }

    /// Moves a conversation into `project` by re-homing its workspace at the
    /// project's root folder (`session.workspace.move`). Hermes derives
    /// project membership from the session's folder, so the project tree is
    /// reloaded afterwards instead of patched locally.
    @discardableResult
    func moveSession(_ session: SessionSummary, to project: ProjectSummary) async -> Bool {
        if sessionMutationID != nil {
            errorMessage = AppLocalization.string("Wait for the current conversation change to finish, then try again.")
            return false
        }
        guard client != nil, isConnected else {
            errorMessage = AppLocalization.string("Reconnect to Hermes to move this conversation.")
            return false
        }
        guard let client,
              supportsProjects,
              supportsSessionWorkspaceMove,
              !project.isHome,
              let path = project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              sessionBelongsToProfile(session, profile: activeProfile) else {
            errorMessage = AppLocalization.string("This conversation can't be moved to \(project.title).")
            return false
        }

        let profile = activeProfile
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        do {
            // `session_key` is the DURABLE stored key: a live catalog row's
            // `id` is its runtime session id, which the gateway's state.db
            // lookup would not find.
            try await client.moveSessionWorkspace(session.storedSessionId ?? session.id, cwd: path)
            guard profile == activeProfile, self.client === client else { return false }
            await loadProjects(using: client, profile: profile)
            return true
        } catch {
            guard profile == activeProfile, self.client === client else { return false }
            if isMethodUnavailable(error) {
                // The project tree still works on this gateway; only the
                // move is missing, so hide the action instead of projects.
                workspaceMoveUnsupportedClient = client
                errorMessage = AppLocalization.string("Update Hermes to move conversations between projects.")
            } else {
                errorMessage = AppLocalization.string("Could not move this conversation to \(project.title): \(UserFacingError.message(for: error))")
            }
            return false
        }
    }

    /// The project folder picker starts at the same live workspace the chat
    /// browser uses, else at Home's folder, so a project can be made with no
    /// chat open (issue 1661). Folder paths are selected from Hermes'
    /// filesystem listing, not entered as arbitrary strings by the phone.
    var projectFolderPickerRoot: String {
        // runtime.cwd outlives the chat that set it.
        if let session = activeSessionId, !session.isEmpty, let folder = chatWorkspaceFolder { return folder }
        return projects.first(where: \.isHome)?.primaryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Why a new project can't be made as it stands, or nil: Hermes would
    /// take a second project of the same name, or a folder that is already
    /// another project's, and list both (issue 1661). Home and the repos
    /// Hermes found on its own have no record to clash with.
    func projectCreationProblem(name: String, folders: [String]) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = projects.filter { !$0.isHome && !$0.isAuto }
        if !trimmedName.isEmpty,
           let clash = made.first(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
               .caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return AppLocalization.string("There’s already a project named \(clash.title).")
        }
        for folder in folders {
            let path = Self.normalizedWorkspacePath(folder.trimmingCharacters(in: .whitespacesAndNewlines))
            if let owner = made.first(where: { project in
                project.primaryPath.map { Self.normalizedWorkspacePath($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == path
            }) {
                return AppLocalization.string("\(folder) is already the folder of \(owner.title).")
            }
        }
        return nil
    }

    /// The project a create that failed made anyway: new since the create
    /// was asked, with its name and first folder. A name alone could be
    /// another device's.
    static func projectMadeAnyway(name: String, firstFolder: String, knownIDs: Set<String>,
                                  in projects: [ProjectSummary]) -> ProjectSummary? {
        let folder = normalizedWorkspacePath(firstFolder.trimmingCharacters(in: .whitespacesAndNewlines))
        return projects.first { project in
            !knownIDs.contains(project.id) && !project.isHome && !project.isAuto
                && project.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
                && project.primaryPath.map { normalizedWorkspacePath($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == folder
        }
    }

    /// Whether a folder's listing already has an IDEA.md, which a new
    /// project never writes over (issue 1661).
    static func folderHasProjectIdea(_ entries: [WorkspaceEntry]) -> Bool {
        entries.contains { !$0.isDirectory && $0.name.caseInsensitiveCompare("IDEA.md") == .orderedSame }
    }

    /// A new folder for a project, made in `folder` through the plugin's
    /// workspace routes, which refuse a name that's already there.
    func makeProjectFolder(named name: String, in folder: String, profile: String? = nil) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = try await workspaceFilesClient(profile: profile ?? activeProfile)
            .makeFolder(root: folder, in: folder, name: trimmed)
        return entry?.path
    }

    /// Folders opened in the Folder with Open Folder… (issue 1438): on this
    /// device, for each dashboard and profile, the latest first.
    static let openedWorkspaceFoldersKey = "conduit.workspaceOpenedFolders"
    static let openedWorkspaceFoldersLimit = 8

    private func openedWorkspaceFoldersBucket(profile: String) -> String {
        "\(Self.dashboardPreferenceBucket(activeDashboardID))|\(profile)"
    }

    func openedWorkspaceFolders(profile: String) -> [String] {
        let all = defaults.dictionary(forKey: Self.openedWorkspaceFoldersKey) as? [String: [String]] ?? [:]
        return all[openedWorkspaceFoldersBucket(profile: profile)] ?? []
    }

    func rememberOpenedWorkspaceFolder(_ path: String, profile: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let kept = openedWorkspaceFolders(profile: profile).filter { $0 != trimmed }
        setOpenedWorkspaceFolders(Array(([trimmed] + kept).prefix(Self.openedWorkspaceFoldersLimit)), profile: profile)
    }

    func forgetOpenedWorkspaceFolder(_ path: String, profile: String) {
        setOpenedWorkspaceFolders(openedWorkspaceFolders(profile: profile).filter { $0 != path }, profile: profile)
    }

    private func setOpenedWorkspaceFolders(_ paths: [String], profile: String) {
        var all = defaults.dictionary(forKey: Self.openedWorkspaceFoldersKey) as? [String: [String]] ?? [:]
        all[openedWorkspaceFoldersBucket(profile: profile)] = paths.isEmpty ? nil : paths
        objectWillChange.send()
        defaults.set(all, forKey: Self.openedWorkspaceFoldersKey)
    }

    func workspaceDirectoryEntries(at path: String) async throws -> [WorkspaceEntry] {
        let profile = activeProfile
        let entries = try await workspaceDirectoryEntries(at: path, profile: profile)
        guard profile == activeProfile else { return [] }
        return entries
    }

    /// The sheet's Save Idea after a create whose idea wasn't saved.
    /// `profile` and `dashboard` are the ones the project was made in,
    /// which a switch while the sheet waits doesn't change.
    func saveProjectIdea(_ idea: String, in folder: String, profile: String, dashboard: UUID?) async -> Bool {
        let trimmed = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return await writeProjectIdea(trimmed, in: folder, profile: profile, dashboard: dashboard)
    }

    /// Never over an IDEA.md the folder already has: an existing folder
    /// keeps its files (issue 1661), and an unreadable one is left alone.
    /// False when the idea wasn't saved for any other reason, or when
    /// Conduit has switched to another Hermes since the project was made:
    /// the folder is that host's, not this one's (issue 1688).
    private func writeProjectIdea(_ idea: String, in folder: String, profile: String, dashboard: UUID?) async -> Bool {
        guard dashboard == activeDashboardID,
              let entries = try? await workspaceDirectoryEntries(at: folder, profile: profile) else { return false }
        if Self.folderHasProjectIdea(entries) { return true }
        guard dashboard == activeDashboardID, let dashboardTicketBridge else { return false }
        let separator = folder.hasSuffix("/") || folder.hasSuffix("\\") ? "" : "/"
        let path = "\(folder)\(separator)IDEA.md"
        return (try? await dashboardTicketBridge.requestJSON(
            path: dashboardPath("/api/fs/write-text", profile: profile),
            method: "POST",
            body: ["path": path, "content": idea.hasSuffix("\n") ? idea : "\(idea)\n"]
        )) != nil
    }

    func orderedProfiles(_ values: [String]) -> [String] {
        let discovered = Array(Set(values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        let orders = defaults.dictionary(forKey: profileOrderByDashboardKey) as? [String: [String]] ?? [:]
        let savedOrder = orders[Self.dashboardPreferenceBucket(activeDashboardID)] ?? []
        let knownOrder = savedOrder.filter { discovered.contains($0) }
        let unordered = discovered
            .filter { !knownOrder.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if savedOrder.isEmpty, let defaultProfile = unordered.first(where: { $0 == "default" }) {
            return [defaultProfile] + unordered.filter { $0 != "default" }
        }
        return knownOrder + unordered
    }

    static func normalizedSessionFilterOrder(_ values: [String]) -> [SessionSource] {
        let defaults = Self.defaultSessionFilterOrder
        let requested = values.compactMap(SessionSource.init(rawValue:))
        var unique = requested.reduce(into: [SessionSource]()) { result, source in
            if !result.contains(source), defaults.contains(source) {
                result.append(source)
            }
        }
        // Filters a saved order predates (Voice, Voice Jobs, Cron) take their
        // default place after the one before them, not the end of the row.
        for (position, source) in defaults.enumerated() where !unique.contains(source) {
            let after = defaults[..<position].last { unique.contains($0) }
            let index = after.flatMap { unique.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            unique.insert(source, at: index)
        }
        return unique
    }

    // MARK: - Capabilities

    /// Request-scoped result for a capability load. The caller must be able to
    /// know how THIS request ended without consulting global error/skill
    /// state, which can be stale or mutated by unrelated flows.
    enum CapabilityLoadOutcome {
        case success(profile: String)
        case failed(profile: String, message: String)
        case unavailable(profile: String)
        /// The active dashboard or profile changed mid-request; the result
        /// belongs to an abandoned one and callers should discard it.
        case superseded(requested: CapabilitySnapshotOwner, active: CapabilitySnapshotOwner)

        var isSuperseded: Bool {
            if case .superseded = self { return true }
            return false
        }
    }

    @discardableResult
    func loadCapabilities() async -> CapabilityLoadOutcome {
        capabilityLoadGeneration &+= 1
        let generation = capabilityLoadGeneration
        let profile = activeProfile
        let owner = currentCapabilitiesOwner
        guard let runtime = currentDashboardRuntimeOwner() else { return .unavailable(profile: profile) }
        // Kept for Capabilities to open on next time (#1533).
        async let skillsResult = readKeepingAnswer(KeptRoute.skills, profile: profile, owner: runtime)
        async let toolsetsResult = readKeepingToolsets(profile: profile, owner: runtime)
        // Commit gate: this exact request must still be the newest one AND
        // target the still-active dashboard and profile (A -> B -> A stale
        // commits rejected).
        func ownsRequest() -> Bool {
            CapabilityLoadPolicy.canCommit(
                generation: generation,
                latestGeneration: capabilityLoadGeneration,
                requested: owner,
                active: currentCapabilitiesOwner
            )
        }
        do {
            let (skillsResponse, toolsetsResponse) = try await (skillsResult, toolsetsResult)
            guard ownsRequest() else { return .superseded(requested: owner, active: currentCapabilitiesOwner) }
            self.skills = capabilitySkills(from: skillsResponse)
            self.toolsets = capabilityToolsets(from: toolsetsResponse)
            adoptToolCatalog(ToolCatalog(toolsets: self.toolsets), key: toolCatalogKey)
            capabilitiesOwner = owner
            capabilitiesAreKept = false
            return .success(profile: profile)
        } catch {
            guard ownsRequest() else { return .superseded(requested: owner, active: currentCapabilitiesOwner) }
            errorMessage = AppLocalization.string("Could not load capabilities: \(UserFacingError.message(for: error))")
            return .failed(profile: profile, message: AppLocalization.string("Could not load capabilities: \(UserFacingError.message(for: error))"))
        }
    }

    /// Draws the installed skills and toolsets Hermes gave last time on
    /// this dashboard and profile, kept on the phone (#1533), unless this
    /// profile's are already showing; only once both lists are kept.
    func showKeptCapabilities() {
        guard !capabilitiesAreCurrent,
              let skillsAnswer = keptAnswer(KeptRoute.skills),
              let toolsetsAnswer = keptAnswer(KeptRoute.toolsets) else { return }
        skills = capabilitySkills(from: skillsAnswer)
        toolsets = capabilityToolsets(from: toolsetsAnswer)
        capabilitiesOwner = currentCapabilitiesOwner
        capabilitiesAreKept = true
    }

    func capabilitySkills(from answer: [String: Any]) -> [CapabilitySkill] {
        (answer["_array"] as? [Any] ?? []).compactMap(decodeCapabilitySkill)
            .sorted { lhs, rhs in
                let lhsCat = lhs.category ?? ""
                let rhsCat = rhs.category ?? ""
                if lhsCat != rhsCat { return lhsCat < rhsCat }
                return lhs.name < rhs.name
            }
    }

    private func capabilityToolsets(from answer: [String: Any]) -> [CapabilityToolset] {
        (answer["_array"] as? [Any] ?? []).compactMap(decodeCapabilityToolset)
            .sorted { ($0.label ?? $0.name) < ($1.label ?? $1.name) }
    }

    /// Keeps a switch Hermes took in the list it's kept in, so Capabilities
    /// opens on it next time, the dashboard switched away from included.
    /// A flip drops the read on its way (it was asked before it): rows
    /// still kept ask again, as they'd otherwise stay up.
    private func keepFlip(_ route: String, name: String, enabled: Bool, profile: String, owner: DashboardRuntimeOwner, removals: Int) async {
        if let kept = keptAnswer(route, profile: profile, on: owner), let rows = kept["_array"] as? [Any] {
            let flipped = rows.map { row -> Any in
                guard var row = row as? [String: Any], row["name"] as? String == name else { return row }
                row["enabled"] = enabled
                return row
            }
            keepWrittenAnswer(["_array": flipped], for: route, profile: profile, owner: owner, removals: removals)
        } else {
            noteKeptAnswerWrite(for: route, profile: profile, owner: owner)
        }
        guard capabilitiesAreKept, ownsDashboardRuntime(owner), profile == activeProfile else { return }
        await loadCapabilities()
    }

    /// `rows` is the snapshot the switch was flipped in (a bulk change's
    /// first one); nothing is sent once it is no longer the one showing.
    func toggleSkill(name: String, enabled: Bool, rows: CapabilitySnapshotOwner? = nil) async {
        let profile = activeProfile
        guard capabilityRowsAreCurrent(rows), let owner = currentDashboardRuntimeOwner() else { return }
        let dashboardTicketBridge = owner.bridge
        let removals = offlineChatCache.removals
        let current = skills.first(where: { $0.name == name })?.enabled ?? !enabled
        // Optimistic update. A list read still on its way was read before
        // this flip: it no longer commits (as CapabilitiesStore, #867).
        capabilityLoadGeneration &+= 1
        if let index = skills.firstIndex(where: { $0.name == name }) {
            skills[index].enabled = enabled
        }
        // After every switch flipped before it; a failure puts back what
        // Hermes last confirmed, unless a newer flip is on its way.
        let outcome = await capabilityToggleWrites.send("\(ObjectIdentifier(owner.bridge))|\(profile)|skill|\(name)", enabled: enabled, current: current) {
            // Hermes rewrites the profile config for it: in turn with
            // every other config save.
            try await ProfileConfigWriteQueue.runThrowing {
                _ = try await dashboardTicketBridge.requestJSON(
                    path: "/api/skills/toggle",
                    method: "PUT",
                    body: ["name": name, "enabled": enabled, "profile": profile]
                )
            }
        }
        // Kept only once Hermes took it: a refused flip a newer one
        // replaced says nothing failed, but was never saved.
        if outcome.taken {
            await keepFlip(KeptRoute.skills, name: name, enabled: enabled, profile: profile, owner: owner, removals: removals)
        }
        guard ownsDashboardRuntime(owner), let error = outcome.error, profile == activeProfile else { return }
        if let restore = outcome.restore, let index = skills.firstIndex(where: { $0.name == name }) {
            skills[index].enabled = restore
        }
        errorMessage = AppLocalization.string("Could not update skill: \(UserFacingError.message(for: error))")
        // The flip dropped the read on its way: a list still kept asks again.
        if capabilitiesAreKept { await loadCapabilities() }
    }

    /// `rows` is the snapshot the switch was flipped in (a bulk change's
    /// first one); nothing is sent once it is no longer the one showing.
    func toggleToolset(name: String, enabled: Bool, rows: CapabilitySnapshotOwner? = nil) async {
        let profile = activeProfile
        guard capabilityRowsAreCurrent(rows), let owner = currentDashboardRuntimeOwner() else { return }
        let dashboardTicketBridge = owner.bridge
        let removals = offlineChatCache.removals
        let current = toolsets.first(where: { $0.name == name })?.enabled ?? !enabled
        // Optimistic update. A list read still on its way was read before
        // this flip: it no longer commits (as CapabilitiesStore, #867).
        capabilityLoadGeneration &+= 1
        if let index = toolsets.firstIndex(where: { $0.name == name }) {
            toolsets[index].enabled = enabled
        }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        // In the same order as skill switches: Hermes rewrites one config.
        let outcome = await capabilityToggleWrites.send("\(ObjectIdentifier(owner.bridge))|\(profile)|toolset|\(name)", enabled: enabled, current: current) {
            // Hermes rewrites the profile config for it: in turn with
            // every other config save.
            try await ProfileConfigWriteQueue.runThrowing {
                _ = try await dashboardTicketBridge.requestJSON(
                    path: "/api/tools/toolsets/\(encodedName)",
                    method: "PUT",
                    body: ["enabled": enabled, "profile": profile]
                )
            }
        }
        // Kept only once Hermes took it: a refused flip a newer one
        // replaced says nothing failed, but was never saved.
        if outcome.taken {
            await keepFlip(KeptRoute.toolsets, name: name, enabled: enabled, profile: profile, owner: owner, removals: removals)
        }
        guard ownsDashboardRuntime(owner), let error = outcome.error, profile == activeProfile else { return }
        if let restore = outcome.restore, let index = toolsets.firstIndex(where: { $0.name == name }) {
            toolsets[index].enabled = restore
        }
        errorMessage = AppLocalization.string("Could not update toolset: \(UserFacingError.message(for: error))")
        // The flip dropped the read on its way: a list still kept asks again.
        if capabilitiesAreKept { await loadCapabilities() }
    }

    /// The dashboard, bridge and profile a capability read made now would
    /// belong to.
    var currentCapabilitiesOwner: CapabilitySnapshotOwner {
        CapabilitySnapshotOwner(
            dashboardID: activeDashboardID,
            bridge: dashboardTicketBridge.map { ObjectIdentifier($0) },
            profile: activeProfile
        )
    }

    /// Whether the installed skills and toolsets are the current dashboard's
    /// and profile's: anything that shows them checks this first.
    var capabilitiesAreCurrent: Bool {
        CapabilityLoadPolicy.shouldPresentRows(snapshot: capabilitiesOwner, active: currentCapabilitiesOwner)
    }

    /// Whether a switch flipped in `rows` (nil: the rows showing) may still
    /// act: they are the rows showing, and those are the current
    /// dashboard's and profile's.
    private func capabilityRowsAreCurrent(_ rows: CapabilitySnapshotOwner?) -> Bool {
        guard let rows = rows ?? capabilitiesOwner else { return false }
        return rows == capabilitiesOwner && rows == currentCapabilitiesOwner
    }

    /// The installed skills and toolsets belong to the dashboard switched
    /// away from: a read still on its way commits nothing, and its rows
    /// never show (or act) under the next one.
    private func retireCapabilitySnapshot() {
        capabilityLoadGeneration &+= 1
        capabilitiesOwner = nil
        capabilitiesAreKept = false
        skills = []
        toolsets = []
    }

    private func decodeCapabilitySkill(_ value: Any) -> CapabilitySkill? {
        guard let dict = value as? [String: Any], let name = dict["name"] as? String else { return nil }
        return CapabilitySkill(
            name: name,
            description: dict["description"] as? String,
            category: dict["category"] as? String,
            enabled: dict["enabled"] as? Bool ?? false,
            provenance: dict["provenance"] as? String,
            usage: dict["usage"] as? Int
        )
    }

    // MARK: - Tools catalog for step rows

    /// The active dashboard and profile, for what is kept per profile on
    /// this device (the tools catalog, step summaries).
    var toolCatalogKey: String {
        "\(Self.dashboardPreferenceBucket(activeDashboardID)).\(activeProfile)"
    }

    /// Shows the profile's saved catalog at once, then asks Hermes for the
    /// current one, once per profile while Conduit runs (Capabilities
    /// refreshes it too). A failed read is tried again on the next chat.
    func loadToolCatalogIfNeeded() async {
        let key = toolCatalogKey
        if toolCatalogOwner != key {
            toolCatalogOwner = key
            toolCatalog = ToolCatalog.saved(key: key, defaults: defaults)
        }
        guard !toolCatalogFetched.contains(key), !toolCatalogLoading.contains(key),
              let owner = currentDashboardRuntimeOwner() else { return }
        // Two chats opened in a row ask once.
        toolCatalogLoading.insert(key)
        defer { toolCatalogLoading.remove(key) }
        // The answer Capabilities' Tools tab opens on, kept for it too.
        guard let response = try? await readKeepingToolsets(profile: activeProfile, owner: owner) else { return }
        let toolsets = (response["_array"] as? [Any] ?? []).compactMap(decodeCapabilityToolset)
        adoptToolCatalog(ToolCatalog(toolsets: toolsets), key: key)
    }

    /// An empty catalog (a Hermes still loading its plugins, or one that
    /// answered nothing) neither replaces the saved one nor ends the
    /// retries: the next chat asks again.
    private func adoptToolCatalog(_ catalog: ToolCatalog, key: String) {
        guard !catalog.isEmpty else { return }
        toolCatalogFetched.insert(key)
        if catalog != ToolCatalog.saved(key: key, defaults: defaults) {
            catalog.save(key: key, defaults: defaults)
        }
        guard key == toolCatalogKey else { return }
        toolCatalogOwner = key
        if toolCatalog != catalog { toolCatalog = catalog }
    }

    private func decodeCapabilityToolset(_ value: Any) -> CapabilityToolset? {
        guard let dict = value as? [String: Any], let name = dict["name"] as? String else { return nil }
        let tools = dict["tools"] as? [Any]
        return CapabilityToolset(
            name: name,
            description: dict["description"] as? String,
            enabled: dict["enabled"] as? Bool ?? false,
            configured: dict["configured"] as? Bool,
            label: dict["label"] as? String,
            tools: tools as? [String]
        )
    }

    // MARK: - Scheduled jobs

    func loadCronJobs() async {
        let profile = activeProfile
        let generation = cronJobsGeneration
        // One read at a time for the list as it is, on the connection and
        // profile it is for: one an edit, a dashboard switch, a reconnect or
        // a profile change made stale since doesn't hold the next back.
        let owner = "\(generation)|\(profile)|"
            + (dashboardTicketBridge.map { "\(ObjectIdentifier($0))" } ?? client.map { "c\(ObjectIdentifier($0))" } ?? "")
        // The same list's read joins the one out: it runs on its own, so a
        // Tasks tab whose task restarted mid-read (tab away and back) still
        // sees it land, rather than finding it held and reading nothing.
        if let running = cronJobsRead, running.owner == owner {
            await running.task.value
            return
        }
        // The read's own token, as an owner comes back (A, B, then A again)
        // while an older read for it may still be out.
        let token = UUID()
        let task = Task<Void, Never> { [weak self] in
            await self?.readCronJobs(token: token, profile: profile, generation: generation)
        }
        cronJobsRead = (owner, token, task)
        cronJobsLoading = true
        await task.value
    }

    private func readCronJobs(token: UUID, profile: String, generation: Int) async {
        let startedBridge = dashboardTicketBridge
        let startedClient = client
        defer {
            if cronJobsRead?.token == token {
                cronJobsRead = nil
                cronJobsLoading = false
            }
        }

        do {
            if let dashboardTicketBridge {
                let result = try await dashboardTicketBridge.requestJSON(path: cronDashboardPath("/api/cron/jobs", profile: profile))
                let values = result["_array"] as? [Any] ?? result["jobs"] as? [Any] ?? []
                let jobs = values.compactMap(decodeCronJob)
                guard profile == activeProfile, generation == cronJobsGeneration,
                      self.dashboardTicketBridge === dashboardTicketBridge,
                      cronJobsRead?.token == token else { return }
                cronJobs = jobs.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            } else if let client {
                let jobs = try await client.listCronJobs()
                guard profile == activeProfile, self.client === client, generation == cronJobsGeneration,
                      cronJobsRead?.token == token else { return }
                cronJobs = jobs
            }
        } catch is CancellationError {
            return
        } catch {
            // A read the outgoing connection failed isn't the next one's to report.
            guard profile == activeProfile, generation == cronJobsGeneration,
                  dashboardTicketBridge === startedBridge, client === startedClient,
                  cronJobsRead?.token == token else { return }
            errorMessage = AppLocalization.string("Could not load scheduled jobs: \(UserFacingError.message(for: error))")
        }
    }

    /// The jobs listed are the outgoing dashboard's: they go, and a read
    /// still out for them commits nothing (issue 2094).
    private func retireCronJobsForDashboardSwitch() {
        cronJobsGeneration += 1
        cronJobs = []
        cronJobsRead = nil
        cronJobsLoading = false
    }

    func loadCronRuns(for job: CronJob) async {
        var gateway: (@MainActor () async throws -> [CronRun]?)?
        if let client {
            gateway = { [weak self] in
                let runs = try await client.cronRuns()
                // A reconnect's new client answers for itself.
                return self?.client === client ? runs : nil
            }
        }
        await loadCronRuns(for: job, dashboard: dashboardTicketBridge, gateway: gateway)
    }

    /// A job's Run history. The dashboard's per-job route is the answer, an
    /// empty one too (a job that hasn't run yet). The gateway's `cron.runs`
    /// lists every job's runs, so it is read only without the dashboard, and
    /// only the runs it can tell are this job's are kept (#1707). The list
    /// belongs to one job: opening another clears it until its answer lands
    /// (`cronRunsLoaded`) or the read fails (`cronRunsFailure`), and only the
    /// newest read's answer is kept.
    func loadCronRuns(
        for job: CronJob,
        dashboard: (any DashboardJSONRequester)?,
        gateway: (@MainActor () async throws -> [CronRun]?)?
    ) async {
        let profile = activeProfile
        if cronRunsJobID != job.id {
            cronRuns = []
            cronRunsLoaded = false
            cronRunsFailure = nil
            cronRunsJobID = job.id
        }
        // A retry shows the spinner again, not the last read's failure.
        cronRunsFailure = nil
        cronRunsLoad += 1
        let load = cronRunsLoad
        let inProfile: (CronRun) -> Bool = { run in
            guard let owner = run.profile, !owner.isEmpty else { return true }
            return Self.profilesMatch(owner, profile)
        }
        do {
            if let dashboard {
                let path = cronDashboardPath("/api/cron/jobs/\(job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id)/runs?limit=20", profile: profile)
                let result = try await dashboard.requestJSON(
                    path: path,
                    method: "GET",
                    body: nil,
                    timeoutMilliseconds: 12_000,
                    maxResponseBytes: DataURLLimits.maxJSONResponseBytes
                )
                guard profile == activeProfile, cronRunsLoad == load else { return }
                answerCronRuns(cronRunValues(from: result).compactMap(decodeCronRun).filter(inProfile))
            } else if let gateway, let runs = try await gateway() {
                guard profile == activeProfile, cronRunsLoad == load else { return }
                answerCronRuns(runs.filter { $0.isRun(ofJob: job.id) && inProfile($0) })
            } else {
                // Nothing to ask (offline, or the client was replaced mid-read).
                guard profile == activeProfile, cronRunsLoad == load, !cronRunsLoaded else { return }
                cronRunsFailure = AppLocalization.string("Connect to Hermes to check.")
            }
        } catch {
            // A sheet closed mid-read: no failure, the next open reads again.
            if error is CancellationError || Task.isCancelled { return }
            guard profile == activeProfile, cronRunsLoad == load else { return }
            let message = AppLocalization.string("Could not load scheduled-job runs: \(UserFacingError.message(for: error))")
            if cronRunsLoaded {
                errorMessage = message
            } else {
                cronRunsFailure = message
            }
        }
    }

    private func answerCronRuns(_ runs: [CronRun]) {
        cronRuns = runs
        cronRunsLoaded = true
        cronRunsFailure = nil
    }

    func performCronAction(_ action: CronJobAction, for job: CronJob) async -> Bool {
        guard cronJobActionID == nil else { return false }
        let profile = activeProfile
        cronJobActionID = job.id
        defer { cronJobActionID = nil }
        guard let dashboardTicketBridge else { return false }

        do {
            let encodedID = job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id
            let result = try await dashboardTicketBridge.requestJSON(
                path: cronDashboardPath("/api/cron/jobs/\(encodedID)/\(action.rawValue)", profile: profile),
                method: "POST",
                body: ["profile": profile]
            )
            guard profile == activeProfile else { return false }
            if let updated = decodeCronJob(result), let index = cronJobs.firstIndex(where: { $0.id == job.id }) {
                cronJobs[index] = updated
            } else {
                await loadCronJobs()
            }
            return true
        } catch {
            // One whole sentence per action: a verb dropped into a shared
            // sentence can't be inflected in most languages.
            let reason = UserFacingError.message(for: error)
            switch action {
            case .pause: errorMessage = AppLocalization.string("Could not pause scheduled job: \(reason)")
            case .resume: errorMessage = AppLocalization.string("Could not resume scheduled job: \(reason)")
            case .trigger: errorMessage = AppLocalization.string("Could not run scheduled job: \(reason)")
            }
            return false
        }
    }

    /// Removes the job from Hermes. Chats from its past runs stay; Hermes
    /// keeps those sessions.
    func deleteCronJob(_ job: CronJob) async -> Bool {
        guard cronJobActionID == nil else { return false }
        let profile = activeProfile
        cronJobActionID = job.id
        defer { cronJobActionID = nil }

        do {
            guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            let encodedID = job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id
            _ = try await dashboardTicketBridge.requestJSON(
                path: cronDashboardPath("/api/cron/jobs/\(encodedID)", profile: profile),
                method: "DELETE"
            )
            // Gone on Hermes either way; only the list on screen needs the
            // same profile.
            cronJobsGeneration += 1
            if profile == activeProfile {
                cronJobs.removeAll { $0.id == job.id }
                cronMutedJobIDs.remove(job.id)
                cronActingJobIDs.remove(job.id)
            }
            return true
        } catch {
            errorMessage = AppLocalization.string("Could not delete scheduled job: \(UserFacingError.message(for: error))")
            return false
        }
    }

    /// Creates a job on Hermes (#819) and adds it to the list. Throws
    /// Hermes' reason (a schedule it can't read, a missing prompt) for the
    /// editor to show.
    func createCronJob(_ body: [String: Any]) async throws -> CronJob? {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = activeProfile
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/jobs", profile: profile),
            method: "POST",
            body: body
        )
        return await addCreatedCronJob(result, profile: profile)
    }

    /// Changes only the fields in `updates`; the rest of the job stays.
    func updateCronJob(_ job: CronJob, updates: [String: Any]) async throws {
        guard !updates.isEmpty else { return }
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = activeProfile
        let encodedID = job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/jobs/\(encodedID)", profile: profile),
            method: "PUT",
            body: ["updates": updates]
        )
        guard profile == activeProfile else { return }
        if let updated = decodeCronJob(result), let index = cronJobs.firstIndex(where: { $0.id == job.id }) {
            // A list read already on its way predates the change.
            cronJobsGeneration += 1
            cronJobs[index] = updated
        } else {
            await loadCronJobs()
        }
    }

    /// Where a job can deliver: `local` and each connected platform.
    func loadCronDeliveryTargets() async throws -> [CronDeliveryTarget] {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/delivery-targets", profile: activeProfile)
        )
        return (result["targets"] as? [Any] ?? []).compactMap(CronDeliveryTarget.init)
    }

    /// Hermes' blueprint catalog: built-ins and the profile's plugins'.
    func loadCronBlueprints() async throws -> [CronBlueprint] {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/blueprints", profile: activeProfile)
        )
        return (result["blueprints"] as? [Any] ?? []).compactMap(CronBlueprint.init)
    }

    /// Fills a blueprint's blanks and creates its job on Hermes.
    func instantiateCronBlueprint(_ blueprint: CronBlueprint, values: [String: String]) async throws -> CronJob? {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = activeProfile
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/blueprints/instantiate", profile: profile),
            method: "POST",
            body: ["blueprint": blueprint.key, "values": CronBlueprint.instantiateValues(values, fields: blueprint.fields)]
        )
        return await addCreatedCronJob(result, profile: profile)
    }

    private func addCreatedCronJob(_ result: [String: Any], profile: String) async -> CronJob? {
        let created = decodeCronJob(result["job"] ?? result)
        guard profile == activeProfile else { return created }
        if let created {
            cronJobsGeneration += 1
            cronJobs.removeAll { $0.id == created.id }
            cronJobs.append(created)
            cronJobs.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } else {
            await loadCronJobs()
        }
        return created
    }

    private func cronDashboardPath(_ path: String, profile: String) -> String {
        DashboardPath.withExplicitProfile(path, profile: profile)
    }

    private func decodeCronJob(_ value: Any) -> CronJob? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(CronJob.self, from: data)
    }

    private func decodeCronRun(_ value: Any) -> CronRun? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        if let decoded = try? JSONDecoder().decode(CronRun.self, from: data) { return decoded }
        guard let rawObject = value as? [String: Any] else { return nil }
        let object = rawObject["session"] as? [String: Any] ?? rawObject
        guard
              let id = stringValue(object["id"] ?? object["session_id"] ?? object["run_id"]), !id.isEmpty else { return nil }
        return CronRun(
            id: id,
            lastActive: Self.integerValue(object["last_active"] ?? object["lastActive"]),
            model: stringValue(object["model"]),
            preview: stringValue(object["preview"] ?? object["summary"]),
            profile: stringValue(object["profile"]),
            startedAt: Self.integerValue(object["started_at"] ?? object["startedAt"]),
            title: stringValue(object["title"] ?? object["name"]),
            jobID: stringValue(object["job_id"] ?? object["cron_job_id"])
        )
    }

    private func cronRunValues(from result: [String: Any]) -> [Any] {
        if let values = result["runs"] as? [Any] ?? result["items"] as? [Any] ?? result["_array"] as? [Any] ?? result["data"] as? [Any] {
            return values
        }
        if let nested = result["data"] as? [String: Any] {
            return nested["runs"] as? [Any] ?? nested["items"] as? [Any] ?? []
        }
        if let nested = result["runs"] as? [String: Any] {
            return nested["items"] as? [Any] ?? nested["results"] as? [Any] ?? []
        }
        return []
    }

    /// A loosely typed JSON integer. Floats truncate toward zero (an epoch
    /// with a fraction), and a number no Int can hold is nil, the same as
    /// for strings, rather than NSNumber.intValue's wrapped garbage. A JSON
    /// boolean is no integer: JSONSerialization hands it back as an NSNumber
    /// that `as? Int` would read as 0 or 1.
    nonisolated static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, AnyCodable.isBoolean(number) { return nil }
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return Int(exactly: number.doubleValue.rounded(.towardZero)) }
        if let string = value as? String {
            return Int(string) ?? Double(string).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        }
        return nil
    }

    private func booleanValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    /// Counts display saves that landed, so a config read sent before one
    /// doesn't put the older choice back.
    private var displayPreferencesWriteRevision = 0
    /// The same for time-zone saves, which come back in that config read
    /// too but are counted apart, so a display save doesn't cost the zone.
    private var timeZoneWriteRevision = 0
    /// Display settings reads sent, and the newest whose answer was taken,
    /// so an older read landing after it (or failing after it) doesn't put
    /// its settings back.
    private var displayPreferencesReadsSent: UInt64 = 0
    private var displayPreferencesReadCommitted: UInt64 = 0

    /// The reads every connection makes, sent with its ticket rather than
    /// each after the step before it: the profile list, the chat list's
    /// newest page and the display settings. Each step takes its answer
    /// through `startupReads.read`, or reads again when something changed
    /// since. Only through a saved dashboard's bridge, whose own stores hold
    /// its session; never through the page.
    let startupReads = StartupReads()

    func sendStartupReads(profile: String, includingProfiles: Bool = true) {
        guard let bridge = dashboardTicketBridge,
              bridge.readsWithoutThePageFirst || bridge.usesNativeOAuth else { return }
        let chatList = profileSessionsPath(profile)
        startupReads.send(
            (includingProfiles ? ["/api/profiles"] : []) + [chatList, dashboardPath("/api/config", profile: profile)],
            through: bridge,
            fence: { path in self.startupReadFence(for: bridge, chatList: path == chatList) }
        )
    }

    /// What an early read must still match to be used: no write through the
    /// dashboard, chat list change or display save since it was sent.
    /// The chat list's own read also needs no listing committed since: one
    /// another load committed meanwhile is newer than the early answer.
    private func startupReadFence(for bridge: DashboardTicketBridge, chatList: Bool = false) -> StartupReads.Fence {
        StartupReads.Fence(
            writes: bridge.writesSent,
            catalog: sessionCatalogCache.mutationGeneration,
            display: displayPreferencesWriteRevision,
            listings: chatList ? sessionCatalogCache.commits : 0,
            writesOut: bridge.writesOut
        )
    }

    func loadProfileDisplayPreferences() async {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return }
        let dashboardTicketBridge = owner.bridge
        let revision = displayPreferencesWriteRevision
        let zoneRevision = timeZoneWriteRevision
        displayPreferencesReadsSent &+= 1
        let read = displayPreferencesReadsSent
        do {
            let config = try await startupReads.read(
                dashboardPath("/api/config", profile: profile),
                through: dashboardTicketBridge,
                fence: startupReadFence(for: dashboardTicketBridge)
            )
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return }
            // A read sent after this one that already landed is newer.
            guard read > displayPreferencesReadCommitted else { return }
            displayPreferencesReadCommitted = read
            let display = config["display"] as? [String: Any] ?? [:]
            // A time-zone or display save that landed while this read was
            // out is newer, each for its own setting.
            if zoneRevision == timeZoneWriteRevision {
                profileTimeZoneSetting = (profile, config[ProfileTimeZone.configKey] as? String ?? "")
            }
            guard revision == displayPreferencesWriteRevision else { return }
            let reasoning = ReasoningDisplayMode(display: display)
            displayPreferences = ProfileDisplayPreferences(
                showReasoning: reasoning == .show,
                thinkingOnRequest: reasoning != .off,
                showToolProgress: display["tool_progress"] as? String != "off",
                expandToolsByDefault: display["expand_tools"] as? Bool ?? false,
                showReviews: ProfileDisplayPreferences.showsReviews(display["memory_notifications"])
            )
        } catch {
            // A read cut off by a dashboard switch fails here; it must not
            // reset the next dashboard's preferences for a profile of the
            // same name.
            guard ownsDashboardRuntime(owner), profile == activeProfile,
                  read > displayPreferencesReadCommitted else { return }
            // Unread (offline, say): what this profile last said, not
            // Hermes' defaults, so thinking set to Off stays off.
            displayPreferences = storedDisplayPreferences(dashboardID: activeDashboardID, profile: profile)
                ?? ProfileDisplayPreferences()
            // A zone saved while the read was out is still the one on screen.
            if zoneRevision == timeZoneWriteRevision { profileTimeZoneSetting = nil }
        }
    }

    /// The active profile's `timezone` value, when Conduit has read it.
    var activeProfileTimeZoneSetting: String? {
        guard let setting = profileTimeZoneSetting, profilesMatch(setting.profile, activeProfile) else { return nil }
        return setting.value
    }

    func loadProfileSettings(keys: [String]) async -> [String: ProfileSettingValue] {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else {
            return keptProfileSettings(keys: keys) ?? keptDisplaySettings(keys: keys)
        }
        do {
            let config = try await readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return [:] }
            return profileSettings(in: config, keys: keys)
        } catch {
            // A read that fails after a dashboard or profile switch belongs to
            // the settings page that was left; the one on screen has no error.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return [:] }
            errorMessage = AppLocalization.string("Could not load profile settings: \(UserFacingError.message(for: error))")
            return keptProfileSettings(keys: keys) ?? keptDisplaySettings(keys: keys)
        }
    }

    /// The settings as Hermes answers now, or nil when it didn't: for a
    /// control that waits for Hermes rather than show a kept value as its
    /// answer (a provider's key order).
    func readProfileSettings(keys: [String]) async -> [String: ProfileSettingValue]? {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner(),
              let config = try? await readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner),
              ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
        return profileSettings(in: config, keys: keys)
    }

    /// What the settings pages open on before Hermes answers, and keep when
    /// it can't: the config last read, kept on the phone, with the display
    /// settings the chats follow meanwhile over it. Nil when no config is
    /// kept, so a page waits rather than show Hermes' defaults as its own.
    func keptProfileSettings(keys: [String]) -> [String: ProfileSettingValue]? {
        guard let config = keptAnswer(KeptRoute.config) else { return nil }
        return profileSettings(in: config, keys: keys)
            .merging(keptDisplaySettings(keys: keys)) { _, display in display }
    }

    private func profileSettings(in config: [String: Any], keys: [String]) -> [String: ProfileSettingValue] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, ProfileSettingValue)? in
            if key == ReasoningDisplayMode.settingKey {
                // Worked out from two config values (ReasoningDisplayMode).
                let display = config["display"] as? [String: Any] ?? [:]
                return (key, .text(ReasoningDisplayMode(display: display).rawValue))
            }
            return profileSettingValue(in: config, key: key).map { (key, $0) }
        })
    }

    /// Unread, the display rows show what the chats follow meanwhile: the
    /// settings last read, kept on the phone. Self-improvement updates
    /// keeps only whether they show, so it reads Never show or Hermes'
    /// default.
    private func keptDisplaySettings(keys: [String]) -> [String: ProfileSettingValue] {
        let kept = displayPreferences
        var values: [String: ProfileSettingValue] = [
            ReasoningDisplayMode.settingKey: .text(kept.reasoningMode.rawValue),
            "display.tool_progress": .text(kept.showToolProgress ? "all" : "off"),
            "display.expand_tools": .bool(kept.expandToolsByDefault),
        ]
        if !kept.showReviews { values["display.memory_notifications"] = .text("off") }
        return values.filter { keys.contains($0.key) }
    }

    func loadProfileConfigOptions() async -> ProfileConfigOptions {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return keptProfileConfigOptions() ?? ProfileConfigOptions() }
        do {
            async let configRequest = readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            async let pluginsRequest = readKeepingAnswer(KeptRoute.pluginsHub, profile: profile, owner: owner)
            let (config, plugins) = try await (configRequest, pluginsRequest)
            guard profile == activeProfile else { return ProfileConfigOptions() }
            return Self.profileConfigOptions(config: config, plugins: plugins)
        } catch {
            // Options are supplementary; retain safe built-ins when an older
            // dashboard does not expose its plugin hub.
            return keptProfileConfigOptions() ?? ProfileConfigOptions()
        }
    }

    /// The choices last read, from the answers kept on the phone, or nil
    /// when they aren't kept.
    func keptProfileConfigOptions() -> ProfileConfigOptions? {
        guard let config = keptAnswer(KeptRoute.config), let plugins = keptAnswer(KeptRoute.pluginsHub) else { return nil }
        return Self.profileConfigOptions(config: config, plugins: plugins)
    }

    static func profileConfigOptions(config: [String: Any], plugins: [String: Any]) -> ProfileConfigOptions {
        var result = ProfileConfigOptions()
        if let personalities = ((config["agent"] as? [String: Any])?["personalities"] as? [String: Any])?.keys {
            result.personalities = personalities.sorted()
        }
        let providers = plugins["providers"] as? [String: Any] ?? [:]
        let memoryOptions = providers["memory_options"] as? [[String: Any]] ?? []
        result.memoryProviders = memoryOptions.compactMap { option in
            option["status"] as? String == "ready" ? option["name"] as? String : nil
        }.sorted()
        let contextOptions = providers["context_options"] as? [[String: Any]] ?? []
        result.contextEngines = Array(Set(result.contextEngines + contextOptions.compactMap { $0["name"] as? String })).sorted()
        return result
    }

    func loadProfileModelDefaults() async -> ProfileModelDefaults? {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return nil }
        do {
            async let optionsRequest = readKeepingAnswer(KeptRoute.modelOptions, profile: profile, owner: owner)
            async let infoRequest = readKeepingAnswer(KeptRoute.modelInfo, profile: profile, owner: owner)
            async let configRequest = readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            let (options, info, config) = try await (optionsRequest, infoRequest, configRequest)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            return Self.profileModelDefaults(options: options, info: info, config: config)
        } catch {
            // Same fence as the success path: a failure from the dashboard or
            // profile switched away from is not the on-screen page's error.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            errorMessage = AppLocalization.string("Could not load model defaults: \(UserFacingError.message(for: error))")
            return nil
        }
    }

    /// The Model page's catalog and defaults as last read, from the answers
    /// kept on the phone, or nil when they aren't all kept.
    func keptProfileModelDefaults() -> ProfileModelDefaults? {
        guard let options = keptAnswer(KeptRoute.modelOptions),
              let info = keptAnswer(KeptRoute.modelInfo),
              let config = keptAnswer(KeptRoute.config) else { return nil }
        return Self.profileModelDefaults(options: options, info: info, config: config)
    }

    static func profileModelDefaults(
        options: [String: Any],
        info: [String: Any],
        config: [String: Any]
    ) -> ProfileModelDefaults {
        let optionsObject = AnyCodable.from(options).objectValue ?? [:]
        let providers = modelProviders(in: options)
        // Profile config is the persisted default. Hermes stores it under
        // `model.default` and `model.provider`, but `/api/config` flattens
        // `model` to the bare model string and drops the provider, so the
        // provider comes from `/api/model/info` (read from the same config)
        // or the options payload's current selection.
        let modelConfig = config["model"] as? [String: Any] ?? [:]
        let model = [modelConfig["default"] as? String, config["model"] as? String, info["model"] as? String, optionsObject["model"]?.stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? ""
        let provider = [modelConfig["provider"] as? String, info["provider"] as? String, optionsObject["provider"]?.stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? ""
        let reasoning = profileReasoningEffort(in: config)
        return ProfileModelDefaults(providers: providers, model: model, provider: provider, reasoning: reasoning)
    }

    func setProfileMainModel(provider: String, model: String, reasoning: String) async -> Bool {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return false }
        let dashboardTicketBridge = owner.bridge
        do {
            // Hermes writes the profile config for it: in turn with every
            // other config save.
            let result = try await ProfileConfigWriteQueue.runThrowing { [self] in
                try await dashboardTicketBridge.requestJSON(
                    path: dashboardPath("/api/model/set", profile: profile),
                    method: "POST",
                    body: ["model": model, "provider": provider, "scope": "main", "profile": profile]
                )
            }
            // Another dashboard took over: stop. A profile switch on this
            // dashboard doesn't stop the save: the model change already
            // reached Hermes, and the captured profile's config must follow
            // it; only what's shown on screen depends on the profile.
            guard ownsDashboardRuntime(owner) else { return false }
            if result["confirm_required"] as? Bool == true {
                if profile == activeProfile {
                    errorMessage = result["confirm_message"] as? String ?? AppLocalization.string("Hermes requires confirmation before using this model.")
                }
                return false
            }
            try await updateProfileConfig(profile: profile) { config in
                var modelConfig = config["model"] as? [String: Any] ?? [:]
                modelConfig["default"] = model
                modelConfig["provider"] = provider
                config["model"] = modelConfig
                // Hermes reads the profile default from `agent.reasoning_effort`
                // (Desktop writes it there too). The PUT deep-merges, so an old
                // top-level `reasoning` stays on disk; loading reads the agent
                // key first, so it no longer wins.
                var agentConfig = config["agent"] as? [String: Any] ?? [:]
                agentConfig["reasoning_effort"] = reasoning
                config["agent"] = agentConfig
                config["reasoning"] = nil
            }
            // The kept config has the new model now; the catalog, which
            // marks the provider in use (a delegate inherits its models),
            // and the model's info follow it, so the Model page opens on
            // the save next time (#1533).
            Task { [weak self] in
                _ = try? await self?.readKeepingAnswer(KeptRoute.modelOptions, profile: profile, owner: owner)
                _ = try? await self?.readKeepingAnswer(KeptRoute.modelInfo, profile: profile, owner: owner)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            errorMessage = AppLocalization.string("Could not save model defaults: \(UserFacingError.message(for: error))")
            return false
        }
    }

    /// One GET, change and PUT of the whole profile config, run after any
    /// earlier one finishes (ProfileConfigWriteQueue, shared with the
    /// voice settings' own service). Settings pages save independently
    /// (the Model page has three savers), and two overlapping round trips
    /// would let the later PUT put back what the earlier one changed.
    private func updateProfileConfig(
        profile: String,
        _ change: @escaping @MainActor (inout [String: Any]) -> Void
    ) async throws {
        // Sent only to the dashboard it was made on: one queued behind a
        // write that outlives a switch must not reach the next dashboard's
        // profile of the same name.
        let owner = currentDashboardRuntimeOwner()
        try await ProfileConfigWriteQueue.runThrowing { @MainActor [weak self] in
            guard let self, let owner, self.ownsDashboardRuntime(owner) else { throw CancellationError() }
            let bridge = owner.bridge
            let removals = self.offlineChatCache.removals
            var config = try await bridge.requestJSON(path: self.dashboardPath(KeptRoute.config, profile: profile))
            guard self.ownsDashboardRuntime(owner) else { throw CancellationError() }
            change(&config)
            _ = try await bridge.requestJSON(
                path: self.dashboardPath(KeptRoute.config, profile: profile),
                method: "PUT",
                body: ["config": config, "profile": profile]
            )
            // What the settings pages open on next is what was just saved.
            self.keepWrittenAnswer(config, for: KeptRoute.config, profile: profile, owner: owner, removals: removals)
        }
    }

    /// The profile's default reasoning effort. Hermes keeps it at
    /// `agent.reasoning_effort`; Conduit used to save a top-level
    /// `reasoning`, which is read only when the real key is unset. A
    /// hand-written `false`/`off` means no reasoning, as on Desktop.
    nonisolated static func profileReasoningEffort(in config: [String: Any]) -> String {
        let agentValue = (config["agent"] as? [String: Any])?["reasoning_effort"]
        for value in [agentValue, config["reasoning"], config["reasoning_effort"]] {
            if let flag = value as? NSNumber, AnyCodable.isBoolean(flag), !flag.boolValue { return "none" }
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { continue }
            return text == "false" || text == "off" || text == "disabled" ? "none" : text
        }
        return "medium"
    }

    /// `GET /api/config/schema` for the active profile. Empty when the
    /// dashboard can't serve it, which settings pages read as "show every
    /// setting".
    func loadProfileConfigSchema() async -> ProfileConfigSchema {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return keptProfileConfigSchema() ?? ProfileConfigSchema() }
        do {
            let json = try await readKeepingAnswer(KeptRoute.configSchema, profile: profile, owner: owner)
            guard profile == activeProfile else { return ProfileConfigSchema() }
            return ProfileConfigSchema(json: json)
        } catch {
            return keptProfileConfigSchema() ?? ProfileConfigSchema()
        }
    }

    /// The schema last read, kept on the phone, or nil when none is.
    func keptProfileConfigSchema() -> ProfileConfigSchema? {
        keptAnswer(KeptRoute.configSchema).map(ProfileConfigSchema.init(json:))
    }

    /// The profile's `fallback_providers`, or nil when the config couldn't load.
    func loadProfileFallbackModels() async -> [ProfileFallbackModel]? {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return nil }
        do {
            let config = try await readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            return ProfileFallbackModel.list(from: config["fallback_providers"])
        } catch {
            // A failure from the dashboard or profile switched away from is
            // not the on-screen page's error.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            errorMessage = AppLocalization.string("Could not load profile settings: \(UserFacingError.message(for: error))")
            return nil
        }
    }

    /// The fallbacks last read, from the config kept on the phone, or nil
    /// when none is kept.
    func keptProfileFallbackModels() -> [ProfileFallbackModel]? {
        keptAnswer(KeptRoute.config).map { ProfileFallbackModel.list(from: $0["fallback_providers"]) }
    }

    /// Saves the complete entries in order. `PUT /api/config` deep-merges
    /// objects but replaces lists, so the whole list goes up each time.
    func setProfileFallbackModels(_ entries: [ProfileFallbackModel]) async -> Bool {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return false }
        let list = entries.filter(\.isComplete).map(\.jsonObject)
        do {
            try await updateProfileConfig(profile: profile) { config in
                config["fallback_providers"] = list
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            // As for the sibling savers: a save that fails after a dashboard
            // or profile switch has nothing to report to the page on screen.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            errorMessage = AppLocalization.string("Could not save fallback models: \(UserFacingError.message(for: error))")
            return false
        }
    }

    /// The subagents' own fallbacks (`delegation.fallback_providers`), or
    /// nil when the config couldn't load. Unset (null) means a subagent on
    /// the chat's model takes the chat's fallbacks.
    func loadDelegateFallbackModels() async -> ProfileFallbackChain? {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return nil }
        do {
            let config = try await readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            return ProfileFallbackChain(delegationIn: config)
        } catch {
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            errorMessage = AppLocalization.string("Could not load profile settings: \(UserFacingError.message(for: error))")
            return nil
        }
    }

    func keptDelegateFallbackModels() -> ProfileFallbackChain? {
        keptAnswer(KeptRoute.config).map(ProfileFallbackChain.init(delegationIn:))
    }

    /// Saves the subagents' fallbacks: null for the chat's, else the
    /// complete entries in order (none listed turns fallback off).
    func setDelegateFallbackModels(_ chain: ProfileFallbackChain) async -> Bool {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return false }
        let value: Any = chain.inherits ? NSNull() : chain.entries.filter(\.isComplete).map(\.jsonObject)
        do {
            try await updateProfileConfig(profile: profile) { config in
                var delegation = config["delegation"] as? [String: Any] ?? [:]
                delegation["fallback_providers"] = value
                config["delegation"] = delegation
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            errorMessage = AppLocalization.string("Could not save fallback models: \(UserFacingError.message(for: error))")
            return false
        }
    }

    func setProfileSetting(_ key: String, value: ProfileSettingValue) async -> Bool {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return false }
        let dashboardTicketBridge = owner.bridge
        do {
            if profile == "default" && (key == "context.engine" || key == "memory.provider") {
                let raw = value.textValue ?? ""
                let body = key == "context.engine" ? ["context_engine": raw] : ["memory_provider": raw]
                let removals = offlineChatCache.removals
                // Hermes writes the profile config for it: in turn with
                // every other config save.
                try await ProfileConfigWriteQueue.runThrowing {
                    _ = try await dashboardTicketBridge.requestJSON(path: "/api/dashboard/plugin-providers", method: "PUT", body: body)
                }
                // The page opens on it next time, as on a config it saved,
                // a switch to another profile or dashboard meanwhile included.
                if var config = keptAnswer(KeptRoute.config, profile: profile, on: owner) {
                    setProfileSettingValue(value, in: &config, key: key)
                    keepWrittenAnswer(config, for: KeptRoute.config, profile: profile, owner: owner, removals: removals)
                } else {
                    noteKeptAnswerWrite(for: KeptRoute.config, profile: profile, owner: owner)
                }
                return ownsDashboardRuntime(owner) && profile == activeProfile
            }
            let reasoning = key == ReasoningDisplayMode.settingKey ? value.textValue.flatMap(ReasoningDisplayMode.init(rawValue:)) : nil
            if key == ReasoningDisplayMode.settingKey, reasoning == nil { return false }
            try await updateProfileConfig(profile: profile) { [weak self] config in
                if let reasoning {
                    var display = config["display"] as? [String: Any] ?? [:]
                    reasoning.write(into: &display)
                    config["display"] = display
                } else {
                    self?.setProfileSettingValue(value, in: &config, key: key)
                }
            }
            if reasoning != nil || key.hasPrefix("display.") { displayPreferencesWriteRevision &+= 1 }
            // The write landed on its own profile; what's mirrored on screen
            // must still be that dashboard's and profile's.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return true }
            // Only the zone on screen voids a settings read's zone: one saved
            // for a profile switched away from leaves the new one's read alone.
            if key == ProfileTimeZone.configKey { timeZoneWriteRevision &+= 1 }
            if key == ProfileTimeZone.configKey, let zone = value.textValue {
                profileTimeZoneSetting = (profile, zone)
            }
            if let reasoning {
                // Thinking in the chat on screen follows at once.
                displayPreferences.showReasoning = reasoning == .show
                displayPreferences.thinkingOnRequest = reasoning != .off
            }
            if key == "display.memory_notifications" {
                // Rows already in the chat hide or come back with it.
                displayPreferences.showReviews = ProfileDisplayPreferences.showsReviews(value.textValue)
            }
            if key == "display.tool_progress" {
                // The kept choice follows the save, so the offline copy does too.
                displayPreferences.showToolProgress = value.textValue != "off"
            }
            if key == "display.expand_tools", let expand = value.boolValue {
                displayPreferences.expandToolsByDefault = expand
            }
            if key == "approvals.mode", let mode = value.textValue?.lowercased() {
                // Mirror the saved profile mode immediately and re-resolve the
                // effective indicator state through the same precedence
                // applyRuntime uses, so the floor and the picker lock take
                // effect without waiting for the next session snapshot. The
                // last server-reported session value carries through when
                // known (runtime.yolo may be the floor-forced value, not the
                // session flag); only the floor/override precedence re-runs.
                runtime.approvalsMode = mode
                let requestedSessionID = activeSessionId
                let resolvedCanonicalSessionID = canonicalSessionID(for: requestedSessionID)
                applyEffectiveYolo(
                    sessionIDsForOverride: [resolvedCanonicalSessionID, requestedSessionID]
                        .compactMap { $0 },
                    snapshotYolo: lastReportedSessionYolo ?? runtime.yolo,
                    snapshotReportedApprovalsMode: nil
                )
            }
            return true
        } catch is CancellationError {
            // A save queued on a dashboard since switched away from: nothing
            // was sent, and the dashboard on screen has nothing to report.
            return false
        } catch {
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            errorMessage = AppLocalization.string("Could not save \(key): \(UserFacingError.message(for: error))")
            return false
        }
    }

    func profileSettingValue(in config: [String: Any], key: String) -> ProfileSettingValue? {
        let components = key.split(separator: ".").map(String.init)
        var current: Any = config
        for component in components {
            guard let object = current as? [String: Any], let next = object[component] else { return nil }
            current = next
        }
        // JSON numbers and booleans are both NSNumber, and `as? Bool` also
        // accepts a plain 0 or 1, so a count of 1 would read as a switch.
        if let value = current as? NSNumber {
            return AnyCodable.isBoolean(value) ? .bool(value.boolValue) : .number(value.doubleValue)
        }
        if let value = current as? String { return .text(value) }
        // A stray number in a list is shown as text, so saving the list
        // doesn't drop it.
        if let value = current as? [Any] { return .list(value.map { $0 as? String ?? "\($0)" }) }
        return nil
    }

    private func setProfileSettingValue(_ value: ProfileSettingValue, in config: inout [String: Any], key: String) {
        let components = key.split(separator: ".").map(String.init)
        guard let leaf = components.last else { return }
        let rawValue: Any
        switch value {
        case .bool(let value): rawValue = value
        case .text(let value): rawValue = value
        case .number(let value): rawValue = value
        case .list(let value): rawValue = value
        }
        setNestedValue(rawValue, in: &config, path: Array(components.dropLast()), leaf: leaf)
    }

    private func setNestedValue(_ value: Any, in object: inout [String: Any], path: [String], leaf: String) {
        guard let next = path.first else {
            object[leaf] = value
            return
        }
        var child = object[next] as? [String: Any] ?? [:]
        setNestedValue(value, in: &child, path: Array(path.dropFirst()), leaf: leaf)
        object[next] = child
    }

    func setDisplayPreference(_ key: DisplayPreferenceKey, enabled: Bool) async -> Bool {
        let profile = activeProfile
        let previous = displayPreferences
        applyDisplayPreference(key, enabled: enabled)
        guard let owner = currentDashboardRuntimeOwner() else {
            displayPreferences = previous
            return false
        }
        // A read still out (a switch's, in the background) predates this.
        displayPreferencesWriteRevision &+= 1

        do {
            try await updateProfileConfig(profile: profile) { config in
                var display = config["display"] as? [String: Any] ?? [:]
                switch key {
                case .toolProgress: display["tool_progress"] = enabled ? "on" : "off"
                case .expandTools: display["expand_tools"] = enabled
                }
                config["display"] = display
            }
            displayPreferencesWriteRevision &+= 1
            return true
        } catch {
            // After a dashboard switch the preferences on screen are the next
            // dashboard's (even for a profile of the same name): nothing to
            // restore over them and nothing to report.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            displayPreferences = previous
            errorMessage = AppLocalization.string("Could not save display preference: \(UserFacingError.message(for: error))")
            return false
        }
    }

    private func applyDisplayPreference(_ key: DisplayPreferenceKey, enabled: Bool) {
        switch key {
        case .toolProgress: displayPreferences.showToolProgress = enabled
        case .expandTools: displayPreferences.expandToolsByDefault = enabled
        }
    }

    func dashboardPath(_ path: String, profile: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    /// The reads whose answers the settings pages keep (#1533): dashboard
    /// routes, and gateway calls kept beside them. Usage's periods
    /// (UsageReport.route), Pulse's routes (PulseClient.keptRoute), Voice
    /// settings' (HermesVoiceConfigurationService.KeptRead) and the
    /// Capabilities tabs' (CapabilitiesStore.KeptRoute) are kept under
    /// their own.
    enum KeptRoute {
        static let config = "/api/config"
        static let configSchema = "/api/config/schema"
        static let modelOptions = "/api/model/options?explicit_only=true"
        static let modelInfo = "/api/model/info"
        /// Hermes' auxiliary model slots, for Voice settings' voice reply model.
        static let modelAuxiliary = "/api/model/auxiliary"
        static let pluginsHub = "/api/dashboard/plugins/hub"
        /// Capabilities' installed skills and toolsets.
        static let skills = "/api/skills"
        static let toolsets = "/api/tools/toolsets"
        static let delegationStatus = "rpc:delegation.status"
        /// Settings > Usage's quota: the gateway's `model.options`, whose
        /// models the Voice and Pulse model pickers list too.
        static let providerQuotas = "rpc:model.options"
        /// A live voice mode's status line on Voice settings, by the mode's
        /// name: not a read's answer but what its check said.
        static let liveVoiceStatus = "conduit:live-voice-status/"
        /// The Bots list's bots and Desktop's groups, as Conduit read them
        /// (`KeptBotRoster`): `profiles.list` lists the whole Hermes, so
        /// it's kept once per dashboard.
        static let botRoster = "rpc:profiles.list"
        /// The Bots list's hosted rooms and their pictures
        /// (`KeptGroupRooms`), once per dashboard too.
        static let groupRooms = "rpc:groups.list"
        /// The bot editor's details of a profile (`BotProfileDetails`: its
        /// description, SOUL, model, skills, tools and MCP servers, as
        /// `profiles.describe` gave them), kept in that profile's answers:
        /// Edit Bot's bot, or New Bot's Start From profile.
        static let botDetails = "rpc:profiles.describe"
        /// Edit Bot's MCP catalog and its servers' sign-in states
        /// (`BotMcpSetupSnapshot`, with `mcp.servers.list`), in the bot's.
        static let botMcpSetup = "rpc:mcp.catalog"
        /// The scope of an answer about all of a Hermes' profiles at once
        /// (delegation's pause), kept once per dashboard: no profile is
        /// named with nothing.
        static let everyProfile = ""
    }

    /// A read whose answer is kept for the screen that shows it, so that
    /// screen opens on it next time (#1533): per dashboard, profile and
    /// route, in the saved chats' store, which wipes it with them.
    func readKeepingAnswer(_ route: String, profile: String, owner: DashboardRuntimeOwner) async throws -> [String: Any] {
        try await keepingAnswer(profile: profile, owner: owner, keptAs: { _ in route }) {
            try await owner.bridge.requestJSON(path: dashboardPath(route, profile: profile))
        }
    }

    /// The toolsets, read and kept as `readKeepingAnswer` does unless
    /// Hermes lists none: a Hermes still loading its plugins answers an
    /// empty list, which the chat's tool catalog refuses too
    /// (adoptToolCatalog), and the Tools tab would open on nothing.
    private func readKeepingToolsets(profile: String, owner: DashboardRuntimeOwner) async throws -> [String: Any] {
        try await keepingAnswer(
            profile: profile,
            owner: owner,
            keptAs: { ($0["_array"] as? [Any])?.isEmpty == false ? KeptRoute.toolsets : nil }
        ) {
            try await owner.bridge.requestJSON(path: dashboardPath(KeptRoute.toolsets, profile: profile))
        }
    }

    /// Runs `read` and keeps its answer as `readKeepingAnswer` does, under
    /// the route `keptAs` names for it (nil: not kept): for an answer read
    /// another way (a gateway call), or a step that answers with a screen's
    /// state (Pulse's), which is then what the screen opens on next.
    /// `writes` for a step that changes what it answers with (a save, a
    /// forget): it's as new as when it lands, so the answer to a read asked
    /// while it was out never goes back over it, and it's kept for the
    /// dashboard it was made on, another one open by then or not.
    func keepingAnswer(
        profile: String,
        owner: DashboardRuntimeOwner,
        keptAs route: ([String: Any]) -> String?,
        writes: Bool = false,
        turnOnly: () -> Bool = { false },
        _ read: () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        let removals = offlineChatCache.removals
        let asked = nextKeptAnswerTurn()
        let answer = try await read()
        let turn = writes ? nextKeptAnswerTurn() : asked
        if let route = route(answer) {
            keepAnswer(answer, for: route, profile: profile, owner: owner, removals: removals, turn: turn, writes: writes,
                       turnOnly: turnOnly())
        }
        return answer
    }

    /// Runs `read` and keeps what it decoded, as Conduit's own JSON, the
    /// way `keepingAnswer` keeps an answer: for a list Conduit reads through
    /// its decoders (the Bots list's), whose answer can't be kept as Hermes
    /// gave it. Without an owner it only reads.
    func keepingRead<Kept: Encodable>(
        as route: String,
        profile: String,
        owner: DashboardRuntimeOwner?,
        keeps: (Kept) -> Bool = { _ in true },
        unchanged: (Kept) -> Bool = { _ in false },
        _ read: () async throws -> Kept
    ) async throws -> Kept {
        guard let owner else { return try await read() }
        var kept: Kept?
        var same = false
        _ = try await keepingAnswer(profile: profile, owner: owner, keptAs: { $0.isEmpty ? nil : route },
                                    turnOnly: { same }) {
            let value = try await read()
            kept = value
            // A read only partly Hermes' answer (`keeps` says) keeps nothing.
            guard keeps(value) else { return [:] }
            // The same as what's kept: nothing is encoded or written, but
            // its turn still counts, so an older read landing after it
            // can't put an earlier answer back (issue 2152).
            if unchanged(value) {
                same = true
                return ["unchanged": true]
            }
            return Self.keptJSON(value) ?? [:]
        }
        guard let kept else { throw CancellationError() }
        return kept
    }

    /// What `keepingRead` kept for the route on the open dashboard, or nil.
    func keptRead<Kept: Decodable>(_ type: Kept.Type, _ route: String, profile: String) -> Kept? {
        keptAnswer(route, profile: profile).flatMap { Self.decodeKept(type, from: $0) }
    }

    /// Changes what `keepingRead` kept for the route on the owner's
    /// dashboard, the one open or not, as Hermes took a write there, and
    /// keeps it over the answer to any read asked before it (#1533). With
    /// nothing kept to change, the write counts all the same.
    func keepWrittenChange<Kept: Codable>(
        _ type: Kept.Type,
        _ route: String,
        profile: String,
        on owner: DashboardRuntimeOwner?,
        _ change: (inout Kept) -> Void
    ) {
        guard let owner else { return }
        guard var kept = keptAnswer(route, profile: profile, on: owner).flatMap({ Self.decodeKept(type, from: $0) }) else {
            noteKeptAnswerWrite(for: route, profile: profile, owner: owner)
            return
        }
        change(&kept)
        guard let answer = Self.keptJSON(kept) else { return }
        keepWrittenAnswer(answer, for: route, profile: profile, owner: owner, removals: offlineChatCache.removals)
    }

    private static func keptJSON<Kept: Encodable>(_ value: Kept) -> [String: Any]? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func decodeKept<Kept: Decodable>(_ type: Kept.Type, from answer: [String: Any]) -> Kept? {
        guard let data = try? JSONSerialization.data(withJSONObject: answer) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The number the answer kept for the route on the open dashboard
    /// was kept under, so a screen decodes it once per answer.
    func keptAnswerTurn(_ route: String, profile: String) -> Int {
        guard let dashboardID = activeDashboardID else { return 0 }
        return keptAnswerTurnsKept[Self.keptAnswerScope(dashboardID, profile, route)] ?? 0
    }

    /// Keeps what the phone just wrote, over the answer to any read asked
    /// before it, for the dashboard it wrote to.
    func keepWrittenAnswer(
        _ answer: [String: Any],
        for route: String,
        profile: String,
        owner: DashboardRuntimeOwner,
        removals: Int
    ) {
        keepAnswer(answer, for: route, profile: profile, owner: owner, removals: removals, turn: nextKeptAnswerTurn(), writes: true)
    }

    /// Numbers the reads whose answers are kept as they're asked, and the
    /// writes as they land: an answer is kept only over an older one, so a
    /// read asked before a save, a forget or another read never puts its
    /// answer back over theirs (#1533).
    private var keptAnswerTurns = 0
    /// The number of the answer kept, per dashboard, profile and route.
    private var keptAnswerTurnsKept: [String: Int] = [:]

    private func nextKeptAnswerTurn() -> Int {
        keptAnswerTurns += 1
        return keptAnswerTurns
    }

    /// A write that leaves nothing to keep counts all the same: the answer
    /// to a read asked before it isn't kept after it.
    func noteKeptAnswerWrite(for route: String, profile: String, owner: DashboardRuntimeOwner) {
        guard let dashboardID = owner.dashboardID else { return }
        keptAnswerTurnsKept[Self.keptAnswerScope(dashboardID, profile, route)] = nextKeptAnswerTurn()
    }

    private static func keptAnswerScope(_ dashboardID: UUID, _ profile: String, _ route: String) -> String {
        [dashboardID.uuidString, profile, route].joined(separator: "\u{1F}")
    }

    /// Kept with nothing newer kept since, and nothing wiped since it was
    /// asked (a sign-out, Delete Saved Chats, a deleted bot): a read's
    /// answer only while its dashboard is still the one open, and a
    /// write's for the dashboard it was made on, as that's what its Hermes
    /// holds now. A write counts from when it landed, kept or not.
    private func keepAnswer(
        _ answer: [String: Any],
        for route: String,
        profile: String,
        owner: DashboardRuntimeOwner,
        removals: Int,
        turn: Int,
        writes: Bool,
        turnOnly: Bool = false
    ) {
        guard let dashboardID = owner.dashboardID else { return }
        let scope = Self.keptAnswerScope(dashboardID, profile, route)
        guard turn > keptAnswerTurnsKept[scope, default: 0] else { return }
        let keeps = offlineChatCache.removals == removals && (writes || ownsDashboardRuntime(owner))
        guard keeps || writes else { return }
        keptAnswerTurnsKept[scope] = turn
        // The same as what's kept (keepingRead's `unchanged`): the turn alone.
        guard keeps, !turnOnly else { return }
        // A schema's fields are keyed by config path, not by what they hold.
        let names: Set<String> = route == KeptRoute.configSchema ? ["fields"] : []
        let answer = route == KeptRoute.modelAuxiliary ? HelperModelSlot.keptAnswer(answer) : answer
        offlineChatCache.recordAnswer(answer, route: route, dashboardID: dashboardID, profile: profile, namesUnder: names)
    }

    /// The answer the active profile's screen last read for the route (or
    /// the given scope's, as `KeptRoute.everyProfile`), or nil when none is
    /// kept.
    func keptAnswer(_ route: String, profile: String? = nil) -> [String: Any]? {
        guard let dashboardID = activeDashboardID else { return nil }
        return offlineChatCache.keptAnswer(route, dashboardID: dashboardID, profile: profile ?? activeProfile)
    }

    /// The answer kept for the route on the owner's dashboard, the one open
    /// or not: what a write that lands there changes.
    func keptAnswer(_ route: String, profile: String, on owner: DashboardRuntimeOwner) -> [String: Any]? {
        owner.dashboardID.flatMap { offlineChatCache.keptAnswer(route, dashboardID: $0, profile: profile) }
    }

    /// Where Voice settings keep their answers for the profile, beside the
    /// other settings pages': on this dashboard, which they read only while
    /// it's the one open. Nil without a bridge.
    func voiceSettingsAnswers(profile: String) -> KeptAnswers? {
        guard let owner = currentDashboardRuntimeOwner() else { return nil }
        return KeptAnswers(
            kept: { [weak self] route in
                guard let self, self.ownsDashboardRuntime(owner) else { return nil }
                return self.keptAnswer(route, profile: profile)
            },
            keep: { [weak self] route, writes, read in
                guard let self else { return try await read() }
                return try await self.keepingAnswer(profile: profile, owner: owner, keptAs: { _ in route }, writes: writes, read)
            }
        )
    }

    /// Where a screen that reads through its own service (Capabilities'
    /// tabs, the Tasks board) keeps its answers for the profile (or the
    /// dashboard's own, as `KeptRoute.everyProfile`), beside the settings
    /// pages': on the dashboard open when they're asked for, offline too,
    /// whose kept answers a change that lands after a switch still changes.
    /// A read keeps its answer only with a bridge to read through.
    func screenAnswers(profile: String) -> KeptAnswers {
        let dashboardID = activeDashboardID
        let owner = currentDashboardRuntimeOwner()
        return KeptAnswers(
            kept: { [weak self] route in
                guard let self, let dashboardID else { return nil }
                return self.offlineChatCache.keptAnswer(route, dashboardID: dashboardID, profile: profile)
            },
            keep: { [weak self] route, writes, read in
                guard let self, let owner else { return try await read() }
                return try await self.keepingAnswer(profile: profile, owner: owner, keptAs: { _ in route }, writes: writes, read)
            },
            noteWrite: { [weak self] route in
                guard let self, let owner else { return }
                self.noteKeptAnswerWrite(for: route, profile: profile, owner: owner)
            }
        )
    }

    /// Hermes' value wins and is kept on the phone; a read that fails keeps
    /// the last value this profile had, else Hermes' own default
    /// (interrupt), so Settings never shows a mode Hermes doesn't use.
    func loadBusyInputMode(using client: HermesClient) async {
        let key = busyInputModeCacheKey
        // Shown while Hermes answers, and kept if it can't.
        restoreBusyInputMode()
        let revision = busyInputModeWriteRevision
        do {
            let mode = try await client.busyInputMode()
            // A switch away while this was out reads its own, and a mode
            // picked meanwhile is newer.
            guard self.client === client, revision == busyInputModeWriteRevision else { return }
            busyInputMode = mode
            defaults.set(mode.rawValue, forKey: key)
        } catch {}
    }

    /// Bumped by each busy mode picked, so a read that was already out
    /// doesn't put the old one back.
    private var busyInputModeWriteRevision = 0

    /// Another profile: the busy mode it last had here, until Hermes
    /// answers for it.
    private func restoreBusyInputMode() {
        busyInputMode = defaults.string(forKey: busyInputModeCacheKey).flatMap(BusyInputMode.init(rawValue:)) ?? .interrupt
    }

    /// The busy mode last read from or saved to Hermes, per server and profile.
    private var busyInputModeCacheKey: String {
        let server = defaults.string(forKey: Self.chatResumeServerIdentityKey) ?? ""
        return "\(Self.busyInputModeCachePrefix)\(server)|\(activeProfile)"
    }

    static let busyInputModeCachePrefix = "conduit.busyInputMode.v1."

    func setBusyInputMode(_ mode: BusyInputMode) async -> Bool {
        guard let client else { return false }
        let previous = busyInputMode
        // The profile that takes the write, captured before it.
        let key = busyInputModeCacheKey
        busyInputMode = mode
        busyInputModeWriteRevision &+= 1
        do {
            if let setBusyInputMode = chatResumeLifecycleOperations.setBusyInputMode {
                try await setBusyInputMode(client, mode)
            } else {
                try await client.setBusyInputMode(mode)
            }
            defaults.set(mode.rawValue, forKey: key)
            return true
        } catch {
            busyInputMode = previous
            errorMessage = AppLocalization.string("Could not save message behavior: \(UserFacingError.message(for: error))")
            return false
        }
    }

    // MARK: - Clarify lifecycle (AppState+Clarify.swift, AppState+StreamingText.swift, AppState+ChatSupport.swift)

    /// Injectable relay transport for per-question batch answers. Production
    /// resolves through the shared PushNotificationService; tests inject
    /// canned outcomes to pin the released-vs-qid-locked handling.
    var relayQuestionResponder: (_ requestId: String, _ questionId: String, _ answer: String) async throws -> PushNotificationService.RelayQuestionOutcome =
        { requestId, questionId, answer in
            try await PushNotificationService.shared.respondToRelayDecisionQuestion(
                requestId: requestId,
                questionId: questionId,
                answer: answer
            )
        }

    /// In-memory tokens for approvals currently submitting an RPC on this device.
    /// This state is ephemeral and never persisted. Restored approval cards
    /// from disk without an active RPC in flight yield to authoritative replays.
    var liveApprovalSubmissions = Set<ApprovalSubmissionIdentity>()
    /// Input prompts withdrawn (`request.cancel`) while this device's answer
    /// was in flight, with the cancel reason. The gateway drops an answer for
    /// a closed request, so the send's completion must not claim "Sent".
    var withdrawnInFlightInputPrompts = [String: String]()
    /// Request ids of input prompts whose answer this device is sending right
    /// now. Like `liveApprovalSubmissions`: a `.submitting` card without one
    /// lost its send to an ownership fence, and only an authoritative replay
    /// of the still-open request can make it answerable again.
    var liveInputPromptSubmissions = Set<String>()
    /// Connect-card answers on their way, by operation: which submission
    /// and the seq it went out at. A resume that rebuilds the card keeps
    /// its buttons waiting, and only that submission's failure reopens them.
    var liveConnectionSubmissions: [String: (token: UUID, seq: Int)] = [:]

    // MARK: - Chat support surfaces (AppState+StreamingText.swift, AppState+ChatSupport.swift, AppState+ResponseHaptics.swift, AppState+VoiceConversation.swift, AppState+WatchCalls.swift)

    var inlineImageRowFetches: [String: Task<InlineImageRowFetch, Never>] = [:]
    var inlineImageRowsUnavailable: Set<String> = []

    /// A mode switch from a call screen is under way.
    var isSwitchingVoiceMode = false

    /// The live call screen a mode switch is waiting on to slide away. Its
    /// dismissal is the switch's own: it must neither close nor minimise
    /// the call that replaces it, which can be on the same engine (a
    /// hands-free Local Live call moving to Local).
    var voiceModeSwitchDismissing: VoiceCallEngine?

    /// How long a call's request to Hermes waits for a dropped chat
    /// connection before it is reported as not sent (#1060). A seam for tests.
    var voiceRequestConnectionWait: Duration = .seconds(20)

    /// The quick check of a quiet connection, or nil when there is nothing
    /// to check (no open socket, or one that spoke recently). A test seam.
    var quietTransportLiveness: @MainActor (HermesClient) async -> Bool? = { client in
        guard client.isConnected, client.quietInterval >= AppState.quietTransportCheckAfter else { return nil }
        return await client.checkLiveness()
    }

    var quietTransportCheckTask: Task<Void, Never>?

    // MARK: Apple Watch voice

    /// A call the Apple Watch started is being set up or served here
    /// (designs/apple-watch-voice-direct.md). Like CarPlay, it keeps
    /// transport recovery going with the phone locked, so its tokens, tools
    /// and job news reach Hermes.
    @Published var isWatchVoiceCallActive = false

    /// What the user last said in a Watch call, sent with the tool call
    /// it led to: the iPhone doesn't hear the call, and a change to the
    /// user's calendar, reminders or alarms takes their own yes.
    var watchCallUserTurn: (id: UUID, text: String)?

    /// The chat a Classic voice call started fresh, archived on the host
    /// when that call ends (#1124): Hermes Desktop's list leaves it out,
    /// Conduit keeps listing it with its calls, and the next turn anyone
    /// runs in it brings it back. Calls in an existing chat stay with it.
    var classicVoiceChatToArchive: (chatID: String, profile: String, dashboardID: UUID?)?
}

// MARK: - Live Turn Projection

/// What a running turn shows while it streams: the reply text so far and the
/// open thinking card. Both change at display cadence (about 20 to 30 times a
/// second for as long as a turn streams), so they publish here and never on
/// AppState. Every view that observes AppState, including the root view of
/// each sheet, re-renders on any AppState publish; a publish here re-renders
/// only the chat's live rows (`ChatLiveThinkingRow`, `ChatLiveStreamingRow`).
///
/// Only AppState's own coalescing, drawer pause and segment settling write
/// it, through AppState's `streamingText` and `liveReasoningSegment` (tests
/// use `setStreamingTextForTesting`, in debug builds only). Its setters are
/// internal since those moved to AppState+Session.swift (issue 828).
@MainActor
final class LiveTurnProjection: ObservableObject {
    @Published var streamingText = "" {
        didSet { reshape() }
    }
    @Published var reasoningSegment: AppState.LiveReasoningSegment? {
        didSet { reshape() }
    }
    /// Which live rows the turn shows, published only when one comes or
    /// goes: the chat's transcript draws them (TranscriptModel), and their
    /// text comes from the values above.
    @Published private(set) var shape = LiveTurnShape()

    private func reshape() {
        let next = LiveTurnShape(thinkingID: reasoningSegment?.id, streams: !streamingText.isEmpty)
        if next != shape { shape = next }
    }
}

/// The live rows a running turn shows, apart from their text.
struct LiveTurnShape: Equatable {
    /// The open thinking card's id.
    var thinkingID: String?
    /// The reply has text streaming in.
    var streams = false
}
