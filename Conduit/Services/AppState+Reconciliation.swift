//
//  AppState+Reconciliation.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Authoritative reconciliation.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Authoritative reconciliation

    /// The only entry point for cold start, foreground refresh, reconnect, and
    /// manual refresh. It never derives liveness from transcript shape.
    func syncSession() async {
        cancelChatResumeRestoration()
        await syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
    }

    func syncSession(
        purpose: ChatResumeSyncPurpose,
        using existingReconciliationToken: UUID?,
        automaticWorkToken existingAutomaticWorkToken: ChatResumeAutomaticWorkToken?,
        requiredViewportTransitionGeneration: UInt64? = nil,
        historySourceUnavailable: Bool = false
    ) async {
        _ = await performSyncSession(
            purpose: purpose,
            using: existingReconciliationToken,
            automaticWorkToken: existingAutomaticWorkToken,
            requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
            historySourceUnavailable: historySourceUnavailable
        )
    }

    func performSyncSession(
        purpose: ChatResumeSyncPurpose,
        using existingReconciliationToken: UUID?,
        automaticWorkToken existingAutomaticWorkToken: ChatResumeAutomaticWorkToken?,
        requiredViewportTransitionGeneration: UInt64? = nil,
        historySourceUnavailable: Bool = false,
        onCatalogPublished: () -> Void = {}
    ) async -> ChatResumeSyncExecutionOutcome {
        guard chatViewportTransitionIsCurrent(
            requiredViewportTransitionGeneration
        ) else { return .superseded }
        let purpose = beginChatResumeRecovery(purpose: purpose)
        let automaticWorkToken = purpose == .automaticReturn
            ? (existingAutomaticWorkToken ?? beginAutomaticChatResumeWork())
            : nil
        guard automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
            return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
        }
        let automaticOperationID = beginAutomaticSyncOperation(for: automaticWorkToken)
        defer {
            finishAutomaticSyncOperation(
                id: automaticOperationID,
                restoringBaseline: !automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                )
            )
        }
        if let existingReconciliationToken,
           !claimReconciliation(
            existingReconciliationToken,
            automaticSyncOperationID: automaticOperationID
           ) {
            return .superseded
        }
        guard let client else {
            if let existingReconciliationToken {
                settleReconciliation(
                    existingReconciliationToken,
                    automaticSyncOperationID: automaticOperationID
                )
            }
            return .completed
        }
        // A notification destination always wins over automatic restoration of
        // the previously active/newest session. Check both before and after
        // the catalog fetch because a notification tap can arrive mid-launch.
        guard PushNotificationService.shared.pendingTarget == nil else {
            cancelChatResumeRestoration()
            if let existingReconciliationToken {
                settleReconciliation(
                    existingReconciliationToken,
                    automaticSyncOperationID: automaticOperationID
                )
            }
            return .superseded
        }
        let token = existingReconciliationToken ?? beginReconciliation()
        guard claimReconciliation(
            token,
            automaticSyncOperationID: automaticOperationID
        ) else { return .superseded }
        let profile = activeProfile
        let dashboardID = activeDashboardID
        let retainedActiveTurn = activeTurnCatalogSession()
        // Capture the selected conversation's complete identity — durable id,
        // runtime id, and every positively confirmed alias — BEFORE replacing
        // the published catalog. A preserve-current recovery is allowed to
        // outlive a transient catalog omission; it must not fall back to
        // another chat, and it must not rediscover its alias set from the
        // replacement catalog that just forgot it.
        let preservedIdentity = purpose == .preserveCurrent
            ? captureConversationIdentity(for: activeSessionId)
            : nil
        let turnStateBeforeSync = turnState
        turnState = .synchronizing
        noteConnectionStep("Chat sync started")

        // Set while this sync's catalog read is in flight: a failure there
        // is news only if no list read that started later has listed.
        var pendingCatalogReadTicket: UInt64?
        do {
            // This intentionally mirrors the proven React Native startup
            // sequence: discover the live gateway's current sessions first,
            // then resume the newest chat. A persisted runtime id can belong
            // to a process that no longer exists after a relaunch.
            let readTicket = takeSessionListReadTicket()
            pendingCatalogReadTicket = readTicket
            let catalogLoad = try await profileCatalog(using: client, deferringOlderPages: true)
            pendingCatalogReadTicket = nil
            // The rest of a due full read runs once this sync is over, so
            // the drawer still fills in without holding up the chat. Only a
            // sync that reached its list schedules it (a newer list read may
            // have listed in its place): an abandoned one leaves the read to
            // the sync that replaced it.
            var publishedCatalog = false
            defer {
                if catalogLoad.olderPagesDeferred, publishedCatalog {
                    loadDeferredCatalogPages(after: client, profile: profile, dashboardID: dashboardID)
                }
            }
            let loadedSessions = catalogLoad.sessions
            let awaitingListing = newChatRowAwaitingListing(loaded: loadedSessions)
            let allSessions = uniqueSessions(
                [retainedActiveTurn, awaitingListing].compactMap { $0 } + loadedSessions
            )
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  dashboardID == activeDashboardID,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            guard PushNotificationService.shared.pendingTarget == nil else {
                cancelChatResumeRestoration()
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return .superseded
            }
            guard automaticChatResumeWorkIsCurrent(
                automaticWorkToken,
                syncOperationID: automaticOperationID
            ), chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration) else {
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            // A list read that started after this sync's read already
            // listed newer rows; the sync still resumes its chat.
            if claimSessionListListing(readTicket) {
                let listedSessions = allSessions.filter { $0.source != .cron }
                let listedCron = allSessions.filter { $0.source == .cron }
                // A project's page beside the chat follows this list too.
                if listedSessions != sessions || listedCron != cronSessions { chatListCatalogGeneration &+= 1 }
                sessions = listedSessions
                cronSessions = listedCron
                settleNewChatAwaitingListing(loaded: loadedSessions)
                savedChatListReplacedByLiveList(
                    newestPageOnly: catalogLoad.olderPagesDeferred,
                    dashboardID: dashboardID
                )
            }
            sessionCatalogLoadState.markLoaded(SessionCatalogOwner(dashboardID: dashboardID, profile: profile))
            if let dashboardID {
                widgetSettledCatalogOwner = WidgetWorkspaceID(dashboardID: dashboardID, profile: profile)
                widgetLaunchCoordinator.readinessChanged()
            }
            refreshVoiceSessionTags()
            // Reported per call: whether THIS sync reached the catalog is
            // independent of its outcome, which is also `.completed` for a
            // failed catalog load and `.superseded` after a published one.
            onCatalogPublished()
            publishedCatalog = true
            // Labeled rows are positive identity evidence; commit them so
            // notification routing survives a later catalog omission.
            conversationIdentityIndex.recordCatalogIdentity(allSessions, profile: profile)
            publishWidgetSnapshot()
            // A chat tapped in the saved list before this list landed wins
            // over the automatic resume, the same way a notification does.
            if let pickedSessionID = takeChatPickedFromSavedList(dashboardID: dashboardID, profile: profile) {
                cancelChatResumeRestoration()
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                openChatPickedFromSavedList(pickedSessionID)
                return .superseded
            }

            guard automaticChatResumeWorkIsCurrent(
                automaticWorkToken,
                syncOperationID: automaticOperationID
            ), chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration) else {
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            // A canonical Bot Chat is reserved presentation state reachable
            // only through the Bots roster: it must never be chosen as this
            // workspace's ordinary resume target. Selection-only — the
            // published catalog above stays raw. Two independent signals:
            // the reserved title (which needs no roster, so a cold launch is
            // covered) and positive bot ownership (the roster's canonical
            // registries plus this process's bot-chat registry, which cover a
            // row whose title no longer names the canonical chat).
            // The saved reference's KIND decides how it may be restored. A Bot
            // Mode conversation is not this workspace's conversation: seeding
            // its bot scope first makes the resume below address the BOT's
            // profile store, carry the bot's label, and never claim the
            // dashboard profile's persisted title — while the reserved-title
            // and ownership filters keep the ordinary selection from ever
            // adopting it. Under "jump to latest activity" the user opted out
            // of "where I left off" entirely, so Bot Mode is never entered
            // automatically.
            // The stored reference's kind (with positive evidence healing a
            // legacy id-only record) plus any identity the catalog links to it
            // — a compaction or runtime rebind can leave the bot evidence on
            // an ALIAS of the stored id, so the union is consulted here just
            // as it is when recording.
            var storedReference = chatResumeCoordinator.lastSession(for: profile)
            // Absence evidence decides something only for an UNVERIFIED
            // reference, and it must be evidence from NOW when it does: the
            // roster is verified per connection, so a bot registered mid-session
            // would be missing from it and a legacy pointer would look resolved.
            // Re-verify here in exactly that case (a legacy pointer keeps the
            // cost until it is rewritten as verified; a typed reference — the
            // normal case — never pays it, because absence never decides for it).
            // Only a PREVIOUS ANSWER can be stale. `.idle`/`.loading` have none,
            // and the connect path has already awaited its probe before this runs,
            // so re-verifying here is always a re-check of something — never a
            // fresh RPC on a path that has not probed yet (which would put a bare
            // network round trip in front of every resume in a context that only
            // wants to know whether its one answer still holds).
            let rosterAnswerMayBeStale: Bool = {
                switch botModePhase {
                case .available, .failed: return true
                case .idle, .loading, .gatewayUnsupported: return false
                }
            }()
            if storedReference?.isUnverified == true, rosterAnswerMayBeStale {
                await refreshBotRoster()
                guard automaticChatResumeWorkIsCurrent(
                        automaticWorkToken,
                        syncOperationID: automaticOperationID
                      ),
                      chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                      token == reconciliationToken,
                      profile == activeProfile,
                      let activeClient = self.client,
                      activeClient === client else {
                    settleReconciliation(token, automaticSyncOperationID: automaticOperationID)
                    return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
                }
                storedReference = chatResumeCoordinator.lastSession(for: profile)
            }
            // Bot evidence is READ HERE, after any refresh above: `botOwnership`
            // is a snapshot, and the re-verification can discover a bot the
            // earlier snapshot did not know — healing and the candidate filter
            // must both see that answer, not the one that prompted the refresh.
            let ownership = botOwnership
            // A row this run already found dead (`session.resume` 4007) is
            // not offered again, however long the catalog keeps listing it.
            let deadRowIDs = deadResumeRowIDs[
                Self.deadResumeRowKey(dashboardID: dashboardID, profile: profile)
            ] ?? []
            let resumeCandidates = BotChatHygiene.ordinaryResumeCandidates(
                allSessions,
                roster: botRoster,
                botOwnedSessionIDs: ownership.botOwnedIDs
            ).filter { !Self.resumeRow($0, isAmong: deadRowIDs) }
            let storedReferenceAliases = Self.aliasesForStoredReference(
                storedReference,
                catalog: allSessions
            )
            let healedReference = ownership.referenceIfBot(
                storedReference,
                aliases: storedReferenceAliases
            )
            let botSavedReference = purpose == .automaticReturn
                && chatResumeCoordinator.behavior == .continueWhereLeftOff
                ? healedReference
                : nil
            if let botSavedReference {
                registerBotSessionReference(botSavedReference)
                applyBotSessionLabel(botSavedReference)
            }
            // A cold launch can receive a catalog before Hermes has indexed
            // the just-created/in-flight conversation. When Continue Where I
            // Left Off names a saved identity that is absent from that
            // catalog, resume it directly rather than letting the catalog's
            // first row replace the user's conversation. An id the client
            // positively attributes to Bot Mode — under ANY of its identities
            // — is exempt: it is restored through the Bot Mode path above,
            // never as an ordinary conversation of this workspace.
            // An UNTYPED (v1-migrated) reference is not authority to resume a
            // catalog-absent conversation while bot evidence is unavailable:
            // it carries no kind, and a bot chat written there by a build that
            // could not record one would be resumed as an ordinary
            // conversation of this workspace. Our own v2 writes carry the kind,
            // so they keep the escape hatch unconditionally — and a gateway
            // that cannot host Bot Mode cannot hold a bot chat either.
            let savedReferenceIsAuthoritative = !(storedReference?.isUnverified ?? false)
                || botEvidenceIsAvailable
            // Before the saved id can be resumed directly (#1810).
            dropSavedPulseChat(profile: profile, purpose: purpose, among: allSessions)
            let missingSavedSessionID = botSavedReference?.sessionID
                ?? (savedReferenceIsAuthoritative
                    ? chatResumeCoordinator.missingSavedSessionID(
                        in: allSessions,
                        profile: profile,
                        purpose: purpose,
                        botOwnedSessionIDs: ownership.botOwnedIDs,
                        savedSessionAliases: storedReferenceAliases
                      )
                    : nil)
            if let missingSavedSessionID {
                chatResumeRestorationRequest = nil
                chatResumeCoordinator.prepareDirectTarget(
                    sessionID: missingSavedSessionID,
                    profile: profile,
                    purpose: purpose
                )
            }
            let target = missingSavedSessionID == nil
                ? selectChatResumeTarget(
                    in: resumeCandidates,
                    profile: profile,
                    purpose: purpose,
                    currentSessionID: activeSessionId,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticOperationID
                )
                : nil
            if let target {
                // A freshly selected catalog row positively establishes the
                // target's identity: the row's ids are the accepted set, and
                // its stored id (when labeled) is the durable one. For a
                // preserve-current hit, keep the PRE-captured aliases too —
                // the refreshed row can keep the conversation while dropping
                // a runtime alias, and in-flight events for that alias must
                // stay associated with this reconciliation. The union is
                // durably anchored: a row sharing only a colliding runtime
                // alias must not absorb the selected conversation's aliases.
                let targetIDs = Set([target.id] + target.alternateIds)
                var acceptedTargetIDs = targetIDs
                if let preservedIdentity,
                   !targetIDs.isDisjoint(with: preservedIdentity.acceptedSessionIDs) {
                    let targetStored = target.storedSessionId
                    let durablyAnchored = targetStored == nil
                        || preservedIdentity.durableSessionID == nil
                        || targetStored == preservedIdentity.durableSessionID
                        || targetStored.map { preservedIdentity.acceptedSessionIDs.contains($0) } ?? false
                    if durablyAnchored {
                        acceptedTargetIDs.formUnion(preservedIdentity.acceptedSessionIDs)
                    }
                }
                let targetIdentity = ConversationIdentity(
                    profile: profile,
                    durableSessionID: target.storedSessionId ?? target.id,
                    runtimeSessionID: target.storedSessionId != nil ? target.id : nil,
                    acceptedSessionIDs: acceptedTargetIDs
                )
                var succeeded = await reconcile(
                    sessionId: target.id,
                    using: client,
                    token: token,
                    acceptedSessionIDs: acceptedTargetIDs,
                    conversationIdentity: targetIdentity,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                    historySourceUnavailable: historySourceUnavailable
                )
                if !succeeded, purpose == .automaticReturn {
                    succeeded = await resumeByStoredIDAfterNotFound(
                        target,
                        acceptedSessionIDs: acceptedTargetIDs,
                        conversationIdentity: targetIdentity,
                        using: client,
                        profile: profile,
                        token: token,
                        automaticWorkToken: automaticWorkToken,
                        automaticSyncOperationID: automaticOperationID,
                        requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                        historySourceUnavailable: historySourceUnavailable
                    )
                }
                if !succeeded,
                   purpose == .automaticReturn,
                   reconciliationSessionWasNotFound,
                   resumeRecoveryOwnsViewport(
                    token: token,
                    profile: profile,
                    client: client,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
                   ) {
                    // The catalog LISTS a row `session.resume` answers 4007
                    // for: the same authoritative evidence the missing-saved-
                    // session branch below recovers from, which only runs when
                    // the row is absent from the catalog. Retrying it would
                    // loop forever behind the read-only saved copy ("Failed
                    // to restore this conversation"); retire it instead.
                    return await retireUnresumableResumeTargets(
                        targetIDs.union([target.storedSessionId].compactMap { $0 }),
                        candidates: resumeCandidates,
                        using: client,
                        profile: profile,
                        dashboardID: dashboardID,
                        purpose: purpose,
                        token: token,
                        automaticWorkToken: automaticWorkToken,
                        automaticSyncOperationID: automaticOperationID,
                        requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                        historySourceUnavailable: historySourceUnavailable
                    )
                }
                if !succeeded,
                   purpose == .automaticReturn,
                   !reconciliationWasIdentityRejected,
                   automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                   ),
                   token == reconciliationToken,
                   profile == activeProfile {
                    scheduleReconnectAfterFailedSync()
                }
                return succeeded
                    ? .completed
                    : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            } else if let missingSavedSessionID {
                // The store holds the durable session ID after an admitted
                // resume. It remains safe to address directly even while the
                // catalog temporarily omits the row; an identity gate still
                // rejects a contradictory server response.
                let savedIdentity = ConversationIdentity(
                    profile: profile,
                    durableSessionID: missingSavedSessionID,
                    runtimeSessionID: nil,
                    acceptedSessionIDs: [missingSavedSessionID]
                )
                let succeeded = await reconcile(
                    sessionId: missingSavedSessionID,
                    using: client,
                    token: token,
                    acceptedSessionIDs: savedIdentity.acceptedSessionIDs,
                    conversationIdentity: savedIdentity,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                    historySourceUnavailable: historySourceUnavailable
                )
                if !succeeded,
                   reconciliationSessionWasNotFound,
                   automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                   ),
                   chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                   token == reconciliationToken,
                   profile == activeProfile,
                   let activeClient = self.client,
                   activeClient === client {
                    // `session.resume` code 4007 is authoritative evidence
                    // that the saved conversation was deleted. Forget only
                    // the still-current pointer, then select from the catalog
                    // we already loaded under the same ownership fences.
                    guard chatResumeCoordinator.lastSessionID(for: profile) == missingSavedSessionID else {
                        return .superseded
                    }
                    let handledMissingSessionError = chatSyncErrorMessage
                    // Clears whatever kind the reference recorded for this
                    // workspace: the conversation's authoritative absence is
                    // not evidence about which surface it belonged to.
                    chatResumeCoordinator.rememberSession(nil, for: profile)
                    // Gone for the rest of this run, as a listed row that
                    // answers 4007: a message waiting for it doesn't go back
                    // into its draft (#996).
                    deadResumeRowIDs[
                        Self.deadResumeRowKey(dashboardID: dashboardID, profile: profile),
                        default: []
                    ].insert(missingSavedSessionID)
                    // Its agents go with it, whichever conversation (or new
                    // chat) is opened instead.
                    keepDelegateAgents(of: [])
                    if let fallback = selectChatResumeTarget(
                        in: resumeCandidates,
                        profile: profile,
                        purpose: purpose,
                        currentSessionID: nil,
                        automaticWorkToken: automaticWorkToken,
                        automaticSyncOperationID: automaticOperationID
                    ) {
                        let fallbackIDs = Set([fallback.id] + fallback.alternateIds)
                        let fallbackIdentity = ConversationIdentity(
                            profile: profile,
                            durableSessionID: fallback.storedSessionId ?? fallback.id,
                            runtimeSessionID: fallback.storedSessionId != nil ? fallback.id : nil,
                            acceptedSessionIDs: fallbackIDs
                        )
                        var fallbackSucceeded = await reconcile(
                            sessionId: fallback.id,
                            using: client,
                            token: token,
                            acceptedSessionIDs: fallbackIDs,
                            conversationIdentity: fallbackIdentity,
                            automaticWorkToken: automaticWorkToken,
                            automaticSyncOperationID: automaticOperationID,
                            requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                            historySourceUnavailable: historySourceUnavailable
                        )
                        if !fallbackSucceeded {
                            fallbackSucceeded = await resumeByStoredIDAfterNotFound(
                                fallback,
                                acceptedSessionIDs: fallbackIDs,
                                conversationIdentity: fallbackIdentity,
                                using: client,
                                profile: profile,
                                token: token,
                                automaticWorkToken: automaticWorkToken,
                                automaticSyncOperationID: automaticOperationID,
                                requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                                historySourceUnavailable: historySourceUnavailable
                            )
                        }
                        if fallbackSucceeded, chatSyncErrorMessage == handledMissingSessionError {
                            chatSyncErrorMessage = nil
                        }
                        if !fallbackSucceeded,
                           reconciliationSessionWasNotFound,
                           resumeRecoveryOwnsViewport(
                            token: token,
                            profile: profile,
                            client: client,
                            automaticWorkToken: automaticWorkToken,
                            automaticSyncOperationID: automaticOperationID,
                            requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
                           ) {
                            // The fallback is gone too: keep walking the
                            // catalog instead of stopping on a dead row with
                            // nothing scheduled.
                            return await retireUnresumableResumeTargets(
                                fallbackIDs.union([fallback.storedSessionId].compactMap { $0 }),
                                candidates: resumeCandidates,
                                using: client,
                                profile: profile,
                                dashboardID: dashboardID,
                                purpose: purpose,
                                token: token,
                                automaticWorkToken: automaticWorkToken,
                                automaticSyncOperationID: automaticOperationID,
                                requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                                historySourceUnavailable: historySourceUnavailable
                            )
                        }
                        if !fallbackSucceeded,
                           !reconciliationWasIdentityRejected,
                           !reconciliationSessionWasNotFound,
                           automaticChatResumeWorkIsCurrent(
                            automaticWorkToken,
                            syncOperationID: automaticOperationID
                           ),
                           token == reconciliationToken,
                           profile == activeProfile {
                            // The prior saved identity was authoritatively
                            // deleted; do not let it masquerade as a visible
                            // preserve-current target on the retry.
                            activeSessionId = nil
                            scheduleReconnectAfterFailedSync()
                        }
                        return fallbackSucceeded
                            ? .completed
                            : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
                    }
                    await createAndReconcileSession(
                        using: client,
                        profile: profile,
                        token: token,
                        resumePurpose: purpose,
                        automaticWorkToken: automaticWorkToken,
                        automaticSyncOperationID: automaticOperationID,
                        requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
                    )
                    return automaticChatResumeWorkIsCurrent(
                        automaticWorkToken,
                        syncOperationID: automaticOperationID
                    ) ? .completed : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
                }
                if !succeeded,
                   !reconciliationWasIdentityRejected,
                   automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                   ),
                   token == reconciliationToken,
                   profile == activeProfile {
                    scheduleReconnectAfterFailedSync()
                }
                return succeeded
                    ? .completed
                    : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            } else if purpose == .preserveCurrent, let preservedIdentity,
                      let preservedSessionID = preservedIdentity.resumeTargetID {
                // The refreshed catalog omitted the selected conversation (or
                // only its runtime alias). Resume the captured identity
                // directly with the alias set captured BEFORE the replacement,
                // so stream events addressed to a forgotten runtime alias stay
                // associated with this reconciliation instead of leaking into
                // or being erased by the transcript replacement.
                let succeeded = await reconcile(
                    sessionId: preservedSessionID,
                    using: client,
                    token: token,
                    acceptedSessionIDs: preservedIdentity.acceptedSessionIDs,
                    conversationIdentity: preservedIdentity,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                    historySourceUnavailable: historySourceUnavailable
                )
                return succeeded ? .completed : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            } else {
                await createAndReconcileSession(
                    using: client,
                    profile: profile,
                    token: token,
                    resumePurpose: purpose,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
                )
                return automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                )
                    ? .completed
                    : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
        } catch {
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(
                    token,
                    automaticSyncOperationID: automaticOperationID
                )
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            turnState = .reconnecting
            // A list read that started after this sync's catalog read
            // already listed: the list is current, and this older failure
            // is no news (as for loadSessions). The chat still did not
            // resume, so the reconnect below still runs.
            let catalogFailureIsSuperseded = pendingCatalogReadTicket.map { $0 <= sessionListListedTicket } ?? false
            // A read cancelled under it says nothing about the catalog
            // either (as for loadSessions): the next showing reads again.
            let wasCancelled = error is CancellationError
                || (error as? URLError)?.code == .cancelled || Task.isCancelled
            if !catalogFailureIsSuperseded, !wasCancelled {
                chatSyncErrorMessage = AppLocalization.string("Failed to load gateway sessions: \(UserFacingError.message(for: error))")
                sessionCatalogLoadState.markFailed(
                    UserFacingError.message(for: error),
                    owner: SessionCatalogOwner(dashboardID: dashboardID, profile: profile)
                )
            }
            settleReconciliation(
                token,
                automaticSyncOperationID: automaticOperationID
            )
            if purpose == .automaticReturn {
                scheduleReconnectAfterFailedSync()
            } else if wasCancelled, isConnected, turnState == .reconnecting {
                // Nothing retries a cancelled sync of the open chat, and the
                // socket is still up: the chat gets back the state it had,
                // a running reply included (the cancelled read says nothing
                // about it). Only a transitional one settles, as a
                // foreground boundary settles an aborted recovery's.
                if turnStateBeforeSync == .synchronizing || turnStateBeforeSync == .reconnecting {
                    setRunning(false)
                } else {
                    turnState = turnStateBeforeSync
                }
            }
            return .completed
        }
    }

    private func chatResumeSyncInterruptionOutcome(
        for automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) -> ChatResumeSyncExecutionOutcome {
        guard let automaticWorkToken,
              !chatResumeCoordinator.isCurrent(automaticWorkToken) else {
            return .superseded
        }
        return .automaticIntentInvalidated
    }

    /// Recovery for automatic-resume targets `session.resume` authoritatively
    /// reports missing (code 4007) although the catalog lists them, so the
    /// missing-saved-session branch of `performSyncSession` (which needs the
    /// row ABSENT from the catalog) never ran. Without it a cold launch stayed
    /// on the read-only saved copy and retried the same dead row forever.
    /// Same recovery as that branch: forget the saved pointer if it names a
    /// dead row, then open the next catalog row, and a fresh chat when none
    /// resumes. A row that is itself missing is skipped, never retried; any
    /// other failure is not evidence the row is dead, so it keeps the usual
    /// retry instead of creating a chat.
    ///
    /// Ported from Marceswan/hermes-conduit, where it first shipped for
    /// macOS only.
    private func retireUnresumableResumeTargets(
        _ deadIDs: Set<String>,
        candidates: [SessionSummary],
        using client: HermesClient,
        profile: String,
        dashboardID: UUID?,
        purpose: ChatResumeSyncPurpose,
        token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        automaticSyncOperationID: UUID?,
        requiredViewportTransitionGeneration: UInt64?,
        historySourceUnavailable: Bool
    ) async -> ChatResumeSyncExecutionOutcome {
        let deadRowKey = Self.deadResumeRowKey(dashboardID: dashboardID, profile: profile)
        var dead = deadIDs
        deadResumeRowIDs[deadRowKey, default: []].formUnion(dead)
        let handledError = chatSyncErrorMessage
        if let saved = chatResumeCoordinator.lastSessionID(for: profile), dead.contains(saved) {
            // Clears whatever kind the reference recorded: the
            // conversation's authoritative absence is not evidence about
            // which surface it belonged to.
            chatResumeCoordinator.rememberSession(nil, for: profile)
            // Its agents go with it, whichever conversation (or new chat) is
            // opened instead.
            keepDelegateAgents(of: [])
        } else {
            // The saved conversation is alive and may be the fallback: only
            // the dead rows' agents go.
            keepDelegateAgents(of: Set(delegateAgents.map(\.sessionId)).subtracting(dead))
        }
        // A catalog full of rows the gateway cannot resume (a profile
        // mis-tag, a pruned state.db) must not cost one resume plus one
        // history request per row: after `deadResumeRowProbeLimit` more dead
        // rows, create a fresh chat.
        var probes = 0
        while probes < Self.deadResumeRowProbeLimit {
            guard resumeRecoveryOwnsViewport(
                token: token,
                profile: profile,
                client: client,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID,
                requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
            ) else {
                return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
            }
            let remaining = candidates.filter { !Self.resumeRow($0, isAmong: dead) }
            guard let fallback = selectChatResumeTarget(
                in: remaining,
                profile: profile,
                purpose: purpose,
                currentSessionID: nil,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID
            ) else { break }
            probes += 1
            let fallbackIDs = Set([fallback.id] + fallback.alternateIds)
            let fallbackIdentity = ConversationIdentity(
                profile: profile,
                durableSessionID: fallback.storedSessionId ?? fallback.id,
                runtimeSessionID: fallback.storedSessionId != nil ? fallback.id : nil,
                acceptedSessionIDs: fallbackIDs
            )
            var fallbackSucceeded = await reconcile(
                sessionId: fallback.id,
                using: client,
                token: token,
                acceptedSessionIDs: fallbackIDs,
                conversationIdentity: fallbackIdentity,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID,
                requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                historySourceUnavailable: historySourceUnavailable
            )
            if !fallbackSucceeded {
                fallbackSucceeded = await resumeByStoredIDAfterNotFound(
                    fallback,
                    acceptedSessionIDs: fallbackIDs,
                    conversationIdentity: fallbackIdentity,
                    using: client,
                    profile: profile,
                    token: token,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticSyncOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                    historySourceUnavailable: historySourceUnavailable
                )
            }
            if fallbackSucceeded {
                if chatSyncErrorMessage == handledError { chatSyncErrorMessage = nil }
                return .completed
            }
            if reconciliationSessionWasNotFound {
                dead.formUnion(fallbackIDs)
                dead.formUnion([fallback.storedSessionId].compactMap { $0 })
                deadResumeRowIDs[deadRowKey, default: []].formUnion(dead)
                continue
            }
            if !reconciliationWasIdentityRejected,
               resumeRecoveryOwnsViewport(
                token: token,
                profile: profile,
                client: client,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID,
                requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
               ) {
                // A dead row is not a visible preserve-current target for
                // the retry: it returns to the saved conversation, or the
                // newest live one when the pointer was retired above.
                activeSessionId = nil
                scheduleReconnectAfterFailedSync()
            }
            return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
        }
        guard resumeRecoveryOwnsViewport(
            token: token,
            profile: profile,
            client: client,
            automaticWorkToken: automaticWorkToken,
            automaticSyncOperationID: automaticSyncOperationID,
            requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
        ) else {
            return chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
        }
        // The create is a reconciliation like `createNewSession`'s: the
        // failed resume above left `.reconnecting`, and a New Chat tapped now
        // must wait for this `session.create` rather than start a second one.
        turnState = .synchronizing
        await createAndReconcileSession(
            using: client,
            profile: profile,
            token: token,
            resumePurpose: purpose,
            automaticWorkToken: automaticWorkToken,
            automaticSyncOperationID: automaticSyncOperationID,
            requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
        )
        return automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) ? .completed : chatResumeSyncInterruptionOutcome(for: automaticWorkToken)
    }

    /// `session.resume` just answered 4007 for `row.id`. When the row names a
    /// different stored id, that 4007 can mean only that Hermes dropped the
    /// RUNTIME (a gateway restart, idle reaping): it resumes by the stored
    /// id, the durable identity (#446). Resumes once more by the stored id,
    /// with the same accepted ids and identity, before anything treats the
    /// row as dead. Returns whether that resume succeeded. Afterwards
    /// `reconciliationSessionWasNotFound` describes the LAST resume, so a
    /// caller retires the row only when its stored id is missing too. A row
    /// without a distinct stored id, any other failure, or a sync that lost
    /// ownership is left exactly as it was (false, nothing resumed).
    private func resumeByStoredIDAfterNotFound(
        _ row: SessionSummary,
        acceptedSessionIDs: Set<String>,
        conversationIdentity: ConversationIdentity,
        using client: HermesClient,
        profile: String,
        token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        automaticSyncOperationID: UUID?,
        requiredViewportTransitionGeneration: UInt64?,
        historySourceUnavailable: Bool
    ) async -> Bool {
        // A Kanban worker is refused under any of its ids.
        guard reconciliationSessionWasNotFound,
              !reconciliationWasKanbanWorker,
              let storedID = row.storedSessionId,
              !storedID.isEmpty,
              storedID != row.id,
              resumeRecoveryOwnsViewport(
                token: token,
                profile: profile,
                client: client,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID,
                requiredViewportTransitionGeneration: requiredViewportTransitionGeneration
              ) else { return false }
        let handledError = chatSyncErrorMessage
        let succeeded = await reconcile(
            sessionId: storedID,
            using: client,
            token: token,
            acceptedSessionIDs: acceptedSessionIDs,
            conversationIdentity: conversationIdentity,
            automaticWorkToken: automaticWorkToken,
            automaticSyncOperationID: automaticSyncOperationID,
            requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
            historySourceUnavailable: historySourceUnavailable
        )
        // The runtime id's "Failed to restore this conversation" was handled
        // by this resume; the conversation is on screen.
        if succeeded, chatSyncErrorMessage == handledError { chatSyncErrorMessage = nil }
        return succeeded
    }

    /// Further dead catalog rows the recovery above probes before it gives up
    /// on the catalog and creates a fresh chat.
    private static let deadResumeRowProbeLimit = 3

    private static func deadResumeRowKey(dashboardID: UUID?, profile: String) -> String {
        "\(dashboardID?.uuidString ?? "-")|\(profile)"
    }

    /// Whether this run found any of `sessionIDs` gone from Hermes
    /// (`session.resume` 4007): a chat that can't be opened again.
    func conversationIsGone(sessionIDs: Set<String>, dashboardID: UUID?, profile: String) -> Bool {
        let dead = deadResumeRowIDs[Self.deadResumeRowKey(dashboardID: dashboardID, profile: profile)] ?? []
        return !dead.isDisjoint(with: sessionIDs)
    }

    /// Whether any identity of `row` (its id, aliases or stored id) is in `ids`.
    private static func resumeRow(_ row: SessionSummary, isAmong ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        if ids.contains(row.id) { return true }
        if row.alternateIds.contains(where: { ids.contains($0) }) { return true }
        if let stored = row.storedSessionId, ids.contains(stored) { return true }
        return false
    }

    /// The ownership fences every step of the dead-row recovery re-checks
    /// after an await: the same automatic intent, viewport transition,
    /// reconciliation, profile and client this sync started with.
    private func resumeRecoveryOwnsViewport(
        token: UUID,
        profile: String,
        client: HermesClient,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        automaticSyncOperationID: UUID?,
        requiredViewportTransitionGeneration: UInt64?
    ) -> Bool {
        guard automaticChatResumeWorkIsCurrent(
                automaticWorkToken,
                syncOperationID: automaticSyncOperationID
              ),
              chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
              token == reconciliationToken,
              profile == activeProfile,
              let activeClient = self.client,
              activeClient === client else { return false }
        return true
    }

    func beginReconciliation() -> UUID {
        let token = UUID()
        let bufferedEvents = reconciliation?.bufferedEvents ?? []
        let bufferedGenerations = reconciliation?.bufferedGenerations ?? []
        let streamTextAtBoundary: String?
        let streamSessionIDAtBoundary: String?
        if let existingReconciliation = reconciliation {
            streamTextAtBoundary = existingReconciliation.streamTextAtBoundary
            streamSessionIDAtBoundary = existingReconciliation.streamSessionIDAtBoundary
        } else {
            streamTextAtBoundary = activeSessionId.map { _ in streamingBuffer }
            streamSessionIDAtBoundary = activeSessionId
        }
        reconciliationToken = token
        reconciliation = Reconciliation(
            token: token,
            requestedSessionId: activeSessionId ?? "",
            acceptsAnySession: true,
            streamTextAtBoundary: streamTextAtBoundary,
            streamSessionIDAtBoundary: streamSessionIDAtBoundary,
            bufferedEvents: bufferedEvents,
            bufferedGenerations: bufferedGenerations
        )
        refreshActiveChatScrollSessionIdentity(isReconciling: true)
        return token
    }

    func invalidateReconciliation() {
        let wasReconciling = activeChatScrollSessionIdentity.isReconciling
        let closed = reconciliation
        reconciliationToken = UUID()
        reconciliation = nil
        refreshActiveChatScrollSessionIdentity(
            isReconciling: false,
            advanceSettledRevision: wasReconciling
        )
        releaseHeldSideAgentCompletions(closing: closed)
    }

    /// Shows the side-agent answers held while the reconciliation was open,
    /// after any transcript it committed. An answer addressed to an id the
    /// closed reconciliation accepted for the active conversation (a resume
    /// that rotated the runtime id before the catalog learned it) is shown
    /// there, as it would have been while the boundary was open; one from
    /// another conversation still isn't.
    private func releaseHeldSideAgentCompletions(closing closed: Reconciliation?) {
        guard reconciliation == nil, !heldSideAgentCompletions.isEmpty else { return }
        let held = heldSideAgentCompletions
        heldSideAgentCompletions = []
        let aliases = closed?.acceptedSessionIDs ?? []
        for event in held {
            guard case .sideAgentComplete(let sessionId, let kind, let taskId, let text, let question) = event,
                  let activeSessionId, sessionId != activeSessionId,
                  !eventBelongsToActiveSession(sessionId),
                  aliases.contains(activeSessionId), aliases.contains(sessionId) else {
                applyStreamEvent(event)
                continue
            }
            applyStreamEvent(.sideAgentComplete(sessionId: activeSessionId, kind: kind, taskId: taskId,
                                                text: text, question: question))
        }
    }

    @discardableResult
    private func claimReconciliation(
        _ token: UUID,
        automaticSyncOperationID: UUID?
    ) -> Bool {
        guard token == reconciliationToken,
              var reconciliation else { return false }
        reconciliation.automaticSyncOperationID = automaticSyncOperationID
        self.reconciliation = reconciliation
        return true
    }

    @discardableResult
    func settleReconciliation(
        _ token: UUID,
        automaticSyncOperationID: UUID? = nil
    ) -> Bool {
        guard token == reconciliationToken,
              let activeReconciliation = reconciliation,
              activeReconciliation.automaticSyncOperationID == automaticSyncOperationID else {
            return false
        }
        let wasReconciling = activeChatScrollSessionIdentity.isReconciling
        reconciliation = nil
        refreshActiveChatScrollSessionIdentity(
            isReconciling: false,
            advanceSettledRevision: wasReconciling
        )
        releaseHeldSideAgentCompletions(closing: activeReconciliation)
        return true
    }

    func selectChatResumeTarget(
        in catalog: [SessionSummary],
        profile: String,
        purpose: ChatResumeSyncPurpose,
        currentSessionID: String?,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil
    ) -> SessionSummary? {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else { return nil }
        if purpose == .automaticReturn {
            chatResumeRestorationRequest = nil
        }
        dropSavedPulseChat(profile: profile, purpose: purpose, among: catalog)
        // The stored selection is authoritative only when its kind is known or
        // bot evidence could be read: a v1-migrated id cannot be told from a
        // bot chat, and adopting a catalog row by it is the fail-open the
        // typed payload exists to close.
        let savedReferenceIsAuthoritative = !(chatResumeCoordinator.lastSession(for: profile)?.isUnverified ?? false)
            || botEvidenceIsAvailable
        return chatResumeCoordinator.selectTarget(
            in: catalog,
            profile: profile,
            purpose: purpose,
            currentSessionID: currentSessionID,
            // Positive bot ownership is decided at the moment of selection:
            // the registry and roster both change across a session, and a
            // conversation must never be adopted by the workspace because the
            // evidence arrived a moment after the decision.
            botOwnedSessionIDs: botOwnedSessionIDs,
            savedSelectionIsAuthoritative: savedReferenceIsAuthoritative,
            // Read at the moment of selection too: a bot's work read that
            // lands mid-sync names its workstreams for this pick, and a feed
            // read names Pulse's chat.
            unlistedSessionIDs: Set(catalog.lazy.filter { self.isUnlistedChat($0) }.map(\.id))
        )
    }

    /// A chat of this profile's that no list shows: a bot's workstream
    /// (#1755) or Pulse's own chat, which the Pulse screen stands in for.
    /// Conduit never opens one by itself (the chat it resumes, CarPlay's
    /// list, a call's chat search); one the user opened stays open.
    func isUnlistedChat(_ session: SessionSummary) -> Bool {
        isWorkstreamRow(session) || isPulseHomeChat(session)
    }

    /// Pulse's chat is never the chat Conduit opens by itself, even a saved
    /// one (picked before this phone knew it, or opened from a push): the
    /// Pulse screen stands in for it. The chat on screen stays.
    func dropSavedPulseChat(profile: String, purpose: ChatResumeSyncPurpose, among catalog: [SessionSummary]) {
        guard purpose != .preserveCurrent, let home = pulseHomeChat, showsPulseScreen else { return }
        forgetResumedPulseChat(home, profile: profile, among: catalog)
    }

    /// Drops Pulse's chat as the saved chat to resume, so the pick goes to a
    /// listed chat. The two are matched by any of the chat's ids.
    /// Only in Pulse's own profile, and never through a shared lineage root,
    /// so a branch of Pulse's chat stays a chat of its own.
    func forgetResumedPulseChat(_ home: String, profile: String, among catalog: [SessionSummary]) {
        guard profilesMatch(profile, pulseHomeProfile),
              let saved = chatResumeCoordinator.lastSessionID(for: profile) else { return }
        func names(_ id: String) -> Set<String> {
            var ids: Set<String> = [id]
            if let canonical = canonicalSessionID(for: id) { ids.insert(canonical) }
            for row in catalog + sessions
            where sessionBelongsToProfile(row, profile: profile) && row.nestingIDs.contains(id) {
                ids.formUnion(row.nestingIDs)
            }
            return ids
        }
        guard !names(saved).isDisjoint(with: names(home)) else { return }
        chatResumeCoordinator.rememberSession(nil, for: profile)
    }

    /// The same by a chat's id alone (a call's chat search hit), in `profile`.
    /// Any listed row it names (by any of its ids) goes by the row's rule.
    func isUnlistedChat(id: String, profile: String) -> Bool {
        sessions.contains {
            sessionBelongsToProfile($0, profile: profile)
                && SessionContentSearch.identities(of: $0).contains(id) && isUnlistedChat($0)
        }
            || isWorkstreamSession(id) || isPulseHomeChat(id: id, profile: profile)
    }

    @discardableResult
    func beginChatResumeRecovery(
        purpose: ChatResumeSyncPurpose
    ) -> ChatResumeSyncPurpose {
        recoverySequence.register(purpose)
    }

    func chatResumePurposeForDisconnect() -> ChatResumeSyncPurpose {
        recoverySequence.currentPurpose
    }

    func planChatResumeReconnect(
        purpose: ChatResumeSyncPurpose
    ) -> ChatResumeReconnectSchedulingDecision {
        recoverySequence.planReconnect(requestedPurpose: purpose)
    }

    private func publishChatResumeRestorationIfReady(
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil
    ) {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else { return }
        guard let sessionKey = activeChatScrollSessionIdentity.canonicalSessionKey else {
            return
        }
        // This id is derived from the adopted transcript and can briefly lag
        // during a session handoff; TranscriptScroller revalidates it against
        // rendered targets and falls back if it belongs to the prior session.
        guard let request = chatResumeCoordinator.reconciliationSettled(
            sessionKey: sessionKey,
            pendingClarifyMessageID: pendingClarifyMessageID
        ) else {
            // reconciliationSettled returned nil. If there was a pending
            // session key (mismatch path), clear the freeze so viewport
            // recording resumes. If there was no pending key, there's
            // nothing to clean up.
            chatResumeCoordinator.abandonPendingAutomaticSyncIfPending()
            return
        }
        chatResumeRestorationRequest = request
    }

    @discardableResult
    func settleReconciliationAndPublish(
        _ token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil
    ) -> Bool {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else {
            settleReconciliation(
                token,
                automaticSyncOperationID: automaticSyncOperationID
            )
            return false
        }
        guard settleReconciliation(
            token,
            automaticSyncOperationID: automaticSyncOperationID
        ) else { return false }
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else { return false }
        publishChatResumeRestorationIfReady(
            automaticWorkToken: automaticWorkToken,
            automaticSyncOperationID: automaticSyncOperationID
        )
        cancelScheduledReconnect()
        recoverySequence.complete()
        if automaticWorkToken != nil {
            activeAutomaticChatResumeWork = nil
        }
        return true
    }

    @discardableResult
    func reconcile(
        sessionId: String,
        using client: HermesClient,
        token: UUID,
        acceptedSessionIDs: Set<String> = [],
        conversationIdentity: ConversationIdentity? = nil,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil,
        requiredViewportTransitionGeneration: UInt64? = nil,
        historySourceUnavailable: Bool = false,
        presentationMigrationSessionIDs: Set<String> = [],
        conversationProfile: String? = nil,
        widgetLease: WidgetLaunchLease? = nil
    ) async -> Bool {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ), chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
              widgetLease?.isCurrent != false else {
            return false
        }
        // Canonical Bot Chats live in the bot's profile: every re-entry path
        // (explicit open, reconnect, refresh, preserve-current sync) resolves
        // the resume scope from authoritative bot evidence, so a re-resume can
        // never land on the dashboard profile and lose the session. The
        // in-memory registry is only ONE of the three sources — it is cleared
        // at every server-identity boundary and empty in a fresh process, so
        // the roster's canonical registries and the durable reference's own
        // recorded scope are consulted too. Order matters: the registry is
        // this process's own observation, the roster is the server's current
        // answer, the reference is what the open recorded.
        // Deliberately the ADDRESSED id alone: `acceptedSessionIDs` can carry
        // a previous conversation's aliases (the scroll identity unions them
        // when a resume continues the conversation it replaced), and a foreign
        // id must never pull this conversation onto a bot profile's store.
        // The workspace profile is read from the same binding the rest of this
        // body uses, so the durable-reference fallback cannot disagree with it.
        let profile = activeProfile
        let conversationScopeProfile = conversationProfile
            ?? botScopeProfile(forSessionIDs: [sessionId], workspaceProfile: profile)
        let priorReconciliation = reconciliation?.token == token ? reconciliation : nil
        let bufferedEvents = priorReconciliation?.bufferedEvents ?? []
        let bufferedGenerations = priorReconciliation?.bufferedGenerations ?? []
        reconciliation = Reconciliation(
            token: token,
            requestedSessionId: sessionId,
            automaticSyncOperationID: automaticSyncOperationID,
            acceptedSessionIDs: acceptedSessionIDs.union([sessionId]),
            streamTextAtBoundary: priorReconciliation?.streamTextAtBoundary,
            streamSessionIDAtBoundary: priorReconciliation?.streamSessionIDAtBoundary,
            bufferedEvents: bufferedEvents,
            bufferedGenerations: bufferedGenerations
        )
        // Any previously held durable anchors belong to a different reconcile
        // transaction; they are re-adopted below only from a transcript this
        // reconcile actually validated and accepted. A rejected identity
        // restores them — the rejection must not consume ordering evidence.
        let savedDurablePersistedRowIDs = durablePersistedRowIDs
        durablePersistedRowIDs = []
        reconciliationWasIdentityRejected = false
        reconciliationSessionWasNotFound = false
        reconciliationWasKanbanWorker = false
        refreshActiveChatScrollSessionIdentity(isReconciling: true)
        turnState = .synchronizing
        // The resume RPC can overlap a user-initiated config.set. Capture the
        // local-write position before launching either request so a response
        // from the older snapshot cannot clear the newer override.
        let yoloWriteBaseline = sessionYoloWriteBaseline(for: sessionId)
        var resumeRPCFailedSessionNotFound = false

        do {
            // Match Hermes Desktop: fetch the durable transcript and resume the
            // live runtime concurrently. The compact resume (`omit_messages`)
            // keeps the whole persisted transcript out of the WebSocket
            // response; the HTTP endpoint reads the timestamped rows from
            // state.db and hydrates the conversation instead.
            let bridge = dashboardTicketBridge
            // Prefer the compact projection whenever a history source exists
            // to hydrate the transcript — the dashboard bridge, or a test seam
            // standing in for one. A cold bridge does not change the flavor:
            // requestJSON's bounded readiness poll (30 × 100 ms) waits for the
            // page inside the concurrent transcript fetch, so the compact
            // resume is never delayed by that wait, and a bridge still not
            // usable afterwards degrades to the single legacy resume. The
            // legacy resume — cold bridge, gateway without the history route —
            // carries the transcript in the RPC response, whose size is
            // bounded by the socket limit (the pre-compact behavior).
            //
            // A caller that POSITIVELY established structural history
            // absence moments ago (the foreground freshness path) skips the
            // compact attempt entirely: a compact resume here would be
            // followed by a doomed history request and a second legacy
            // resume — one non-compact resume does the whole job.
            let compactResume = !historySourceUnavailable
                && (chatResumeLifecycleOperations.persistedTranscript != nil || bridge != nil)
            var result: SessionResumeResult
            var transcript: PersistedSessionTranscript?
            // Hermes refuses a resume carrying the whole transcript past
            // `sessions.max_resume_messages` (4130), yet resumes the same
            // chat compact, whose guard counts only its newest segment
            // (issue 2025: a Bot Chat past 20,000 rows, 29 in its newest
            // segment). That resume brings no rows: the history source fills
            // them in when it answers now, else the chat keeps the rows it
            // shows. A history read that failed for now leaves them
            // unresolved, so the next send reads again; a source that isn't
            // there (no dashboard page, a 404) can't be read before a send
            // either, which would block every send, so the next return to
            // the app reads it. A chat with none to keep shows the refusal,
            // which says what to do.
            var keepsRowsOnScreen = false
            var keptRowsAwaitHistory = false
            func resumeCarryingTranscript() async throws -> SessionResumeResult {
                do {
                    return try await openChatResumeSession(
                        sessionId,
                        using: client,
                        compact: false,
                        profile: conversationScopeProfile
                    )
                } catch let refusal as RpcError where HermesClient.isResumeTooLongError(refusal) {
                    let compact = try await openChatResumeSession(
                        sessionId,
                        using: client,
                        compact: true,
                        profile: conversationScopeProfile
                    )
                    let history = await persistedTranscriptOutcome(
                        sessionId: sessionId,
                        profile: conversationScopeProfile ?? profile,
                        using: dashboardTicketBridge
                    )
                    if case .hydrated(let persisted) = history, transcriptMatchesSession(
                        persisted,
                        requestedSessionId: sessionId,
                        resumedSessionId: compact.sessionId
                    ) {
                        transcript = persisted
                        return compact
                    }
                    guard !messages.isEmpty,
                          rowsOnScreenBelong(to: [sessionId, compact.sessionId, compact.storedSessionId])
                    else { throw refusal }
                    keepsRowsOnScreen = true
                    // Only a source that isn't there settles them; a read
                    // that failed, or a page naming another chat, is tried
                    // again before the next send.
                    if case .unavailable = history {} else { keptRowsAwaitHistory = true }
                    return compact
                }
            }
            if compactResume {
                async let resumedSession = openChatResumeSession(
                    sessionId,
                    using: client,
                    compact: true,
                    profile: conversationScopeProfile
                )
                async let transcriptOutcome = persistedTranscriptOutcome(
                    sessionId: sessionId,
                    profile: conversationScopeProfile ?? profile,
                    using: bridge
                )
                do {
                    result = try await resumedSession
                } catch {
                    resumeRPCFailedSessionNotFound = (error as? RpcError)?.code == 4007
                    throw error
                }
                switch await transcriptOutcome {
                case .hydrated(let persisted):
                    // The endpoint may resolve a runtime ID to its stored
                    // session ID; only rows belonging to this session may
                    // hydrate the transcript. A foreign identity means the
                    // history source is unusable for this resume — request
                    // the transcript through the resume RPC instead.
                    if transcriptMatchesSession(
                        persisted,
                        requestedSessionId: sessionId,
                        resumedSessionId: result.sessionId
                    ) {
                        transcript = persisted
                    } else {
                        do {
                            result = try await resumeCarryingTranscript()
                        } catch {
                            resumeRPCFailedSessionNotFound = (error as? RpcError)?.code == 4007
                            throw error
                        }
                    }
                case .unavailable:
                    // No usable history source (missing bridge, or a gateway
                    // predating the messages endpoint): re-resume carrying
                    // the transcript, exactly as pre-compact builds did.
                    do {
                        result = try await resumeCarryingTranscript()
                    } catch {
                        resumeRPCFailedSessionNotFound = (error as? RpcError)?.code == 4007
                        throw error
                    }
                case .failed(let error):
                    // An unrelated history failure must not be papered over by
                    // a legacy resume that would hide it: surface it instead.
                    throw error
                }
            } else {
                do {
                    result = try await resumeCarryingTranscript()
                } catch {
                    resumeRPCFailedSessionNotFound = (error as? RpcError)?.code == 4007
                    throw error
                }
            }
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  widgetLease?.isCurrent != false,
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                return false
            }
            // The compact resume refused nothing but brought no rows: the
            // ones on screen stand for the chat, and the next read (a send,
            // a return to the app) brings them up to date.
            if keepsRowsOnScreen {
                result = SessionResumeResult(
                    sessionId: result.sessionId,
                    storedSessionId: result.storedSessionId,
                    messages: messages,
                    snapshot: result.snapshot
                )
            }

            // Admission gate: validate what the resume response claims about
            // this conversation BEFORE adopting anything. A rejected claim
            // must not be adopted into conversation-owned state: no
            // `activeSessionId`, selected conversation identity, transcript,
            // scroll canonical identity, conversation persistence key,
            // composer ownership, presentation cache, or resume-store
            // selected identity may change. The refreshed session catalog is
            // independent discovery state and is NOT rolled back on
            // rejection.
            let referenceIdentity = conversationIdentity ?? ConversationIdentity(
                profile: profile,
                durableSessionID: nil,
                runtimeSessionID: reconciliation?.requestedSessionId,
                acceptedSessionIDs: acceptedSessionIDs.union([sessionId])
            )
            let claim = ResumeIdentityClaim(
                runtimeSessionID: result.sessionId,
                durableSessionID: result.storedSessionId
            )
            var context = reconciliation
            switch ConversationIdentityGate.admit(
                claim: claim,
                selected: referenceIdentity,
                catalog: sessions + cronSessions
            ) {
            case .failure(let rejection):
                sessionCatalogLog.fault(
                    "Rejected contradictory resume: \(rejection.logLabel, privacy: .public); requested=\(sessionId, privacy: .private(mask: .hash)), returned=\(result.sessionId, privacy: .private(mask: .hash))"
                )
                // Restore the ordering evidence the reconcile entry cleared:
                // ordering evidence is conversation-owned state, so a
                // rejection may not consume it. (The already-published
                // catalog refresh stays — discovery state is independent of
                // the rejected claim.)
                durablePersistedRowIDs = savedDurablePersistedRowIDs
                reconciliationWasIdentityRejected = true
                // Unstick the synchronizing wait without clobbering a live
                // running turn; the transcript and identity above are left
                // exactly as they were.
                if turnState == .synchronizing {
                    turnState = .idle
                }
                chatSyncErrorMessage = AppLocalization.string("Hermes returned a different conversation while resuming this one. Try reopening it.")
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                return false
            case .success:
                context?.resolvedSessionId = result.sessionId
                context?.acceptedSessionIDs.insert(result.sessionId)
                // A row this run found dead (4007) that resumes after all is
                // alive: later automatic returns may pick it again.
                let deadRowKey = Self.deadResumeRowKey(dashboardID: activeDashboardID, profile: profile)
                if deadResumeRowIDs[deadRowKey] != nil {
                    deadResumeRowIDs[deadRowKey]?.subtract(
                        acceptedSessionIDs.union([sessionId, result.sessionId])
                            .union([result.storedSessionId].compactMap { $0 })
                    )
                }
                // A response that explicitly names the durable identity may
                // ESTABLISH it for a runtime-only conversation (the same
                // adoption the create path performs) or confirm the selected
                // one. It never overwrites a different established durable
                // id — confirmed-alias claims keep the existing binding.
                if let established = result.storedSessionId, !established.isEmpty,
                   referenceIdentity.durableSessionID == nil
                    || referenceIdentity.durableSessionID == established {
                    context?.resolvedDurableSessionId = established
                }
                // Commit the admitted result as FRESH AUTHORITATIVE evidence
                // in the shared identity index: the app just accepted this
                // resume into conversation-owned state, so the index must
                // agree — a historical conflicting mapping for the same
                // runtime id is rebound here, never kept (split-brain is
                // unacceptable between the selected conversation and the
                // index).
                //
                // Durable candidates in priority order: an explicitly
                // established stored id from the response, the selected
                // conversation's established durable id, and finally the
                // RESUME TARGET itself — the request was addressed by that
                // stored id, so it is the durable the app is acting on (for
                // a runtime-addressed resume the mapping degenerates to a
                // self-mapping, which the index skips as information-free).
                let requestedDurableCandidate: String? = sessionId
                let admittedDurable = context?.resolvedDurableSessionId
                    ?? referenceIdentity.durableSessionID
                    ?? requestedDurableCandidate
                if let admittedDurable, !admittedDurable.isEmpty {
                    for admittedRuntimeID in [result.sessionId, sessionId] {
                        conversationIdentityIndex.recordAuthoritative(
                            runtimeID: admittedRuntimeID,
                            durableID: admittedDurable,
                            // A canonical Bot Chat is indexed under the BOT's
                            // profile: it must never satisfy an identity
                            // lookup made for a dashboard-profile
                            // conversation.
                            profile: conversationScopeProfile ?? profile,
                            source: .resume
                        )
                    }
                    // Keep the bot-chat resume scope reachable for every
                    // later re-resume of this conversation (reconnects,
                    // refreshes) — in-memory only, never a durable pointer.
                    if let conversationScopeProfile {
                        // The captured label travels with the conversation:
                        // a resume that rotates the runtime id must not
                        // strand the label on the old id, or the reply
                        // headers would fall to the roster's current label
                        // while the title keeps the captured one. The
                        // compaction-recovery path propagates it identically.
                        // The candidates are the conversation's OWN ids —
                        // addressed, returned and admitted-durable — never
                        // `acceptedSessionIDs`, whose aliases can carry a
                        // previous conversation's ids.
                        let resumedLabel = [sessionId, result.sessionId, result.storedSessionId, admittedDurable]
                            .compactMap { ChatScrollIdentityNormalization.sessionID($0) }
                            .compactMap { botChatSessionLabels[$0] }
                            .first
                        noteBotChatSession(result.sessionId, profile: conversationScopeProfile, label: resumedLabel)
                        noteBotChatSession(sessionId, profile: conversationScopeProfile, label: resumedLabel)
                        noteBotChatSession(result.storedSessionId, profile: conversationScopeProfile, label: resumedLabel)
                    }
                    // Durable-owned presentation: the durable key is the
                    // only persistent presentation key for this
                    // conversation. Runtime-keyed records migrate into it
                    // now, and the alias keys are retired so a later
                    // re-attribution of a runtime id to a different
                    // conversation can never inherit this presentation.
                    // `presentationMigrationSessionIDs` are notification
                    // presentation sources — untrusted as identity, so they
                    // were never added to the accepted set; now that
                    // admission HAS succeeded they are legitimate migration
                    // sources for the pending decision cards they carried.
                    let runtimeAliases = acceptedSessionIDs
                        .union([result.sessionId, sessionId])
                        .union(presentationMigrationSessionIDs)
                        .subtracting([admittedDurable])
                    sessionPresentationCache.consolidateUnderDurableKey(
                        // The conversation's own namespace: a bot chat's
                        // presentation survives dashboard-profile switches.
                        profile: conversationScopeProfile ?? profile,
                        durableSessionID: admittedDurable,
                        runtimeAliases: Array(runtimeAliases)
                    )
                }
                // A live voice turn captured the pre-rebind runtime; the
                // admitted alias keeps its assistant stream flowing — but
                // only when the reconciled conversation IS the voice turn's
                // conversation (positive id overlap), never another one.
                voiceConversationController.extendAssistantSessionIDs(
                    [result.sessionId],
                    ofConversationContaining: referenceIdentity.acceptedSessionIDs
                        .union([sessionId])
                )
            }
            reconciliation = context
            refreshActiveChatScrollSessionIdentity(isReconciling: true)

            // Do not replace a live/in-flight projection with a database read
            // that may be a few events behind. Once the turn is settled, the
            // persisted transcript is the exact Desktop source for timestamps,
            // tool previews, and completed response content.
            let transcriptMatches = transcript.map {
                transcriptMatchesSession(
                    $0,
                    requestedSessionId: sessionId,
                    resumedSessionId: result.sessionId
                )
            } ?? false
            // Adopt the durable row ids ONLY from a transcript this reconcile
            // validated and accepted; they anchor the ambiguous-delivery
            // verifier's ordering evidence for this conversation. The
            // persisted ORDERING frontier is re-established from the same
            // acceptance — never carried over from a previous conversation
            // state.
            durablePersistedRowIDs = (transcriptMatches ? transcript?.durableRowIDs : nil) ?? []
            persistedOrderingFrontier = Self.orderingFrontier(
                from: transcriptMatches ? transcript : nil
            )

            // Capture the pre-reconcile transcript and window for the graft
            // decision below before either is replaced. The window write
            // itself happens after the graft: whether the refreshed tail
            // grafted onto the backfilled prefix determines whether the
            // prefix-preservation fact survives into the refreshed window.
            // A chat left after Load earlier comes back empty (an open, the
            // chat a profile switch opens on): the rows it had are kept for
            // this reconcile to graft onto (issue 1825), under the same
            // ownership and overlap rules as a reconnect's.
            // Stored rows or the resume's (reconcileRowsSource).
            let rowsSource = Self.reconcileRowsSource(
                transcriptMatches: transcriptMatches,
                storedMessages: transcript?.messages,
                result: result
            )
            // Taken only for a graft onto Hermes' stored rows: a live turn's
            // rows come from the resume, which grafts nothing, and the kept
            // rows stay for the next open.
            let reopenedTranscript = messages.isEmpty && persistedTranscriptWindow == nil && rowsSource == .stored
                ? takeLeftBackfilledTranscript(
                    for: Set([sessionId, result.sessionId, transcript?.resolvedSessionId].compactMap { $0 }),
                    profile: conversationScopeProfile ?? profile
                )
                : nil
            let previousTranscriptMessages = reopenedTranscript?.messages ?? messages
            let priorWindow = reopenedTranscript?.window ?? persistedTranscriptWindow
            if let transcript, transcriptMatches, result.snapshot.hasLiveProjection, !transcript.messages.isEmpty {
                // Desktop keeps its live projection during an active turn. Seed
                // the same durable presentation details first so the completed
                // portion of a backgrounded turn does not lose its timestamps.
                // Durable-owned: writes land on the durable key only, so the
                // alias keys consolidation just retired stay retired.
                let presentationDurableID = context?.resolvedDurableSessionId
                    ?? referenceIdentity.durableSessionID
                    ?? sessionId
                sessionPresentationCache.save(
                    transcript.messages,
                    profile: conversationScopeProfile ?? profile,
                    sessionIDs: Self.durableOwnedPresentationIDs(
                        [sessionId, result.sessionId, transcript.resolvedSessionId].compactMap { $0 },
                        durableSessionID: presentationDurableID
                    )
                )
            }
            let priorWindowForGraft = priorWindowOwnsThisConversation(
                priorWindow,
                requestedSessionId: sessionId,
                resolvedSessionId: transcript?.resolvedSessionId,
                runtimeSessionId: result.sessionId,
                profile: conversationScopeProfile ?? profile
            ) ? priorWindow : nil
            let presentationResult: SessionResumeResult
            var graftedBackfilledPrefix = false
            if let transcript, rowsSource == .stored {
                // A re-reconciliation replaces only the newest page. Keep
                // everything "Load earlier messages" already backfilled by
                // re-anchoring the refreshed tail onto the older prefix;
                // without this, any reconnect during a browsed long session
                // would silently truncate the visible history back to one
                // page. The graft must survive REPEATED reconciles — the
                // explicit hasBackfilledPrefix flag carries that fact, since
                // the network coverage reset below erases the offset
                // evidence after the first one.
                let grafted = PersistedTranscriptWindow.grafting(
                    refreshedTail: transcript.messages,
                    ontoBackfilled: previousTranscriptMessages,
                    window: priorWindowForGraft
                )
                presentationResult = SessionResumeResult(
                    sessionId: result.sessionId,
                    storedSessionId: result.storedSessionId,
                    messages: grafted.messages,
                    snapshot: result.snapshot
                )
                graftedBackfilledPrefix = grafted.grafted
            } else if let transcript, rowsSource == .resumeKeepingStoredIDs {
                // A live turn's rows come from the resume; the ones Hermes
                // has stored keep the stored rows' ids (#1648).
                presentationResult = Self.keepingStoredRowIDs(result, from: transcript.messages)
            } else {
                presentationResult = result
            }

            // Persisted-history window bookkeeping. The window describes the
            // REST-fetched display history only — runtime state above is
            // untouched. A pagination echo carrying the `order=latest` tail
            // contract opens the bounded window; a legacy one-shot hydration
            // (or a hydration that failed the session-identity gate) leaves
            // no window, because no older page exists to fetch. A graft that
            // kept the backfilled prefix preserves that fact; a refreshed
            // tail with no safe anchor is authoritative and resets it.
            //
            // The refresh resets coverage to the fetched page even when the
            // graft kept older rows. The next backfills then retrace
            // the backfilled prefix in page-sized increments, each deduped
            // against held rows, until coverage catches up — harmless
            // duplicate requests that self-correct, never gaps. Under-
            // counting is the safe direction: trusting the prior coverage
            // after a server-side rewrite could silently skip rows. A
            // conversation that was already fully backfilled re-lights the
            // affordance once and re-retires on its first terminal page.
            if let transcript, transcriptMatches, let page = transcript.page,
               page.honorsTailContract {
                // The window records EVERY identity the accepted
                // transaction produced — requested, resolved stored, and
                // runtime — so ownership stays self-contained even before
                // the session catalog learns the runtime↔stored alias.
                // The profile stamp is the conversation's own scope: a bot
                // chat's older pages must be fetched from the BOT's store.
                persistedTranscriptWindow = PersistedTranscriptWindowState(
                    requestedSessionID: sessionId,
                    profile: conversationScopeProfile ?? profile,
                    pageSize: PersistedTranscriptPagination.pageSize,
                    resolvedSessionID: transcript.resolvedSessionId,
                    runtimeSessionID: result.sessionId,
                    nextOffset: page.rawReturned,
                    canLoadEarlier: page.mayHaveOlderRows(fetchedRowCount: page.rawReturned),
                    hasBackfilledPrefix: graftedBackfilledPrefix,
                    // The grafted prefix keeps its rows, so the page starts
                    // noted on it still mark where a long chat can cut back
                    // to (issue 1828), covering no more than this page.
                    loadedPageStarts: graftedBackfilledPrefix
                        ? (priorWindowForGraft?.pageStartsCarried(into: page.rawReturned) ?? [])
                        : []
                )
            } else if keepsRowsOnScreen {
                // The rows kept from the screen keep their paging window:
                // what Load earlier brought in stays, and grafts again on
                // the next refresh.
                persistedTranscriptWindow = priorWindowForGraft
            } else {
                persistedTranscriptWindow = nil
            }

            let resumeSessionIDs = [result.sessionId, reconciliation?.requestedSessionId]
                .compactMap { $0 }
            let reconcileExplicitYolo = !hasNewerSessionYoloWrite(
                since: yoloWriteBaseline,
                sessionIDs: resumeSessionIDs
            )
            guard applyChatResume(
                presentationResult,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID
            ) else {
                if let reopenedTranscript { putBackLeftBackfilledTranscript(reopenedTranscript) }
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return false
            }
            schedulePendingApprovalsRefresh(sessionId: result.sessionId, using: client)
            // The context meter's read goes on beside the open, as the
            // approvals read does: the resume's snapshot already set the
            // meter, and the open settles, lands and finishes without
            // waiting a round trip for it (issue 1824).
            scheduleChatResumeContextRefresh(sessionId: result.sessionId, using: client)
            if let afterResumeApplied = chatResumeLifecycleOperations.afterResumeApplied {
                await afterResumeApplied(client, result.sessionId)
            }

            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  widgetLease?.isCurrent != false,
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return false
            }

            let bufferedEntries = reconciliation?.token == token
                ? (reconciliation?.bufferedEntries ?? []).filter {
                    reconciliation?.accepts(sessionID(for: $0.event)) == true
                }
                : []
            var bufferedEvents = bufferedEntries.map { $0.event }
            var bufferedGenerations = bufferedEntries.map { $0.generation }
            if result.snapshot.hasLiveProjection {
                let resumedInflightText = streamingBuffer
                let boundary = reconciliation?.token == token ? reconciliation : nil
                let acceptedSessionIDs: Set<String>
                if let boundary,
                   let boundarySessionID = boundary.streamSessionIDAtBoundary {
                    // The boundary's accepted set was captured from the
                    // catalog and scroll identity BEFORE recovery replaced
                    // them, so it survives a refresh that temporarily forgot
                    // the runtime alias. Do NOT re-derive it from the
                    // replaced catalog: that would drop exactly the alias the
                    // resume window needs. An empty set intentionally
                    // disables deduplication rather than risking text from a
                    // different session.
                    acceptedSessionIDs = boundary.acceptedSessionIDs
                    if !acceptedSessionIDs.contains(result.sessionId) {
                        sessionCatalogLog.debug(
                            "Skipping buffered delta dedup because resumed session \(result.sessionId, privacy: .private(mask: .hash)) is not a boundary-confirmed alias (boundary=\(boundarySessionID, privacy: .private(mask: .hash)))"
                        )
                    }
                } else {
                    acceptedSessionIDs = [result.sessionId]
                }
                let knownPrefix: String?
                let coveredText: String?
                if let boundary {
                    knownPrefix = Self.normalizedReconciliationBoundaryPrefix(
                        boundaryText: boundary.streamTextAtBoundary,
                        boundarySessionID: boundary.streamSessionIDAtBoundary,
                        resumedSessionID: result.sessionId,
                        acceptedSessionIDs: acceptedSessionIDs,
                        after: messages
                    )
                    coveredText = Self.reconciliationBoundaryCoverageText(
                        boundaryText: boundary.streamTextAtBoundary,
                        boundarySessionID: boundary.streamSessionIDAtBoundary,
                        resumedSessionID: result.sessionId,
                        acceptedSessionIDs: acceptedSessionIDs,
                        snapshotInflightText: result.snapshot.inflightAssistantText,
                        after: messages
                    )
                } else {
                    knownPrefix = nil
                    coveredText = nil
                }

                // The live bubble was just seeded from the cumulative inflight
                // projection, which already includes deltas emitted while this
                // reconciliation was in flight. Replay only the portion beyond
                // the normalized text captured at the same session boundary.
                let deduplicated = Self.deduplicatingBufferedEvents(
                    bufferedEvents,
                    againstInflight: resumedInflightText,
                    knownPrefix: knownPrefix,
                    sessionID: result.sessionId,
                    acceptedSessionIDs: acceptedSessionIDs,
                    coveredText: coveredText,
                    hasBoundaryAnchor: boundary?.streamTextAtBoundary?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty == false
                )
                bufferedGenerations = Self.generations(
                    bufferedGenerations, of: bufferedEvents, keptIn: deduplicated
                )
                bufferedEvents = deduplicated
            }
            let bufferedYoloAuthority = reconcileExplicitYolo ? result.snapshot.yolo : nil
            // The approval mode is profile-scoped and independent of the
            // per-session YOLO write gate: a user toggle during the resume must
            // not let a stale buffered event re-impose an outdated floor.
            let bufferedApprovalsModeAuthority = result.snapshot.approvalsMode
            zip(bufferedEvents, bufferedGenerations).forEach { event, generation in
                applyNumberedStreamEvent(
                    event,
                    turnGeneration: generation,
                    authoritativeYolo: bufferedYoloAuthority,
                    authoritativeApprovalsMode: bufferedApprovalsModeAuthority
                )
            }
            // Rows kept from the screen aren't proof the chat is current
            // (applyChatResume took them as if they were); a history read
            // that failed for now is tried again before the next send.
            if keptRowsAwaitHistory {
                transcriptFreshnessIsStale = true
            }
            let settled = settleReconciliationAndPublish(
                token,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID
            )
            // The chat resumed: an earlier failure waiting behind a room is
            // no longer news when the room closes, nor the one on screen if
            // it was a failed restore of this chat (issue 2025: the error
            // stayed over a chat that came back on the next try).
            if settled {
                chatErrorBehindRoom = nil
                if let failed = chatRestoreFailureShown, errorMessage == failed {
                    errorMessage = nil
                }
                chatRestoreFailureShown = nil
            }
            if settled, reconcileExplicitYolo {
                // Re-assert only after the ownership guard above (token,
                // profile, client) re-validated this reconciliation and after
                // the synchronous settle, so a profile or client switch during
                // the suspending reads above cannot push a stale
                // write through the old client for the old profile's session.
                // A user YOLO write that completed since the resume began
                // already pushed the server, so skip instead of duplicating
                // it; one still in flight is skipped inside
                // reassertSessionYolo. The mid-RPC race is accepted: the value
                // was chosen under verified ownership, and the next resume
                // reconciles.
                await reassertSessionYolo(
                    for: result.sessionId,
                    snapshot: result.snapshot,
                    using: client
                )
            }
            return settled

        } catch {
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return false
            }
            // An empty chat made here that Hermes lost: a fresh one in its
            // place, rather than a restore error no refresh can clear.
            // Only the resume's own refusal (4007 on the dashboard, 4001
            // not_found on the authority), never a history read's 404.
            if resumeRPCFailedSessionNotFound
                || (error as? RpcError).map(HermesClient.isSessionNotFoundError) == true,
               conversationScopeProfile == nil,
               openChatIsEmptyNewChat(acceptedSessionIDs.union([sessionId])) {
                return await replaceLostEmptyNewChat(
                    lostSessionIDs: acceptedSessionIDs.union([sessionId]),
                    using: client,
                    profile: profile,
                    token: token,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticSyncOperationID,
                    requiredViewportTransitionGeneration: requiredViewportTransitionGeneration,
                    widgetLease: widgetLease
                )
            }
            // Before the failure state, which the replayed prompts' running
            // edge must not overwrite.
            replayBufferedDecisionPrompts(for: token)
            turnState = .reconnecting
            reconciliationSessionWasNotFound = resumeRPCFailedSessionNotFound
            switch error {
            case is LegacyTranscriptOversizedError, DashboardTicketBridgeError.oversizedResponse:
                // Oversized history responses carry their own user-facing
                // copy: the legacy compatibility message for an old backend
                // attempting the whole transcript, neutral copy for a
                // bounded current-Hermes page with one enormous row (which
                // must not claim the backend lacks pagination).
                chatSyncErrorMessage = UserFacingError.message(for: error)
            case let rpcError as RpcError where rpcError.code == 4132:
                // A Kanban worker's transcript: Hermes lets only the board
                // run it. Lists leave these out; a link can still reach one.
                reconciliationWasKanbanWorker = true
                reconciliationSessionWasNotFound = true
                chatSyncErrorMessage = AppLocalization.string("This chat is a Kanban task's worker, so only the board can run it. Open the task on the Kanban board and check its Worker Log.")
            default:
                chatSyncErrorMessage = AppLocalization.string("Failed to restore this conversation: \(UserFacingError.message(for: error))")
            }
            // A later restore of the chat that works takes it down again.
            chatRestoreFailureShown = chatSyncErrorMessage
            settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
            chatResumeCoordinator.abandonPendingAutomaticSync()
            return false
        }
    }

    /// Whether the rows on screen are the chat these ids name: the open
    /// chat by any id it answers to (its durable id, a rotated runtime, the
    /// catalog's aliases), since an automatic return resumes a Bot Chat by
    /// its saved stored id while it is open by its runtime id (issue 2025).
    private func rowsOnScreenBelong(to ids: [String?]) -> Bool {
        guard let open = activeSessionId else { return false }
        let own = Set((chatOwnSessionIDs(for: open).union([open]))
            .compactMap { ChatScrollIdentityNormalization.sessionID($0) })
        return ids.contains { id in
            ChatScrollIdentityNormalization.sessionID(id).map(own.contains) == true
        }
    }

    func openChatResumeSession(
        _ sessionID: String,
        using client: HermesClient,
        compact: Bool,
        profile: String? = nil
    ) async throws -> SessionResumeResult {
        if let openSessionWithProfile = chatResumeLifecycleOperations.openSessionWithProfile {
            return try await openSessionWithProfile(client, sessionID, compact, profile)
        }
        if let openSession = chatResumeLifecycleOperations.openSession {
            return try await openSession(client, sessionID, compact)
        }
        let label = compact ? "Chat resume" : "Chat resume with full transcript"
        let startedAt = Date()
        do {
            let result: SessionResumeResult
            if compact {
                result = try await client.openSession(sessionID, profile: profile)
            } else {
                result = try await client.openSessionLegacy(sessionID, profile: profile)
            }
            noteConnectionStep(label, since: startedAt)
            return result
        } catch {
            noteConnectionStep(label, since: startedAt, error: error)
            throw error
        }
    }

    /// Reads the resumed chat's context breakdown without holding the
    /// reconcile. Its answer applies only while the same client still has
    /// the same chat open (refreshContextUsage).
    @discardableResult
    private func scheduleChatResumeContextRefresh(
        sessionId: String,
        using client: HermesClient
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            await self?.refreshChatResumeContext(sessionId: sessionId, using: client)
        }
    }

    private func refreshChatResumeContext(
        sessionId: String,
        using client: HermesClient
    ) async {
        if let refreshContext = chatResumeLifecycleOperations.refreshContext {
            await refreshContext(client, sessionId)
        } else {
            await refreshContextUsage(sessionId: sessionId, using: client)
        }
    }

    /// Best-effort recovery for approvals queued behind the single oldest
    /// `pending_approval` carried by `session.resume`. The read is deliberately
    /// detached from the foreground restore path and additive: an absent row
    /// is not expiry evidence, and a replay must not unlock a local submission
    /// or terminal decision.
    @discardableResult
    func schedulePendingApprovalsRefresh(
        sessionId: String,
        using client: HermesClient,
        replacingLegacyErrorMessageID: String? = nil
    ) -> Task<Void, Never> {
        pendingApprovalsRequestGeneration &+= 1
        let generation = pendingApprovalsRequestGeneration
        let profile = presentationProfile(for: sessionId)
        let viewportGeneration = chatViewportTransitionGeneration
        let reconciliationGeneration = reconciliationToken
        let acceptedSessionIDs = activeChatScrollSessionIdentity.equivalentSessionIDs
            .union([sessionId])

        // Snapshot every locally-known identified pending/submitting request
        // ID *before* the RPC starts.  After the response returns only IDs
        // present in this snapshot are eligible for retirement — approvals
        // that arrived via stream events while the RPC was in flight are
        // invisible to the snapshot and therefore safe from spurious deletion.
        let identifiedRequestIDsKnownAtRequestStart: Set<String> = Set(
            messages.compactMap { message in
                guard let approval = message.approval,
                      acceptedSessionIDs.contains(approval.sessionId),
                      let reqId = approval.requestId,
                      SessionPresentationCache.isPendingDecision(approval.status) else {
                    return nil
                }
                return reqId
            }
        )

        return Task { @MainActor [weak self] in
            let approvals: [ApprovalActivity]
            do {
                if let pendingApprovalsWithProfile = self?.chatResumeLifecycleOperations.pendingApprovalsWithProfile {
                    approvals = try await pendingApprovalsWithProfile(client, sessionId, profile)
                } else if let pendingApprovals = self?.chatResumeLifecycleOperations.pendingApprovals {
                    approvals = try await pendingApprovals(client, sessionId)
                } else {
                    approvals = try await client.pendingApprovals(sessionId: sessionId, profile: profile)
                }
            } catch {
                // Older gateways do not expose approval.pending, and this
                // optional recovery read may also time out. Neither is
                // evidence that an already-present card was resolved.
                return
            }
            guard let self,
                  generation == self.pendingApprovalsRequestGeneration,
                  profile == self.presentationProfile(for: sessionId),
                  self.client === client,
                  viewportGeneration == self.chatViewportTransitionGeneration,
                  reconciliationGeneration == self.reconciliationToken,
                  !acceptedSessionIDs.isDisjoint(
                    with: self.activeChatScrollSessionIdentity.equivalentSessionIDs
                  ) else { return }

            let acceptedApprovals = approvals.filter {
                acceptedSessionIDs.contains($0.sessionId)
            }
            let returnedIdentifiedRequestIDs = Set(acceptedApprovals.compactMap { $0.requestId })
            let cacheSessionIDs = self.presentationCacheSessionIDs(for: sessionId)

            if let replacingLegacyErrorMessageID {
                // The error that started this read may since have been
                // retried (the card reads Sending) or answered: that
                // submission owns the card now and settles it, so this
                // read replaces nothing.
                if let card = self.messages.first(where: { $0.id == replacingLegacyErrorMessageID }),
                   card.approval?.status != .error {
                    return
                }
                let identifiedApprovals = acceptedApprovals.filter { $0.requestId != nil }
                if !identifiedApprovals.isEmpty {
                    self.messages.removeAll { $0.id == replacingLegacyErrorMessageID }
                }
                // Started only after the legacy response settled: these
                // identified rows are fresh gateway truth and can replace the
                // ambiguous legacy card without guessing by text or position.
                for approval in identifiedApprovals {
                    self.applyApprovalActivity(approval, authoritative: true)
                }
            } else {
                // A successful approval.pending read provides the authoritative
                // unresolved identified queue. Retire any local identified
                // pending/submitting cards that are absent from the returned
                // queue, provided they are not actively executing an in-process
                // submission RPC right now on this device.
                var retiredRequestIDs = Set<String>()
                self.messages.removeAll { message in
                    guard let existing = message.approval,
                          acceptedSessionIDs.contains(existing.sessionId),
                          let reqId = existing.requestId,
                          SessionPresentationCache.isPendingDecision(existing.status) else {
                        return false
                    }
                    // Only IDs that existed locally before the RPC started are
                    // eligible — anything that arrived via a stream event while
                    // the RPC was in flight must survive.
                    guard identifiedRequestIDsKnownAtRequestStart.contains(reqId) else {
                        return false
                    }
                    if self.hasLiveApprovalSubmission(for: existing, equivalentSessionIDs: acceptedSessionIDs) {
                        return false
                    }
                    if !returnedIdentifiedRequestIDs.contains(reqId) {
                        retiredRequestIDs.insert(reqId)
                        return true
                    }
                    return false
                }
                for reqId in retiredRequestIDs {
                    self.sessionPresentationCache.removePendingDecision(
                        key: "approval-request:\(reqId)",
                        profile: profile,
                        sessionIDs: cacheSessionIDs
                    )
                }

                for approval in acceptedApprovals {
                    if approval.requestId != nil {
                        // Identified approvals are authoritatively reconciled
                        // against the gateway's complete pending queue.
                        self.applyApprovalActivity(approval, authoritative: true)
                    } else {
                        // Legacy approvals are session-scoped and FIFO; do not
                        // destructively overwrite legacy active cards with an
                        // authoritative replay.
                        self.applyApprovalActivity(approval, authoritative: false)
                    }
                }
            }
            self.cacheMessagePresentation()
        }
    }

    /// Returns the chat it created and opened, nil when it opened none.
    @discardableResult
    func createAndReconcileSession(
        using client: HermesClient,
        profile: String,
        token: UUID,
        resumePurpose: ChatResumeSyncPurpose = .preserveCurrent,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil,
        requiredViewportTransitionGeneration: UInt64? = nil,
        cwd: String? = nil,
        widgetLease: WidgetLaunchLease? = nil,
        listsBeforeHermes: Bool = false
    ) async -> String? {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ), chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
              widgetLease?.isCurrent != false else { return nil }
        do {
            let created: (sessionId: String, storedSessionId: String?, profile: String?)
            if let widgetSessionCreatorOverride {
                created = try await widgetSessionCreatorOverride(client, cwd)
            } else if let createSession = chatResumeLifecycleOperations.createSession {
                created = try await createSession(client, cwd)
            } else {
                // No model: a new chat runs on the profile's default model,
                // not on whatever the chat open before it was switched to
                // (#916). The model picker switches this chat afterwards.
                created = try await client.createSession(cwd: cwd)
            }
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  widgetLease?.isCurrent != false,
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                return nil
            }
            if let returnedProfile = created.profile,
               !profilesMatch(returnedProfile, profile) {
                turnState = .idle
                errorMessage = AppLocalization.string("Hermes created this conversation in \(profileDisplayName(returnedProfile)), not \(profileDisplayName(profile)). It was not opened.")
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                await loadSessions(forceRefresh: true)
                return nil
            }
            let runtimeSessionID = created.sessionId.isEmpty ? (created.storedSessionId ?? "") : created.sessionId
            guard !runtimeSessionID.isEmpty else {
                turnState = .idle
                errorMessage = AppLocalization.string("Hermes didn't finish creating the conversation. Try again.")
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                chatResumeCoordinator.abandonPendingAutomaticSync()
                return nil
            }

            // `session.create` already returns the active runtime session.
            // Some Hermes versions do not make its history-resume record
            // available immediately, so resuming here races the persistence
            // layer and leaves the composer stuck synchronizing.
            markChatViewportReplacement()
            setActiveSessionState(id: runtimeSessionID, title: AppLocalization.string("New conversation"))
            // The model shown is the previous chat's until Hermes reports
            // this one's (session.info), and this chat may run on another.
            runtime.model = ""
            runtime.provider = ""
            runtime.serviceTier = ""
            keepDelegateAgents(of: [])
            newChatOpenedSessionID = runtimeSessionID
            newChatOpenedDurableSessionID = created.storedSessionId ?? runtimeSessionID
            messages = []
            dismissOfflineChatPresentation()
            persistedTranscriptWindow = nil
            resetTranscriptLifecycleEvidence()
            noteChatViewportTranscriptReplacement()
            clearStreamingText()
            activeAssistantMessageId = nil
            resetReasoningTurn()
            turnState = .idle
            noteConnectionStep("New chat ready")
            errorMessage = nil
            // A fresh conversation has no per-session override and no
            // server-reported flag yet; re-resolve from the profile mode
            // (still valid — it is profile-scoped) so the new chat does not
            // inherit the previous session's effective indicator until the
            // first snapshot arrives.
            lastReportedSessionYolo = nil
            if runtime.approvalsMode != nil {
                applyEffectiveYolo(
                    sessionIDsForOverride: [runtimeSessionID],
                    snapshotYolo: nil,
                    snapshotReportedApprovalsMode: runtime.approvalsMode
                )
            } else {
                runtime.yolo = false
            }

            let storedID = created.storedSessionId ?? runtimeSessionID
            // The create response's runtime/stored semantics are verified
            // here (the summary is built from the same response), so the
            // pair is fresh authoritative evidence: the created conversation
            // is being adopted into the catalog below, and the index must
            // agree rather than keep any historical mapping for the runtime.
            if let runtime = ChatScrollIdentityNormalization.sessionID(runtimeSessionID),
               let durable = ChatScrollIdentityNormalization.sessionID(storedID),
               runtime != durable {
                conversationIdentityIndex.recordAuthoritative(
                    runtimeID: runtime,
                    durableID: durable,
                    profile: activeProfile,
                    source: .create
                )
            }
            let summary = SessionSummary(
                id: storedID,
                alternateIds: [runtimeSessionID, created.storedSessionId]
                    .compactMap { $0 }
                    .filter { $0 != storedID },
                title: activeSessionTitle,
                model: runtime.model.isEmpty ? "Hermes" : runtime.model,
                updatedLabel: AppLocalization.string("now"),
                // A locally-created conversation's activity is NOW: without
                // this instant its row would rank behind every dated row in
                // the "latest activity" fallback, abandoning a conversation
                // whose first turn is still in flight.
                lastActivityAt: Date().timeIntervalSince1970,
                profile: activeProfile,
                source: .chat,
                isActive: true,
                isArchived: false,
                lineageRootId: nil
            )
            sessions = [summary] + sessions.map { existing in
                var updated = existing
                updated.isActive = false
                return updated
            }
            // A chat someone started is listed at once; one a sync starts
            // because there was nothing to resume waits for Hermes.
            if listsBeforeHermes {
                newChatAwaitingListing = NewChatAwaitingListing(
                    ids: Self.chatListIDs(of: [summary]),
                    profile: activeProfile,
                    cwd: cwd
                )
            }
            if resumePurpose == .automaticReturn {
                _ = selectChatResumeTarget(
                    in: [summary],
                    profile: profile,
                    purpose: resumePurpose,
                    currentSessionID: runtimeSessionID,
                    automaticWorkToken: automaticWorkToken,
                    automaticSyncOperationID: automaticSyncOperationID
                )
            }
            Task { [weak self] in
                guard let self,
                      self.activeProfile == profile,
                      self.activeSessionId == runtimeSessionID else { return }
                await self.loadSlashCommands()
                await self.loadSessions()
            }
            settleReconciliationAndPublish(
                token,
                automaticWorkToken: automaticWorkToken,
                automaticSyncOperationID: automaticSyncOperationID
            )
            return runtimeSessionID
        } catch {
            guard automaticChatResumeWorkIsCurrent(
                    automaticWorkToken,
                    syncOperationID: automaticSyncOperationID
                  ),
                  chatViewportTransitionIsCurrent(requiredViewportTransitionGeneration),
                  widgetLease?.isCurrent != false,
                  token == reconciliationToken,
                  profile == activeProfile,
                  let activeClient = self.client,
                  activeClient === client else {
                settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
                return nil
            }
            turnState = .idle
            chatSyncErrorMessage = AppLocalization.string("Failed to create session: \(UserFacingError.message(for: error))")
            settleReconciliation(token, automaticSyncOperationID: automaticSyncOperationID)
            chatResumeCoordinator.abandonPendingAutomaticSync()
            if resumePurpose == .automaticReturn {
                scheduleReconnectAfterFailedSync()
            }
            return nil
        }
    }

    @discardableResult
    func applyChatResume(
        _ result: SessionResumeResult,
        automaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticSyncOperationID: UUID? = nil
    ) -> Bool {
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            syncOperationID: automaticSyncOperationID
        ) else { return false }
        let retainedRestoredMessages = pendingDecisionRestorationMessages(for: result.sessionId)
        let previousSessionID = activeSessionId
        let previousMessages = messages
        // The server answered with an authoritative conversation: it replaces
        // the read-only offline copy wholesale, even when it is empty.
        dismissOfflineChatPresentation()
        markChatViewportReplacement()
        // A canonical Bot Chat keeps the title the open just applied (the
        // bot's display label) and is recorded with kind `.bot`: cold launch
        // restores the conversation the user was in, while the ordinary
        // Sessions surface never adopts it. The create-adoption defaults
        // (title, durable-identity persistence) apply only to
        // dashboard-profile conversations.
        let isBotConversation = botConversationProfile(for: result.sessionId) != nil
        setActiveSessionState(
            id: result.sessionId,
            title: isBotConversation ? nil : AppLocalization.string("New conversation")
        )
        // The durable identity is recorded for BOTH kinds — the reference's
        // own kind is resolved from the bot registry, so a Bot Chat persists
        // as a Bot Chat. Only the dashboard profile's title cache stays
        // ordinary-only: the bot's label belongs to the conversation, not to
        // the workspace's title bookkeeping.
        persistAdmittedDurableSessionIdentity(from: result)
        if !isBotConversation {
            updateActiveSessionTitle(
                for: result.sessionId,
                fallbackSessionId: reconciliation?.requestedSessionId
            )
        }
        // Pending clarifications and approvals are user-actionable decision
        // events, not merely projections of the gateway's current turn state.
        // Hermes can omit a one-shot decision event from a resume, and
        // `running == false` can describe the preceding text even while the
        // decision remains unresolved. Restore both card types independently
        // of the turn snapshot; the gateway decision key remains authoritative
        // when it includes a resolved record.
        let restorePendingDecisionCards = true
        let sessionIDs = [result.sessionId, reconciliation?.requestedSessionId].compactMap { $0 }
        let gatewayDecisionKeys = Set(result.messages.compactMap(SessionPresentationCache.decisionKey(for:)))
        let retainedMessages = retainedRestoredMessages.filter { message in
            guard let key = SessionPresentationCache.decisionKey(for: message),
                  !gatewayDecisionKeys.contains(key) else {
                return false
            }
            return restorePendingDecisionCards
        }
        let restored = sessionPresentationCache.merge(
            result.messages + retainedMessages,
            profile: presentationProfile(for: result.sessionId),
            sessionIDs: sessionIDs,
            includePendingClarifications: restorePendingDecisionCards,
            includePendingApprovals: restorePendingDecisionCards,
            includePendingTools: result.snapshot.running != false
        )
        // Hermes' rows don't hold the chat's own notes: a refresh of the same
        // chat keeps them, a resume of another chat leaves them behind.
        let resumedIDs = chatOwnSessionIDs(for: result.sessionId)
            .union(sessionIDs + [result.storedSessionId].compactMap { $0 })
        let isSameChat = previousSessionID.map {
            !chatOwnSessionIDs(for: $0).union([$0]).isDisjoint(with: resumedIDs)
        } ?? false
        // The same messages from the other source (Hermes' stored rows or a
        // resume's) keep the ids they're drawn under (#1648).
        let rekeyed = isSameChat
            ? Self.keepingRowIDs(from: previousMessages, in: restored, durableIDs: durablePersistedRowIDs)
            : restored
        let rebuilt = isSameChat ? Self.keepingLocalNotes(from: previousMessages, in: rekeyed) : rekeyed
        messages = mergeVoiceCallMarkers(into: mergeCachedReviews(into: rebuilt, sessionId: result.sessionId), sessionId: result.sessionId)
        // A cached push copy of a clarify the transcript already holds from
        // Hermes goes, so one question never shows as two cards.
        for live in messages.compactMap(\.clarify)
        where !live.requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix) {
            removePushCardsSuperseded(by: live)
        }
        if result.snapshot.running == false {
            sessionPresentationCache.removePendingTools(
                profile: presentationProfile(for: result.sessionId),
                sessionIDs: presentationCacheSessionIDs(for: result.sessionId)
            )
        }
        // The gateway's authoritative pending clarification restores the
        // answerable card even when the one-shot clarify.request fired while
        // this device was detached; answers locked before the detach come
        // back keyed by qid and stay locked. Keyed by request_id, so a resume
        // refresh updates an existing card instead of duplicating it.
        if let pendingClarify = result.snapshot.pendingClarify {
            applyClarifyActivity(pendingClarify, source: .authoritativeSnapshot)
        }
        for clarify in result.snapshot.additionalPendingClarifies {
            applyClarifyActivity(clarify, source: .authoritativeSnapshot)
        }
        // Masked input prompts are live-only (never cached), so the rebuilt
        // transcript holds none: the gateway's open requests are the whole
        // truth, and a prompt withdrawn while detached simply stays gone.
        for prompt in result.snapshot.pendingInputPrompts {
            applyInputPromptActivity(prompt, authoritative: true)
        }
        // The open connect card, live-only like the input cards: the
        // resume's copy is the whole truth.
        if let payload = result.snapshot.pendingConnectionPayload,
           let connection = ConnectionActivity.from(payload: payload, sessionId: result.sessionId) {
            applyConnectionActivity(connection)
        }
        let authoritativePendingApproval = result.snapshot.pendingApprovalPayload.flatMap {
            MessageNormalizer.approvalActivity(from: $0, sessionId: result.sessionId)
        }
        if let pendingApproval = authoritativePendingApproval {
            applyApprovalActivity(pendingApproval, authoritative: true)
        }
        noteChatViewportTranscriptReplacement()
        // An authoritative resume/reconcile just replaced the transcript:
        // whatever rows a failed freshness read could not see are now either
        // present or authoritatively absent, any optimistic-turn provenance
        // died with the rows it pointed at, and the adopted ordering
        // frontier covers everything persisted — no local debt can outlive
        // it.
        transcriptFreshnessIsStale = false
        locallyOwnedInFlightTurn = nil
        pendingLocalOrderingDebt = nil
        var gatewayPendingDecisionKeys = SessionPresentationCache.pendingDecisionKeys(in: result.messages)
        if let pendingClarify = result.snapshot.pendingClarify {
            gatewayPendingDecisionKeys.insert("clarify:\(pendingClarify.requestId)")
        }
        for clarify in result.snapshot.additionalPendingClarifies {
            gatewayPendingDecisionKeys.insert("clarify:\(clarify.requestId)")
        }
        if let pendingApproval = authoritativePendingApproval,
           let key = SessionPresentationCache.pendingDecisionKey(for: ChatMessage(
               id: "pending-approval-key",
               role: .approval,
               content: pendingApproval.description,
               timestamp: "",
               approval: pendingApproval
           )) {
            gatewayPendingDecisionKeys.insert(key)
        }
        let restoredPendingDecisionKeys = SessionPresentationCache
            .pendingDecisionKeys(in: messages)
            .subtracting(gatewayPendingDecisionKeys)
        let liveSubmittingApprovalKeys = Set(
            messages.compactMap { message -> String? in
                guard let approval = message.approval, approval.status == .submitting else { return nil }
                let equivalentSessionIDs = activeChatScrollSessionIdentity.equivalentSessionIDs
                    .union([approval.sessionId])
                guard hasLiveApprovalSubmission(
                    for: approval,
                    equivalentSessionIDs: equivalentSessionIDs
                ) else { return nil }
                return SessionPresentationCache.decisionKey(for: message)
            }
        )
        let resettableRestoredDecisionKeys = restoredPendingDecisionKeys
            .subtracting(liveSubmittingApprovalKeys)
        let gatewayHasPendingDecision = !gatewayPendingDecisionKeys.isEmpty
        var restoredMessagesAwaitingConfirmation: [ChatMessage] = []
        if result.snapshot.running != true && !resettableRestoredDecisionKeys.isEmpty {
            Self.resetSubmittingRestoredDecisions(
                in: &messages,
                matching: resettableRestoredDecisionKeys
            )
            restoredMessagesAwaitingConfirmation = messages.filter {
                guard let key = SessionPresentationCache.decisionKey(for: $0),
                      resettableRestoredDecisionKeys.contains(key) else {
                    return false
                }
                return SessionPresentationCache.pendingDecisionKey(for: $0) != nil
            }
        } else {
            clearPendingDecisionRestorationGuard()
        }
        let hasPendingDecision = Self.hasPendingDecision(in: messages)
        // Persist the gateway transcript on every resume so fresh rows are not
        // lost. A locally restored card remains in the active AppState for the
        // next foreground cycle. Any pending decision observed without an
        // explicit active-turn signal is persisted with a bounded unconfirmed
        // marker. The marker is intentionally independent from
        // `gatewayConfirmsActiveTurn`: an ambiguous resume may contain a
        // gateway-provided card that still needs the same stale-card guard.
        let gatewayConfirmsActiveTurn = result.snapshot.running == true
            || (result.snapshot.running != false && gatewayHasPendingDecision)
        let unconfirmedPendingDecisionKeys = result.snapshot.running != true
            ? SessionPresentationCache.pendingDecisionKeys(in: messages)
            : []
        let shouldPersistMergedPresentation = gatewayConfirmsActiveTurn
            || !unconfirmedPendingDecisionKeys.isEmpty
        // Persisted presentation is durable-owned: once this conversation's
        // canonical/durable id is established, alias keys are not re-created
        // by writes (the merge lookup above stays a tolerant superset).
        let persistedSessionIDs = Self.durableOwnedPresentationIDs(
            sessionIDs,
            durableSessionID: reconciliation?.resolvedDurableSessionId
                ?? activeChatScrollSessionIdentity.canonicalSessionID
        )
        sessionPresentationCache.save(
            shouldPersistMergedPresentation ? messages : result.messages,
            profile: presentationProfile(for: result.sessionId),
            sessionIDs: persistedSessionIDs,
            preservePendingDecisionCards: gatewayConfirmsActiveTurn || !unconfirmedPendingDecisionKeys.isEmpty,
            unconfirmedPendingDecisionKeys: unconfirmedPendingDecisionKeys
        )
        if result.snapshot.running != true && !resettableRestoredDecisionKeys.isEmpty {
            let restoredAt = sessionPresentationCache.unconfirmedPendingDecisionDate(
                profile: presentationProfile(for: result.sessionId),
                sessionIDs: sessionIDs
            ) ?? Date()
            restoredPendingDecisionCardsAwaitingConfirmation = PendingDecisionRestorationGuard(
                profile: presentationProfile(for: result.sessionId),
                sessionID: result.sessionId,
                pendingDecisionKeys: resettableRestoredDecisionKeys,
                restoredAt: restoredAt,
                messages: restoredMessagesAwaitingConfirmation
            )
        }
        scheduleSecondaryProfileTitleRecovery(
            sessionId: result.sessionId,
            messages: messages
        )
        clearStreamingText()
        if result.snapshot.hasLiveProjection {
            let recoveredText = Self.unpersistedInflightAssistantText(
                result.snapshot.inflightAssistantText,
                after: messages
            )
            streamingBuffer = recoveredText
            streamingText = recoveredText
        }
        activeAssistantMessageId = nil
        resetReasoningTurn()
        applyRuntime(
            result.snapshot,
            for: result.sessionId
        )
        // Agents this chat started that are still running: a chat opened
        // (or reconnected) after they began never saw them start.
        let resumedSessionID = result.sessionId
        Task { [weak self] in _ = await self?.adoptDelegateRoster(for: resumedSessionID) }
        // Its standing goal, loop and heartbeat, for the dock above the
        // composer.
        Task { [weak self] in await self?.refreshSessionControl(for: resumedSessionID) }
        chatCards.applyServerPlan(
            result.snapshot.todoState,
            for: chatCardsChat(including: [result.sessionId, result.storedSessionId])
        )

        noteConnectionStep("Chat ready")
        // An omitted running state is ambiguous while a decision or live
        // projection is present, but an explicit false is authoritative: the
        // session is idle even when a pending card remains answerable.
        if result.snapshot.running == nil && (result.snapshot.hasLiveProjection || hasPendingDecision) {
            turnState = .running
        } else if TurnState.fromGatewayRunning(result.snapshot.running) == .unsupportedGateway {
            turnState = .unsupportedGateway
            errorMessage = AppLocalization.string("Update Hermes to send, stop, and steer messages from Conduit. This version can't report whether a reply is still running.")
            return true
        } else {
            turnState = TurnState.fromGatewayRunning(result.snapshot.running)
        }
        // A resume that says the turn is over settles it, as setRunning(false)
        // does: its notes are no longer running (a forced idle that only
        // unsticks a sync keeps them; their ids are unique to this turn).
        if result.snapshot.running == false { runningTurnNoteIDs = [] }
        // The resume snapshot is authoritative about the turn state.
        turnLifecycleEvidence = TurnLifecycleEvidence(
            revision: turnLifecycleEvidence.revision &+ 1,
            running: turnState.isRunning
        )
        turnStateIsStale = false
        return true
    }

    /// A resume can rotate the ephemeral runtime ID after a process relaunch.
    /// Persist the stored identity that Hermes admitted, not the runtime ID
    /// that happens to route this process, so the next cold launch addresses
    /// the durable conversation even before its catalog row appears.
    private func persistAdmittedDurableSessionIdentity(from result: SessionResumeResult) {
        guard let durableSessionID = ChatScrollIdentityNormalization.sessionID(
            reconciliation?.resolvedDurableSessionId ?? result.storedSessionId
        ) else {
            return
        }
        let durableKey = ChatScrollSessionKey(
            profile: activeProfile,
            sessionID: durableSessionID
        )
        guard durableKey.isValid else { return }

        if let runtimeSessionID = ChatScrollIdentityNormalization.sessionID(result.sessionId) {
            let runtimeKey = ChatScrollSessionKey(
                profile: activeProfile,
                sessionID: runtimeSessionID
            )
            if runtimeKey.isValid, runtimeKey != durableKey {
                chatResumeCoordinator.migrateSessionIdentity(from: runtimeKey, to: durableKey)
            }
        }
        chatResumeCoordinator.rememberSession(
            sessionReference(forPersistedID: durableKey.sessionID, activeSessionID: activeSessionId),
            for: durableKey.profile
        )
    }

    static func hasPendingDecision(in messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            // A retryable `.error` or in-flight `.submitting` question stays
            // unresolved; an expired sibling does not erase an active answer.
            let clarifyPending = message.clarify.map {
                SessionPresentationCache.isPendingDecision($0)
            } ?? false
            let approvalPending = message.approval.map {
                SessionPresentationCache.isPendingDecision($0.status)
            } ?? false
            let inputPending = message.inputPrompt.map {
                $0.isAnswerable || $0.status == .submitting
            } ?? false
            let connectionPending = message.connection?.isOpen ?? false
            return clarifyPending || approvalPending || inputPending || connectionPending
        }
    }

    private static func resetSubmittingRestoredDecisions(
        in messages: inout [ChatMessage],
        matching keys: Set<String>
    ) {
        for index in messages.indices {
            if var clarify = messages[index].clarify,
               clarify.questions.contains(where: { $0.status == .submitting }),
               let key = SessionPresentationCache.decisionKey(for: messages[index]),
               keys.contains(key) {
                // A restored .submitting question has no knowable outcome —
                // its RPC died with the previous process. Answered sibling
                // questions stay locked; only the in-flight ones reset.
                for questionIndex in clarify.questions.indices
                where clarify.questions[questionIndex].status == .submitting {
                    clarify.questions[questionIndex].status = .pending
                    clarify.questions[questionIndex].answer = nil
                    clarify.questions[questionIndex].error = nil
                }
                messages[index].clarify = clarify
            }
            if var approval = messages[index].approval,
               approval.status == .submitting,
               let key = SessionPresentationCache.decisionKey(for: messages[index]),
               keys.contains(key) {
                approval.status = .pending
                approval.choice = nil
                approval.error = nil
                messages[index].approval = approval
            }
        }
    }

    /// Deltas buffered while reconciliation ran are usually already contained
    /// in the resume snapshot's cumulative `inflight` projection — replaying
    /// them on top of the seeded live bubble repeats that text. When the exact
    /// stream text at the matching session boundary is known, consume only the
    /// corresponding span of the buffered deltas. Edge whitespace is ignored
    /// consistently with resume seeding, and the raw covered count preserves
    /// event order when deltas carry that whitespace. Interior whitespace is
    /// not rewritten: a mismatch may be real content, so leave it intact.
    /// Without a matching boundary or session, repeated text is ambiguous, so
    /// leave events intact.
    nonisolated static func normalizedReconciliationBoundaryPrefix(
        boundaryText: String?,
        boundarySessionID: String?,
        resumedSessionID: String,
        acceptedSessionIDs: Set<String>,
        after messages: [ChatMessage]
    ) -> String? {
        guard let boundaryText,
              let boundarySessionID,
              !boundarySessionID.isEmpty,
              acceptedSessionIDs.contains(boundarySessionID),
              acceptedSessionIDs.contains(resumedSessionID) else {
            return nil
        }
        return unpersistedInflightAssistantText(boundaryText, after: messages)
    }

    nonisolated static func reconciliationBoundaryCoverageText(
        boundaryText: String?,
        boundarySessionID: String?,
        resumedSessionID: String,
        acceptedSessionIDs: Set<String>,
        snapshotInflightText: String,
        after messages: [ChatMessage]
    ) -> String? {
        guard let boundaryText,
              let boundarySessionID,
              !boundarySessionID.isEmpty,
              acceptedSessionIDs.contains(boundarySessionID),
              acceptedSessionIDs.contains(resumedSessionID) else {
            return nil
        }

        let normalizedBoundaryText = boundaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSnapshotText = snapshotInflightText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSnapshotText.hasPrefix(normalizedBoundaryText) {
            return String(normalizedSnapshotText.dropFirst(normalizedBoundaryText.count))
        }

        let normalizedUnpersistedBoundary = unpersistedInflightAssistantText(
            boundaryText,
            after: messages
        )
        let normalizedUnpersistedSnapshot = unpersistedInflightAssistantText(
            snapshotInflightText,
            after: messages
        )
        guard normalizedUnpersistedSnapshot.hasPrefix(normalizedUnpersistedBoundary) else {
            return nil
        }
        return String(
            normalizedUnpersistedSnapshot.dropFirst(normalizedUnpersistedBoundary.count)
        )
    }

    /// The generations of the events `deduplicatingBufferedEvents` kept,
    /// which drops only the earliest deltas (and may trim the next one in
    /// place), so the rest keep their slots.
    nonisolated static func generations(
        _ generations: [Int?],
        of events: [StreamEvent],
        keptIn deduplicated: [StreamEvent]
    ) -> [Int?] {
        guard generations.count == events.count else {
            return Array(repeating: nil, count: deduplicated.count)
        }
        var dropped = events.count - deduplicated.count
        var kept: [Int?] = []
        kept.reserveCapacity(deduplicated.count)
        for (event, generation) in zip(events, generations) {
            if dropped > 0, case .messageDelta = event {
                dropped -= 1
                continue
            }
            kept.append(generation)
        }
        return kept
    }

    nonisolated static func deduplicatingBufferedEvents(
        _ events: [StreamEvent],
        againstInflight inflight: String,
        knownPrefix: String?,
        sessionID: String,
        acceptedSessionIDs: Set<String> = [],
        coveredText explicitCoveredText: String? = nil,
        hasBoundaryAnchor: Bool = false
    ) -> [StreamEvent] {
        let coveredText: String
        if let explicitCoveredText {
            guard let knownPrefix else { return events }
            let normalizedInflight = inflight.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKnownPrefix = knownPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedInflight.hasPrefix(normalizedKnownPrefix) else {
                return events
            }
            let expectedCoveredText = String(
                normalizedInflight.dropFirst(normalizedKnownPrefix.count)
            )
            let normalizedExplicitCoveredText = explicitCoveredText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitCoverageOverlapsSeededText = Self.suffixPrefixOverlapLengths(
                covered: normalizedExplicitCoveredText,
                buffered: expectedCoveredText
            )
            guard !expectedCoveredText.isEmpty,
                  explicitCoverageOverlapsSeededText.count == 1 else {
                return events
            }
            coveredText = explicitCoveredText
        } else {
            guard let knownPrefix else { return events }
            if inflight.hasPrefix(knownPrefix) {
                coveredText = String(inflight.dropFirst(knownPrefix.count))
            } else {
                let normalizedInflight = inflight.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedKnownPrefix = knownPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedInflight.hasPrefix(normalizedKnownPrefix) else {
                    return events
                }
                coveredText = String(
                    normalizedInflight.dropFirst(normalizedKnownPrefix.count)
                )
            }
        }
        let normalizedCoveredText = coveredText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCoveredText.isEmpty else { return events }

        let bufferedDeltaTexts = events.compactMap { event in
            if case .messageDelta(_, let text) = event {
                return text
            }
            return nil
        }
        guard !bufferedDeltaTexts.isEmpty else { return events }

        let deltaSessionIDs = Set(events.compactMap { event in
            if case .messageDelta(let sessionId, _) = event {
                return sessionId
            }
            return nil
        })
        let allowedSessionIDs = acceptedSessionIDs.isEmpty
            ? Set([sessionID])
            : acceptedSessionIDs
        guard deltaSessionIDs.count == 1,
              let deltaSessionID = deltaSessionIDs.first,
              allowedSessionIDs.contains(deltaSessionID) else {
            return events
        }

        if let newTurnIndex = events.firstIndex(where: { event in
            guard case .messageStart(let startSessionID) = event else { return false }
            return allowedSessionIDs.contains(startSessionID)
        }) {
            // A message start observed after the reconciliation boundary is
            // an explicit new-turn marker. Deduplicate any older buffered
            // events, but preserve the marker and everything after it because
            // the same text can be fresh content from the new turn.
            let eventsBeforeNewTurn = Array(events[..<newTurnIndex])
            let eventsAfterNewTurn = Array(events[newTurnIndex...])
            return deduplicatingBufferedEvents(
                eventsBeforeNewTurn,
                againstInflight: inflight,
                knownPrefix: knownPrefix,
                sessionID: sessionID,
                acceptedSessionIDs: acceptedSessionIDs,
                coveredText: explicitCoveredText,
                hasBoundaryAnchor: hasBoundaryAnchor
            ) + eventsAfterNewTurn
        }

        guard hasBoundaryAnchor else {
            // Content equality cannot distinguish a fresh turn that happens
            // to repeat the snapshot. Without a non-empty stream boundary (or
            // the explicit message-start marker above), preserve the events
            // rather than risking loss of genuinely new text.
            return events
        }

        let bufferedDeltaText = bufferedDeltaTexts.joined()
        let normalizedBufferedDeltaText = bufferedDeltaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBufferedDeltaText.isEmpty else { return events }

        let coveredRawCharacters: Int
        if normalizedBufferedDeltaText == normalizedCoveredText {
            coveredRawCharacters = bufferedDeltaText.count
        } else if normalizedBufferedDeltaText.hasPrefix(normalizedCoveredText) {
            let leadingWhitespaceCount = bufferedDeltaText.prefix { $0.isWhitespace }.count
            let coveredEnd = leadingWhitespaceCount + normalizedCoveredText.count
            let coveredTrailingWhitespaceCount = coveredText.reversed().prefix { $0.isWhitespace }.count
            let bufferedTrailingWhitespaceCount = bufferedDeltaText.dropFirst(coveredEnd)
                .prefix { $0.isWhitespace }
                .count
            coveredRawCharacters = coveredEnd + min(
                coveredTrailingWhitespaceCount,
                bufferedTrailingWhitespaceCount
            )
        } else if normalizedCoveredText.hasPrefix(normalizedBufferedDeltaText) {
            coveredRawCharacters = bufferedDeltaText.count
        } else {
            let overlaps = Self.suffixPrefixOverlapLengths(
                covered: normalizedCoveredText,
                buffered: normalizedBufferedDeltaText
            )
            guard overlaps.count == 1, let overlap = overlaps.first else {
                // Repeated content can produce multiple valid alignments. A
                // content-only guess could consume genuinely new text, so
                // preserve the events when the offset is ambiguous.
                return events
            }
            let leadingWhitespaceCount = bufferedDeltaText.prefix { $0.isWhitespace }.count
            coveredRawCharacters = leadingWhitespaceCount + overlap
        }

        var remainingCoverage = coveredRawCharacters
        var deduplicated: [StreamEvent] = []
        deduplicated.reserveCapacity(events.count)
        for event in events {
            guard case .messageDelta(let sessionId, let text) = event else {
                deduplicated.append(event)
                continue
            }
            guard remainingCoverage > 0 else {
                deduplicated.append(event)
                continue
            }

            let consumed = min(remainingCoverage, text.count)
            guard consumed > 0 else {
                deduplicated.append(event)
                continue
            }
            remainingCoverage -= consumed
            let remainder = String(text.dropFirst(consumed))
            if !remainder.isEmpty {
                deduplicated.append(.messageDelta(sessionId: sessionId, text: remainder))
            }
        }
        return deduplicated
    }

    /// Returns every non-empty prefix of `buffered` that is also a suffix of
    /// `covered`. The prefix-function scan stays linear in the cumulative
    /// projection size; callers can reject repeated-content ambiguity when
    /// more than one alignment is possible.
    nonisolated static func suffixPrefixOverlapLengths(
        covered: String,
        buffered: String
    ) -> [Int] {
        let pattern = Array(buffered)
        guard !pattern.isEmpty, !covered.isEmpty else { return [] }

        var prefixLengths = Array(repeating: 0, count: pattern.count)
        var prefixLength = 0
        for index in 1..<pattern.count {
            while prefixLength > 0, pattern[index] != pattern[prefixLength] {
                prefixLength = prefixLengths[prefixLength - 1]
            }
            if pattern[index] == pattern[prefixLength] {
                prefixLength += 1
            }
            prefixLengths[index] = prefixLength
        }

        let text = Array(covered)
        var matched = 0
        var overlaps: [Int] = []
        for (index, character) in text.enumerated() {
            while matched > 0, pattern[matched] != character {
                matched = prefixLengths[matched - 1]
            }
            if pattern[matched] == character {
                matched += 1
            }
            if matched == pattern.count {
                if index == text.count - 1 {
                    overlaps.append(pattern.count)
                }
                matched = prefixLengths[matched - 1]
            }
        }

        while matched > 0 {
            overlaps.append(matched)
            matched = prefixLengths[matched - 1]
        }
        return overlaps
    }

    /// `session.resume.inflight` is a cumulative projection on some gateways.
    /// When its already-persisted prefix is also present in the recovered
    /// transcript, rendering it as the live bubble repeats the last reply.
    /// Keep only the unpersisted suffix so the next delta continues naturally.
    ///
    /// Hermes' projection is every delta of the turn, all of its steps run
    /// together, while each step's text is saved as its own row before the
    /// step's tools run. So the text of every saved step of the running turn
    /// (the assistant rows after its prompt) comes off, in order; what is
    /// left is the step still being written. Without this, rejoining a turn
    /// a few steps in put the whole turn's text in one live bubble below
    /// its own tool cards.
    nonisolated static func unpersistedInflightAssistantText(
        _ inflight: String,
        after messages: [ChatMessage]
    ) -> String {
        let recovered = inflight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recovered.isEmpty,
              let lastReplyIndex = messages.lastIndex(where: {
                  $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return recovered
        }
        // Only the running turn's own steps: an earlier turn's reply can
        // repeat a phrase this turn writes, and must not cut it. A steer is
        // part of the running turn, not its prompt.
        let promptIndex = messages.lastIndex(where: { $0.role == .user && !$0.isSteer })
        if let promptIndex, lastReplyIndex < promptIndex {
            return recovered
        }

        let persisted = messages[lastReplyIndex].content.trimmingCharacters(in: .whitespacesAndNewlines)
        if recovered == persisted || persisted.hasPrefix(recovered) {
            return ""
        }
        if recovered.hasPrefix(persisted) {
            return String(recovered.dropFirst(persisted.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let promptIndex else { return recovered }
        let savedSteps = messages[messages.index(after: promptIndex)...]
            .filter { $0.role == .assistant }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var cursor = recovered.startIndex
        for step in savedSteps {
            // A step the projection doesn't show (reworded when saved) is
            // passed over; the steps after it still place the cut.
            if let end = endOfInflightStep(step, in: recovered, from: cursor) {
                cursor = end
            }
        }
        guard cursor > recovered.startIndex else { return recovered }
        return String(recovered[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Steps shorter than this ("Done.") are only matched where the
    /// projection's next step starts: found further on, they are as likely a
    /// phrase of the step still being written.
    nonisolated static let inflightStepSearchMinimumCharacters = 24

    /// Where `step` ends in `text`, from `start`. Saved steps follow one
    /// another in the projection, so the step is looked for right at
    /// `start` first; only a long one is searched for further on, past text
    /// the projection has and the rows don't. Whitespace is not compared:
    /// a saved step is trimmed, and its line breaks may not be the streamed
    /// ones.
    nonisolated static func endOfInflightStep(
        _ step: String,
        in text: String,
        from start: String.Index
    ) -> String.Index? {
        let needle = Array(step.filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return nil }
        // Right at `start`, skipping whitespace on both sides.
        var index = start
        var matched = 0
        while index < text.endIndex, matched < needle.count {
            let character = text[index]
            index = text.index(after: index)
            if character.isWhitespace { continue }
            guard character == needle[matched] else { break }
            matched += 1
        }
        if matched == needle.count { return index }

        guard needle.count >= inflightStepSearchMinimumCharacters else { return nil }
        if let range = text.range(of: step, range: start..<text.endIndex) {
            return range.upperBound
        }
        // The text's visible characters, each with the index just past it.
        var haystack: [Character] = []
        var ends: [String.Index] = []
        index = start
        while index < text.endIndex {
            let next = text.index(after: index)
            if !text[index].isWhitespace {
                haystack.append(text[index])
                ends.append(next)
            }
            index = next
        }
        guard let last = firstMatchEnd(of: needle, in: haystack) else { return nil }
        return ends[last]
    }

    /// Knuth–Morris–Pratt: the haystack position of the first match's last
    /// character.
    private nonisolated static func firstMatchEnd(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var failure = [Int](repeating: 0, count: needle.count)
        var matched = 0
        for position in 1..<needle.count {
            while matched > 0, needle[position] != needle[matched] { matched = failure[matched - 1] }
            if needle[position] == needle[matched] { matched += 1 }
            failure[position] = matched
        }
        matched = 0
        for (position, character) in haystack.enumerated() {
            while matched > 0, character != needle[matched] { matched = failure[matched - 1] }
            if character == needle[matched] { matched += 1 }
            if matched == needle.count { return position }
        }
        return nil
    }

    func canonicalSessionID(for sessionID: String?) -> String? {
        ChatSessionPersistenceIdentity.canonicalID(
            for: sessionID,
            identity: activeChatScrollSessionIdentity,
            catalog: sessions + cronSessions,
            activeProfile: activeProfile
        )
    }

    /// Derives bookkeeping keys for an explicit profile. Callers must pass
    /// the profile that owns the state being tracked; nothing here consults
    /// mutable activeProfile.
    func sessionYoloKeys(
        profile: String,
        sessionIDs: [String]
    ) -> Set<ChatScrollSessionKey> {
        var keys = Set<ChatScrollSessionKey>()
        for id in sessionIDs {
            let candidate = ChatScrollSessionKey(profile: profile, sessionID: id)
            if candidate.isValid { keys.insert(candidate) }
        }
        return keys
    }

    /// Current-state reads legitimately consult the active profile.
    private func sessionYoloKeysForCurrentProfile(
        sessionIDs: [String]
    ) -> Set<ChatScrollSessionKey> {
        sessionYoloKeys(profile: activeProfile, sessionIDs: sessionIDs)
    }

    private func sessionYoloWriteBaseline(for sessionID: String) -> SessionYoloWriteBaseline {
        let sessionIDs = [sessionID, canonicalSessionID(for: sessionID)].compactMap { $0 }
        let keys = sessionYoloKeysForCurrentProfile(sessionIDs: sessionIDs)
        return SessionYoloWriteBaseline(
            revisions: Dictionary(uniqueKeysWithValues: keys.map { key in
                (key, sessionYoloWriteRevisions[key] ?? 0)
            })
        )
    }

    private func hasNewerSessionYoloWrite(
        since baseline: SessionYoloWriteBaseline,
        sessionIDs: [String]
    ) -> Bool {
        sessionYoloKeysForCurrentProfile(sessionIDs: sessionIDs).contains { key in
            sessionYoloWriteRevisions[key, default: 0] > baseline.revisions[key, default: 0]
        }
    }

    func recordSessionYoloWrite(for sessionIDs: [String]) {
        sessionYoloWriteRevision &+= 1
        for key in sessionYoloKeysForCurrentProfile(sessionIDs: sessionIDs) {
            sessionYoloWriteRevisions[key] = sessionYoloWriteRevision
        }
    }

    /// In-flight ownership is registered against explicit keys so the exact
    /// entries created at operation start are the ones cleanup removes -
    /// even when the active profile moved on while the RPC was suspended.
    /// The reference-counted map supports overlapping writes for the same
    /// session: each logical operation owns an independent registration, and
    /// cleanup only removes the key when the last reference is released.
    func beginSessionYoloWrite(keys: Set<ChatScrollSessionKey>) {
        for key in keys {
            inFlightSessionYoloWriteCounts[key, default: 0] += 1
        }
    }

    func endSessionYoloWrite(keys: Set<ChatScrollSessionKey>) {
        for key in keys {
            let remaining = inFlightSessionYoloWriteCounts[key, default: 0] - 1
            if remaining > 0 {
                inFlightSessionYoloWriteCounts[key] = remaining
            } else {
                inFlightSessionYoloWriteCounts.removeValue(forKey: key)
            }
        }
    }

#if DEBUG
    /// Test seam: the current dashboard-switch generation, so tests can
    /// construct genuinely-stale (never-current) generation values for the
    /// restore/renewal fences.
    func dashboardSwitchGenerationForTesting() -> UInt64 {
        dashboardSwitchGeneration
    }

    /// Test-only view of pending YOLO write ownership. Each entry maps a key
    /// to the number of active operations holding it; a non-empty dictionary
    /// after all operations settled means the bookkeeping leaked.
    var inFlightSessionYoloWriteCountsForTesting: [ChatScrollSessionKey: Int] {
        inFlightSessionYoloWriteCounts
    }
#endif

    func hasInFlightSessionYoloWrite(sessionIDs: [String]) -> Bool {
        sessionYoloKeysForCurrentProfile(sessionIDs: sessionIDs).contains { key in
            (inFlightSessionYoloWriteCounts[key] ?? 0) > 0
        }
    }

    func applyRuntime(
        _ snapshot: SessionRuntimeSnapshot,
        for sessionID: String? = nil,
        authoritativeYolo: Bool? = nil,
        authoritativeApprovalsMode: String? = nil
    ) {
        // The snapshot lands as one runtime. Each write through the
        // published property publishes AppState, and a resume arrives while
        // the chat it opened is still animating in, so a dozen member
        // writes cost every observer a dozen redraws for one new state.
        var next = runtime
        if let model = snapshot.model { next.model = model }
        if let provider = snapshot.provider { next.provider = provider }
        if let cwd = snapshot.cwd { next.cwd = cwd }
        if let percent = snapshot.contextPercent { next.contextPercent = normalizedContextPercent(percent, used: snapshot.contextUsed, max: snapshot.contextMax) }
        if let used = snapshot.contextUsed { next.contextUsed = used }
        if let max = snapshot.contextMax { next.contextMax = max }
        if let count = snapshot.activeAgents { setActiveAgents(count) }
        if let reasoningEffort = snapshot.reasoningEffort {
            next.reasoningEffort = reasoningEffort.lowercased() == "none" ? "" : reasoningEffort
        }
        if let fast = snapshot.fast { next.fast = fast }
        // A gateway that reports `fast` without the tier leaves no stale
        // Ultrafast behind.
        if let serviceTier = snapshot.serviceTier ?? snapshot.fast.map({ _ in "" }) {
            next.serviceTier = serviceTier
        }
        if let approvalsMode = authoritativeApprovalsMode ?? snapshot.approvalsMode {
            next.approvalsMode = approvalsMode
        }
        setRuntime(next)
        if let reportedYolo = authoritativeYolo ?? snapshot.yolo {
            lastReportedSessionYolo = reportedYolo
        }
        let requestedSessionID = sessionID ?? activeSessionId
        let resolvedCanonicalSessionID = canonicalSessionID(for: requestedSessionID)
        let sessionIDsForOverride = [resolvedCanonicalSessionID, requestedSessionID]
            .compactMap { $0 }
        if let resolvedCanonicalSessionID,
           let requestedSessionID,
           resolvedCanonicalSessionID != requestedSessionID {
            sessionYoloStore.canonicalizeOverride(
                for: activeProfile,
                canonicalSessionID: resolvedCanonicalSessionID,
                aliases: [requestedSessionID]
            )
        }
        applyEffectiveYolo(
            sessionIDsForOverride: sessionIDsForOverride,
            snapshotYolo: authoritativeYolo ?? snapshot.yolo,
            snapshotReportedApprovalsMode: authoritativeApprovalsMode ?? snapshot.approvalsMode
        )
        // The session authority lists the chat's queue in every resume and
        // pushes it on every change; a snapshot without it says nothing.
        if let queued = snapshot.queuedPrompts, let requestedSessionID {
            // Waiting behind a running turn (another client's, which this
            // socket didn't see start) or a turn a restart cut off: the
            // user's own send moves to the dock.
            adoptOwnQueuedSends(queued)
            authorityQueue.apply(queued, for: requestedSessionID)
        }
    }

    /// Resolve the effective session YOLO state from the current profile
    /// approval mode and the stored per-session override. Shared by
    /// `applyRuntime` (snapshot reconciliation) and the Settings save path so
    /// the indicator, the floor, and the Model Picker lock can never disagree
    /// with the saved mode.
    func applyEffectiveYolo(
        sessionIDsForOverride: [String],
        snapshotYolo: Bool?,
        snapshotReportedApprovalsMode: String?
    ) {
        let storedOverride = sessionYoloStore.storedOverride(
            for: activeProfile,
            sessionIDs: sessionIDsForOverride
        )
        let globalYoloFloor = runtime.approvalsMode?.lowercased() == "off"
        let resolved: Bool?
        if globalYoloFloor {
            // Hermes auto-approves globally when approvals.mode == "off"; a
            // per-session toggle cannot require approvals. Reflect the server's
            // effective state so the indicator does not claim otherwise.
            resolved = true
        } else if let storedOverride {
            // The per-session choice is authoritative. The gateway holds the
            // flag in memory only and forgets it on restart, so AppState
            // re-asserts it after resume (see reassertSessionYolo).
            resolved = storedOverride
        } else if let yolo = snapshotYolo {
            resolved = yolo
        } else if let mode = snapshotReportedApprovalsMode, mode.lowercased() != "off" {
            // Only the snapshot's own non-off mode report resolves to "approvals
            // apply" — a last-known mode with the signal omitted entirely is
            // unknown, not a disagreement, and must not flicker the indicator.
            resolved = false
        } else {
            // Otherwise keep the last-known indicator value; a partial
            // projection omitting the approval fields must not flicker it.
            resolved = nil
        }
        // Written only when it changes: every resume snapshot lands here, and
        // a same-value write still publishes AppState mid-slide-in.
        if let resolved, runtime.yolo != resolved { runtime.yolo = resolved }
    }

    /// The context breakdown RPC is the gateway's complete accounting source.
    /// Session snapshots may omit it, or expose the percentage as a fraction.
    /// The breakdown read, or nil when it couldn't be read or another chat
    /// (or server) became active while it was.
    @discardableResult
    func refreshContextUsage() async -> ContextBreakdown? {
        guard let client, let sessionId = activeSessionId else { return nil }
        // Before a reconnect has resumed the chat, Hermes may no longer hold
        // its runtime and refuses the read ("not in memory"). The resume
        // reads the breakdown itself once the chat is back (#1060).
        guard turnState != .reconnecting, turnState != .synchronizing else { return nil }
        return await refreshContextUsage(sessionId: sessionId, using: client)
    }

    func applyContextBreakdown(_ breakdown: ContextBreakdown) {
        // One runtime, one publication: these three arrive together while
        // the chat is opening.
        var next = runtime
        next.contextUsed = breakdown.resolvedUsed
        next.contextMax = breakdown.contextMax
        next.contextPercent = breakdown.resolvedPercent
        setRuntime(next)
    }

    @discardableResult
    private func refreshContextUsage(sessionId: String, using client: HermesClient) async -> ContextBreakdown? {
        do {
            let breakdown = try await client.contextBreakdown(sessionId)
            guard self.client === client, activeSessionId == sessionId else { return nil }
            applyContextBreakdown(breakdown)
            return breakdown
        } catch {
            // Context accounting is supplementary to chat recovery. Preserve
            // the latest stream/snapshot values when older gateways lack it.
            return nil
        }
    }

    func normalizedContextPercent(_ percent: Double, used: Int?, max: Int?) -> Double {
        // The counts are unambiguous; a percent of 1 or less could be a
        // fraction or a small 0-100 reading (Hermes sends 0-100, so 1% of a
        // large window would otherwise fill the meter).
        if let used, used > 0, let capacity = max, capacity > 0 {
            return min(Swift.max((Double(used) / Double(capacity)) * 100, 0), 100)
        }
        if percent > 0 {
            let normalized = (0...1).contains(percent) ? percent * 100 : percent
            return min(Swift.max(normalized, 0), 100)
        }
        if let used, let capacity = max, capacity > 0 {
            return min(Swift.max((Double(used) / Double(capacity)) * 100, 0), 100)
        }
        return 0
    }
}

extension AppState {
    // MARK: - Keeping row ids and local notes across a reconcile

    func pendingDecisionRestorationMessages(for sessionID: String) -> [ChatMessage] {
        guard let restorationGuard = restoredPendingDecisionCardsAwaitingConfirmation,
              restorationGuard.profile == presentationProfile(for: sessionID),
              restorationGuard.sessionID == sessionID else {
            return []
        }
        guard !sessionPresentationCache.isUnconfirmedPendingDecisionExpired(
            since: restorationGuard.restoredAt
        ) else {
            clearPendingDecisionRestorationGuard()
            return []
        }
        return restorationGuard.messages
    }

    func clearPendingDecisionRestorationGuard() {
        restoredPendingDecisionCardsAwaitingConfirmation = nil
    }

    /// A transcript of the same chat rebuilt from the gateway's rows, with
    /// each message `previous` already showed under another id taking that
    /// id back (#1648). Hermes' stored rows carry their database ids, and a
    /// resume's rows take the same ids from their `row_id`
    /// (MessageNormalizer), but a gateway that sends no `row_id` numbers its
    /// resume rows by position ("0", "1-reasoning", ...): a refresh that
    /// switched source then re-keyed every row, so the transcript drew and
    /// measured them all again from guesses, lost the reader's place, and
    /// took a re-keyed latest user message for a new turn. A message pairs
    /// by its role, text and tool call when each list holds it once and
    /// their times, where both say one, agree. The same pairing gives a
    /// live turn's resume rows the ids of the stored rows read with them
    /// (`keepingStoredRowIDs`), so on such a gateway only the rows Hermes
    /// hasn't stored yet are drawn under positional ids. A row whose id
    /// `durableIDs` holds keeps it: the delivery checks, the graft of a
    /// refreshed page onto older history and the merge of newer stored rows
    /// all find rows by Hermes' stored ids. An id never goes to a row while
    /// another row of the rebuilt transcript still has it, and an optimistic
    /// row's id is never carried.
    static func keepingRowIDs(
        from previous: [ChatMessage],
        in rebuilt: [ChatMessage],
        durableIDs: Set<String>
    ) -> [ChatMessage] {
        let previousIDs = Set(previous.map(\.id))
        let rebuiltIDs = Set(rebuilt.map(\.id))
        // Nothing re-keyed: every rebuilt row is new or already shown.
        guard rebuilt.contains(where: { !previousIDs.contains($0.id) }),
              previous.contains(where: { !rebuiltIDs.contains($0.id) }) else { return rebuilt }
        struct Signature: Hashable {
            let role: MessageRole
            let content: String
            let tool: String?
        }
        func signature(_ message: ChatMessage) -> Signature {
            let tool = message.tool.map { tool in
                tool.id.flatMap { $0.isEmpty ? nil : $0 } ?? tool.name
            }
            return Signature(role: message.role, content: message.content, tool: tool)
        }
        // Only a message both lists hold once pairs: a text repeated ("yes",
        // "continue") can't tell which copy is which, above all against a
        // stored page a few rows behind the resume, so its copies keep their
        // own ids. Pairs keep their order: the longest run of them rising in
        // both lists stays, so a row moved out of order doesn't pair.
        var previousCount: [Signature: Int] = [:]
        var previousIndex: [Signature: Int] = [:]
        for (index, message) in previous.enumerated() {
            let key = signature(message)
            previousCount[key, default: 0] += 1
            previousIndex[key] = index
        }
        var rebuiltCount: [Signature: Int] = [:]
        for message in rebuilt { rebuiltCount[signature(message), default: 0] += 1 }
        var candidates: [(rebuilt: Int, previous: Int)] = []
        for (index, message) in rebuilt.enumerated() {
            let key = signature(message)
            guard rebuiltCount[key] == 1, previousCount[key] == 1,
                  let shownIndex = previousIndex[key],
                  MessageTimestampFormatter.sameMoment(previous[shownIndex].timestamp, message.timestamp) else { continue }
            candidates.append((rebuilt: index, previous: shownIndex))
        }
        let pairs = Self.risingRun(candidates)
        var result = rebuilt
        for pair in pairs {
            let shown = previous[pair.previous]
            let message = rebuilt[pair.rebuilt]
            // An optimistic row's id (`local-`) stays its own: the delivery
            // and steer checks read it as a row Hermes hasn't stored yet.
            guard message.id != shown.id,
                  !shown.id.hasPrefix("local-"),
                  !previousIDs.contains(message.id),
                  !durableIDs.contains(message.id),
                  !rebuiltIDs.contains(shown.id) else { continue }
            var kept = message.withID(shown.id)
            // What only the shown row knew: its stored row (reactions and
            // rewinds address it) and a step's measured time.
            kept.rowId = kept.rowId ?? shown.rowId
            kept.stepDuration = kept.stepDuration ?? shown.stepDuration
            result[pair.rebuilt] = kept
        }
        return result
    }

    /// A live turn's resume rows, read with Hermes' stored rows of the same
    /// chat (`stored`): the ones Hermes has stored take those rows' ids, so
    /// the turn's end, when the stored rows take over, doesn't re-key the
    /// chat on a gateway whose resume rows don't name their stored rows
    /// (`row_id`) (#1648).
    static func keepingStoredRowIDs(
        _ result: SessionResumeResult,
        from stored: [ChatMessage]
    ) -> SessionResumeResult {
        guard !stored.isEmpty else { return result }
        return SessionResumeResult(
            sessionId: result.sessionId,
            storedSessionId: result.storedSessionId,
            messages: keepingRowIDs(from: stored, in: result.messages, durableIDs: []),
            snapshot: result.snapshot
        )
    }

    /// Where a reconcile's rows come from.
    enum ReconcileRowsSource: Equatable {
        /// Hermes' stored rows (a settled turn, or a resume with no rows).
        case stored
        /// The resume's rows, a live turn's, with the stored ones keeping
        /// the stored rows' ids (`keepingStoredRowIDs`, #1648).
        case resumeKeepingStoredIDs
        /// The resume's rows as they came: no stored rows of this chat.
        case resume
    }

    /// A compact resume ships no persisted transcript, so the REST rows are
    /// the durable base even while a turn is live: the in-flight projection
    /// rides on top through the streaming bubble, matching Desktop's
    /// cache-as-base rendering. A resume that carried messages keeps the
    /// historical precedence where a live projection wins over the REST
    /// read, its stored rows keeping their ids.
    static func reconcileRowsSource(
        transcriptMatches: Bool,
        storedMessages: [ChatMessage]?,
        result: SessionResumeResult
    ) -> ReconcileRowsSource {
        guard transcriptMatches, let storedMessages else { return .resume }
        let resumeCarriedTranscript = !result.messages.isEmpty
        if (!storedMessages.isEmpty || !resumeCarriedTranscript)
            && (!result.snapshot.hasLiveProjection || !resumeCarriedTranscript) {
            return .stored
        }
        return storedMessages.isEmpty ? .resume : .resumeKeepingStoredIDs
    }

    /// The longest run of `pairs` (in rebuilt order) whose shown index rises
    /// too, by patience sorting.
    private static func risingRun(_ pairs: [(rebuilt: Int, previous: Int)]) -> [(rebuilt: Int, previous: Int)] {
        // tails[k]: the index in `pairs` ending the best run of length k + 1
        // found so far; links[i]: the pair before pairs[i] in its run.
        var tails: [Int] = []
        var links = [Int](repeating: -1, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].previous < pair.previous { low = middle + 1 } else { high = middle }
            }
            if low > 0 { links[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run: [(rebuilt: Int, previous: Int)] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.append(pairs[cursor])
            cursor = links[cursor]
        }
        return run.reversed()
    }

    /// The chat's own notes (slash command output, /btw and /background
    /// answers), which Hermes never stores, carried from `previous` into a
    /// transcript of the same chat rebuilt from the gateway's rows. Each goes
    /// back after the row it followed, or at the end when that row isn't
    /// among the rebuilt ones; the notes keep their order either way, so a
    /// note never lands above one that came before it. A note the rebuilt
    /// rows already hold (same id, or a system row with the same text) isn't
    /// added again; two notes with the same text are still two notes.
    static func keepingLocalNotes(from previous: [ChatMessage], in rebuilt: [ChatMessage]) -> [ChatMessage] {
        var rebuiltIndex: [String: Int] = [:]
        for (index, message) in rebuilt.enumerated() where rebuiltIndex[message.id] == nil {
            rebuiltIndex[message.id] = index
        }
        let rebuiltSystemTexts = Set(rebuilt.lazy.filter { $0.role == .system }.map(\.content))
        // The notes by the rebuilt row they go after: -1 is the top,
        // rebuilt.count - 1 the end.
        var notesAfter: [Int: [ChatMessage]] = [:]
        // The top until a row has gone by.
        var anchor = -1
        // Never above a note already placed.
        var floor = -1
        for message in previous {
            guard message.role == .system, message.id.hasPrefix("slash-") else {
                anchor = rebuiltIndex[message.id] ?? rebuilt.count - 1
                continue
            }
            guard rebuiltIndex[message.id] == nil, !rebuiltSystemTexts.contains(message.content) else { continue }
            floor = max(floor, anchor)
            notesAfter[floor, default: []].append(message)
        }
        guard !notesAfter.isEmpty else { return rebuilt }
        var kept = notesAfter[-1] ?? []
        kept.reserveCapacity(rebuilt.count + notesAfter.values.reduce(0) { $0 + $1.count })
        for (index, message) in rebuilt.enumerated() {
            kept.append(message)
            kept.append(contentsOf: notesAfter[index] ?? [])
        }
        return kept
    }
}
