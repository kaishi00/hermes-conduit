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
    @Published var sessionFilterOrder: [SessionSource] = AppState.defaultSessionFilterOrder

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
    @Published var savedDashboardRegistry: SavedDashboardRegistry {
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
    @Published var isProfileSwitching = false
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
    /// Test seam: sends a Sort it out or Remember it share in place of
    /// submitComposer.
    var sharedDraftSendOverride: ((String, [Attachment]) async -> Bool)?
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
    var projectPositionsBySessionID: [String: Int]?
    /// The catalog's rows under every id they answer to, built once per
    /// `sessions` change for `catalogRow(answeringTo:)`.
    var catalogRowsByAnyID: [String: SessionSummary]?
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
    weak var projectEditingUnsupportedClient: HermesClient? {
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
    /// The registries of the other profiles something on screen shows (All,
    /// a project's page, Bots Home), read by name beside the profile in
    /// use's.
    @Published var otherProfilesLiveStatus = OtherProfilesLiveStatus()
    /// What on screen shows other profiles' live status, by what asked:
    /// their registries are read with the profile in use's while it shows.
    var liveStatusAsks: [String: LiveStatusAsk] = [:]
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
                if let created = shownChat.newChatOpenedSessionID, activeSessionId != created {
                    shownChat.newChatOpenedSessionID = nil
                }
                schedulePendingComposerSendCheck()
                // The dock acts only on word this visit got (issue 2372):
                // another chat, or the same one opened again, reads its
                // goal, loop and heartbeat afresh. A new id for the open
                // chat keeps them.
                // Cleared even while empty, so a read the last visit started
                // can't fill it either.
                let sameChat = activeChatScrollSessionIdentity.contains(oldValue)
                    || sessionControl.sessionID.map(sessionControlIsOpenChat) == true
                if !sameChat { sessionControl.clear() }
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
    /// The chat on screen: its transcript and the reply streaming into it
    /// (ChatState, stage 1 of the all-live rework). Its changes publish as
    /// AppState's (`shownChatChanges`).
    let shownChat = ChatState()
    var shownChatChanges: AnyCancellable?
    /// The chat on screen's own activity (`ChatState`): its title, plan
    /// card, refresh, branch and rewind, its agents, and replies streaming
    /// to another device.
    var chatCards: ChatCardsModel { shownChat.chatCards }
    var activeSessionTitle: String {
        get { shownChat.activeSessionTitle }
        set { shownChat.activeSessionTitle = newValue }
    }
    var isChatRefreshing: Bool {
        get { shownChat.isChatRefreshing }
        set { shownChat.isChatRefreshing = newValue }
    }
    var isBranchingChat: Bool {
        get { shownChat.isBranchingChat }
        set { shownChat.isBranchingChat = newValue }
    }
    var isRewindingTurns: Bool {
        get { shownChat.isRewindingTurns }
        set { shownChat.isRewindingTurns = newValue }
    }
    var slashPromptRefusedDuringRewind: Bool {
        get { shownChat.slashPromptRefusedDuringRewind }
        set { shownChat.slashPromptRefusedDuringRewind = newValue }
    }
    var activeAgents: Int {
        get { shownChat.activeAgents }
        set { shownChat.activeAgents = newValue }
    }
    var delegateAgents: [DelegateAgentActivity] {
        get { shownChat.delegateAgents }
        set { shownChat.delegateAgents = newValue }
    }
    var activeChatRepliesElsewhere: Bool {
        get { shownChat.activeChatRepliesElsewhere }
        set { shownChat.activeChatRepliesElsewhere = newValue }
    }
    /// Bumped on every write to `messages`.
    var chatTranscriptRevision: UInt64 { shownChat.transcriptRevision }
    /// A message an Artifacts screen asked to show; the chat scrolls to it
    /// once its transcript has the row (AppState+Artifacts).
    @Published var pendingArtifactReveal: ArtifactReveal?
    /// Every chat Hermes waits on the user in, every profile's (issue 1705;
    /// AppState+NeedsYou). Its own observable, as `chatCards`.
    let needsYou = NeedsYouStore()
    /// A chat opened from the Needs you list or banner, to scroll to its
    /// waiting card once its transcript has it.
    @Published var pendingNeedsYouReveal: NeedsYouReveal?
    /// Cached once per transcript mutation so view updates do not rescan the full history.
    var pendingClarifyMessageID: String? { shownChat.pendingClarifyMessageID }
    /// What that card is, for the jump button's words.
    var pendingDecisionKind: PendingDecisionKind { shownChat.pendingDecisionKind }
    /// The chat on screen's transcript (`ChatState.messages`, which also
    /// keeps its revision and waiting card current).
    var messages: [ChatMessage] {
        get { shownChat.messages }
        set {
            shownChat.messages = newValue
            advanceChatViewportExpectedTranscriptRevisionIfNeeded()
            // Hermes' rows take over from the saved copy's in the same
            // update: the chat view draws one or the other, never a mix, and
            // rows with the same id stay where they are (#1533).
            if !messages.isEmpty, offlineChatPresentation != nil {
                offlineChatPresentation = nil
            }
        }
    }
    /// The chat on screen's saved copy, shown while the server has not
    /// answered yet (`ChatState.offlineChatPresentation`).
    var offlineChatPresentation: OfflineChatPresentation? {
        get { shownChat.offlineChatPresentation }
        // A message waiting for the chat on screen follows what's shown.
        set {
            let oldValue = shownChat.offlineChatPresentation
            shownChat.offlineChatPresentation = newValue
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
    /// Persisted-history pagination window of the active conversation
    /// (`ChatState.persistedTranscriptWindow`).
    var persistedTranscriptWindow: PersistedTranscriptWindowState? {
        get { shownChat.persistedTranscriptWindow }
        set { shownChat.persistedTranscriptWindow = newValue }
    }
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
    /// The chat on screen's turn (`ChatState.turnState`). What follows a
    /// change outside the chat stays here.
    var turnState: TurnState {
        get { shownChat.turnState }
        set {
            let oldValue = shownChat.turnState
            shownChat.turnState = newValue
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
    /// Whether `turnState` may have missed server-side turn edges
    /// (`ChatState.turnStateIsStale`).
    var turnStateIsStale: Bool {
        get { shownChat.turnStateIsStale }
        set { shownChat.turnStateIsStale = newValue }
    }
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
    /// Whether the visible persisted transcript may be MISSING rows
    /// (`ChatState.transcriptFreshnessIsStale`).
    var transcriptFreshnessIsStale: Bool {
        get { shownChat.transcriptFreshnessIsStale }
        set { shownChat.transcriptFreshnessIsStale = newValue }
    }
    @Published var busyInputMode: BusyInputMode = .steer
    @Published var displayPreferences = ProfileDisplayPreferences() {
        // Kept on the device too, so the saved chats draw as Settings says
        // before the host answers (offline from launch).
        didSet { if displayPreferences != oldValue { rememberDisplayPreferences() } }
    }
    /// The profile's `timezone` config value ("" = the server's local time)
    /// and the profile it was read for. Hermes runs cron schedules in it.
    @Published var profileTimeZoneSetting: (profile: String, value: String)?
    /// The running turn's live reply text and thinking card, on their own
    /// object (`ChatState.liveTurn`).
    var liveTurn: LiveTurnProjection { shownChat.liveTurn }
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
    /// Each profile's archived calls as last read, which a catalog read
    /// within their lifetime takes again (issue 2357).
    var archivedCallsReads: [String: ArchivedCallsRead] = [:]
    /// The projects as last read: for which profile, through which client,
    /// and when. A catalog read that changed nothing reads them again only
    /// past `projectsRereadInterval` (issue 2357).
    var projectsRead: (profile: String, client: ObjectIdentifier, at: Date)?
    /// The scope the catalog last committed for: a read that lists the same
    /// rows for it again skips the work that follows a change (issue 2357).
    var catalogCommitOwner: SessionCatalogOwner?
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

    // MARK: - Runtime (AppState+UIState.swift)

    /// When a Pulse feed read last landed, and for which dashboard
    /// (PulseFeed.swift).
    var pulseFeedAppliedAt: (dashboard: UUID?, at: Date)?

    @Published var runtime = RuntimeState()
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
    /// Update Hermes in Settings > Connection, and the dashboard it belongs
    /// to (AppState+HermesUpdate.swift).
    @Published var hermesUpdate: HermesUpdateState = .idle
    var hermesUpdateDashboardID: UUID?
    var hermesUpdateTask: Task<Void, Never>?
    /// Test seam: answers Update Hermes' dashboard requests.
    var hermesUpdateRequest: (@MainActor (String, String) async throws -> [String: Any])?
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
    @Published var modelVisibility = ModelVisibility()
    /// The model sheet's pinned and recent models, for the active dashboard.
    @Published var modelQuickPicks = ModelQuickPicks()

    // MARK: - UI state (AppState+Pulse.swift, AppState+UIState.swift)

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
    /// Conduit is in the background, or inactive on an iPhone or iPad (the
    /// app switcher, Control Center, a system alert), where a swipe away
    /// from the switcher asks Conduit to quit while a reply still redraws.
    /// An iPad app on a Mac is inactive whenever another app is in front,
    /// where the reply stays in view, so there only the background counts.
    var sceneHidesLiveRows = false
    /// On a Mac, inactive means another app is in front, where Conduit's
    /// window stays in view. Tests set their own.
    var inactiveSceneStaysInView = ProcessInfo.processInfo.isiOSAppOnMac

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
    @Published var settingsDismissRequest: UInt64 = 0
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
    /// The chat on screen's composer requests (`ChatState`, composer).
    var composerPrefillText: String {
        get { shownChat.composerPrefillText }
        set { shownChat.composerPrefillText = newValue }
    }
    var composerPrefillToken: UUID {
        get { shownChat.composerPrefillToken }
        set { shownChat.composerPrefillToken = newValue }
    }
    var composerPrefillDraftKey: ComposerDraftKey? {
        get { shownChat.composerPrefillDraftKey }
        set { shownChat.composerPrefillDraftKey = newValue }
    }
    var composerQuoteRequest: ComposerQuoteRequest? {
        get { shownChat.composerQuoteRequest }
        set { shownChat.composerQuoteRequest = newValue }
    }
    var pendingQuotedReplyJump: QuotedReplyJump? {
        get { shownChat.pendingQuotedReplyJump }
        set { shownChat.pendingQuotedReplyJump = newValue }
    }
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
    lazy var pulseRememberedHomes: [String: String] =
        defaults.dictionary(forKey: Self.pulseHomesKey) as? [String: String] ?? [:]
    /// The profile Pulse runs in per dashboard, as the last feed named it
    /// (`pulseHomeProfile`); none kept for a plugin that names none.
    lazy var pulseRememberedProfiles: [String: String] =
        defaults.dictionary(forKey: Self.pulseProfilesKey) as? [String: String] ?? [:]
    /// The bot whose Bot Chat Do it and Ask open for a Pulse card from no
    /// chat, per dashboard (`pulseDoItBot`); none for a new chat.
    lazy var pulseDoItBots: [String: String] =
        defaults.dictionary(forKey: Self.pulseDoItBotsKey) as? [String: String] ?? [:]

    /// Morning briefs folded on the Pulse screen, per dashboard: each
    /// brief's card id with the cards in it still open when it was folded,
    /// each with when it came (PulseLayout.Brief.isFolded), kept across
    /// launches, so a brief read and folded stays out of the way until it's
    /// opened again or a card in it comes back open. `pulseFoldedBriefsKept`
    /// briefs of each: the one just folded, and the others with the highest
    /// ids, which are the newest: the host numbers cards in the order it
    /// makes them.
    lazy var pulseFoldedBriefs: [String: [String: [String: Double]]] =
        defaults.dictionary(forKey: Self.pulseFoldedBriefsKey) as? [String: [String: [String: Double]]] ?? [:]
    /// Files dropped on the open chat (`ChatState.composerDropRequest`).
    var composerDropRequest: AttachmentDropRequest? {
        get { shownChat.composerDropRequest }
        set { shownChat.composerDropRequest = newValue }
    }
    /// The same for the open group room's composer, kept apart so a chat's
    /// composer never takes a quote meant for a room.
    @Published var roomQuoteRequest: ComposerQuoteRequest?
    /// The open chat's composer focus and dictation asks (`ChatState`).
    var composerFocusRequest: ComposerFocusRequest? {
        get { shownChat.composerFocusRequest }
        set { shownChat.composerFocusRequest = newValue }
    }
    var composerDictationRequest: ComposerDictationRequest? {
        get { shownChat.composerDictationRequest }
        set { shownChat.composerDictationRequest = newValue }
    }
    @Published var roomDropRequest: AttachmentDropRequest?
    /// Words added to a room's kept draft from outside its composer (a
    /// dictation Retry). The open room's composer adds them to its field.
    @Published var roomDraftAppend: RoomDraftAppend?
    /// A bot to add to the room composer's "To" row (its picture tapped, or
    /// its message replied to). The room composer applies and consumes it.
    @Published var roomRecipientRequest: RoomRecipientRequest?
    /// Words the composer puts back, and sends still checking (`ChatState`).
    var composerRestoreRequests: [ComposerRestoreRequest] {
        get { shownChat.composerRestoreRequests }
        set { shownChat.composerRestoreRequests = newValue }
    }
    var composerSendChecks: [ComposerSendCheck] {
        get { shownChat.composerSendChecks }
        set { shownChat.composerSendChecks = newValue }
    }

    // MARK: - Sending while connecting (AppState+PendingSend.swift)

    /// A message sent before its chat was ready (#417), and the rest of
    /// sending while connecting (`ChatState`).
    var pendingComposerSend: PendingComposerSend? {
        get { shownChat.pendingComposerSend }
        set { shownChat.pendingComposerSend = newValue }
    }
    /// Why a waiting message went back to a draft, and its symbol (`ChatState`).
    var composerNotice: String? {
        get { shownChat.composerNotice }
        set { shownChat.composerNotice = newValue }
    }
    var composerNoticeSystemImage: String {
        get { shownChat.composerNoticeSystemImage }
        set { shownChat.composerNoticeSystemImage = newValue }
    }
    /// A reasoning write is in flight (`ChatState.isWritingReasoningEffort`).
    var isWritingReasoningEffort: Bool {
        get { shownChat.isWritingReasoningEffort }
        set { shownChat.isWritingReasoningEffort = newValue }
    }
    static let composerReturnNoticeSystemImage = "arrow.uturn.backward.circle"
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

    // MARK: - Capabilities (AppState+HelperModels.swift, AppState+GeminiQwenLive.swift, AppState+GPTLive.swift, AppState+GrokLive.swift, AppState+LocalLive.swift, AppState+Voice.swift, AppState+VoiceConversation.swift)

    @Published var slashCommands: [SlashCommand] = AppState.builtInSlashCommands
    /// Hermes' argument words for each command (`commands.catalog` `sub`),
    /// by command name: `fast` → normal, fast, ultrafast, …
    @Published var slashSubcommands: [String: [String]] = AppState.conduitSlashSubcommands
    @Published var skills: [CapabilitySkill] = []
    @Published var toolsets: [CapabilityToolset] = []
    /// The active profile's tools catalog, for step rows (`ChatStepLabel`).
    @Published var toolCatalog = ToolCatalog()
    /// A short summary per finished run of steps: by dashboard and profile
    /// (`toolCatalogKey`), then by the run's first tool call
    /// (AppState+StepSummaries.swift).
    @Published var stepSummaries: [String: [String: String]] = ChatStepSummaries.saved()
    /// Test seam: answers `POST /side-question` in place of the dashboard.
    var stepSummarySender: (([String: Any]) async throws -> [String: Any])?
    /// Runs asked about and not answered yet (`ChatState`).
    var stepSummaryRequested: [ChatStepSummaries.Run: Date] {
        get { shownChat.stepSummaryRequested }
        set { shownChat.stepSummaryRequested = newValue }
    }
    /// The chat on screen's suggestion row, authority queue and session
    /// controls, and what the row asks the composer to do (`ChatState`).
    var predictive: PredictiveStore { shownChat.predictive }
    var authorityQueue: AuthorityQueueStore { shownChat.authorityQueue }
    var sessionControl: SessionControlStore { shownChat.sessionControl }
    var predictiveComposerRequest: PredictiveComposerRequest? {
        get { shownChat.predictiveComposerRequest }
        set { shownChat.predictiveComposerRequest = newValue }
    }
    /// Test seam: answers `POST /predict` in place of the dashboard.
    var predictiveSender: (([String: Any]) async throws -> [String: Any])?
    /// Whose catalog `toolCatalog` is (dashboard and profile), and the
    /// catalogs Hermes already sent this run, or is sending now.
    var toolCatalogOwner: String?
    var toolCatalogFetched: Set<String> = []
    var toolCatalogLoading: Set<String> = []
    /// The dashboard, bridge and profile the installed skills/toolsets were
    /// read from. Rows are only presentable, and their switches only act,
    /// while this equals `currentCapabilitiesOwner`: two dashboards can have
    /// a profile of the same name.
    @Published var capabilitiesOwner: CapabilitySnapshotOwner?
    /// The installed skills and toolsets shown are the ones kept from
    /// Hermes' last answer (#1533), drawn until it answers again.
    @Published var capabilitiesAreKept = false
    /// Monotonic request token for capability loads; older requests can never
    /// commit over newer ones (protects the A -> B -> A race).
    var capabilityLoadGeneration: UInt64 = 0
    /// Skill and toolset switches, written in the order flipped.
    let capabilityToggleWrites = CapabilityToggleWrites()
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
    /// A live mode whose provider still needs the user's OK after a call
    /// the phone wasn't showing (CarPlay, the Watch) stopped on it (#827):
    /// the phone asks on its own sheet.
    @Published var liveVoiceConsentRequest: LiveVoiceModeName?

    /// The helper models read in flight. A reader asking meanwhile on the
    /// same profile and Hermes shares it: the Model page and its Helper
    /// models section open together. A save in its profile drops it, so a
    /// read asked after the save isn't answered from before it; another
    /// profile's save (the work watch's) leaves it under way. A reader that leaves
    /// doesn't cancel it: the next one joins it, and the bridge's request
    /// timeout ends one Hermes never answers.
    var helperModelsRead: (profile: String, owner: DashboardRuntimeOwner, task: Task<HelperModelsAnswer, Error>)?

    /// The search the next Gemini Live session uses, resolved when it
    /// starts (automatic asks the host whether it has a search backend).
    var geminiLiveSearchSource: GeminiLiveSearchSource = .google

    /// The profile's persona for the next Gemini Live session.
    var geminiLivePersonality: String?
    /// The host's memory for the next Gemini Live session, read when it
    /// starts so it reflects what Hermes has learned since the last one.
    var geminiLiveMemoryContext: GeminiLiveMemoryContext?

    /// The search the next Qwen Live session uses, resolved when it
    /// starts (automatic asks the host whether it has a search backend).
    var qwenLiveSearchSource: GeminiLiveSearchSource = .none

    /// The profile's persona for the next Qwen Live session.
    var qwenLivePersonality: String?
    /// The host's memory for the next Qwen Live session, read when it
    /// starts so it reflects what Hermes has learned since the last one.
    var qwenLiveMemoryContext: GeminiLiveMemoryContext?
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

    /// Hermes-hosted Gemini Live credentials (the conduit_push plugin), read
    /// through whichever dashboard bridge is current at call time.
    lazy var geminiLiveTokenClient = makeLiveTokenClient(provider: .gemini) { [weak self] in
        self?.activeProfile ?? "default"
    }

    lazy var qwenLiveTokenClient = makeLiveTokenClient(provider: .qwen) { [weak self] in
        self?.activeProfile ?? "default"
    }

    /// Built on first use only: boundaries that merely check whether Gemini
    /// Live is running must not construct its audio engines.
    var geminiLiveControllerCreated = false
    var qwenLiveControllerCreated = false

    lazy var geminiLiveController = makeDirectLiveController(provider: .gemini)
    lazy var qwenLiveController = makeDirectLiveController(provider: .qwen)

    // MARK: GPT-Live voice mode

    /// Presents the GPT-Live sheet. Separate from the classic and Gemini Live
    /// sheets: no two voice modes run at once.
    @Published var showGPTLiveSheet = false

    /// The persona and memory for the next GPT-Live call, read when it
    /// starts and dropped when it closes.
    var gptLivePersonality: String?
    var gptLiveMemoryContext: GeminiLiveMemoryContext?
    /// Whether the next GPT-Live call does its own web lookups ("Look up:")
    /// on the host's search backend, read when it starts.
    var gptLiveWebLookUps = false

    /// GPT-Live calls start on the Hermes host (the conduit_push plugin),
    /// through whichever dashboard bridge is current at call time.
    lazy var gptLiveClient = makeGPTLiveClient { [weak self] in
        self?.activeProfile ?? "default"
    }

    /// Built on first use only, like Gemini Live's.
    var gptLiveControllerCreated = false

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

    // MARK: Grok Live voice mode

    /// Presents the Grok Live sheet. Separate from the other voice sheets:
    /// no two voice modes run at once.
    @Published var showGrokLiveSheet = false

    /// What the next Grok Live call starts with, read when it starts and
    /// dropped when it closes: the host's memory and persona, and the voice
    /// its config names.
    var grokLivePersonality: String?
    var grokLiveMemoryContext: GeminiLiveMemoryContext?
    /// Grok looks things up with xAI's own search, never the host's (#598).
    let grokLiveSearchSource: GeminiLiveSearchSource = .grok
    private var grokLiveVoice: String?

    /// Grok Live's relay socket and status on the Hermes host (the
    /// conduit_push plugin), through whichever dashboard bridge is current
    /// at call time.
    lazy var grokLiveClient = makeGrokLiveClient { [weak self] in
        self?.activeProfile ?? "default"
    }

    /// Built on first use only, like Gemini Live's.
    var grokLiveControllerCreated = false

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

    // MARK: Local Live voice mode

    /// Presents the Local Live sheet. Separate from the other voice sheets:
    /// no two voice modes run at once.
    @Published var showLocalLiveSheet = false

    /// Whether the host's web lookups were available when the agent-mode
    /// call last checked.
    var localLiveWebLookUps = false
    /// The profile's SOUL.md for the next agent-mode call, read when it
    /// starts and dropped when it closes, as the other live modes' are.
    var localLivePersonality: String?
    /// Counts persona lookups and teardowns, so a lookup that finishes
    /// after its call ended or a newer one started stores nothing.
    var localLivePersonaLookup = 0

    /// Local Live's relay socket and status on the Hermes host (the
    /// conduit_push plugin), through whichever dashboard bridge is current
    /// at call time.
    lazy var localLiveClient = makeLocalLiveClient { [weak self] in
        self?.activeProfile ?? "default"
    }

    /// Built on first use only, like the other live modes'.
    var localLiveControllerCreated = false

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
        },
        // A refused transcript says why, as the live modes do.
        submitRefusal: { [weak self] in self?.callRefusalMessageForOpenChat() }
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
    @Published var suspendedVoiceConversation: SuspendedVoiceConversation?
    /// One-shot intent for the Voice sheet's auto-listen on fresh
    /// presentation. Armed only by `openVoiceConversation` and consumed
    /// exactly once (by the sheet, or by the `.active` edge for a sheet that
    /// appeared off screen), so a restored suspended conversation can
    /// never hot-start the microphone when SwiftUI recreates the sheet's
    /// view identity. Lifecycle suspension and every destructive Voice
    /// boundary disarm it.
    var voiceSheetShouldAutoListen = false

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
    var cronRunsJobID: String?
    /// The newest Run history read, so an older one that lands last is dropped.
    var cronRunsLoad = 0
    /// Whether `cronRuns` holds an answer for `cronRunsJobID` yet, so the
    /// sheet says a job hasn't run only once it knows.
    @Published var cronRunsLoaded = false
    /// Why the open job's history couldn't be read, before any answer came:
    /// the sheet says so rather than that the job hasn't run.
    @Published var cronRunsFailure: String?
    @Published var cronJobsLoading = false
    @Published var cronJobActionID: String?
    /// Bumped by a job delete so a list load that started before it can't
    /// bring the deleted job back.
    var cronJobsGeneration = 0
    /// The read in flight and the list generation, profile and connection
    /// it is for. A second ask for the same list joins it.
    var cronJobsRead: (owner: String, token: UUID, task: Task<Void, Never>)?
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

    /// Catalog rows `session.resume` answered 4007 for during an automatic
    /// resume, per dashboard and profile, for this app run. The catalog can
    /// keep listing a conversation the gateway no longer resumes; without
    /// this, the retry after a failed fresh-chat create would select and
    /// probe the same dead rows again.
    var deadResumeRowIDs: [String: Set<String>] = [:]
    /// The chat on screen's open reconcile (`ChatState.reconciliation`).
    var reconciliation: Reconciliation? {
        get { shownChat.reconciliation }
        set { shownChat.reconciliation = newValue }
    }
    var activeClientEpoch = UUID()
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
    let profileDiscoveryLoaderOverride: (@MainActor () async throws -> [String: Any])?
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
    var leaveCatalogRefreshPending = false
    var leaveCatalogRefreshReportsFailure = false
    /// The coalesced read serves a `sessions.changed`: if it fails, the
    /// change stays pending (issue 2294).
    var leaveCatalogRefreshReadsChange = false
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
    /// Why the notification route's last attempt failed, and which tap's
    /// route said it, kept while another attempt is still due: the chat that
    /// opens on the retry should not have been told, in the meantime, that it
    /// is gone or that it could not be restored (#1919). The tap is kept so a
    /// route that was replaced meanwhile never wears this one's words, and
    /// the viewport transition of its latest attempt, so a chat the user
    /// opened since never wears them either.
    var notificationRouteFailure: NotificationRouteFailure?
    var openChatSyncReadID: UUID?
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
    var projectsRequestGeneration = 0
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
    let modelVisibilityKey = "conduit.modelVisibility.v1"
    let profileOrderKey = "conduit.profileOrder.v1"
    let sessionFilterOrderKey = "conduit.sessionFilterOrder.v1"
    let reviewSummaryCacheKey = "conduit.reviewSummaryCache.v1"
    let knownProfilesKey = "conduit.knownProfiles.v1"
    /// Each known profile's name, for Siri and Shortcuts.
    let knownProfileNamesKey = "conduit.knownProfileNames.v1"
    /// Per-dashboard copies of profile-level presentation choices (#148).
    /// Profile names repeat across Hermes servers ("default" everywhere), so
    /// these are keyed by dashboard UUID. The pre-scoping global values were
    /// adopted by the registry's first dashboard.
    let activeProfileByDashboardKey = "conduit.activeProfileByDashboard.v1"
    let profileOrderByDashboardKey = "conduit.profileOrderByDashboard.v1"
    let modelVisibilityByDashboardKey = "conduit.modelVisibilityByDashboard.v1"
    let modelQuickPicksByDashboardKey = "conduit.modelQuickPicksByDashboard.v1"
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
        // The chat on screen's changes publish as AppState's, as they did
        // when its transcript and stream were AppState's own properties.
        shownChatChanges = shownChat.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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

    /// The failed send's error under the composer (`ChatState.sendFailureShown`).
    var sendFailureShown: String? {
        get { shownChat.sendFailureShown }
        set { shownChat.sendFailureShown = newValue }
    }

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
    /// One read of each Linked Rooms list at a time (issue 2359).
    let linkedRoomDraftsReader = LinkedRoomListRead()
    /// A drafts read asked for with the people that hasn't run yet.
    var linkedRoomDraftsPeopleAsked = false
    let linkedRoomInvitesReader = LinkedRoomListRead()
    let linkedRoomApprovalsReader = LinkedRoomListRead()
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
    /// Bumped by a change made here to who and what Group Chats lists (a
    /// copy's delete, a Block, a leave or take out), so a copies,
    /// approvals, drafts or invites read it overtook is dropped: issued
    /// before the change, it could list what the change took away
    /// (issue 2347).
    var linkedRosterGeneration = 0
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
    /// On the home: who's in the open room with none of their agents.
    @Published var activeRoomJustMe: [String] = []
    /// Whether every Hermes in the open room is the user's own, over Links
    /// both sides marked (`GET /rooms/people`'s `own_hermes`, plugin 0.169):
    /// its bots work as at home, so Group Info offers no room choices. Nil
    /// until the room's first people read lands (or fails, which reads as
    /// false: the rules hold), so such a room never shows them first.
    @Published var activeRoomOwnHermes: Bool?
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

    // MARK: - Connection Repair (Round 6)

    /// Dashboards a repair registered for a new address, by sign-in or
    /// password reconnect (`registerRepairDashboard`); cleared when a
    /// repair begins (either entry) and once one connects, so a later
    /// repair never inherits them.
    var repairRegisteredDashboardIDs: Set<UUID> = []

    // MARK: - Saved dashboards (#148) (AppState+Dashboards.swift, AppState+SignIn.swift)

    /// Bumped on every dashboard switch; a restore that started under an
    /// older generation must not install its connection underneath a newer
    /// switch.
    var dashboardSwitchGeneration: UInt64 = 0

    /// Dashboards whose saved password Face ID or Touch ID unlocked since
    /// launch, with a fingerprint of the password it unlocked: a different
    /// password saved later for the same dashboard asks again. Clearing the
    /// saved password (sign-out, removal, a switch to browser sign-in) drops
    /// it. The unlock holds while Conduit runs, also after a long time away,
    /// as a connected Conduit never asks again on return; a cold launch
    /// asks.
    var faceIDUnlockedDashboards: [UUID: SHA256.Digest] = [:]

    /// Face ID or Touch ID for a saved password. Test seam.
    var unlockWithFaceID: @MainActor () async -> Bool = {
        guard BiometricAuth.isAvailable else { return false }
        return await BiometricAuth.authenticate(reason: AppLocalization.string("Unlock Conduit"))
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
            if pendingNewChat != nil { shownChat.newChatOpenedSessionID = nil }
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


    // MARK: - Slash Commands (AppState+SlashCommands.swift)

    var lastSlashCatalogPayload: AnyCodable?

    // MARK: - Profiles and preferences (AppState+SessionCatalog.swift, AppState+TranscriptHistory.swift, AppState+Profiles.swift, AppState+Clarify.swift, AppState+Projects.swift)

    /// Dashboard and profile scopes whose plugin refused the history page
    /// route this run (`HistoryPage.isRefusedForScope`).
    var historyPageRefusedScopes: Set<String> = []

    /// Profile list reads sent, and the newest of them whose list (with
    /// names) was taken, so an older answer landing after it doesn't commit.
    var profileListReadsSent: UInt64 = 0
    var profileListReadCommitted: UInt64 = 0

    /// The project a rename or delete is running for; a second one waits.
    @Published var projectMutationID: String?

    // MARK: - Scheduled jobs (AppState+ScheduledJobs.swift, AppState+ProfileConfig.swift, AppState+KeptAnswers.swift)

    /// Counts display saves that landed, so a config read sent before one
    /// doesn't put the older choice back.
    var displayPreferencesWriteRevision = 0
    /// The same for time-zone saves, which come back in that config read
    /// too but are counted apart, so a display save doesn't cost the zone.
    var timeZoneWriteRevision = 0
    /// Display settings reads sent, and the newest whose answer was taken,
    /// so an older read landing after it (or failing after it) doesn't put
    /// its settings back.
    var displayPreferencesReadsSent: UInt64 = 0
    var displayPreferencesReadCommitted: UInt64 = 0

    /// The reads every connection makes, sent with its ticket rather than
    /// each after the step before it: the profile list, the chat list's
    /// newest page and the display settings. Each step takes its answer
    /// through `startupReads.read`, or reads again when something changed
    /// since. Only through a saved dashboard's bridge, whose own stores hold
    /// its session; never through the page.
    let startupReads = StartupReads()

    /// Numbers the reads whose answers are kept as they're asked, and the
    /// writes as they land: an answer is kept only over an older one, so a
    /// read asked before a save, a forget or another read never puts its
    /// answer back over theirs (#1533).
    var keptAnswerTurns = 0
    /// The number of the answer kept, per dashboard, profile and route.
    var keptAnswerTurnsKept: [String: Int] = [:]

    /// Bumped by each busy mode picked, so a read that was already out
    /// doesn't put the old one back.
    var busyInputModeWriteRevision = 0

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
