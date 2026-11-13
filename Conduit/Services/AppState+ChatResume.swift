//
//  AppState+ChatResume.swift
//  Conduit
//
//  Resuming a chat: the surface it returns to, the viewport it restores,
//  and the transport continuation after a reconnect. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Resuming a chat: return surface, viewport and transport

    func cancelScheduledReconnect() {
        reconnectTask?()
        reconnectTask = nil
        // A cycle already past its timer (awaiting the readiness probe)
        // sees this and stops.
        reconnectCycleGeneration &+= 1
        recoverySequence.clearQueuedReconnect()
    }

    func setChatResumeBehavior(_ behavior: ChatResumeBehavior) {
        chatResumeCoordinator.setBehavior(behavior)
        cancelOwnedAutomaticSyncOperation()
        activeAutomaticChatResumeWork = nil
        recoverySequence.preserveTransportAfterAutomaticIntentCancellation()
        chatResumeBehavior = chatResumeCoordinator.behavior
        chatResumeRestorationRequest = nil
    }

    /// True when any presented sheet owns the surface other than the sessions
    /// drawer itself. Explicit navigation and existing modals take precedence
    /// over the preferred return surface.
    var isModalSheetPresented: Bool {
        showModelPicker || showContextSheet || showWorkspaceSheet || showGatewaySheet
            || showAgentsSheet || showVoiceSheet || showQwenLiveSheet || showGeminiLiveSheet || showGPTLiveSheet || showGrokLiveSheet || showLocalLiveSheet || isSettingsSheetPresented
    }

    /// True when an explicit destination exists but has not been routed yet
    /// (a notification tap or voice intent recorded before the app was
    /// connected). Routing services own this fact; only the read lives here,
    /// mirroring how syncSession already defers to a pending notification
    /// target. Explicit navigation outranks the preferred return surface from
    /// the moment the destination exists, not just once routing starts.
    var hasPendingExplicitNavigation: Bool {
        PushNotificationService.shared.pendingTarget != nil
            || PendingVoiceIntentStore.shared.hasPendingIntent
            || widgetLaunchCoordinator.hasPendingRequest
    }

    /// Persisted separately from the resume store: this only changes which
    /// surface is presented first on a qualifying return, and deliberately
    /// issues no presentation request — the next qualifying return picks it up.
    func setChatReturnSurface(_ surface: ChatReturnSurface) {
        guard surface != chatReturnSurface else { return }
        chatReturnSurface = surface
        defaults.set(surface.rawValue, forKey: Self.chatReturnSurfaceKey)
    }

    /// "Open to" is the drawer shell's choice. V2 hides it (its tabs keep
    /// the chat that was showing), so a Sessions picked under the drawer
    /// shell no longer closes the chat on every return (#1559).
    var chatReturnSurfaceApplies: Bool {
        !(defaults.object(forKey: V2ShellPreference.key) as? Bool ?? V2ShellPreference.defaultValue)
    }

    /// Issues a one-shot preferred-return-surface request. Suppressed while
    /// an explicit destination is pending or being opened, or when a modal
    /// sheet already owns the surface; MainView re-checks at presentation
    /// time as a backstop.
    func requestPreferredReturnSurface() {
        guard chatReturnSurfaceApplies, chatReturnSurface == .sessions else { return }
        guard !hasPendingExplicitNavigation else { return }
        guard !isOpeningNotificationSession else { return }
        guard !isModalSheetPresented else { return }
        preferredReturnSurfaceRequest &+= 1
    }

    /// MainView's first authenticated appearance in this process is the
    /// cold-launch return. Mid-process re-entries (disconnect → sign back
    /// in) are not cold launches; they rely on the scene-phase path.
    func requestPreferredReturnSurfaceForColdLaunch() {
        guard !hasRequestedColdLaunchReturnSurface else { return }
        hasRequestedColdLaunchReturnSurface = true
        requestPreferredReturnSurface()
    }

    /// Auth teardown (sign-out) is not a qualifying return. Retire any
    /// outstanding preferred-return request at the boundary — claimed,
    /// unclaimed, or deferred — so a MainView recreated on the next sign-in
    /// can never present a stale request. The monotonic counter is left
    /// untouched; only the consumed watermark advances.
    func retireOutstandingPreferredReturnSurfaceRequests() {
        consumedReturnSurfaceRequest = max(consumedReturnSurfaceRequest, preferredReturnSurfaceRequest)
        deferredReturnSurfaceRequest = nil
    }

    /// Claims the pending preferred-return-surface request for presentation.
    /// Returns true exactly once per issued request — the watermark lives in
    /// AppState, so a MainView recreated after sign-out/sign-in can never
    /// re-present an already-claimed request.
    ///
    /// Consumption semantics: while explicit navigation is pending the claim
    /// defers without consuming; the next unblocked claim of the same request
    /// then drops it, because the explicit route fully won that qualifying
    /// return. In-flight notification opens, modals, and preference changes
    /// consume-and-drop immediately (established precedence losers).
    func claimPreferredReturnSurfacePresentation() -> Bool {
        let current = preferredReturnSurfaceRequest
        guard current > consumedReturnSurfaceRequest else { return false }
        if hasPendingExplicitNavigation {
            deferredReturnSurfaceRequest = current
            return false
        }
        defer { deferredReturnSurfaceRequest = nil }
        if deferredReturnSurfaceRequest == current {
            consumedReturnSurfaceRequest = current
            return false
        }
        consumedReturnSurfaceRequest = current
        guard chatReturnSurfaceApplies, chatReturnSurface == .sessions,
              !isOpeningNotificationSession,
              !isModalSheetPresented else { return false }
        return true
    }

    func recordChatViewport(
        _ snapshot: ChatScrollSnapshot,
        for key: ChatScrollSessionKey,
        holdWhile: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        chatResumeCoordinator.recordViewport(snapshot, for: key, holdWhile: holdWhile)
    }

    func installChatViewportSnapshotProvider(
        id: UUID,
        capture: @escaping @MainActor () -> ChatRenderedViewportSnapshot?
    ) {
        chatViewportSnapshotProvider = (id, capture)
    }

    func removeChatViewportSnapshotProvider(id: UUID) {
        guard chatViewportSnapshotProvider?.id == id else { return }
        chatViewportSnapshotProvider = nil
    }

    @discardableResult
    func beginExplicitChatViewportTransition(ownedBy widgetLease: WidgetLaunchLease? = nil) -> UInt64 {
        if widgetLease == nil { widgetLaunchCoordinator.supersede() }
        else if widgetLease?.isCurrent != true { return chatViewportTransitionGeneration }
        if let transition = chatViewportTransition {
            finishChatViewportTransition(generation: transition.generation)
        }
        // A newer navigation: the Bot Chat on its way stands down, and so
        // does a list tap's mark, joined or not yet open: what shows next
        // isn't covered by it. (A tap's own open sets its cover next.)
        botChatOnItsWay = nil
        botChatLatestMark = nil
        let renderedViewport = chatViewportSnapshotProvider?.capture()
        chatResumeCoordinator.captureViewportAndFreeze(
            renderedViewport?.snapshot,
            for: renderedViewport?.sessionKey
        )
        chatViewportTransitionGeneration &+= 1
        chatViewportTransition = ChatViewportTransition(
            generation: chatViewportTransitionGeneration
        )
        cancelChatResumeRestoration()
        // A newer navigation (a notification, a widget, a switch) takes over
        // from a chat still waiting in the saved list to open.
        if chatPickedFromSavedList != nil {
            chatPickedFromSavedList = nil
            if offlineChatPresentation?.isPickedChat == true { dismissOfflineChatPresentation() }
        }
        return chatViewportTransitionGeneration
    }

    /// Whether the navigation that began transition `generation` still owns
    /// the chat: no newer one has begun a transition. A transition that
    /// finished in place (the chat laid out its new transcript, or its
    /// restoration was given up) still does. On screen the chat lays out
    /// while an open still awaits its context refresh: that open finished,
    /// nothing superseded it (#449).
    func chatViewportTransitionIsCurrent(generation: UInt64) -> Bool {
        chatViewportTransitionGeneration == generation
    }

    func chatViewportTransitionIsCurrent(_ generation: UInt64?) -> Bool {
        generation.map { chatViewportTransitionIsCurrent(generation: $0) } ?? true
    }

    /// The chat's screen was popped (Back, the edge swipe, Close beside the
    /// list: V2Shell) while a Bot Chat was on its way: its open no longer
    /// owns the screen, so it stands down as a newer tap's would make it,
    /// and the chat open before keeps its viewport. A tab switch that only
    /// hides the screen leaves the open to land.
    func standDownBotChatOnItsWay() {
        guard let coming = botChatOnItsWay,
              chatViewportTransitionIsCurrent(generation: coming.transition) else { return }
        finishChatViewportTransition(generation: coming.transition)
        chatViewportTransitionGeneration &+= 1
        botChatOnItsWay = nil
    }

    func markChatViewportReplacement() {
        guard var transition = chatViewportTransition else { return }
        transition.hasReplacement = true
        chatViewportTransition = transition
    }

    func noteChatViewportTranscriptReplacement() {
        guard var transition = chatViewportTransition,
              transition.hasReplacement else { return }
        transition.expectedSessionKey = currentChatScrollSessionKey
        transition.expectedTranscriptRevision = chatTranscriptRevision
        chatViewportTransition = transition
    }

    func advanceChatViewportExpectedTranscriptRevisionIfNeeded() {
        guard var transition = chatViewportTransition,
              transition.hasReplacement,
              transition.expectedTranscriptRevision != nil,
              transition.expectedSessionKey.map({ expected in
                  currentChatScrollSessionKey.map {
                      activeChatScrollSessionIdentity.areEquivalent(expected, $0)
                  } == true
              }) == true else { return }
        transition.expectedTranscriptRevision = chatTranscriptRevision
        chatViewportTransition = transition
    }

    func cancelChatViewportTransitionIfNoReplacement(generation: UInt64) {
        guard let transition = chatViewportTransition,
              generation == transition.generation,
              !transition.hasReplacement else { return }
        finishChatViewportTransition(generation: generation)
    }

    func finishChatViewportTransition(generation: UInt64) {
        guard chatViewportTransition?.generation == generation else { return }
        chatViewportTransition = nil
        chatResumeCoordinator.unfreezeViewport()
    }

    func finishChatViewportTransitionIfNoTranscriptReplacement(
        generation: UInt64
    ) {
        guard let transition = chatViewportTransition,
              transition.generation == generation,
              transition.expectedTranscriptRevision == nil else { return }
        finishChatViewportTransition(generation: generation)
    }

    func chatViewportLayoutDidSettle(
        sessionKey: ChatScrollSessionKey,
        transitionGeneration: UInt64,
        transcriptRevision: UInt64,
        renderRevision: UInt64,
        receivedScopedPreference: Bool
    ) {
        guard let transition = chatViewportTransition,
              transitionGeneration == transition.generation,
              transition.hasReplacement,
              transition.expectedTranscriptRevision == transcriptRevision,
              receivedScopedPreference,
              transition.expectedSessionKey.map({ expected in
                  activeChatScrollSessionIdentity.areEquivalent(expected, sessionKey)
              }) == true,
              activeChatScrollSessionIdentity.areEquivalent(
                sessionKey,
                currentChatScrollSessionKey
              ) else { return }
        finishChatViewportTransition(generation: transitionGeneration)
    }

    private var currentChatScrollSessionKey: ChatScrollSessionKey? {
        if let canonical = activeChatScrollSessionIdentity.canonicalSessionKey {
            return canonical
        }
        guard let activeSessionId else { return nil }
        let fallback = ChatScrollSessionKey(profile: activeProfile, sessionID: activeSessionId)
        return fallback.isValid ? fallback : nil
    }

    func flushChatResumeViewport() {
        chatResumeCoordinator.flush()
    }

    func completeChatResumeRestoration(generation: UInt64) {
        chatResumeCoordinator.completeRestoration(generation: generation)
        if chatResumeRestorationRequest?.generation == generation,
           !chatResumeCoordinator.isCurrent(generation: generation) {
            chatResumeRestorationRequest = nil
        }
    }

    func abandonChatResumeRestoration(generation: UInt64) {
        let abandonedSessionKey = chatResumeRestorationRequest?.generation == generation
            ? chatResumeRestorationRequest?.sessionKey
            : nil
        chatResumeCoordinator.abandonRestoration(generation: generation)
        if chatResumeRestorationRequest?.generation == generation,
           !chatResumeCoordinator.isCurrent(generation: generation) {
            chatResumeRestorationRequest = nil
        }
        if let transition = chatViewportTransition,
           let abandonedSessionKey,
           transition.expectedSessionKey.map({ expected in
               activeChatScrollSessionIdentity.areEquivalent(expected, abandonedSessionKey)
           }) == true {
            finishChatViewportTransition(generation: transition.generation)
        }
    }

    func beginAutomaticChatResumeWork() -> ChatResumeAutomaticWorkToken {
        composerEditClaimedAutomaticWork = false
        if let activeAutomaticChatResumeWork,
           chatResumeCoordinator.isCurrent(activeAutomaticChatResumeWork) {
            return activeAutomaticChatResumeWork
        }
        let token = chatResumeCoordinator.beginAutomaticWork()
        activeAutomaticChatResumeWork = token
        return token
    }

    func automaticChatResumeWorkIsCurrent(
        _ token: ChatResumeAutomaticWorkToken?,
        syncOperationID: UUID? = nil,
        reconnectOperationID: UUID? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              token.map(chatResumeCoordinator.isCurrent) ?? true else { return false }
        if let syncOperationID,
           activeAutomaticSyncOperation?.id != syncOperationID {
            return false
        }
        if let reconnectOperationID,
           activeAutomaticReconnectOperation?.id != reconnectOperationID {
            return false
        }
        return true
    }

    func transportContinuation(
        purpose: ChatResumeSyncPurpose,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        automaticReconnectOperationID: UUID?
    ) -> ChatResumeTransportContinuation? {
        // Checked after every suspension in connect(with:),
        // reconnectForRetry, and the post-connect sync flow — the gate is
        // transport-wide, not reconnect-only: any chat-resume work that goes
        // inactive/backgrounded mid-flight must not keep publishing state
        // (watchdog: 0x8BADF00D). handleScenePhase(.active) re-establishes
        // the transport and syncs the session catalog on return. A connected
        // CarPlay Voice surface keeps the process foreground and admits the
        // work as well, as do the other surfaces canRunTransportRecovery
        // lists, a running shortcut send included.
        guard !Task.isCancelled, canRunTransportRecovery else { return nil }
        if let automaticReconnectOperationID,
           activeAutomaticReconnectOperation?.id != automaticReconnectOperationID {
            return nil
        }
        guard let automaticWorkToken else {
            return (purpose, nil, false)
        }
        if chatResumeCoordinator.isCurrent(automaticWorkToken) {
            return (purpose, automaticWorkToken, false)
        }
        guard purpose == .automaticReturn else { return nil }
        return (.preserveCurrent, nil, true)
    }

    func synchronizeTransportContinuation(
        purpose: ChatResumeSyncPurpose,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        automaticReconnectOperationID: UUID?,
        client: HermesClient,
        profile: String
    ) async -> ChatResumeTransportContinuation? {
        guard transportContinuation(
                purpose: purpose,
                automaticWorkToken: automaticWorkToken,
                automaticReconnectOperationID: automaticReconnectOperationID
              ) != nil,
              let activeClient = self.client,
              activeClient === client,
              activeProfile == profile else { return nil }
        let viewportTransitionGeneration = chatViewportTransitionGeneration
        var publishedCatalog = false
        let outcome = await performSyncSession(
            purpose: purpose,
            using: nil,
            automaticWorkToken: automaticWorkToken,
            onCatalogPublished: { publishedCatalog = true }
        )
        // Before the checkpoint below: a sync that published the catalog has
        // done the bootstrap's work even if the scene deactivates right after.
        settleOwedPostConnectBootstrap(
            for: client,
            publishedCatalog: publishedCatalog,
            automaticWorkToken: automaticWorkToken
        )
        guard let continuation = transportContinuation(
                purpose: purpose,
                automaticWorkToken: automaticWorkToken,
                automaticReconnectOperationID: automaticReconnectOperationID
              ),
              let activeClient = self.client,
              activeClient === client,
              activeProfile == profile else { return nil }
        guard outcome == .automaticIntentInvalidated,
              continuation.handedOffAutomaticIntent,
              purpose == .automaticReturn,
              chatViewportTransition == nil,
              chatViewportTransitionGeneration == viewportTransitionGeneration else {
            return continuation
        }

        var preservedPublishedCatalog = false
        _ = await performSyncSession(
            purpose: .preserveCurrent,
            using: nil,
            automaticWorkToken: nil,
            onCatalogPublished: { preservedPublishedCatalog = true }
        )
        settleOwedPostConnectBootstrap(
            for: client,
            publishedCatalog: preservedPublishedCatalog,
            automaticWorkToken: nil
        )
        guard let preservedContinuation = transportContinuation(
                purpose: .preserveCurrent,
                automaticWorkToken: nil,
                automaticReconnectOperationID: automaticReconnectOperationID
              ),
              let activeClient = self.client,
              activeClient === client,
              activeProfile == profile else { return nil }
        return (
            preservedContinuation.purpose,
            preservedContinuation.automaticWorkToken,
            true
        )
    }

    /// Tracks a continuation handoff (`.automaticReturn` → `.preserveCurrent`)
    /// on the owed bootstrap of the same client; never upgrades.
    func followOwedPostConnectBootstrapPurpose(
        _ purpose: ChatResumeSyncPurpose,
        for client: HermesClient
    ) {
        guard purpose == .preserveCurrent,
              owedPostConnectBootstrap?.client === client else { return }
        owedPostConnectBootstrap?.purpose = .preserveCurrent
    }

    /// Settles the owed bootstrap of `client` after a sync attempt made on
    /// its behalf. The bootstrap is done once a sync has published the
    /// catalog — whatever outcome it then reported, and even if a later
    /// continuation checkpoint fails — so the next `.active` never repeats
    /// the catalog load and `session.resume`. Until then it stays owed, but
    /// once the automatic intent it carried is gone (the user took
    /// ownership, a notification destination won) it is owed as
    /// `.preserveCurrent`, never as a replayed `.automaticReturn`.
    func settleOwedPostConnectBootstrap(
        for client: HermesClient,
        publishedCatalog: Bool,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) {
        guard owedPostConnectBootstrap?.client === client else { return }
        if publishedCatalog {
            owedPostConnectBootstrap = nil
        } else if owedPostConnectBootstrap?.purpose == .automaticReturn,
                  let automaticWorkToken,
                  !chatResumeCoordinator.isCurrent(automaticWorkToken) {
            owedPostConnectBootstrap?.purpose = .preserveCurrent
        }
    }

    func cancelChatResumeRestoration() {
        // Cancelling the automatic intent an interrupted connect was carrying
        // is the same handoff that connect's own continuation would have
        // observed: the owed bootstrap then preserves the visible
        // conversation instead of replaying the automatic return.
        if let owed = owedPostConnectBootstrap,
           owed.purpose == .automaticReturn,
           let token = owed.automaticWorkToken,
           chatResumeCoordinator.isCurrent(token) {
            owedPostConnectBootstrap?.purpose = .preserveCurrent
        }
        chatResumeCoordinator.cancelViewportRestoration(
            keepViewportFrozen: chatViewportTransition != nil
        )
        cancelOwnedAutomaticSyncOperation()
        activeAutomaticChatResumeWork = nil
        recoverySequence.preserveTransportAfterAutomaticIntentCancellation()
        // Every chat drag lands here; republishing an already-nil request
        // would re-evaluate the whole chat view for nothing.
        if chatResumeRestorationRequest != nil {
            chatResumeRestorationRequest = nil
        }
    }
}

