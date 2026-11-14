//
//  AppState+Lifecycle.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Lifecycle coordination;
//  Foreground observational refresh.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Lifecycle coordination

    struct Reconciliation {
        let token: UUID
        let requestedSessionId: String
        var automaticSyncOperationID: UUID?
        var resolvedSessionId: String?
        /// Durable id an admitted resume explicitly established for this
        /// conversation (parsed from `stored_session_id` / `session_key`).
        /// Routing state only — it rebinds the conversation's runtime to a
        /// new stored key without ever looking like navigation.
        var resolvedDurableSessionId: String?
        var acceptedSessionIDs: Set<String>
        let acceptsAnySession: Bool
        let streamTextAtBoundary: String?
        let streamSessionIDAtBoundary: String?
        var bufferedEvents: [StreamEvent] = []
        /// The turn each buffered event named (`execution_generation`), in
        /// step with `bufferedEvents`, so a replay is told apart as live
        /// events are (`takeVoiceEventAfterCancel`).
        var bufferedGenerations: [Int?] = []

        init(
            token: UUID,
            requestedSessionId: String,
            automaticSyncOperationID: UUID? = nil,
            resolvedDurableSessionId: String? = nil,
            acceptedSessionIDs: Set<String> = [],
            acceptsAnySession: Bool = false,
            streamTextAtBoundary: String? = nil,
            streamSessionIDAtBoundary: String? = nil,
            bufferedEvents: [StreamEvent] = [],
            bufferedGenerations: [Int?] = []
        ) {
            self.token = token
            self.requestedSessionId = requestedSessionId
            self.automaticSyncOperationID = automaticSyncOperationID
            self.resolvedDurableSessionId = resolvedDurableSessionId
            self.acceptedSessionIDs = acceptedSessionIDs
            self.acceptsAnySession = acceptsAnySession
            self.streamTextAtBoundary = streamTextAtBoundary
            self.streamSessionIDAtBoundary = streamSessionIDAtBoundary
            self.bufferedEvents = bufferedEvents
            self.bufferedGenerations = bufferedGenerations
        }

        /// Each buffered event with the turn it named (nil when none).
        var bufferedEntries: [(event: StreamEvent, generation: Int?)] {
            let generations = bufferedGenerations.count == bufferedEvents.count
                ? bufferedGenerations
                : Array(repeating: nil, count: bufferedEvents.count)
            return zip(bufferedEvents, generations).map { (event: $0, generation: $1) }
        }

        func accepts(_ sessionId: String) -> Bool {
            guard !sessionId.isEmpty else { return false }
            if acceptsAnySession { return true }
            return acceptedSessionIDs.contains(sessionId)
                || sessionId == requestedSessionId
                || sessionId == resolvedSessionId
        }
    }

    struct PendingStreamingCompletion {
        let sessionId: String
        let messageId: String?
        let finalContent: String
        let reasoning: String?
        /// The row this turn's `message.interim` sealed with the final text
        /// already (`message.complete`'s `response_previewed` /
        /// `response_reused`); the completion settles onto it.
        let shownRowID: String?
    }

    /// One live reasoning segment as projected to the UI: the identity and
    /// mount timestamp are fixed for the segment's lifetime, only `content`
    /// advances at display cadence. Rendering treats it exactly like a
    /// settled `.reasoning` row (same ThinkingCard presentation).
    struct LiveReasoningSegment: Equatable {
        let id: String
        let timestamp: String
        var content: String
    }

    static let quietReturnWindow: TimeInterval = 10

    struct ChatViewportTransition {
        let generation: UInt64
        var hasReplacement = false
        var expectedSessionKey: ChatScrollSessionKey?
        var expectedTranscriptRevision: UInt64?
    }

    struct AutomaticSyncOperation {
        let id: UUID
        let previousTurnState: TurnState
    }

    struct AutomaticReconnectOperation {
        let id: UUID
        let previousIsConnecting: Bool
        let previousTurnState: TurnState
    }

    /// A resume without explicit active-turn confirmation can restore a
    /// decision card from local presentation data. Keep the card in memory for
    /// this AppState so another foreground resume can still show it, but strip
    /// it from cache writes until Hermes confirms the turn. Scope the guard to
    /// the session/profile that produced it so a session switch cannot affect
    /// another session's presentation.
    struct PendingDecisionRestorationGuard {
        let profile: String
        let sessionID: String
        let pendingDecisionKeys: Set<String>
        let restoredAt: Date
        let messages: [ChatMessage]
    }

    struct SessionYoloWriteBaseline {
        let revisions: [ChatScrollSessionKey: UInt64]
    }

    /// Whether transport recovery (reconnect cycles and the post-connect
    /// sync they drive) may run. The phone scene being active is one such
    /// surface; a connected CarPlay Voice surface is another. In a car the
    /// phone is usually locked, so gating recovery on the phone scene alone
    /// left a socket lost during suspension dead for the whole drive and
    /// CarPlay reporting Voice unavailable.
    var canRunTransportRecovery: Bool {
        isSceneActive || isCarPlayVoiceSurfaceActive || isLockedVoiceSurfaceActive || isWatchVoiceCallActive || isNativeHermesCallActive
            || isShortcutSendRunning
    }

    var isShortcutSendRunning: Bool { shortcutSendsRunning > 0 || shortcutConnectHeld }

    /// A shortcut run ended. A connect still under way runs on until it
    /// lands or fails, however long that takes, so it settles its own state:
    /// a time limit would cut a slow one off and leave the same "connecting"
    /// behind. The hold starts nothing new, since every reconnect path waits
    /// while a connect is under way; the phone coming on screen settles it
    /// too.
    func endShortcutSend() {
        shortcutSendsRunning -= 1
        guard shortcutSendsRunning == 0, isConnecting, !isConnected, !shortcutConnectHeld else { return }
        shortcutConnectHeld = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await connecting in self.$isConnecting.values where !connecting { break }
            self.shortcutConnectHeld = false
        }
    }

    /// A connect cut off off screen after its socket opened (the app left,
    /// or a call ended, at its next step) leaves the socket unpublished:
    /// Conduit reads as disconnected over a live socket until the phone
    /// comes on screen and publishes it. A shortcut run off screen publishes
    /// it the same way, then checks it like any quiet socket (#2164). The
    /// bootstrap that connect owes still waits for the phone.
    func publishOpenSocketOffScreen() {
        guard !isSceneActive, !isConnected, let client, client.isConnected else { return }
        noteConnectionStep("Open socket published for a shortcut")
        isConnected = true
        isConnecting = false
    }

    /// A transport whose handshake completed but whose post-connect bootstrap
    /// (profiles, Bot Mode roster, catalog sync + resume) was abandoned
    /// because the scene went inactive mid-connect — e.g. the Face ID
    /// success animation of a saved-credential restore outlives the
    /// handshake. The next `.active` on the SAME healthy client owes that
    /// bootstrap; the observational foreground probe alone never loads the
    /// catalog.
    ///
    /// The purpose follows the interrupted connect's own continuation: once
    /// the user takes ownership (the connect's automatic intent is cancelled
    /// or handed off), the owed sync is `.preserveCurrent`, never a replayed
    /// `.automaticReturn`.
    struct OwedPostConnectBootstrap {
        let client: HermesClient
        var purpose: ChatResumeSyncPurpose
        let automaticWorkToken: ChatResumeAutomaticWorkToken?
    }

    /// The dashboard's persisted transcript is richer than `session.resume`:
    /// it retains database timestamps, complete tool-call inputs, and other
    /// presentation fields. The resume RPC remains authoritative for live turn
    /// state and any in-flight projection.
    struct DashboardSessionCatalog {
        let sessions: [SessionSummary]
        /// True only when the dashboard returned a meaningful, terminal
        /// catalog. Empty or unusable responses must remain mergeable with
        /// the previous snapshot instead of evicting it.
        let isAuthoritative: Bool
    }

    /// A deferred catalog read that a newer read overtook. It publishes
    /// nothing and stays quiet: the newer read owns the list.
    struct CatalogReadSuperseded: Error {}

    struct ProfileCatalogLoad {
        let sessions: [SessionSummary]
        /// A full read was due but only the newest page was read.
        let olderPagesDeferred: Bool
    }

    struct TitleGenerationSettings {
        let enabled: Bool
        let language: String?
    }

    static func localTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static let reviewTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Durable-owned presentation persistence: once the conversation's
    /// durable identity is positively established (a catalog-confirmed or
    /// admission-established canonical), the durable key is the only key
    /// presentation writes land under — runtime aliases are never
    /// re-persisted, so a flush can never recreate an alias copy that
    /// `consolidateUnderDurableKey` retired. Without a durable id
    /// (runtime-only conversations) the supplied ids pass through unchanged.
    static func durableOwnedPresentationIDs(
        _ ids: [String],
        durableSessionID: String?
    ) -> [String] {
        guard let durableSessionID = ChatScrollIdentityNormalization.sessionID(durableSessionID) else {
            return ids
        }
        // A lookup may need the whole alias set, but a WRITE does not: the
        // durable key owns the persisted record.
        return [durableSessionID]
    }

    func presentationCacheSessionIDs(for sessionID: String) -> [String] {
        Self.durableOwnedPresentationIDs(
            [
                sessionID,
                activeSessionId,
                reconciliation?.requestedSessionId,
                reconciliation?.resolvedSessionId
            ].compactMap { $0 },
            durableSessionID: activeChatScrollSessionIdentity.canonicalSessionID
        )
    }

    /// Hermes can omit UI-only fields from persisted history. Retain a bounded
    /// local record so a reload does not drop a timestamp or tool preview.
    func cacheMessagePresentation(for sessionIDs: [String] = []) {
        let ids = Self.durableOwnedPresentationIDs(
            sessionIDs + [
                activeSessionId,
                reconciliation?.requestedSessionId,
                reconciliation?.resolvedSessionId
            ].compactMap { $0 },
            durableSessionID: activeChatScrollSessionIdentity.canonicalSessionID
        )
        let restorationKeys: Set<String>? = {
            guard let restorationGuard = restoredPendingDecisionCardsAwaitingConfirmation,
                  restorationGuard.profile == presentationProfile(for: activeSessionId),
                  activeSessionId == restorationGuard.sessionID else {
                return nil
            }
            return restorationGuard.pendingDecisionKeys
        }()
        let cacheableMessages = restorationKeys.map {
            SessionPresentationCache.removingPendingDecisionPresentation(
                from: messages,
                matching: $0
            )
        } ?? messages
        let pendingDecisionKeys = SessionPresentationCache.pendingDecisionKeys(in: cacheableMessages)
        // Gateway-provided cards do not create a restoration guard, so keep
        // their bounded expiry marker across ordinary cache flushes as well.
        // Push-recorded cards (recordPendingDecision) live only in the store —
        // the in-memory transcript has never seen them — so union in the
        // store's pending keys or the flush would drop the card before the
        // notification-open resume merge could restore it.
        let storedPendingDecisionKeys = sessionPresentationCache.storedPendingDecisionKeys(
            profile: presentationProfile(for: activeSessionId),
            sessionIDs: ids
        )
        let pendingDecisionKeysToPreserve = restorationKeys
            ?? pendingDecisionKeys.union(storedPendingDecisionKeys)
        let preservePendingDecisionCards = restorationKeys == nil
            || !pendingDecisionKeys.isEmpty
            || !storedPendingDecisionKeys.isEmpty
        sessionPresentationCache.save(
            cacheableMessages,
            profile: presentationProfile(for: activeSessionId),
            sessionIDs: ids,
            preservePendingDecisionCards: preservePendingDecisionCards,
            unconfirmedPendingDecisionKeys: pendingDecisionKeysToPreserve
        )
    }

    /// Coalesces presentation-cache writes during streaming. Instead of
    /// serializing the entire message array to UserDefaults on every
    /// WebSocket frame (30+ times/sec), batch flushes at most once every
    /// 2 seconds (debounce), with a hard 5-second ceiling (max interval)
    /// so continuous streaming can never postpone a flush indefinitely.
    func schedulePresentationCacheFlush(for sessionId: String) {
        presentationCacheFlushTask?.cancel()
        // Capture the profile identity this deferred write belongs to. The
        // task only keeps the session ID immutable; everything else it reads
        // (messages, reconciliation IDs, restoration guards) is live state.
        let scheduledProfile = activeProfile
        let scheduledEpoch = presentationCacheProfileEpoch
        let suspendForDebounce = presentationCacheDebounceSuspension
        let now = Date()
        let sinceLastFlush = lastPresentationCacheFlushDate
            .map { now.timeIntervalSince($0) }
            ?? .infinity
        // If 5s already elapsed since the last successful write, flush
        // immediately rather than scheduling another debounce.
        let delay: Duration = sinceLastFlush >= 5 ? .zero : .seconds(2)
        presentationCacheFlushTask = Task { [weak self] in
            do {
                try await suspendForDebounce(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            // Stale-execution fence: if the app switched profiles while this
            // flush was parked, the captured session ID no longer describes
            // the live transcript, and writing through the now-active cache
            // namespace would cross-contaminate profiles. switchProfile also
            // flushes and cancels before switching; this guard keeps the
            // operation safe on its own so no caller can forget it.
            guard self.activeProfile == scheduledProfile,
                  self.presentationCacheProfileEpoch == scheduledEpoch else {
                presentationCacheFlushTask = nil
                return
            }
            self.cacheMessagePresentation(for: [sessionId])
            self.lastPresentationCacheFlushDate = Date()
            self.presentationCacheFlushTask = nil
        }
    }

    /// Keeps the process alive after suspension begins until the
    /// presentation cache's queued disk writes have landed, then the saved
    /// chats' (copies, held rows and the Chats list). Main actor only: both
    /// callbacks that end the task arrive on the main queue.
    func holdBackgroundTaskUntilCacheWritesLand() {
        let end = BackgroundTaskHold.begin("conduit.sessionPresentationCache.flush")
        let offlineChatCache = offlineChatCache
        sessionPresentationCache.notifyWhenPendingWritesLand {
            offlineChatCache.notifyWhenPendingWritesLand(end)
        }
    }

    /// Flushes any pending presentation-cache write immediately (used on
    /// session switch, completion, and scene-phase change).
    func flushPendingPresentationCache(for sessionIDs: [String] = []) {
        presentationCacheFlushTask?.cancel()
        presentationCacheFlushTask = nil
        lastPresentationCacheFlushDate = Date()
        cacheMessagePresentation(for: sessionIDs)
        recordOfflineChatCopy()
        keepBotChatCopy()
        // Kept while that chat is still the one on screen: a flush can run
        // while a bot open awaits its lookup.
        if outgoingBotChatCopyOwner?.sessionID != activeSessionId {
            outgoingBotChatCopyOwner = nil
        }
    }

    // MARK: - Foreground observational refresh

    /// Outcome of the read-only liveness probe for the active conversation.
    private enum ForegroundRuntimeProbe {
        /// A live runtime row matched the active session's identity.
        case live(LiveSessionStatus)
        /// The registry answered but listed no runtime for this session: the
        /// turn ended and its transport went away, or the gateway restarted.
        case absent
        /// The registry could not be read (older gateway, transient RPC
        /// failure). The caller falls back to the resume-based refresh.
        case unavailable(String)
    }

    /// Foreground recovery repairs the current conversation whenever one is
    /// visible. Automatic return is only appropriate when there is no current
    /// identity to preserve.
    var foregroundRecoveryPurpose: ChatResumeSyncPurpose {
        guard let activeSessionId,
              !activeSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .automaticReturn
        }
        return .preserveCurrent
    }

    /// Completes the bootstrap an interrupted connect abandoned (see
    /// `owedPostConnectBootstrap`), on the retained healthy client: the same
    /// profiles + roster evidence, then the connect's own catalog sync and
    /// resume decision, then the ancillary loads.
    func runOwedPostConnectBootstrap(
        _ owed: OwedPostConnectBootstrap,
        reconciliationToken token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        isCurrent: @MainActor () -> Bool
    ) async {
        let client = owed.client
        let profile = activeProfile
        func stillOwns() -> Bool {
            isCurrent() && self.client === client && activeProfile == profile
        }
        botRosterVerifiedForCurrentConnection = false
        async let profilesLoad: Void = loadChatResumeProfiles()
        async let rosterLoad: Void = loadChatResumeBotRoster()
        _ = await (profilesLoad, rosterLoad)
        guard stillOwns() else {
            settleReconciliation(token)
            return
        }
        let viewportTransitionGeneration = chatViewportTransitionGeneration
        let ownedAutomaticWorkToken = owed.purpose == .automaticReturn ? automaticWorkToken : nil
        var publishedCatalog = false
        let outcome = await performSyncSession(
            purpose: owed.purpose,
            using: token,
            automaticWorkToken: ownedAutomaticWorkToken,
            onCatalogPublished: { publishedCatalog = true }
        )
        // Same rule as the connect path: retired once the catalog was
        // published; otherwise still owed (a failed catalog load retries on
        // the next healthy foreground), as `.preserveCurrent` if the user
        // took ownership mid-sync.
        settleOwedPostConnectBootstrap(
            for: client,
            publishedCatalog: publishedCatalog,
            automaticWorkToken: ownedAutomaticWorkToken
        )
        guard stillOwns() else { return }
        // Mirror `synchronizeTransportContinuation`: an automatic return the
        // user overrode still repairs around the visible conversation.
        if outcome == .automaticIntentInvalidated,
           owed.purpose == .automaticReturn,
           chatViewportTransition == nil,
           chatViewportTransitionGeneration == viewportTransitionGeneration {
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
            guard stillOwns() else { return }
        }
        // Two independent reads, each guarding its own answer against a switch
        // while it was out: sent together, so the tail waits one round trip for
        // them, not two (issue 1727).
        async let busyInputModeRead: Void = loadChatResumeBusyInputMode(using: client)
        async let displayPreferencesRead: Void = loadChatResumeProfileDisplayPreferences()
        _ = await (busyInputModeRead, displayPreferencesRead)
        guard stillOwns() else { return }
        Task { await loadChatResumeSlashCommands() }
        Task { await refreshNotifierPluginStatus() }
    }

    /// A healthy foreground transition must be observational, not a session
    /// replacement. `session.resume` is a session SWITCH upstream (switch_
    /// session), and the full sync path re-derives the target session,
    /// replaces the transcript, and resets the live reasoning projection — a
    /// harmless background→foreground cycle must not manufacture a semantic
    /// turn boundary. So the healthy-socket path first probes the gateway's
    /// in-memory runtime registry (`session.active_list`), which upstream
    /// guarantees does not resume, focus, or mutate a session, and only falls
    /// back to `session.resume` when the registry proves the live runtime is
    /// gone (or cannot answer).
    func refreshForegroundOnHealthyTransport(
        using client: HermesClient,
        probeRead: Task<ForegroundRuntimeRowsRead, Never>? = nil,
        freshnessCheckArmed: Bool,
        reconciliationToken token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) async {
        guard foregroundRefreshOwnsReconciliation(token),
              automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
            settleReconciliation(token)
            return
        }
        let requestedSessionID = activeSessionId
        // A foreground recovery is repairing the conversation already on
        // screen. It must never use automatic-return fallback selection while
        // that conversation still has an identity: a transient catalog gap or
        // stale saved id would otherwise replace it with an unrelated chat.
        let recoveryPurpose = foregroundRecoveryPurpose
        let probe: ForegroundRuntimeProbe
        if let requestedSessionID {
            probe = await probeForegroundRuntime(
                requestedSessionID: requestedSessionID,
                using: client,
                alreadyReading: probeRead
            )
        } else {
            probe = .absent
        }
        guard foregroundRefreshOwnsReconciliation(token),
              automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
            settleReconciliation(token)
            return
        }
        // Scene-transition evidence. The arming flag was consumed at the
        // `.active` transition itself (one foreground return pays the check;
        // dips stay observational). The pre-suspension running set is read
        // but never cleared here: the next real transition overwrites it, so
        // a token-rotated refresh cannot consume evidence a newer refresh
        // still needs. A working/waiting row matching the pre-suspension
        // running set continues a turn Conduit already owns; without that
        // match, liveness alone says nothing about whether the local
        // transcript saw the activity, and a real background interval may
        // have hidden persisted turns from another surface entirely.
        let preSuspensionRunningIDs = preSuspensionTurnRunningSessionIDs
        switch probe {
        case let .live(row):
            if row.status == "starting" {
                // Runtime present, liveness inconclusive: "starting" also
                // covers promptless agent pre-warm (session.create / cold
                // resume) and transiently masks a running turn during the
                // build window, so it proves neither busy nor idle. Live
                // events own the next edge; never manufacture a resume here.
                // A transitional state (.synchronizing / .reconnecting) left
                // by an aborted recovery attempt is NOT valid stream-owned
                // state, though: normalize it to a usable neutral baseline
                // (starting is never classified as running) so the composer
                // cannot stay disabled indefinitely — and a newer buffered
                // busy edge still wins during the boundary replay.
                lifecycleLog.notice(
                    "Foreground refresh: probe=starting session=\(requestedSessionID ?? "-", privacy: .private(mask: .hash)) → observation-only, transitional state normalized"
                )
                if turnState == .synchronizing || turnState == .reconnecting {
                    setRunning(false)
                }
                settleForegroundBoundary(token, automaticWorkToken: automaticWorkToken)
            } else if row.isRunning {
                let acceptedIDs = acceptedIdentitySessionIDs(
                    forRequested: requestedSessionID ?? ""
                )
                let continuesLocalTurn = !preSuspensionRunningIDs.isDisjoint(with: acceptedIDs)
                if row.status == "waiting", !Self.hasPendingDecision(in: messages) {
                    // Waiting is a committed busy state, but it normally
                    // represents an answerable approval or clarification.
                    // A registry probe alone cannot restore the missing card,
                    // so re-resume the current conversation authoritatively.
                    lifecycleLog.notice(
                        "Foreground refresh: probe=waiting without visible decision → authoritative resume"
                    )
                    await syncSession(
                        purpose: recoveryPurpose,
                        using: token,
                        automaticWorkToken: automaticWorkToken
                    )
                } else if !freshnessCheckArmed {
                    // Overlay-dip semantics: the socket survived the dip and
                    // live events kept the transcript current, so the
                    // observational adopt stands without a transcript read.
                    if !messages.isEmpty {
                        lifecycleLog.notice(
                            "Foreground refresh: probe=live status=\(row.status, privacy: .public) session=\(requestedSessionID ?? "-", privacy: .private(mask: .hash)) → observation-only adopt (unarmed)"
                        )
                        adoptForegroundRunningState(
                            reconciliationToken: token,
                            automaticWorkToken: automaticWorkToken
                        )
                    } else {
                        // A running runtime over an empty local transcript
                        // means this surface never hydrated (failed resume,
                        // or the turn was started from another surface):
                        // attach through the full refresh, whose resume
                        // returns the live projection.
                        lifecycleLog.notice(
                            "Foreground refresh: probe=live localTranscript=empty → resume refresh (attach live projection)"
                        )
                        await syncSession(
                            purpose: recoveryPurpose,
                            using: token,
                            automaticWorkToken: automaticWorkToken
                        )
                    }
                } else if continuesLocalTurn, !messages.isEmpty {
                    // Same-session working is NOT same-turn proof: Turn A can
                    // complete and Turn B start in the SAME session while
                    // Conduit was suspended. One bounded tail read proves
                    // continuity — an unchanged verdict keeps the zero-resume
                    // fast path; anything else takes the authoritative
                    // attach below (which owns the in-flight projection).
                    await reconcileForegroundCrossSurfaceActivity(
                        livenessIsRunning: true,
                        requestedSessionID: requestedSessionID ?? "",
                        probeRow: row,
                        reconciliationToken: token,
                        automaticWorkToken: automaticWorkToken
                    )
                } else {
                    // Working without turn-continuity evidence after a real
                    // background: a turn this device never owned. Persisted
                    // history alone cannot supply the in-flight assistant/
                    // reasoning projection, so attach authoritatively — the
                    // compact resume fast-path returns the live projection
                    // and the reconcile merges the persisted prefix.
                    lifecycleLog.notice(
                        "Foreground refresh: probe=live status=\(row.status, privacy: .public) session=\(requestedSessionID ?? "-", privacy: .private(mask: .hash)) → authoritative attach (remote running turn)"
                    )
                    await syncSession(
                        purpose: recoveryPurpose,
                        using: token,
                        automaticWorkToken: automaticWorkToken
                    )
                }
            } else if turnState.isRunning {
                // The turn ended while the app was suspended and the idle edge
                // was missed. Presentation recovery needs the authoritative
                // bounded transcript refresh, which is allowed to resume
                // because nothing is running anymore.
                lifecycleLog.notice(
                    "Foreground refresh: probe=idle localTurn=running → resume refresh (turn ended while away)"
                )
                await syncSession(
                    purpose: recoveryPurpose,
                    using: token,
                    automaticWorkToken: automaticWorkToken
                )
            } else if freshnessCheckArmed {
                // Authoritative idle after a real background: the runtime
                // being idle does not prove the local transcript saw
                // everything persisted while Conduit was away. One bounded
                // persisted-tail read decides between the observational idle
                // adoption and merging the missed rows.
                await reconcileForegroundCrossSurfaceActivity(
                    livenessIsRunning: false,
                    requestedSessionID: requestedSessionID ?? "",
                    probeRow: row,
                    reconciliationToken: token,
                    automaticWorkToken: automaticWorkToken
                )
            } else {
                adoptForegroundAuthoritativeIdle(
                    token: token,
                    automaticWorkToken: automaticWorkToken
                )
            }
        case .absent:
            // No live runtime for this session: either the turn completed and
            // the registry reaped it while the transport was away, or the
            // gateway restarted and the runtime id is gone. Both need the
            // resume-based refresh to reattach (or recover completed work).
            // `session.resume` reuses a live runtime when one exists, so this
            // cannot create a duplicate runtime for a session that is alive.
            lifecycleLog.notice(
                "Foreground refresh: probe=absent → resume refresh (runtime not live)"
            )
            await syncSession(
                purpose: recoveryPurpose,
                using: token,
                automaticWorkToken: automaticWorkToken
            )
        case let .unavailable(reason):
            // Older gateway or transient registry failure: keep the proven
            // resume-based refresh rather than guessing.
            lifecycleLog.notice(
                "Foreground refresh: probe unavailable (\(reason, privacy: .private)) → resume refresh"
            )
            await syncSession(
                purpose: recoveryPurpose,
                using: token,
                automaticWorkToken: automaticWorkToken
            )
        }
    }

    /// The ids of every `session.active_list` row still running or about to
    /// (working, waiting, starting): what a turn's Live Activity is settled
    /// against. Idle rows are sessions with no turn.
    nonisolated static func liveTurnSessionIDs(_ rows: [LiveSessionStatus]) -> Set<String> {
        var ids = Set<String>()
        for row in rows where row.status != "idle" {
            for id in [row.runtimeSessionId, row.storedSessionId] where !id.isEmpty { ids.insert(id) }
        }
        return ids
    }

    /// Reads the live registry once more after `registryAbsenceSpan`, so a
    /// turn whose chat a one-off read found absent is settled even with the
    /// chat list's poll off screen. One at a time: a read already waiting
    /// settles every absence seen meanwhile.
    func scheduleLiveTurnRegistryRecheck() {
        guard liveTurnRegistryRecheck == nil else { return }
        liveTurnRegistryRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LiveTurnActivities.registryAbsenceSpan + 1))
            guard let self, !Task.isCancelled else { return }
            // Cleared first, so this read can ask for the next one.
            self.liveTurnRegistryRecheck = nil
            await self.refreshLiveSessionStatuses()
        }
    }

    /// `session.active_list` rows are the gateway's live registry: every row
    /// naming both a runtime and a stored id is fresh authoritative routing
    /// evidence (the same authority class as a catalog snapshot), recorded
    /// through the explicit authoritative rebind. The write is strictly
    /// OBSERVATIONAL — recording rows never mutates the selected
    /// conversation, and the healthy-foreground rule (observe the registry,
    /// never resume without cause) is untouched.
    func recordActiveListEvidence(_ rows: [LiveSessionStatus], profile: String) {
        // Every active_list read is a full snapshot of the profile's live
        // registry, so it also drives the chat list's Working / Needs input
        // state (#454).
        if profile == activeProfile {
            let index = SessionLiveStatusIndex(rows: rows)
            if index != liveSessionStatusIndex || liveSessionStatusProfile != profile {
                liveSessionStatusIndex = index
                liveSessionStatusProfile = profile
            }
        }
        // Lock Screen progress of a turn that ended unseen (#605).
        if liveTurnActivitiesRegistrySnapshot(Self.liveTurnSessionIDs(rows), profile, activeDashboardID?.uuidString) {
            scheduleLiveTurnRegistryRecheck()
        }
        for row in rows {
            conversationIdentityIndex.recordAuthoritative(
                runtimeID: row.runtimeSessionId,
                durableID: row.storedSessionId,
                profile: profile,
                source: .activeList
            )
        }
    }

    /// One `session.active_list` read, with the connection it was asked
    /// on: rows from before a server change must not count.
    struct ForegroundRuntimeRowsRead: Sendable {
        let rows: Result<[LiveSessionStatus], Error>
        let profile: String
        let serverIdentity: String?
    }

    /// Starts the registry read now, so the foreground's health ping and
    /// this read share one round trip (issue 1727). Reading has no side
    /// effects; the rows are judged in `probeForegroundRuntime`.
    func startForegroundRuntimeRowsRead(using client: HermesClient) -> Task<ForegroundRuntimeRowsRead, Never> {
        let profile = activeProfile
        let serverIdentity = defaults.string(forKey: Self.chatResumeServerIdentityKey)
        let probeActiveSessions = chatResumeLifecycleOperations.probeActiveSessions
        return Task { @MainActor in
            let rows: Result<[LiveSessionStatus], Error>
            do {
                if let probeActiveSessions {
                    rows = .success(try await probeActiveSessions(client))
                } else {
                    rows = .success(try await client.activeSessions())
                }
            } catch {
                rows = .failure(error)
            }
            return ForegroundRuntimeRowsRead(rows: rows, profile: profile, serverIdentity: serverIdentity)
        }
    }

    /// Read-only registry probe for the active conversation. Matches a row by
    /// ANY identity the conversation is known under (requested, stored, and
    /// runtime aliases), so a runtime-id rotation cannot be mistaken for a
    /// dead runtime while the catalog already knows the alias.
    /// `alreadyReading` is a read the foreground started beside its health
    /// ping; without one the probe reads now.
    private func probeForegroundRuntime(
        requestedSessionID: String,
        using client: HermesClient,
        alreadyReading: Task<ForegroundRuntimeRowsRead, Never>? = nil
    ) async -> ForegroundRuntimeProbe {
        let reading = alreadyReading ?? startForegroundRuntimeRowsRead(using: client)
        let read = await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            reading.cancel()
        }
        do {
            let rows = try read.rows.get()
            // Currency fence: rows observed before a SERVER change must not
            // repopulate the index scope that change cleared. The fence is
            // the committed server identity — the exact boundary
            // prepareChatResumeForConnection uses — so a same-server client
            // replacement (reconnect, possibly re-addressed) stays valid
            // while a real server switch discards its in-flight rows.
            guard read.profile == activeProfile,
                  defaults.string(forKey: Self.chatResumeServerIdentityKey) == read.serverIdentity else {
                return .unavailable("Probe superseded by connection change")
            }
            recordActiveListEvidence(rows, profile: read.profile)
            let acceptedIDs = acceptedIdentitySessionIDs(forRequested: requestedSessionID)
            if let row = rows.first(where: {
                acceptedIDs.contains($0.runtimeSessionId) || acceptedIDs.contains($0.storedSessionId)
            }) {
                return .live(row)
            }
            return .absent
        } catch {
            return .unavailable(UserFacingError.message(for: error))
        }
    }

    /// Every identity the active conversation answers to: the requested id,
    /// its canonical stored id, and the catalog's confirmed aliases.
    func acceptedIdentitySessionIDs(forRequested requestedSessionID: String) -> Set<String> {
        var ids = knownSessionIDs(for: requestedSessionID)
        ids.insert(requestedSessionID)
        if let canonical = canonicalSessionID(for: requestedSessionID) {
            ids.insert(canonical)
        }
        if let activeSessionId {
            ids.insert(activeSessionId)
        }
        return ids
    }

    /// Adopts an authoritative running state WITHOUT replacing any
    /// presentation state: no transcript swap, no streaming-buffer reset, no
    /// reasoning-segment reset. Ordering: the probe snapshot is the OLDER
    /// observation, so it establishes the running baseline FIRST; the buffered
    /// events captured while the foreground reconciliation boundary was open
    /// are replayed SECOND — they arrived after the snapshot was taken and the
    /// newest authoritative edge must win (a buffered sessionBusy(false) or
    /// completion therefore settles the turn instead of being overwritten back
    /// to running). applyStreamEvent's active-session gate still applies. The
    /// boundary settles last.
    func adoptForegroundRunningState(
        reconciliationToken token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) {
        guard token == shownChat.reconciliationToken else { return }
        // Probe baseline (older observation).
        setRunning(true)
        turnStateIsStale = false
        // Newer live edges win over the snapshot.
        let bufferedEntries = reconciliation?.bufferedEntries ?? []
        bufferedEntries.forEach { applyNumberedStreamEvent($0.event, turnGeneration: $0.generation) }
        _ = settleReconciliationAndPublish(token, automaticWorkToken: automaticWorkToken)
    }

    /// Replays the events buffered while the foreground reconciliation
    /// boundary was open — newer live edges win over any baseline the caller
    /// just adopted — then settles the boundary. Used when the registry answer
    /// is inconclusive ("starting", so the local state stays stream-owned) and
    /// after the authoritative-idle adoption, where the caller establishes the
    /// idle baseline first.
    func settleForegroundBoundary(
        _ token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) {
        guard token == shownChat.reconciliationToken else { return }
        let bufferedEntries = reconciliation?.bufferedEntries ?? []
        bufferedEntries.forEach { applyNumberedStreamEvent($0.event, turnGeneration: $0.generation) }
        _ = settleReconciliationAndPublish(token, automaticWorkToken: automaticWorkToken)
    }

    /// Adopts an authoritative idle observation: the registry says this
    /// runtime is idle, so a transitional state (.synchronizing /
    /// .reconnecting) left behind by an aborted recovery attempt cannot
    /// survive a healthy-socket foreground cycle — the observational refresh
    /// must still end with a usable composer. setRunning(false) is idempotent
    /// for .idle and preserves an unsupportedGateway marker. The adopted idle
    /// is the OLDER observation: events buffered while the boundary was open
    /// are newer live edges and must win (a busy edge that raced the probe
    /// re-owns the state) before the boundary settles and discards them.
    func adoptForegroundAuthoritativeIdle(
        token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) {
        lifecycleLog.notice("Foreground refresh: probe=idle → adopt idle")
        setRunning(false)
        turnStateIsStale = false
        settleForegroundBoundary(token, automaticWorkToken: automaticWorkToken)
    }
}
