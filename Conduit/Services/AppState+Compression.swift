//
//  AppState+Compression.swift
//  Conduit
//
//  Compressing a session (`session.compress`), its recovery and legacy
//  fallback, and adopting the compressed transcript. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Session compression (`session.compress`)

    /// Dedicated `/compress` handler (upstream Desktop parity): the
    /// `session.compress` RPC with its LLM-scale timeout, transcript adoption
    /// from the response, and the `slash.exec` fallback only for gateways
    /// that predate the dedicated method.
    func compressActiveSession(
        focusTopic: String,
        legacyCommand: String,
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async {
        guard isCurrentComposerSubmission(context) else { return }
        if compressingSessionIDs.contains(where: { composerSessionIDsAreEquivalent($0, sessionID) }) {
            errorMessage = AppLocalization.string("Compression is already in progress for this conversation.")
            return
        }
        var activeClaimID = sessionID
        compressingSessionIDs.insert(activeClaimID)
        defer { compressingSessionIDs.remove(activeClaimID) }
        let trimmedTopic = focusTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusTopicParam = trimmedTopic.isEmpty ? nil : trimmedTopic
        // The conversation's terminal-compaction generation at RPC
        // invocation: a `pending` response may only establish the server-side
        // claim when no terminal edge landed during the await.
        let invocationGeneration = terminalServerCompactionGeneration(for: sessionID)
        do {
            let outcome = try await compressSessionWithRecovery(
                client: client,
                sessionID: sessionID,
                focusTopic: focusTopicParam,
                invocationGeneration: invocationGeneration,
                context: context,
                // A stale-runtime recovery rebound the conversation to a
                // fresh runtime: move the in-flight claim with it so
                // coalescing and the spinner follow the recovered identity
                // for the whole retry window (no orphaned old-id entry).
                onRecover: { recoveredSessionID in
                    compressingSessionIDs.remove(activeClaimID)
                    activeClaimID = recoveredSessionID
                    compressingSessionIDs.insert(activeClaimID)
                }
            )
            guard isCurrentComposerSubmission(outcome.context) else { return }
            let disposition = applySessionCompressionResult(
                outcome.result,
                sessionID: outcome.sessionID,
                invocationGeneration: invocationGeneration,
                context: outcome.context
            )
            if disposition == .adopted {
                // Fence: a reconcile whose transcript fetch resolved before
                // the server-side compression committed would otherwise
                // write pre-compression rows and offsets over the freshly
                // re-established invariants. Rotating the token makes every
                // reconcile that predates the compression fail its
                // commit-time ownership check; reconciles that start after
                // this point fetch post-compression state and legitimately
                // own the fence.
                invalidateReconciliation()
                await reestablishPersistedHistoryAfterCompression(
                    requestedSessionID: outcome.sessionID,
                    context: outcome.context
                )
            }
        } catch {
            // A recovery that rebound the session carries the REBASED
            // context: classification, fences, and the legacy fallback must
            // evaluate against the recovered identity, not the dead runtime.
            let errorForReporting: Error
            let reportingContext: ComposerSubmissionContext
            if let recoveryFailure = error as? CompressionRecoveryContextError {
                errorForReporting = recoveryFailure.underlying
                reportingContext = recoveryFailure.context
            } else {
                errorForReporting = error
                reportingContext = context
            }
            guard isCurrentComposerSubmission(reportingContext) else { return }
            if HermesClient.isMissingRPCMethod(errorForReporting) {
                await runLegacyCompressionFallback(
                    legacyCommand: legacyCommand,
                    aliasArgument: focusTopic,
                    client: client,
                    sessionID: activeClaimID,
                    context: reportingContext
                )
            } else {
                appendSlashOutput(
                    AppLocalization.string(
                        "⚠️ Compression failed: \(UserFacingError.message(for: errorForReporting))"
                    ),
                    context: reportingContext
                )
            }
        }
    }

    /// One `session.compress` call with upstream Desktop's stale-runtime
    /// recovery (`withSessionNotFoundResume`, minus the runtime cache): if —
    /// and only if — the gateway answers `4001 "session not found"` for a
    /// reaped/detached runtime, resume the conversation's durable stored id
    /// once, rebind the active runtime through the canonical state helper,
    /// and retry ONCE against the fresh runtime. Timeouts (compression is
    /// legitimately LLM-bound), busy rejections, connection loss, and
    /// compression errors are never recovery signals; a resume failure
    /// rethrows the ORIGINAL compression error, which is the more meaningful
    /// one. The returned context is re-based onto the recovered runtime so
    /// the caller's post-retry fences validate the NEW identity.
    /// A stale-runtime recovery rebound the submission to a fresh runtime;
    /// failures after that rebind fence against the RECOVERED identity, so
    /// reporters must unwrap `underlying` and fence with `context`.
    private struct CompressionRecoveryContextError: Error {
        let underlying: Error
        let context: ComposerSubmissionContext
    }

    private func compressSessionWithRecovery(
        client: HermesClient,
        sessionID: String,
        focusTopic: String?,
        invocationGeneration: Int,
        context: ComposerSubmissionContext,
        onRecover: @MainActor (String) -> Void
    ) async throws -> (result: SessionCompressResult, sessionID: String, context: ComposerSubmissionContext) {
        do {
            let result = try await performCompressSession(
                client: client,
                sessionID: sessionID,
                focusTopic: focusTopic
            )
            return (result, sessionID, context)
        } catch {
            // Bind the ORIGINAL error first: the recovery steps below have
            // their own failure modes, and the original compression error is
            // the one that stays meaningful. (An inner `catch { throw error }`
            // would rethrow the RESUME failure instead.)
            let originalError = error
            guard HermesClient.isSessionNotFoundError(originalError) else { throw originalError }
            // Recovery needs the durable stored id the conversation's
            // identity anchors. A canonical Bot Chat has no catalog row
            // (hidden, another profile): its anchor is the accepted scroll
            // identity, and the recovery resume must ride the BOT profile —
            // otherwise the re-resume would address the dashboard store and
            // never find the session.
            // Resolved like the resume's scope: the registry alone is empty
            // after a relaunch or a server boundary.
            let botScope = botScopeProfile(forSessionIDs: [sessionID], workspaceProfile: activeProfile)
            let storedSessionID: String
            let acceptedIDs: Set<String>
            let recoveryProfile: String?
            if let botScope {
                let canonical = activeChatScrollSessionIdentity.canonicalSessionID ?? sessionID
                storedSessionID = canonical
                acceptedIDs = activeChatScrollSessionIdentity.equivalentSessionIDs
                    .union([sessionID, canonical])
                recoveryProfile = botScope
            } else {
                guard let catalogRow = (sessions + cronSessions).first(where: {
                    $0.id == sessionID || $0.alternateIds.contains(sessionID)
                }) else { throw originalError }
                storedSessionID = catalogRow.storedSessionId ?? catalogRow.id
                acceptedIDs = Set(
                    [catalogRow.id, storedSessionID, sessionID] + catalogRow.alternateIds
                )
                recoveryProfile = nil
            }
            // Drift fence BEFORE the resume side effect: a resume mints a
            // fresh runtime — never mint one for a submission the user has
            // already abandoned.
            guard isCurrentComposerSubmission(context) else { throw originalError }
            let resumed: SessionResumeResult
            do {
                resumed = try await openChatResumeSession(
                    storedSessionID,
                    using: client,
                    compact: true,
                    profile: recoveryProfile
                )
            } catch {
                // Resume failure: surface the ORIGINAL compression error
                // (upstream Desktop rethrows it too).
                throw originalError
            }
            let recoveredSessionID = resumed.sessionId
            // A blank runtime id cannot be rebound or retried.
            guard !recoveredSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw originalError
            }
            // Identity admission — the same gate the resume reconciliation
            // runs: the recovered runtime must belong to the stored
            // conversation this recovery intended. A contradictory durable
            // claim or a runtime positively owned by another catalog row is
            // rejected without rebind or retry.
            // Accept everything the conversation's identity positively
            // anchors — the same seeding breadth the resume reconciliation
            // uses.
            let selectedIdentity = ConversationIdentity(
                profile: recoveryProfile ?? activeProfile,
                durableSessionID: storedSessionID,
                runtimeSessionID: sessionID,
                acceptedSessionIDs: acceptedIDs
            )
            let claim = ResumeIdentityClaim(
                runtimeSessionID: recoveredSessionID,
                durableSessionID: resumed.storedSessionId
            )
            guard case .success = ConversationIdentityGate.admit(
                claim: claim,
                selected: selectedIdentity,
                catalog: sessions + cronSessions
            ) else {
                sessionCatalogLog.notice(
                    "Rejected contradictory recovery resume; requested=\(sessionID, privacy: .private(mask: .hash)), recovered=\(recoveredSessionID, privacy: .private(mask: .hash))"
                )
                throw originalError
            }
            // Record the authoritative runtime → durable mappings BEFORE the
            // retry: the recovered runtime becomes a positively confirmed
            // alias of the stored conversation, and the superseded runtime's
            // mapping keeps late alias-addressed lifecycle signals on the
            // same compaction generation.
            conversationIdentityIndex.recordAuthoritative(
                runtimeID: recoveredSessionID,
                durableID: storedSessionID,
                profile: recoveryProfile ?? activeProfile,
                source: .resume
            )
            conversationIdentityIndex.recordAuthoritative(
                runtimeID: sessionID,
                durableID: storedSessionID,
                profile: recoveryProfile ?? activeProfile,
                source: .resume
            )
            // Migrate the invocation generation onto the recovered
            // conversation's durable key: the pending fence compares against
            // this counter, and without the migration a terminal edge that
            // landed under the superseded runtime's key during the recovery
            // await would be invisible to it.
            let recoveredKey = serverCompactionGenerationKey(for: recoveredSessionID)
            let supersededKey = serverCompactionGenerationKey(for: sessionID)
            serverCompactionTerminalGenerations[recoveredKey] = max(
                serverCompactionTerminalGenerations[recoveredKey] ?? 0,
                serverCompactionTerminalGenerations[supersededKey] ?? 0,
                invocationGeneration
            )
            // Drift fence after the resume await (must remain): identity must
            // still own this submission. If the user navigated away, do not
            // rebind and do not send compression to the recovered runtime.
            guard isCurrentComposerSubmission(context) else { throw originalError }
            // Register the recovered identity BEFORE the state helper below
            // resolves the conversation's kind: the reference must record a
            // Bot Chat as a Bot Chat, and the rotated runtime id is only
            // registered here.
            if let recoveryProfile {
                // Labels are keyed by normalized ids, like the registry.
                let normalizedSessionID = ChatScrollIdentityNormalization.sessionID(sessionID)
                noteBotChatSession(
                    recoveredSessionID,
                    profile: recoveryProfile,
                    label: normalizedSessionID.flatMap { botChatSessionLabels[$0] }
                )
                noteBotChatSession(
                    storedSessionID,
                    profile: recoveryProfile,
                    label: normalizedSessionID.flatMap { botChatSessionLabels[$0] }
                )
            }
            // Rebind through the canonical state helper: updates
            // `activeSessionId` and re-anchors the persisted identity with
            // the conversation's own kind.
            setActiveSessionState(id: recoveredSessionID)
            onRecover(recoveredSessionID)
            // Re-base the submission onto the recovered runtime: the old
            // context describes the dead runtime and would fail every
            // post-retry ownership fence.
            let reboundContext = composerSubmissionContext()
            do {
                let result = try await performCompressSession(
                    client: client,
                    sessionID: recoveredSessionID,
                    focusTopic: focusTopic
                )
                return (result, recoveredSessionID, reboundContext)
            } catch {
                // A second failure is a real error (upstream Desktop), but it
                // belongs to the RECOVERED identity: fence and report there,
                // never against the dead runtime.
                throw CompressionRecoveryContextError(underlying: error, context: reboundContext)
            }
        }
    }

    private func performCompressSession(
        client: HermesClient,
        sessionID: String,
        focusTopic: String?
    ) async throws -> SessionCompressResult {
        if let compressSession = chatResumeLifecycleOperations.compressSession {
            return try await compressSession(client, sessionID, focusTopic)
        }
        return try await client.compressSession(sessionId: sessionID, focusTopic: focusTopic)
    }

    /// Older gateways predate `session.compress`; keep today's generic slash
    /// path working there, mirroring upstream Desktop. Only a missing-method
    /// failure routes here — a timeout means the gateway IS compressing, and
    /// re-running `/compress` through the legacy route would start a second
    /// server-side compression. On those legacy gateways the generic slash
    /// path behaves as for any other command (a `slash.exec` rejection falls
    /// back to `command.dispatch`; a timeout does not).
    private func runLegacyCompressionFallback(
        legacyCommand: String,
        aliasArgument: String,
        client: HermesClient,
        sessionID: String,
        context: ComposerSubmissionContext
    ) async {
        do {
            let legacyResult = try await executeGatewaySlash(
                client: client,
                sessionID: sessionID,
                command: legacyCommand,
                context: context
            )
            guard isCurrentComposerSubmission(context) else { return }
            await handleSlashResult(
                legacyResult,
                depth: 0,
                aliasArgument: aliasArgument,
                client: client,
                sessionID: sessionID,
                context: context
            )
        } catch {
            guard isCurrentComposerSubmission(context) else { return }
            appendSlashOutput(
                AppLocalization.string(
                    "⚠️ Compression failed: \(UserFacingError.message(for: error))"
                ),
                context: context
            )
        }
    }

    /// What the compression result did to the visible transcript — the
    /// caller re-establishes persisted-history invariants only after an
    /// adoption actually replaced it.
    private enum CompressionTranscriptDisposition {
        case adopted
        /// A turn started while the RPC was in flight; adoption was deferred.
        case deferred
        case untouched
    }

    private func applySessionCompressionResult(
        _ result: SessionCompressResult,
        sessionID: String,
        invocationGeneration: Int,
        context: ComposerSubmissionContext
    ) -> CompressionTranscriptDisposition {
        if result.lockHeld {
            // Another compression — this device, another client, or an
            // automatic one — already holds the compression lock. Not an
            // error, and never retried from here.
            appendSlashOutput(
                result.message ?? AppLocalization.string("Compression is already in progress."),
                context: context
            )
            return .untouched
        }
        if result.isPending {
            // The gateway's bounded compute-host wait expired while the host
            // is still compressing; it pushes `session.info` plus a
            // `compacted` status.update edge when the host finishes. Not an
            // error, and never retried (upstream #97948). The RPC ending is
            // NOT the compression finishing: record the server-side
            // compaction so the spinner stays truthful until the `compacted`
            // edge (or an authoritative reconnect) clears it.
            //
            // Pending-resurrection fence: if a terminal `compacted` edge
            // landed while this RPC was in flight, it already processed the
            // completion — the stale continuation must not resurrect the
            // claim. Conversation-level generation cost: another client's
            // terminal edge during our await also suppresses this row (the
            // transcript still refreshes via that edge's own handling).
            if terminalServerCompactionGeneration(for: sessionID) == invocationGeneration {
                establishServerCompactionClaim(
                    sessionId: sessionID,
                    generation: invocationGeneration
                )
                appendSlashOutput(
                    result.message ?? AppLocalization.string("Compression continues in the background; the transcript will refresh when it finishes."),
                    context: context
                )
            }
            return .untouched
        }
        // Any authoritative terminal result ends the server-side claim.
        clearServerCompactionClaim(sessionId: sessionID)
        let record = Self.compressionRecord(for: result)
        guard result.hasMessagesPayload else {
            appendSlashOutput(record, context: context)
            return .untouched
        }
        // Upstream Desktop adopts the returned transcript whenever the
        // `messages` array is present — including an aborted compression,
        // whose payload is the gateway's authoritative (unchanged) history.
        // Abort only suppresses the success record above.
        //
        // A turn that started while the compression RPC was in flight owns
        // the transcript now; replacing it here would erase the live turn's
        // rows and streaming text (Desktop decouples this via per-runtime
        // session state). Mark the window stale so the next authoritative
        // sync converges, and leave the in-flight turn alone.
        //
        // Leave `locallyOwnedInFlightTurn` alone: the live turn still owns
        // the transcript, and settlement records its ordering debt.
        if turnState == .running || shownChat.locallyOwnedInFlightTurn != nil {
            transcriptFreshnessIsStale = true
            // Compression rewrote the persisted history server-side even
            // though adoption is deferred: a pre-compression backfill window
            // must not stay usable — "Load earlier" would page offsets from
            // a row universe that no longer exists. Invalidate here and do
            // NOT rehydrate: the live turn is why adoption was deferred, and
            // the next authoritative reconcile (or pre-send freshness gate)
            // re-establishes pagination and provenance.
            invalidatePersistedHistoryInvariants()
            appendSlashOutput(record, context: context)
            return .deferred
        }
        adoptCompressedTranscript(result.messages, sessionID: sessionID)
        appendSlashOutput(record, context: context)
        return .adopted
    }

    /// The chat record a finished compression leaves behind: summary lines on
    /// success; a warning note instead when the compression aborted (upstream
    /// Desktop keeps an aborted run out of the success path); the host's own
    /// feedback or the removed-count text as the remaining fallbacks.
    private static func compressionRecord(for result: SessionCompressResult) -> String {
        if result.isAborted {
            let detail = result.summaryHeadline ?? result.summaryNote ?? result.message
            return detail.map { "⚠️ \($0)" }
                ?? AppLocalization.string("⚠️ Context compression was aborted; the transcript is unchanged.")
        }
        let summaryLines = [result.summaryHeadline, result.summaryTokenLine, result.summaryNote]
            .compactMap { $0 }
        if !summaryLines.isEmpty {
            return summaryLines.joined(separator: "\n\n")
        }
        if let hostOutput = result.hostOutput, !hostOutput.isEmpty {
            return hostOutput
        }
        let removed = result.removed ?? 0
        return removed > 0
            ? AppLocalization.string("Compressed \(Int(removed)) messages.")
            : AppLocalization.string("Nothing to compress.")
    }

    /// The persisted-history invariants that describe "which persisted rows
    /// the local transcript covers". A server-side compression rewrites that
    /// row universe, so any pre-compression window offset, durable-row
    /// provenance, and ordering frontier is obsolete the moment the rewrite
    /// lands — they are re-established only by a fresh validated hydration.
    func invalidatePersistedHistoryInvariants() {
        persistedTranscriptWindow = nil
        shownChat.durablePersistedRowIDs = []
        shownChat.persistedOrderingFrontier = PersistedOrderingFrontier()
    }

    /// Adopt the gateway's post-compress transcript for the current
    /// conversation. Mirrors the invariant set of `applyChatResume` for an
    /// in-place replacement — viewport replacement bookkeeping,
    /// presentation-cache enrichment, review-card reattachment, and the
    /// authoritative clears of local turn/ordering state — without touching
    /// session identity (compression never switches conversations).
    private func adoptCompressedTranscript(
        _ compressed: [ChatMessage],
        sessionID: String
    ) {
        settleReasoningSegmentIntoTranscript()
        clearStreamingText()
        shownChat.activeAssistantMessageId = nil
        resetReasoningTurn()
        markChatViewportReplacement()
        // Locally restored-but-unanswered decision cards survive a
        // compression: the compressed gateway transcript can no longer carry
        // them. Reattach the ones the gateway rows do not already include
        // (same dedup rule as applyChatResume).
        let gatewayDecisionKeys = Set(compressed.compactMap(SessionPresentationCache.decisionKey(for:)))
        let retainedDecisionMessages = pendingDecisionRestorationMessages(for: sessionID).filter { message in
            guard let key = SessionPresentationCache.decisionKey(for: message) else { return false }
            return !gatewayDecisionKeys.contains(key)
        }
        let merged = sessionPresentationCache.merge(
            compressed + retainedDecisionMessages,
            // The compressed conversation's own namespace: for a bot chat
            // this must agree with the reconcile/open writes, or retained
            // decision cards and presentation land in a foreign partition.
            profile: presentationProfile(for: sessionID),
            sessionIDs: [sessionID],
            includePendingClarifications: false,
            includePendingApprovals: false
        )
        // The chat's own notes aren't among the compressed rows; keep them.
        let kept = Self.keepingLocalNotes(from: messages, in: merged)
        messages = mergeVoiceCallMarkers(into: mergeCachedReviews(into: kept, sessionId: sessionID), sessionId: sessionID)
        // The gateway's authoritative response just replaced the transcript:
        // no local turn/ordering debt can outlive it (applyChatResume's rule).
        transcriptFreshnessIsStale = false
        shownChat.locallyOwnedInFlightTurn = nil
        shownChat.pendingLocalOrderingDebt = nil
        // Compression rewrote the persisted history server-side: window
        // offsets, durable-row provenance, and the ordering frontier from
        // BEFORE the compression describe history that no longer exists.
        // They are re-established only from a fresh validated hydration
        // (reestablishPersistedHistoryAfterCompression); until
        // that succeeds, backfill stays disabled.
        invalidatePersistedHistoryInvariants()
        noteChatViewportTranscriptReplacement()
        cacheMessagePresentation()
    }

    /// Re-establishes the persisted-history invariants the compression
    /// adoption invalidated. The only trustworthy source is a fresh
    /// validated `order=latest offset=0` hydration — the same bounded read
    /// the resume path performs — so the window's next offset, the durable
    /// row provenance, and the ordering frontier are rebuilt from that
    /// response alone. A stale pre-compression nextOffset must never
    /// survive: the compressed history's offsets count from a different
    /// row universe. If the hydration fails (or no history source exists),
    /// the window stays nil and "Load earlier messages" stays disabled
    /// until the next authoritative resume/reconcile rebuilds it.
    private func reestablishPersistedHistoryAfterCompression(
        requestedSessionID: String,
        context: ComposerSubmissionContext
    ) async {
        guard isCurrentComposerSubmission(context) else { return }
        // A bot chat's post-compress rehydration must read the BOT's store
        // and stamp the window with the bot scope, exactly like the initial
        // hydration did.
        let profile = persistedTailProfile(for: requestedSessionID)
        let outcome = await persistedTranscriptOutcome(
            sessionId: requestedSessionID,
            profile: profile,
            using: dashboardTicketBridge
        )
        guard isCurrentComposerSubmission(context) else { return }
        let transcript: PersistedSessionTranscript
        switch outcome {
        case .hydrated(let hydrated):
            transcript = hydrated
        case .unavailable:
            sessionCatalogLog.debug("No persisted-history source after /compress; backfill stays disabled for \(requestedSessionID, privacy: .private(mask: .hash))")
            return
        case .failed(let error):
            sessionCatalogLog.notice("Persisted-history rehydration after /compress failed; backfill stays disabled until the next sync: \(LogRedaction.message(error), privacy: .public)")
            return
        }
        // Identity gate, same rule as the resume path: a response the
        // backend addressed to another conversation must not seed this
        // conversation's ordering evidence.
        guard transcriptMatchesSession(
            transcript,
            requestedSessionId: requestedSessionID,
            resumedSessionId: requestedSessionID
        ) else {
            sessionCatalogLog.debug("Persisted-history page after /compress addressed to another conversation; backfill stays disabled for \(requestedSessionID, privacy: .private(mask: .hash))")
            return
        }
        shownChat.persistedOrderingFrontier = Self.orderingFrontier(from: transcript)
        shownChat.durablePersistedRowIDs = transcript.durableRowIDs
        if let page = transcript.page, page.honorsTailContract {
            persistedTranscriptWindow = PersistedTranscriptWindowState(
                requestedSessionID: requestedSessionID,
                profile: profile,
                pageSize: PersistedTranscriptPagination.pageSize,
                resolvedSessionID: transcript.resolvedSessionId,
                // No resume transaction ran, so the window vouches for the
                // requested + resolved identities only.
                runtimeSessionID: nil,
                nextOffset: page.rawReturned,
                canLoadEarlier: page.mayHaveOlderRows(fetchedRowCount: page.rawReturned),
                hasBackfilledPrefix: false
            )
        } else {
            // Legacy one-shot hydration: the whole persisted history is on
            // screen; no older page exists to fetch.
            persistedTranscriptWindow = nil
        }
    }
}