extension AppState {
    /// Whether any automatic-return work is outstanding that could still
    /// replace the active session. `activeAutomaticChatResumeWork` alone is
    /// not evidence: a completed foreground refresh leaves its token behind,
    /// and nothing ever re-reads it once the scene attempt and its operations
    /// have finished.
    var automaticChatResumeWorkMayStillSelectSession: Bool {
        scenePhaseAttemptID != nil
            || reconnectTask != nil
            || activeAutomaticSyncOperation != nil
            || activeAutomaticReconnectOperation != nil
            || recoverySequence.currentPurpose == .automaticReturn
            || recoverySequence.queuedReconnectPurpose == .automaticReturn
            || chatResumeRestorationRequest != nil
    }

    /// Connected, but not settled: a reconnect (which keeps `isConnected`
    /// while it runs), the foreground refresh, an automatic sync or the
    /// connect's chat sync may still replace the chat on screen, and the
    /// chat's turn state isn't known until they finish. Ask Hermes About
    /// Screen waits this out: a screenshot placed earlier lands on a chat
    /// that is then replaced, and its voice start finds a turn in sync and
    /// falls back to the keyboard. Some of this isn't published, so a
    /// waiter re-checks it on a timer.
    ///
    /// Every part here is in-flight work that ends by itself: the scene
    /// attempt (its health check times out), a reconnect timer (at most
    /// 5 s), the automatic operations (finished with their sync or
    /// reconnect) and the transitional turn states. A latch must never be
    /// added, or a screenshot waits forever: that is why the recovery
    /// sequence's purposes (kept until `complete()` or `cancel()`) and
    /// `chatResumeRestorationRequest` (kept until the chat restores its
    /// scroll), both in `automaticChatResumeWorkMayStillSelectSession`,
    /// are left out.
    var isSettlingConnection: Bool {
        guard isConnected else { return false }
        return isConnecting
            || isProfileSwitching
            || turnState == .synchronizing
            || turnState == .reconnecting
            || scenePhaseAttemptID != nil
            || reconnectTask != nil
            || activeAutomaticSyncOperation != nil
            || activeAutomaticReconnectOperation != nil
    }

