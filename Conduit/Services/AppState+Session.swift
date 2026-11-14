//
//  AppState+Session.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Session; Session management;
//  New Chat; Read state (#454).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Session

    var widgetBotEvidenceIsAvailable: Bool { botEvidenceIsAvailable }

    /// A widget action waits out the return-to-app refresh: that refresh
    /// can drop a socket that died in the background and restore the last
    /// chat, which would fail a new chat or take over the screen it opened.
    var widgetForegroundReady: Bool { isSceneActive && sceneHasBeenActive && scenePhaseAttemptID == nil }

    /// Hermes' @session:<id> links read as the chat's name, cron runs' too.
    func updateSessionReferenceTitles() {
        HermesSessionReference.updateTitles(Self.sessionReferenceTitles(cronSessions + sessions))
    }

    /// Titles by every id a chat answers to. A chat's own id wins over the
    /// same id reached through a continuation's lineage root or alias.
    nonisolated static func sessionReferenceTitles(_ sessions: [SessionSummary]) -> [String: String] {
        var titles: [String: String] = [:]
        let named = sessions.filter { !$0.title.isEmpty }
        for session in named {
            for id in [session.lineageRootId].compactMap({ $0 }) + session.alternateIds {
                titles[id] = session.title
            }
        }
        for session in named {
            for id in [session.id, session.storedSessionId].compactMap({ $0 }) {
                titles[id] = session.title
            }
        }
        return titles
    }

    /// False once the current connection's gateway rejected
    /// `session.workspace.move`, so "Move to Project" stops being offered.
    var supportsSessionWorkspaceMove: Bool {
        guard let client, isConnected else { return false }
        return client !== workspaceMoveUnsupportedClient
    }

    struct OpenChatPinnedRepliesKey: Equatable {
        let profile: String
        let active: String
        let stored: [PinnedReply]
        let transcriptRevision: UInt64
        let sessionsRevision: Int
        let cronSessionsRevision: Int
    }

    var liveTurnRegistryRecheckPending: Bool { liveTurnRegistryRecheck != nil }

    var sessionCatalogOwner: SessionCatalogOwner {
        SessionCatalogOwner(dashboardID: activeDashboardID, profile: activeProfile)
    }

    /// The load phase of the catalog the Chats list shows now.
    var sessionCatalogPhase: SessionCatalogLoadPhase {
        sessionCatalogLoadState.phase(for: sessionCatalogOwner)
    }

    /// The Chats list's first read once a connection is up, for when the
    /// connect's own catalog sync didn't publish one (it was superseded, or
    /// a sign-in reached the list before it). One read: a failure stays
    /// failed until the user tries again.
    func loadSessionCatalogIfNeeded() async {
        guard isConnected, turnState != .synchronizing, sessionCatalogPhase == .notLoaded else { return }
        // One read at a time for one dashboard profile: two lists (or two
        // passes of one) that start it together share it.
        let owner = sessionCatalogOwner
        if let running = sessionCatalogFirstRead, running.owner == owner {
            await running.task.value
            // A read a reconnect left behind settles nothing: read again,
            // for this connection.
            if sessionCatalogPhase == .notLoaded, sessionCatalogFirstRead == nil {
                await loadSessionCatalogIfNeeded()
            }
            return
        }
        let id = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.loadSessions()
            if self.sessionCatalogFirstRead?.id == id { self.sessionCatalogFirstRead = nil }
        }
        sessionCatalogFirstRead = SessionCatalogFirstRead(owner: owner, id: id, task: task)
        await task.value
    }

    struct SessionCatalogFirstRead {
        let owner: SessionCatalogOwner
        let id: UUID
        let task: Task<Void, Never>
    }

    static let maxKeptBotChatCopies = 8

    /// The copy to drop before keeping one under `key`: the least recently
    /// kept, once the count is reached and `key` isn't one of them.
    static func keptBotChatCopyToDrop(keptAt: [String: Date], adding key: String) -> String? {
        guard keptAt[key] == nil, keptAt.count >= maxKeptBotChatCopies else { return nil }
        return keptAt.min { $0.value < $1.value }?.key
    }

    /// Bounded, race-safe lifecycle bookkeeping for the claims above:
    /// - `generation` is the conversation's terminal-compaction counter at
    ///   claim time. A `pending` continuation may only (re-)establish its
    ///   claim while that counter is unchanged, so a `compacted` edge that
    ///   landed during the RPC await wins over the stale continuation.
    /// - `expiresAt` bounds the claim to one full compression budget: a lost
    ///   terminal edge must not keep "Compressing…" alive for the whole
    ///   connection.
    struct ServerCompactionClaim {
        let generation: Int
        let expiresAt: Date
    }

    /// Whether the active conversation is compressing — either a local
    /// `session.compress` RPC is in flight or the gateway reports server-side
    /// compaction. Alias-aware through the same session-equivalence machinery
    /// duplicate detection uses, so a runtime rebind mid-compression
    /// (runtime-old → runtime-new of one conversation) keeps the
    /// "Compressing…" affordance visible.
    var isCompressingActiveSession: Bool {
        guard let activeSessionId else { return false }
        return compressingSessionIDs.contains(where: { composerSessionIDsAreEquivalent($0, activeSessionId) })
            || serverCompactingSessionIDs.contains(where: { composerSessionIDsAreEquivalent($0, activeSessionId) })
    }

    /// Newest AUTHORITATIVE live turn-lifecycle evidence. Every `setRunning`
    /// edge (sessionBusy, message start/delta, completion, interruption,
    /// error, registry-probe corrections, buffered-event replay), the
    /// authoritative resume-snapshot adoption, the typed busy-submission
    /// outcome, and a successful steer advance the revision; optimistic local
    /// writes (the pre-send `.running`, the ambiguous-recovery stamps
    /// themselves) never do. The ambiguous-submission recovery captures this
    /// evidence at its registry observation. At stamp time:
    ///
    /// - A changed REVISION proves newer live evidence arrived while the
    ///   recovery awaited, so the older recovery result must not overwrite
    ///   `turnState`/`turnStateIsStale`. Plain value equality cannot prove
    ///   that — the pre-send stamp already leaves `turnState == .running`,
    ///   so a newer `sessionBusy(true)` is value-indistinguishable from the
    ///   stale baseline.
    /// - The RUNNING half answers a separate question: whether accepted-turn
    ///   OWNERSHIP is still live. Newer busy/running evidence does not
    ///   invalidate a positively-proven accepted submission; newer
    ///   settled/idle/error/interruption evidence does. Stamp authority and
    ///   accepted provenance are therefore decided independently. The
    ///   running half is a single NEWEST-EDGE bit, not per-turn tracking: a
    ///   settle immediately followed by a successor turn's busy edge inside
    ///   one recovery window reads as "running". That is accepted — marker
    ///   use stays validated at the foreground (durable-twin check) and a
    ///   later settle flows into the bounded-debt lifecycle, so the worst
    ///   case is a spurious-but-safe reconcile.
    struct TurnLifecycleEvidence {
        var revision: UInt64
        var running: Bool
    }

    /// Evidence that the in-flight turn was submitted from THIS surface:
    /// recorded when a locally-initiated, non-busy `prompt.submit` is
    /// accepted (or ambiguity recovery proves `.acceptedRunning`), and
    /// validated at use against the transcript (the optimistic user row must
    /// still be present, unpersisted, and head a fully-unpersisted suffix)
    /// plus the local turn state. `preSubmitOrderingBaseline` freezes the
    /// persisted ordering frontier BEFORE the send changes the transcript:
    /// the ordering anchor that lets a later bounded tail read classify
    /// persisted advancement as belonging to our turn (Hermes persists the
    /// user row at turn start, so the twin of the optimistic bubble is
    /// normally there) versus belonging to a later foreign turn. Freezing at
    /// submit time is load-bearing: a later frontier advance never moves a
    /// live marker's baseline, so our turn's own persisted rows still count
    /// as boundaries against a foreign turn that starts after it. Optimistic
    /// row ids never enter `durablePersistedRowIDs`; the two identities stay
    /// distinct — the marker only asserts that ONE new persisted user turn
    /// is expected while our turn is in flight.
    struct LocallyOwnedInFlightTurn {
        var sessionIDs: Set<String>
        var optimisticUserRowID: String
        var preSubmitOrderingBaseline: PersistedOrderingBaseline
        /// Set when a validated bounded read positively observed this turn's
        /// persisted user boundary (the frontier advanced through it).
        var persistedBoundaryObserved = false
    }

    /// Ordering debt for turns whose durable ordering is not yet proven. A
    /// missing-boundary debt expects one or more canonical user rows after the
    /// frontier. A zero-boundary observation obligation permits only trailing
    /// assistant/tool rows: it covers a locally-owned turn whose boundary was
    /// seen while live, plus busy `.queued`/`.steered` outcomes whose typed
    /// response cannot prove whether Hermes later promoted input to a full
    /// turn. One bounded pre-send read clears the matching shape and advances
    /// the frontier; extra user boundaries prove new activity (authoritative
    /// reconcile), while missing rows or an unprovable anchor recover
    /// conservatively. Conversation-scoped: reset with transcript lifecycle
    /// evidence and cleared by authoritative adoption.
    struct PendingLocalOrderingDebt {
        var sessionIDs: Set<String>
        var expectedUserTurnCount: Int
        /// No exact new boundary is owed. Rows before the next expected
        /// boundary may be a settled local tail or the current busy turn's
        /// tail. With zero expected boundaries, an empty or non-user-only
        /// suffix satisfies the obligation; any user boundary proves new
        /// activity that must be adopted authoritatively.
        var allowTrailingRowsWithoutNewUserBoundary: Bool
    }

    /// Persisted ORDERING evidence — deliberately distinct from
    /// `durablePersistedRowIDs` (provenance for rows currently represented
    /// in the visible transcript). This is the newest durable row Conduit
    /// has POSITIVELY observed through a validated bounded persisted-history
    /// read or hydration, or a positive proof that the persisted transcript
    /// is EMPTY. The visible transcript may keep an optimistic row whose
    /// durable twin the frontier already knows about; the optimistic row is
    /// never rewritten, the twin is never merged behind it, and the twin's
    /// id never enters visible provenance — advancing the frontier is purely
    /// ordering metadata for the NEXT locally-owned turn's baseline.
    /// Conversation-scoped: reset on session/profile switch, conversation
    /// replacement, sign-out; re-anchored by every authoritative reconcile
    /// adoption and advancement merge, and advanced by every validated
    /// `.unchanged` bounded read. Assignment is a RE-ANCHORING on the read's
    /// own positive observation, not a monotonic advance: a validated read
    /// whose page no longer contains the previous frontier row (server-side
    /// deletion) re-anchors lower or to unknown — every use site verifies
    /// anchors by id-presence in the page, so a stale anchor degrades to
    /// inconclusive, never to a false verdict.
    struct PersistedOrderingFrontier {
        var newestObservedDurableRowID: String?
        var isPositivelyEmpty = false

        /// Positively empty deliberately wins over an anchored id: the two
        /// states are mutually exclusive by construction (see
        /// `orderingFrontier(from:)`), and emptiness is the stronger claim.
        var baseline: PersistedOrderingBaseline {
            if isPositivelyEmpty { return .positivelyEmpty }
            if let newestObservedDurableRowID { return .anchored(newestObservedDurableRowID) }
            return .unknown
        }
    }

    /// The live reply text as the chat shows it; stored in `liveTurn`.
    /// Deliberately not @Published: reading it in a view that observes
    /// AppState does not refresh with the stream. Views observe `liveTurn`.
    /// Written only by the delta coalescing and turn-boundary code here.
    var streamingText: String {
        get { liveTurn.streamingText }
        set { liveTurn.streamingText = newValue }
    }

    #if DEBUG
    /// Test seam: shows `text` as the live reply, as a coalesced streaming
    /// publish would, without feeding gateway deltas.
    func setStreamingTextForTesting(_ text: String) {
        streamingText = text
    }
    #endif

    /// Live, frequently-changing reasoning projection, stored in `liveTurn`.
    /// Streaming reasoning renders from here at display cadence WITHOUT
    /// mutating the settled `messages` array — per-publish transcript
    /// mutation (O(message count) index scan + copy-on-write copy + revision
    /// bump + scroll-target cache walk) is what made deep agent sessions burn
    /// CPU and battery. The card commits into `messages` exactly once per
    /// segment boundary via `settleReasoningSegmentIntoTranscript()`.
    var liveReasoningSegment: LiveReasoningSegment? {
        get { liveTurn.reasoningSegment }
        set { liveTurn.reasoningSegment = newValue }
    }

    /// Whether a landing is owed that ChatView hasn't taken yet; taking it
    /// clears it.
    func takeChatReplyStartLanding() -> Bool {
        guard chatReplyStartLandingTaken != chatReplyStartLandingRequest else { return false }
        chatReplyStartLandingTaken = chatReplyStartLandingRequest
        return true
    }

    /// Profile changes and network refreshes are asynchronous. Keep a final
    /// ownership boundary at the published catalog so a stale row can never
    /// render under another workspace while a switch is in flight. Canonical
    /// Bot Chats are projected out here (never in the identity machinery's
    /// own catalog views): they are reachable only through the Bots roster.
    /// The projection hides a row when it is canonical to the ROSTER (a
    /// canonical id, or the reserved title stamped with a known bot's
    /// profile) or when positive bot ownership names it under any identity —
    /// including a lineage tip whose title moved on.
    ///
    /// The unconditional reserved-TITLE rule is deliberately NOT applied to
    /// this LISTING (only to resume selection): a row titled "Bot Chat" that
    /// no roster evidence reserves is an ordinary conversation the user can
    /// still see and open (see `BotChatHygiene.isReservedCanonicalTitleRow`).
    ///
    /// The V2 chat list reads this many times per render (its rows, each
    /// filter's count, the voice button's recents), and building it checks
    /// every row against the bot roster, so it is kept until the catalog,
    /// the profile or the bot evidence changes.
    var activeProfileSessions: [SessionSummary] {
        let key = ActiveProfileSessionsKey(
            sessionsRevision: sessionsRevision,
            profile: activeProfile,
            botOwnershipGeneration: botOwnershipGeneration,
            workstreamsGeneration: botWork.workstreamsGeneration
        )
        if let cached = activeProfileSessionsCache, cached.key == key { return cached.rows }
        let botOwned = botOwnedSessionIDs
        let rows = sessions.filter {
            sessionBelongsToProfile($0, profile: activeProfile)
                && !BotChatHygiene.isCanonicalBotChatRow($0, roster: botRoster)
                && !BotChatHygiene.isBotOwnedRow($0, botOwnedSessionIDs: botOwned)
                && !isWorkstreamRow($0)
        }
        activeProfileSessionsCache = (key, rows)
        return rows
    }

    struct ActiveProfileSessionsKey: Equatable {
        let sessionsRevision: Int
        let profile: String
        let botOwnershipGeneration: Int
        let workstreamsGeneration: Int
    }

    /// Kept like `activeProfileSessions`: the default profile holds nearly
    /// every cron run, and the open chat's header and the Chats list under
    /// it read this on every publish.
    var activeProfileCronSessions: [SessionSummary] {
        let key = ActiveProfileCronSessionsKey(cronSessionsRevision: cronSessionsRevision, profile: activeProfile)
        if let cached = activeProfileCronSessionsCache, cached.key == key { return cached.rows }
        let rows = cronSessions.filter { sessionBelongsToProfile($0, profile: activeProfile) }
        activeProfileCronSessionsCache = (key, rows)
        return rows
    }

    struct ActiveProfileCronSessionsKey: Equatable {
        let cronSessionsRevision: Int
        let profile: String
    }

    /// The Chats list's rows: the live ones once this scope's list has
    /// landed, until then the ones it showed last time. Views only; every
    /// decision reads `activeProfileSessions`.
    var listedSessions: [SessionSummary] {
        guard let saved = savedChatListForActiveScope else { return activeProfileSessions }
        guard let kept = saved.keptPinnedRows else { return saved.list.sessions }
        guard !kept.isEmpty else { return activeProfileSessions }
        let key = ListedSessionsKey(
            rows: ActiveProfileSessionsKey(
                sessionsRevision: sessionsRevision,
                profile: activeProfile,
                botOwnershipGeneration: botOwnershipGeneration,
                workstreamsGeneration: botWork.workstreamsGeneration
            ),
            savedChatListRevision: savedChatListRevision
        )
        if let cached = listedSessionsCache, cached.key == key { return cached.rows }
        let rows = saved.listedRows(live: activeProfileSessions)
        listedSessionsCache = (key, rows)
        return rows
    }

    /// The scheduled runs the Chats list shows, like `listedSessions`.
    var listedCronSessions: [SessionSummary] {
        guard let saved = savedChatListForActiveScope, saved.isShowingSavedRows else {
            return activeProfileCronSessions
        }
        return saved.list.cronSessions
    }

    /// Whether the Chats list still shows the saved rows, not live ones.
    var isShowingSavedChatList: Bool {
        savedChatListForActiveScope?.isShowingSavedRows == true
    }

    /// No rows yet because this scope's list is still on its way and none
    /// was saved: the list says it's loading, not that there are no chats.
    var isLoadingChatList: Bool {
        guard savedChatListForActiveScope == nil,
              let dashboardID = activeDashboardID,
              !liveChatListLanded(dashboardID: dashboardID, profile: activeProfile) else { return false }
        return isConnecting || isProfileSwitching || turnState == .synchronizing
    }

    var savedChatListForActiveScope: SavedChatListPresentation? {
        guard let saved = savedChatList,
              saved.dashboardID == activeDashboardID,
              saved.profile == activeProfile else { return nil }
        return saved
    }

    /// Whether this scope's live list has landed in this process: set where
    /// the catalog is published, cleared by a profile or dashboard change.
    func liveChatListLanded(dashboardID: UUID, profile: String) -> Bool {
        widgetSettledCatalogOwner == WidgetWorkspaceID(dashboardID: dashboardID, profile: profile)
    }

    struct ListedSessionsKey: Equatable {
        let rows: ActiveProfileSessionsKey
        let savedChatListRevision: Int
    }

    /// A chat tapped in the saved list (or typed in over its saved copy),
    /// and the scope it was picked in.
    struct SavedChatListPick {
        let dashboardID: UUID
        let profile: String
        /// Every id the chat answers to, to find its live row by.
        let sessionIDs: Set<String>
        /// What it opens by when the live list doesn't have it: its saved
        /// durable id.
        let openID: String
        /// The saved row's id.
        let rowID: String
    }

    // MARK: - Session management

    func loadSessions(forceRefresh: Bool = false) async {
        _ = await loadSessions(
            forceRefresh: forceRefresh,
            requiredViewportTransitionGeneration: nil
        )
    }

    /// The chat list for a widget action waiting on it. A failed read says
    /// nothing in the composer: the launch retries on its next readiness
    /// change and reports its own failure if it runs out of time.
    func loadSessionsForWidgetLaunch() async {
        await loadSessions(
            forceRefresh: false,
            requiredViewportTransitionGeneration: nil,
            reportsFailure: false
        )
    }

    @discardableResult
    func loadSessions(
        forceRefresh: Bool,
        requiredViewportTransitionGeneration: UInt64?,
        reportsFailure: Bool = true,
        yieldsToNewerReads: Bool = false,
        deferringOlderPages: Bool = false
    ) async -> Bool {
        if let requiredViewportTransitionGeneration,
           !chatViewportTransitionIsCurrent(generation: requiredViewportTransitionGeneration) {
            return false
        }
        let activeClient = client
        guard activeClient != nil || sessionCatalogLoaderOverride != nil else { return false }
        let profile = activeProfile
        let dashboardID = activeDashboardID
        let retainedActiveTurn = activeTurnCatalogSession()
        let readTicket = takeSessionListReadTicket()
        do {
            let loadedSessions: [SessionSummary]
            var olderPagesDeferred = false
            if let sessionCatalogLoaderOverride {
                loadedSessions = try await sessionCatalogLoaderOverride(forceRefresh)
            } else if let activeClient {
                let catalogLoad = try await profileCatalog(
                    using: activeClient,
                    forceRefresh: forceRefresh,
                    deferringOlderPages: deferringOlderPages,
                    yieldsToNewerReads: yieldsToNewerReads
                )
                loadedSessions = catalogLoad.sessions
                olderPagesDeferred = catalogLoad.olderPagesDeferred
            } else {
                return false
            }
            guard profile == activeProfile, dashboardID == activeDashboardID else { return false }
            if sessionCatalogLoaderOverride == nil {
                guard let activeClient, self.client === activeClient else { return false }
            }
            guard requiredViewportTransitionGeneration.map({ chatViewportTransitionIsCurrent(generation: $0) }) ?? true else { return false }
            // A read that started later already listed what it saw: this
            // older answer is no news, and the list it would put back is
            // older than the one shown.
            guard claimSessionListListing(readTicket) else { return true }
            let awaitingListing = newChatRowAwaitingListing(loaded: loadedSessions)
            // The newest page alone (a pull to refresh, whose older pages
            // are read right after) keeps the older rows already listed
            // until they land, so the list never shrinks to one page
            // meanwhile, and a failed read after it leaves them.
            let olderListed = olderPagesDeferred ? sessions + cronSessions : []
            let allSessions = uniqueSessions(
                [retainedActiveTurn, awaitingListing].compactMap { $0 } + loadedSessions + olderListed
            )
            let listedSessions = allSessions.filter { $0.source != .cron }
            let listedCron = allSessions.filter { $0.source == .cron }
            // A read that changed the list keeps the list's poll quick. One
            // that lists the same rows for the same scope again (a change
            // event's read, every few seconds while another device works)
            // skips what follows a change (issue 2357): the lists' didSets,
            // the identity index, the widget and the projects.
            let owner = SessionCatalogOwner(dashboardID: dashboardID, profile: profile)
            let listChanged = listedSessions != sessions || listedCron != cronSessions
            let sameListAgain = !listChanged && catalogCommitOwner == owner
            if listChanged { chatListCatalogGeneration &+= 1 }
            if listedSessions != sessions { sessions = listedSessions }
            if listedCron != cronSessions { cronSessions = listedCron }
            catalogCommitOwner = owner
            settleNewChatAwaitingListing(loaded: loadedSessions)
            chatListCatalogFreshness.noteLoaded(at: chatSyncNow())
            observeOpenChatCatalog()
            savedChatListReplacedByLiveList(newestPageOnly: olderPagesDeferred, dashboardID: dashboardID)
            sessionCatalogLoadState.markLoaded(SessionCatalogOwner(dashboardID: dashboardID, profile: profile))
            refreshVoiceSessionTags()
            // Labeled rows are positive identity evidence; commit them so
            // notification routing survives a later catalog omission.
            if !sameListAgain {
                conversationIdentityIndex.recordCatalogIdentity(allSessions, profile: profile)
            }
            // A canonical Bot Chat's raw catalog row is titled exactly
            // "Bot Chat": refreshing the ordinary active-title cache from it
            // would persist the wire title over the bot's display label and
            // write "Bot Chat" into the dashboard profile's persisted cache
            // (the cold-restore bug). Ownership comes from the bot
            // conversation registry, never a title guess.
            if let activeSessionId,
               botConversationProfile(for: activeSessionId) == nil {
                updateActiveSessionTitle(for: activeSessionId)
            }
            if let dashboardID {
                let widgetOwner = WidgetWorkspaceID(dashboardID: dashboardID, profile: profile)
                if !sameListAgain || widgetSettledCatalogOwner != widgetOwner {
                    widgetSettledCatalogOwner = widgetOwner
                    widgetLaunchCoordinator.readinessChanged()
                    publishWidgetSnapshot()
                }
            }
            // A chat tapped in the saved list opens now if no chat sync
            // landed this scope's list first, and a sync still reading it
            // leaves the chat alone.
            if let pickedSessionID = takeChatPickedFromSavedList(dashboardID: dashboardID, profile: profile) {
                cancelChatResumeRestoration()
                openChatPickedFromSavedList(pickedSessionID)
            }
            if let activeClient, !sameListAgain || projectsNeedReading(using: activeClient, profile: profile) {
                Task { [weak self] in
                    await self?.loadProjects(using: activeClient, profile: profile)
                }
            }
            return true
        } catch {
            guard profile == activeProfile, dashboardID == activeDashboardID else { return false }
            if sessionCatalogLoaderOverride == nil {
                guard let activeClient, self.client === activeClient else { return false }
            }
            guard requiredViewportTransitionGeneration.map({ chatViewportTransitionIsCurrent(generation: $0) }) ?? true else { return false }
            // A read cancelled under it (a pull to refresh the list left)
            // says nothing about the catalog: the next showing reads again.
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return false }
            // A read that started later already listed: the list is current,
            // and this older failure is no news.
            guard readTicket > sessionListListedTicket else { return true }
            guard reportsFailure else { return false }
            errorMessage = AppLocalization.string("Failed to load sessions: \(UserFacingError.message(for: error))")
            sessionCatalogLoadState.markFailed(
                UserFacingError.message(for: error),
                owner: SessionCatalogOwner(dashboardID: dashboardID, profile: profile)
            )
            return false
        }
    }

    /// The open chat made here, kept in a list Hermes doesn't list it in
    /// yet. Only looks: the list that is published settles the wait
    /// (`settleNewChatAwaitingListing`).
    func newChatRowAwaitingListing(loaded: [SessionSummary]) -> SessionSummary? {
        guard let awaiting = openNewChatAwaitingListing,
              !loaded.contains(where: awaiting.matches) else { return nil }
        return sessions.first(where: awaiting.matches)
    }

    /// Ends the wait once a published list has Hermes' row for the chat, or
    /// the chat is no longer open: an empty chat left behind is gone, as
    /// Hermes has no row for it. Hermes' row may lose to the open turn's own
    /// row in the list, so a listing always moves the generation a
    /// project's page follows, which then shows Hermes' row in its place.
    func settleNewChatAwaitingListing(loaded: [SessionSummary]) {
        guard newChatAwaitingListing != nil else { return }
        guard let awaiting = openNewChatAwaitingListing,
              sessions.contains(where: awaiting.matches) else {
            newChatAwaitingListing = nil
            return
        }
        if loaded.contains(where: awaiting.matches) {
            newChatAwaitingListing = nil
            chatListCatalogGeneration &+= 1
        }
    }

    /// Whether `session` is the chat open now, by any id it goes by: a
    /// chat New Chat made is open under its runtime id and listed under its
    /// stored one (issue 1454). Another profile's row in All never is.
    func isOpenChatRow(_ session: SessionSummary) -> Bool {
        guard let activeSessionId, !isOtherProfileRow(session) else { return false }
        if session.id == activeSessionId
            || session.storedSessionId == activeSessionId
            || session.alternateIds.contains(activeSessionId) { return true }
        // Hermes' own row knows only the stored id the create confirmed.
        guard let durable = conversationIdentityIndex.durableID(forRuntime: activeSessionId, profile: activeProfile) else {
            return false
        }
        return session.id == durable || session.storedSessionId == durable
    }

    /// The open chat made here in `project`'s folder (or, for Home, in no
    /// folder) that Hermes doesn't list yet, for the project's page.
    func newChatAwaitingListing(in project: ProjectSummary) -> (row: SessionSummary, awaiting: NewChatAwaitingListing)? {
        guard let awaiting = openNewChatAwaitingListing, awaiting.isIn(project),
              let row = sessions.first(where: awaiting.matches) else { return nil }
        return (row, awaiting)
    }

    /// The wait, while its chat is still the open one: a chat left behind
    /// no longer counts, even before the next catalog read ends the wait.
    var openNewChatAwaitingListing: NewChatAwaitingListing? {
        guard let awaiting = newChatAwaitingListing, awaiting.profile == activeProfile,
              let activeSessionId, awaiting.ids.contains(activeSessionId) else { return nil }
        return awaiting
    }

    func takeSessionListReadTicket() -> UInt64 {
        sessionListReadTicket &+= 1
        return sessionListReadTicket
    }

    /// Whether the read holding `ticket` may replace the list: only if no
    /// read that started after it has. A newer read that failed leaves the
    /// list to this one.
    func claimSessionListListing(_ ticket: UInt64) -> Bool {
        guard ticket > sessionListListedTicket else { return false }
        sessionListListedTicket = ticket
        return true
    }

    /// Hermes pushes no catalog changes, so returning to the list from a
    /// chat reads it again: a conversation started there is listed once its
    /// first turn is stored, and an older one shows its latest turn. One
    /// read at a time; a return during a read asks for one more after it.
    /// The list's own reads (ChatSync) pass `reportingFailure: false`: one
    /// nobody asked for puts up no banner.
    /// `readingChange`: the read is for a `sessions.changed`, which stays
    /// pending if the read fails, so the list keeps its 30 s backstop
    /// rather than the 300 s one for a change never signaled (issue 2294).
    func refreshCatalogAfterLeavingChat(reportingFailure: Bool = true, readingChange: Bool = false) {
        guard isConnected, client != nil || sessionCatalogLoaderOverride != nil else {
            if readingChange { catalogChangeSignal.noteChanged() }
            return
        }
        if reportingFailure { leaveCatalogRefreshReportsFailure = true }
        if readingChange { leaveCatalogRefreshReadsChange = true }
        guard leaveCatalogRefreshTask == nil else {
            leaveCatalogRefreshPending = true
            return
        }
        leaveCatalogRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                // A return asked for before this read starts is covered by it.
                self.leaveCatalogRefreshPending = false
                let reportsFailure = self.leaveCatalogRefreshReportsFailure
                self.leaveCatalogRefreshReportsFailure = false
                let readsChange = self.leaveCatalogRefreshReadsChange
                self.leaveCatalogRefreshReadsChange = false
                let listed = await self.loadSessions(
                    forceRefresh: false,
                    requiredViewportTransitionGeneration: nil,
                    reportsFailure: reportsFailure
                )
                if readsChange, !listed { self.catalogChangeSignal.noteChanged() }
            } while self.leaveCatalogRefreshPending && !Task.isCancelled
            self.leaveCatalogRefreshTask = nil
        }
    }

    /// Reads the newest catalog page and the cron rows over the cached
    /// catalog, keeping its full-history markers. The older pages follow
    /// only when the full history is due (every
    /// `SessionCatalogCache.fullHistoryRefreshInterval`), so a tab shown
    /// again and again doesn't walk all 25 pages each time (issue 1962).
    func refreshNewestSessionCatalogPage() async {
        // One visit's read at a time (the Tasks tab and the drawer's Cron
        // list both ask), without the pull's spinner.
        guard !isRefreshingSessionCatalog, !isReadingNewestCatalogPage else { return }
        isReadingNewestCatalogPage = true
        defer { isReadingNewestCatalogPage = false }
        let client = self.client
        let profile = activeProfile
        let dashboardID = activeDashboardID
        await loadSessions(
            forceRefresh: true,
            requiredViewportTransitionGeneration: nil,
            deferringOlderPages: true
        )
        guard let client, self.client === client, activeProfile == profile,
              sessionCatalogCache.shouldLoadFullHistory(forKey: "\(profile):exclude", forceRefresh: false) else { return }
        // An earlier visit's history walk still under way yields to this
        // visit's newer read, so this walk takes its place rather than a
        // second one running beside it.
        loadDeferredCatalogPages(after: client, profile: profile, dashboardID: dashboardID)
    }

    /// Replace this profile's in-memory catalog with Hermes' current data.
    /// Use this after database recovery or deletion outside Conduit.
    func refreshSessionCatalog() async {
        guard !isRefreshingSessionCatalog else { return }
        noteChatListInteraction()
        isRefreshingSessionCatalog = true
        defer { isRefreshingSessionCatalog = false }

        let sessionKey = "\(activeProfile):exclude"
        let cronKey = "\(activeProfile):cron"
        sessionCatalogCache.removeValue(forKey: sessionKey)
        sessionCatalogCache.removeValue(forKey: cronKey)
        archivedCallsReads.removeAll()
        // The newest page is what the pull is for: the spinner clears once
        // it lands, and the older pages are read after it, rather than all
        // 25 one after another first (issue 1724).
        let client = self.client
        let profile = activeProfile
        let dashboardID = activeDashboardID
        await loadSessions(
            forceRefresh: true,
            requiredViewportTransitionGeneration: nil,
            deferringOlderPages: true
        )
        if let client { loadDeferredCatalogPages(after: client, profile: profile, dashboardID: dashboardID) }
    }

    // MARK: - New Chat

    var showsPendingNewChat: Bool { pendingNewChat != nil }

    /// New Chat does something now: starts a chat, has one wait for the
    /// connection, or shows the one already on its way.
    var canTapNewChat: Bool {
        !isStartingNewChat && (canStartNewChatNow || canQueueNewChat || showsPendingNewChat)
    }

    /// New Chat can start a chat right now, with nothing to wait for. Do
    /// it's refusal on the Pulse screen goes by it too (PulseFeed.swift).
    var canStartNewChatNow: Bool {
        isConnected && !isConnecting && !isProfileSwitching && client != nil
            && turnState != .synchronizing && offlineChatPresentation == nil
    }

    /// A connection is coming that a New Chat can wait for. Not during a
    /// call, which refuses a waiting New Chat as it does a widget's, nor a
    /// profile switch, whose own chat comes first.
    private var canQueueNewChat: Bool {
        activeDashboardID != nil && !showLogin && !isVoiceCallInProgress && !isProfileSwitching
            && (isConnecting || isConnected)
    }

    /// The New Chat buttons. Connected, the chat starts as before. While
    /// Conduit connects or synchronizes, the new chat shows straight away
    /// and is created once Hermes can take it, the way a widget's New Chat
    /// waits (AppState+WidgetLaunch.swift).
    func startNewChat() {
        dismissSidebarDrawer()
        guard !showsPendingNewChat, !isStartingNewChat else { return }
        if canStartNewChatNow {
            isStartingNewChat = true
            Task {
                // Only the chat this New Chat created, while it's open.
                if let created = await createNewSessionMarkingStart(), activeSessionId == created {
                    focusNewChatComposer()
                }
            }
            return
        }
        guard canQueueNewChat, let dashboardID = activeDashboardID,
              let link = WidgetLaunchLink(
                  action: .newChat,
                  workspace: WidgetWorkspaceID(dashboardID: dashboardID, profile: activeProfile),
                  reference: nil
              ) else { return }
        // As for a widget's link: the automatic resume would otherwise take
        // the screen the new chat is on.
        cancelChatResumeRestoration()
        newChatLaunchStartedInApp = true
        widgetLaunchCoordinator.receive(link)
    }

    /// On a Mac the app's own New Chat opens ready to type. A phone or
    /// iPad keeps the keyboard down until the field is tapped, so it
    /// doesn't cover the new chat. Only the chat New Chat made takes the
    /// focus: a notification or another chat opened while it was created
    /// is left alone.
    func focusNewChatComposer() {
        guard newChatFocusesComposer, let created = shownChat.newChatOpenedSessionID,
              activeSessionId == created else { return }
        requestComposerFocus(on: created)
    }

    /// The open chat is one Conduit made here (by any of `sessionIDs`):
    /// New Chat's, or the one a sync opened because there was nothing to
    /// resume, and nothing has been said in it yet. Hermes keeps no row for such a
    /// chat until its first message, so when Hermes drops its runtime (a
    /// socket drop it reaped, a gateway restart) a Hermes before v0.22.0
    /// can never reopen it: every resume and send answers "session not
    /// found". Conduit puts a fresh chat in its place instead of that dead
    /// end (replaceLostEmptyNewChat).
    func openChatIsEmptyNewChat(_ sessionIDs: Set<String>) -> Bool {
        guard let created = shownChat.newChatOpenedSessionID, activeSessionId == created,
              sessionIDs.contains(created)
                || shownChat.newChatOpenedDurableSessionID.map(sessionIDs.contains) == true
        else { return false }
        // A slash command's answer (/btw's too) is the user's and lives only
        // here, so it counts as something in the chat; other notices don't.
        return messages.allSatisfy { $0.role == .system && !$0.id.hasPrefix("slash-") }
    }

    /// Opens a fresh chat in place of the empty one New Chat made here that
    /// Hermes no longer has, in the same folder, and drops the lost one's
    /// row. Nothing was said in it, so nothing is lost and nothing is
    /// shown: the user just has a chat that works. Returns whether the new
    /// chat opened. `token` is the reconciliation the failure came from.
    func replaceLostEmptyNewChat(
        lostSessionIDs: Set<String>,
        using client: HermesClient,
        profile: String,
        token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil,
        requiredViewportTransitionGeneration: UInt64? = nil,
        widgetLease: WidgetLaunchLease? = nil
    ) async -> Bool {
        let cwd = openNewChatAwaitingListing?.cwd
        // New Chat's chat is listed at once; one a sync opened because there
        // was nothing to resume waits for Hermes, and so does its stand-in.
        let listsBeforeHermes = openNewChatAwaitingListing != nil
        let lost = lostSessionIDs.union([shownChat.newChatOpenedSessionID, shownChat.newChatOpenedDurableSessionID].compactMap { $0 })
        lifecycleLog.notice("Empty new chat gone on Hermes (session not found) → a fresh one in its place")
        let created = await createAndReconcileSession(
            using: client,
            profile: profile,
            token: token,
            automaticWorkToken: automaticWorkToken,
            automaticSyncOperationID: automaticSyncOperationID,
            requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
            cwd: cwd,
            widgetLease: widgetLease,
            listsBeforeHermes: listsBeforeHermes
        )
        guard let created else { return false }
        // A fresh chat lost in its turn still answers for the first one's
        // draft; an unrelated replacement starts over.
        let earlierLost = shownChat.lostChatReplacement.flatMap { previous in
            previous.fresh.isDisjoint(with: lost) ? nil : previous.lost
        } ?? []
        shownChat.lostChatReplacement = (
            lost: earlierLost.union(lost),
            fresh: Set([created, shownChat.newChatOpenedDurableSessionID].compactMap { $0 })
        )
        handOverWhatWaitsOnLostChat(lost, to: created)
        sessions.removeAll { row in
            row.id != created && !row.alternateIds.contains(created)
                && (lost.contains(row.id) || !lost.isDisjoint(with: row.alternateIds)
                    || row.storedSessionId.map(lost.contains) == true)
        }
        return true
    }

    /// What an action left waiting on the lost chat (a screenshot, a
    /// prompt for the composer, its focus, a Classic voice conversation's
    /// filing) waits on the fresh chat instead: each is keyed by the chat's
    /// own id, and the lost chat's row is about to go.
    private func handOverWhatWaitsOnLostChat(_ lost: Set<String>, to fresh: String) {
        if pendingScreenshots.contains(where: { lost.contains($0.sessionID) }) {
            pendingScreenshots = pendingScreenshots.map { entry in
                guard lost.contains(entry.sessionID) else { return entry }
                return PendingScreenshot(sessionID: fresh, attachment: entry.attachment, dashboardID: entry.dashboardID, kind: entry.kind)
            }
        }
        if let key = composerPrefillDraftKey,
           lost.contains(where: { ComposerBar.composerDraftKey(for: $0, profile: activeProfile) == key }) {
            composerPrefillDraftKey = ComposerBar.composerDraftKey(for: fresh, profile: activeProfile)
        }
        if let request = composerFocusRequest, lost.contains(request.sessionID) {
            composerFocusRequest = ComposerFocusRequest(sessionID: fresh)
        }
        if let chat = classicVoiceChatToArchive, lost.contains(chat.chatID) {
            classicVoiceChatToArchive = (fresh, chat.profile, chat.dashboardID)
            // Filed under Voice as the lost chat was.
            tagVoiceSessions(Array(knownSessionIDs(for: fresh)), kind: .classic)
        }
        // A message typed while it reconnected goes into the fresh chat.
        if var pending = pendingComposerSend, !pending.isNewChat,
           !pending.chatSessionIDs.isDisjoint(with: lost) {
            pending.sessionIDs = Set([fresh, shownChat.newChatOpenedDurableSessionID].compactMap { $0 })
            pending.draftSessionID = shownChat.newChatOpenedDurableSessionID ?? fresh
            pendingComposerSend = pending
            // Its saved copy follows, so a relaunch brings it back here.
            _ = recordPendingComposerSendFile(pending)
        }
    }

    /// Returns the chat this call created and opened, nil when it opened
    /// none (refused, failed, or replaced by a newer navigation).
    @discardableResult
    func createNewSession(cwd: String? = nil, widgetLease: WidgetLaunchLease? = nil) async -> String? {
        guard !isProfileSwitching, isConnected, !isConnecting, let client else {
            if isProfileSwitching || isConnecting {
                errorMessage = AppLocalization.string("Wait for the workspace switch to finish before starting a conversation.")
            }
            return nil
        }
        // A new conversation takes the viewport back from an open room, the
        // same as a session open: otherwise the room stays on screen while
        // the new session is adopted invisibly behind it.
        if activeRoomSurface != nil {
            closeRoomSurface(handingTo: .newChat)
        }
        let transitionGeneration = beginExplicitChatViewportTransition(ownedBy: widgetLease)
        newSessionCreationsInFlight += 1
        defer {
            newSessionCreationsInFlight -= 1
            cancelChatViewportTransitionIfNoReplacement(generation: transitionGeneration)
        }
        guard widgetLease?.isCurrent != false else { return nil }
        let profile = activeProfile
        let previousSessionID = activeSessionId
        let previousTitle = activeSessionTitle
        cacheMessagePresentation()
        // The chat being left shows as it is now when it's opened again.
        recordOfflineChatCopy()
        keepBotChatCopy()
        keepLeftBackfilledTranscript()
        outgoingBotChatCopyOwner = nil
        let newTitle = AppLocalization.string("New conversation")
        activeSessionTitle = newTitle
        let previousTurnState = turnState
        let token = beginReconciliation()
        turnState = .synchronizing
        let created = await createAndReconcileSession(
            using: client,
            profile: profile,
            token: token,
            cwd: cwd,
            widgetLease: widgetLease,
            listsBeforeHermes: true
        )
        // An expired widget launch adopts nothing: the chat still open gets
        // its own turn state back unless something newer took it over.
        if widgetLease?.isCurrent == false, token == shownChat.reconciliationToken,
           activeSessionId == previousSessionID, turnState == .synchronizing {
            turnState = previousTurnState == .synchronizing ? .idle : previousTurnState
        }
        // No chat started: the one still open keeps its own title. A title
        // set for it meanwhile (not the placeholder) is left alone.
        if chatViewportTransitionIsCurrent(generation: transitionGeneration),
           activeSessionId == previousSessionID, activeSessionTitle == newTitle {
            activeSessionTitle = previousTitle
        }
        guard widgetLease?.isCurrent != false else { return nil }
        return created
    }

    /// Re-resume the currently visible conversation. This uses the same
    /// snapshot/event buffering path as foreground recovery, so a refresh
    /// during a turn cannot leave the composer with stale busy state.
    func refreshActiveSession() async {
        guard let client, let sessionId = activeSessionId, !isChatRefreshing else { return }
        let transitionGeneration = beginExplicitChatViewportTransition()
        markChatViewportReplacement()
        isChatRefreshing = true
        defer { isChatRefreshing = false }
        let previousMessages = messages

        // The open id is the runtime Hermes gave this chat when it was
        // resumed. Hermes drops runtimes (socket reconnects, idle reaping)
        // and only resumes by the stored id, so refresh addresses the stored
        // id whenever it is known; resuming the runtime id failed with
        // "session not found" and left the chat synchronizing (#446).
        // A Bot Chat's scope is read from the open id here (registry, roster
        // and saved reference, as reconcile does) and passed on, so it
        // doesn't depend on the stored id being registered too.
        let botProfile = botScopeProfile(forSessionIDs: [sessionId], workspaceProfile: activeProfile)
        let identity = captureConversationIdentity(for: sessionId, scopeProfile: botProfile)
        let token = beginReconciliation()
        let succeeded = await reconcile(
            sessionId: identity?.resumeTargetID ?? sessionId,
            using: client,
            token: token,
            acceptedSessionIDs: identity?.acceptedSessionIDs ?? [sessionId],
            conversationIdentity: identity,
            requiredViewportTransitionGeneration: transitionGeneration,
            conversationProfile: botProfile
        )
        if !succeeded || messages == previousMessages {
            finishChatViewportTransition(generation: transitionGeneration)
        }
        await loadSessions()
    }

    // MARK: - Read state (#454)

    /// Adopts a conversation as the active one and records it as the
    /// workspace's stored selection — WITH its kind, resolved from the bot
    /// registry and the conversation's own identities. Every adoption path
    /// (open, resume, rebind, restore) goes through here, so a Bot Chat can
    /// never be recorded as an ordinary conversation of whatever workspace
    /// happened to be active.
    func setActiveSessionState(
        id: String?,
        title: String? = nil
    ) {
        if activeSessionId != id {
            followLeftChatIfItsReplyRuns(leaving: activeSessionId, for: id)
            clearPendingDecisionRestorationGuard()
            resetResponseHapticTurn()
        }
        activeSessionId = id
        if let persistedID = ChatSessionPersistenceIdentity.canonicalID(
            for: id,
            identity: activeChatScrollSessionIdentity,
            catalog: sessions + cronSessions,
            activeProfile: activeProfile
        ) {
            chatResumeCoordinator.rememberSession(
                sessionReference(forPersistedID: persistedID, activeSessionID: id),
                for: activeProfile
            )
        } else {
            chatResumeCoordinator.rememberSession(nil, for: activeProfile)
        }
        if let title {
            activeSessionTitle = title
            activeSessionTitlesByProfile[activeProfile] = title
        }
        persistActiveSessionTitles()
        publishWidgetSnapshot()
    }

    func setActiveSessionTitle(_ title: String) {
        activeSessionTitle = title
        activeSessionTitlesByProfile[activeProfile] = title
        persistActiveSessionTitles()
        publishWidgetSnapshot()
    }

    func chatResumeLastSessionReference(for profile: String) -> SessionReference? {
        chatResumeCoordinator.lastSession(for: profile)
    }
}