    func cancelChatResumeTransportRecovery() {
        cancelExplicitSessionOpen()
        cancelScheduledReconnect()
        chatResumeCoordinator.cancelViewportRestoration(
            keepViewportFrozen: chatViewportTransition != nil
        )
        cancelOwnedAutomaticOperations()
        activeAutomaticChatResumeWork = nil
        recoverySequence.cancel()
        chatResumeRestorationRequest = nil
    }

    func beginAutomaticSyncOperation(
        for token: ChatResumeAutomaticWorkToken?
    ) -> UUID? {
        guard token != nil else { return nil }
        let operation = AutomaticSyncOperation(
            id: UUID(),
            previousTurnState: activeAutomaticSyncOperation?.previousTurnState
                ?? turnState
        )
        activeAutomaticSyncOperation = operation
        return operation.id
    }

    func finishAutomaticSyncOperation(id: UUID?, restoringBaseline: Bool = false) {
        guard let id, activeAutomaticSyncOperation?.id == id else { return }
        if restoringBaseline,
           let operation = activeAutomaticSyncOperation,
           turnState == .synchronizing {
            turnState = operation.previousTurnState
        }
        activeAutomaticSyncOperation = nil
    }

    func beginAutomaticReconnectOperation(
        for token: ChatResumeAutomaticWorkToken?
    ) -> UUID? {
        guard token != nil else { return nil }
        let operation = AutomaticReconnectOperation(
            id: UUID(),
            previousIsConnecting: activeAutomaticReconnectOperation?.previousIsConnecting
                ?? isConnecting,
            previousTurnState: activeAutomaticReconnectOperation?.previousTurnState
                ?? turnState
        )
        activeAutomaticReconnectOperation = operation
        return operation.id
    }

    func finishAutomaticReconnectOperation(id: UUID?, restoringBaseline: Bool = false) {
        guard let id, activeAutomaticReconnectOperation?.id == id else { return }
        if restoringBaseline, let operation = activeAutomaticReconnectOperation {
            if isConnecting {
                isConnecting = operation.previousIsConnecting
            }
            if turnState == .reconnecting {
                turnState = operation.previousTurnState
            }
        }
        activeAutomaticReconnectOperation = nil
    }

    func cancelOwnedAutomaticOperations() {
        cancelOwnedAutomaticSyncOperation()
        cancelOwnedAutomaticReconnectOperation()
    }

    func cancelOwnedAutomaticSyncOperation() {
        if let operation = activeAutomaticSyncOperation {
            if turnState == .synchronizing {
                turnState = operation.previousTurnState
            }
            activeAutomaticSyncOperation = nil
        }
    }

    private func cancelOwnedAutomaticReconnectOperation() {
        if let operation = activeAutomaticReconnectOperation {
            if isConnecting {
                isConnecting = operation.previousIsConnecting
            }
            if turnState == .reconnecting {
                turnState = operation.previousTurnState
            }
            activeAutomaticReconnectOperation = nil
        }
    }

    @discardableResult
    func acceptChatResumeConversationReplacement(
        _ replacement: ChatResumeConversationReplacement
    ) -> UInt64 {
        beginExplicitChatViewportTransition()
    }

    @discardableResult
    func prepareChatResumeForConnection(to baseURL: String) -> Bool {
        prepareChatResumeForConnection(to: baseURL, dashboardID: nil)
    }

    /// The authoritative server-change boundary. The dashboard UUID is the
    /// server identity when the target is a saved dashboard: URL spellings
    /// can collide across servers and a dashboard's address can move, while
    /// the UUID is stable. Same-dashboard reconnects (same UUID) are never
    /// treated as a server switch; every identity change retires the
    /// outgoing server's runtime ownership exactly once, through this one
    /// state machine.
    @discardableResult
    func prepareChatResumeForConnection(to baseURL: String, dashboardID: UUID?) -> Bool {
        let identity: String
        if let dashboardID {
            identity = dashboardID.uuidString
        } else if let normalized = Self.normalizedChatResumeServerIdentity(baseURL) {
            identity = normalized
        } else {
            // An unparseable, dashboard-less URL is the caller's mistake; the
            // stored identity must not be overwritten with garbage.
            return false
        }
        let previousIdentity = defaults.string(forKey: Self.chatResumeServerIdentityKey)
            .flatMap(Self.normalizedStoredChatResumeIdentity)
            ?? initialChatResumeServerIdentity
        defaults.set(identity, forKey: Self.chatResumeServerIdentityKey)
        // A follow-up's turn may have ended while disconnected: its reply
        // isn't watched for across a reconnect, so none is tagged wrongly.
        stopWaitingForPredictiveFollowUp()
        guard let previousIdentity, previousIdentity != identity else { return false }

        retireSpeechOperationsForServerReplacement(previousIdentity: previousIdentity, identity: identity)
        owedPostConnectBootstrap = nil
        chatResumeCoordinator.clearResumeState()
        cancelOwnedAutomaticOperations()
        activeAutomaticChatResumeWork = nil
        cancelScheduledReconnect()
        recoverySequence.cancel()
        chatResumeRestorationRequest = nil
        invalidateReconciliation()
        invalidateServerCompactionState()
        sessionCatalogCache.removeAll()
        archivedCallsReads.removeAll()
        sessionCatalogLoadState.reset()
        sessions = []
        cronSessions = []
        archivedSessions = []
        projects = []
        supportsProjects = false
        projectsLoading = false
        projectsLoadFailed = false
        profiles = []
        clearPendingDecisionRestorationGuard()
        activeSessionId = nil
        activeSessionTitle = AppLocalization.string("New conversation")
        keepDelegateAgents(of: [])
        messages = []
        clearAuthorityQueueState()
        persistedTranscriptWindow = nil
        resetTranscriptLifecycleEvidence()
        clearStreamingText()
        resetReasoningTurn()
        activeSessionTitlesByProfile = [:]
        pinnedSessionIDsByProfile = [:]
        pinnedSessionIDs = []
        resetHostPins()
        sessionStars = SessionStars()
        defaults.removeObject(forKey: SessionStars.storageKey)
        pinnedChatOrder = PinnedChatOrder()
        defaults.removeObject(forKey: PinnedChatOrder.storageKey)
        defaults.removeObject(forKey: PinnedChatOrder.mixedStorageKey)
        botOrder = BotOrder()
        defaults.removeObject(forKey: BotOrder.storageKey)
        groupRoomOrder = BotOrder.rooms
        defaults.removeObject(forKey: BotOrder.roomStorageKey)
        allProfilesCatalogTask?.cancel()
        allProfilesCatalogTask = nil
        allProfilesCatalog = AllProfilesCatalog()
        clearPinnedReplies()
        voiceJobSessionIDsByProfile = [:]
        defaults.removeObject(forKey: activeSessionTitlesByProfileKey)
        defaults.removeObject(forKey: pinnedSessionIDsByProfileKey)
        defaults.removeObject(forKey: voiceJobSessionIDsByProfileKey)
        defaults.removeObject(forKey: reviewSummaryCacheKey)
        defaults.removeObject(forKey: knownProfilesKey)
        defaults.removeObject(forKey: knownProfileNamesKey)
        // Names are kept per dashboard: the selected one's come back, and
        // the outgoing server's never show here.
        profileHermesNames = profileAppearanceStore.loadHermesNames(dashboardID: activeDashboardID)
        profileBotTitles = profileAppearanceStore.loadBotTitles(dashboardID: activeDashboardID)
        refreshSiriProfileShortcuts()
        clearSessionPresentationCache()
        // Guesses name sessions, and a new server's ids can repeat the old one's.
        forgetPredictiveState()
        // Saved chats are kept apart per dashboard and stay for the next
        // visit there: only removing the dashboard, signing out of it or
        // Settings' Delete Saved Chats wipes them. What of them is in memory
        // belongs to the outgoing server.
        leaveSavedChats(dashboardID: nil)
        // Identity evidence and per-session overrides are keyed only by
        // (profile, session id); without this clear they would leak between
        // Hermes servers whose strings collide. Same boundary that clears
        // the resume store, titles, pins, and review cache.
        conversationIdentityIndex.removeAll()
        liveSessionStatusIndex = SessionLiveStatusIndex()
        liveSessionStatusProfile = nil
        otherProfilesLiveStatus = OtherProfilesLiveStatus()
        liveSessionStatusAvailable = true
        resetDesktopViews(host: nil)
        sessionYoloStore.clearAllOverrides()
        // Bot Mode state is per-server: the roster, the capability phase, and
        // the in-memory bot-chat profile registry all describe the outgoing
        // gateway. The next connection re-probes them before it decides which
        // conversation this workspace was in.
        invalidateBotModeState()
        // Drafts are keyed by (profile, session id) only: they must not
        // leak into another server whose strings collide.
        composerDraftStore.removeAll()
        return true
    }
}
