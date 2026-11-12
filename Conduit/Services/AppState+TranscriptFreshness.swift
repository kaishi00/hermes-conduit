//
//  AppState+TranscriptFreshness.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Cross-surface transcript
//  freshness.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Cross-surface transcript freshness

    /// Ordering baseline a locally-owned turn captured at submit time.
    enum PersistedOrderingBaseline {
        /// The newest durable row positively observed at submit time.
        case anchored(String)
        /// A validated read positively proved the persisted transcript EMPTY.
        /// Valid ordering evidence — distinct from `unknown`, because a
        /// single new user-turn boundary after a known-empty baseline is
        /// provably the first turn.
        case positivelyEmpty
        /// No usable persisted ordering evidence (never hydrated, legacy
        /// hydration, invalidated): every comparison stays inconclusive.
        case unknown

        var isPositivelyEmpty: Bool {
            if case .positivelyEmpty = self { return true }
            return false
        }

        var isUnknown: Bool {
            if case .unknown = self { return true }
            return false
        }
    }

    /// Derives ordering evidence from a transcript a reconcile or freshness
    /// read validated: a contract page anchors on its newest durable row
    /// (contract pages carry durable ids on every row); a positively empty
    /// page proves emptiness; anything else (legacy one-shot hydration, no
    /// transcript) leaves the ordering evidence UNKNOWN — never carried over
    /// from a previous conversation state.
    static func orderingFrontier(
        from transcript: PersistedSessionTranscript?
    ) -> PersistedOrderingFrontier {
        guard let transcript,
              let page = transcript.page,
              page.honorsTailContract else {
            return PersistedOrderingFrontier()
        }
        // Anchor on the NEWEST row the page positively proves durable: the
        // page's newest row may normalize without a durable id while older
        // rows carry theirs, and that older durable row is still the best
        // positively-observed ordering anchor.
        if let anchorIndex = transcript.messages.lastIndex(where: {
            transcript.durableRowIDs.contains($0.id)
        }) {
            return PersistedOrderingFrontier(
                newestObservedDurableRowID: transcript.messages[anchorIndex].id
            )
        }
        // Emptiness is proven on the RAW row view: the server must have
        // returned ZERO rows (not merely rows that all normalize away as
        // hidden display_kind scaffolding — those still carry durable ids).
        if page.rawReturned == 0,
           transcript.messages.isEmpty,
           transcript.durableRowIDs.isEmpty,
           !page.mayHaveOlderRows(fetchedRowCount: 0) {
            return PersistedOrderingFrontier(isPositivelyEmpty: true)
        }
        return PersistedOrderingFrontier()
    }

    /// Transcript-scoped lifecycle evidence (freshness uncertainty,
    /// locally-owned turn provenance, persisted ordering evidence) belongs
    /// to the conversation it was captured for. Call wherever the
    /// transcript is wholesale reset for a new/different conversation
    /// identity: sign-out, profile switch, conversation replacement, session
    /// open.
    func resetTranscriptLifecycleEvidence() {
        transcriptFreshnessIsStale = false
        locallyOwnedInFlightTurn = nil
        persistedOrderingFrontier = PersistedOrderingFrontier()
        pendingLocalOrderingDebt = nil
    }

    /// Outcome of the bounded persisted-tail freshness comparison against the
    /// locally adopted durable frontier.
    enum ForegroundFreshnessVerdict {
        /// The newest page overlaps the local durable frontier and contains
        /// nothing beyond it (or, behind a locally-owned optimistic tail,
        /// exactly the expected user-turn boundary): the local transcript is
        /// current. The payload is the persisted ordering evidence this
        /// validated read positively observed — the caller may advance the
        /// ordering frontier with it while the visible transcript stays
        /// untouched.
        case unchanged(
            observedOrderingFrontier: PersistedOrderingFrontier,
            observedNewUserBoundaries: Int?
        )
        /// The page overlaps the frontier and holds validated durable rows
        /// after it: persisted activity the local transcript never saw.
        case advanced(transcript: PersistedSessionTranscript, newRows: [ChatMessage])
        /// No durable ordering proof: the frontier rotated out of the newest
        /// page, the backend has no tail contract, the response belongs to
        /// another conversation identity, the local tail is not durably
        /// anchored, or there is no local frontier. Same invariant as the
        /// ambiguous-delivery verifier — no anchor means "unchanged" can
        /// never be declared. The bounded resume refresh is the
        /// authoritative fallback.
        case inconclusive
        /// The history source is positively, structurally absent for this
        /// conversation (no bridge, or the endpoint answered 404/410/501):
        /// bounded evidence cannot exist, so the authoritative refresh can
        /// skip its doomed history request and resume non-compact directly.
        case sourceUnavailable
        /// The bounded read failed transiently (timeout, 429/5xx, bridge not
        /// ready). Liveness stays authoritative, but freshness is UNRESOLVED:
        /// the freshness marker is retained so the next authoritative source
        /// re-confirms, and no "unchanged" verdict may be claimed.
        case unresolvedTransient
    }

    /// Compares one bounded persisted-tail read against the local durable
    /// frontier. Ordering key: the page is chronological, so the NEWEST local
    /// durable row present in the page is the anchor and only strictly-later
    /// page rows are candidates; candidate rows already held (streamed in
    /// live under any identity) are dropped by id.
    ///
    /// The local transcript may end on the locally-owned turn's optimistic
    /// rows (`locallyOwnedTurn` non-nil). Hermes persists the user row at
    /// TURN START, so the normal in-flight tail is the pre-submit frontier,
    /// the durable twin of our optimistic user row, and any Turn A
    /// output/tool rows; classification there is by canonical USER-turn
    /// boundaries (see `locallyOwnedTurnFreshnessVerdict`), never raw row
    /// count. A durably-anchored tail keeps the plain frontier comparison:
    /// anchor overlap with nothing newer → unchanged; newer durable rows →
    /// an append-only merge of the advancement.
    func foregroundFreshnessVerdict(
        _ outcome: ForegroundPersistedTailOutcome,
        localFrontier: Set<String>,
        localMessageIDs: Set<String>,
        lastLocalMessageID: String?,
        requestedSessionID: String,
        runtimeSessionID: String,
        livenessIsRunning: Bool,
        locallyOwnedTurn: LocallyOwnedTurnTailEvidence?
    ) -> ForegroundFreshnessVerdict {
        switch outcome {
        case .failed:
            return .unresolvedTransient
        case .unavailable:
            return .sourceUnavailable
        case .unsupportedTailContract:
            // A backend without the tail contract: there is no bounded
            // evidence and the freshness check deliberately does not escalate
            // to a full-transcript read — the bounded resume refresh is the
            // authoritative fallback.
            return .inconclusive
        case let .hydrated(transcript):
            // Defense-in-depth only: foregroundPersistedTailOutcome already
            // refuses to construct .hydrated for a non-contract page.
            guard let page = transcript.page, page.honorsTailContract,
                  transcript.messages.isEmpty || !transcript.durableRowIDs.isEmpty else {
                return .inconclusive
            }
            // Identity first — even an empty page must belong to THIS
            // conversation before it can prove anything (a page echoing a
            // foreign session id is never evidence; pages echoing no id at
            // all match by construction).
            guard transcriptMatchesSession(
                transcript,
                requestedSessionId: requestedSessionID,
                resumedSessionId: runtimeSessionID
            ) else {
                // The endpoint answered for a different conversation
                // identity: never merge rows from a foreign transcript.
                return .inconclusive
            }
            // A positively empty page with no older rows proves the
            // conversation has no persisted rows at all: an idle runtime
            // cannot hide anything behind it, and an empty local transcript
            // has nothing to diverge from. A visible optimistic tail over a
            // positively empty page can only be a locally-owned turn whose
            // rows simply have not persisted yet — still observational; any
            // other tail has no ordering proof.
            if transcript.messages.isEmpty {
                // A page whose raw rows all normalize away (hidden
                // scaffolding) is not positively empty — positive emptiness
                // requires the server to have returned zero raw rows.
                guard page.rawReturned == 0,
                      transcript.durableRowIDs.isEmpty,
                      !page.mayHaveOlderRows(fetchedRowCount: 0) else {
                    return .inconclusive
                }
                if lastLocalMessageID == nil {
                    return .unchanged(
                        observedOrderingFrontier: Self.orderingFrontier(from: transcript),
                        observedNewUserBoundaries: nil
                    )
                }
                if let locallyOwnedTurn,
                   locallyOwnedTurn.baseline.isPositivelyEmpty,
                   livenessIsRunning {
                    return .unchanged(
                        observedOrderingFrontier: Self.orderingFrontier(from: transcript),
                        observedNewUserBoundaries: 0
                    )
                }
                return .inconclusive
            }
            let tailIsDurablyAnchored = lastLocalMessageID.map {
                localFrontier.contains($0)
            } ?? false
            if !tailIsDurablyAnchored, let locallyOwnedTurn {
                // The tail is Conduit's own optimistic turn: classify by
                // user-turn boundaries against the pre-submit anchor.
                return locallyOwnedTurnFreshnessVerdict(
                    transcript,
                    owned: locallyOwnedTurn,
                    localMessageIDs: localMessageIDs,
                    livenessIsRunning: livenessIsRunning
                )
            }
            // Anchored path: the transcript must END on a row the frontier
            // vouches for. Trailing optimistic/streaming rows WITHOUT
            // locally-owned turn evidence keep the strict anchor requirement
            // — the bounded resume refresh converges this exact shape.
            guard tailIsDurablyAnchored,
                  let anchorIndex = transcript.messages.lastIndex(where: {
                      localFrontier.contains($0.id)
                  }) else {
                // No local frontier, unanchored foreign tail, or the frontier
                // rotated out of the newest page (an accepted turn can push
                // hundreds of rows past the window): no ordering proof — same
                // invariant as the ambiguous-delivery verifier.
                return .inconclusive
            }
            let newRows = persistedRowsAfter(
                anchorIndex,
                in: transcript,
                heldIDs: localMessageIDs
            )
            if newRows.isEmpty {
                return .unchanged(
                    observedOrderingFrontier: Self.orderingFrontier(from: transcript),
                    observedNewUserBoundaries: nil
                )
            }
            return .advanced(transcript: transcript, newRows: newRows)
        }
    }

    /// Classifies the bounded persisted tail behind a locally-owned
    /// optimistic turn by USER-turn boundaries. Hermes persists the user row
    /// at turn start (crash resilience), so the normal in-flight shape is:
    /// the pre-submit durable anchor, the durable twin of our optimistic
    /// user row, then any Turn A output/tool rows. The normalizer maps raw
    /// tool results to `.tool` and drops hidden scaffolding before this
    /// point, so `.user` rows in the page are real canonical prompts.
    ///
    /// Exactly ONE new user-turn boundary after the pre-submit anchor, and
    /// it must be the FIRST row after that anchor (a linear transcript's
    /// next row after the old frontier is the next turn's user prompt),
    /// while the runtime is still working/waiting → same locally-owned
    /// Turn A → observational continuation. A second user boundary — a
    /// later turn, or a persisted steer/follow-up inside the running turn —
    /// means the page cannot prove same-turn continuity → authoritative
    /// attach (the safe direction). The merge stays INELIGIBLE
    /// in every optimistic case — the twin would duplicate the optimistic
    /// bubble — so "unchanged" here means transcript untouched and the live
    /// projection stays authoritative.
    private func locallyOwnedTurnFreshnessVerdict(
        _ transcript: PersistedSessionTranscript,
        owned: LocallyOwnedTurnTailEvidence,
        localMessageIDs: Set<String>,
        livenessIsRunning: Bool
    ) -> ForegroundFreshnessVerdict {
        guard livenessIsRunning else {
            // An idle registry behind our optimistic tail cannot prove the
            // turn landed at all: the authoritative refresh converges it.
            return .inconclusive
        }
        let newRows: [ChatMessage]
        switch owned.baseline {
        case .unknown:
            // No usable ordering evidence was captured at submit time.
            return .inconclusive
        case .anchored(let anchorID):
            guard let anchorIndex = transcript.messages.lastIndex(where: {
                $0.id == anchorID
            }) else {
                // The anchor rotated out of the newest page (a long turn can
                // push hundreds of rows past the window): no boundary proof —
                // same invariant as the anchored path.
                return .inconclusive
            }
            newRows = persistedRowsAfter(
                anchorIndex,
                in: transcript,
                heldIDs: localMessageIDs
            )
        case .positivelyEmpty:
            // The whole persisted transcript follows the empty baseline, so
            // every page row is a candidate — but only when the page is
            // complete: older rotated-out rows could hide additional user
            // boundaries and would make the count understate.
            guard let page = transcript.page,
                  !page.mayHaveOlderRows(fetchedRowCount: page.rawReturned) else {
                return .inconclusive
            }
            newRows = persistedRowsAfter(
                nil,
                in: transcript,
                heldIDs: localMessageIDs
            )
        }
        if newRows.isEmpty {
            // Nothing of ours persisted yet — the earliest in-flight shape.
            return .unchanged(
                observedOrderingFrontier: Self.orderingFrontier(from: transcript),
                observedNewUserBoundaries: 0
            )
        }
        let newUserTurnBoundaries = newRows.filter { $0.role == .user }
        guard let firstRow = newRows.first, firstRow.role == .user,
              newUserTurnBoundaries.count == 1 else {
            return .inconclusive
        }
        // Exactly the expected twin of our optimistic Turn A user row (plus
        // any Turn A output/tool rows): our turn is still the only one. The
        // visible transcript stays untouched, but the ordering frontier may
        // advance through the newest observed durable row of this proven
        // Turn A region so the NEXT locally-owned turn anchors past it — and
        // this read positively observed the turn's persisted boundary, so a
        // later settle owes no ordering debt.
        return .unchanged(
            observedOrderingFrontier: Self.orderingFrontier(from: transcript),
            observedNewUserBoundaries: newUserTurnBoundaries.count
        )
    }

    /// Runs the bounded cross-surface freshness reconciliation for a
    /// foreground whose probe liveness could hide missed persisted activity
    /// (real background interval): exactly one TAIL-ONLY persisted read —
    /// never a full-transcript fallback — decides:
    ///
    /// - anchor overlap, nothing newer → observational liveness adoption,
    ///   transcript untouched, zero `session.resume`. With a locally-owned
    ///   optimistic tail, EXACTLY ONE new canonical user-turn boundary after
    ///   the pre-submit anchor (the durable twin Hermes persists at turn
    ///   start, plus any of our turn's output/tool rows) additionally proves
    ///   same-turn continuation — still zero `session.resume`;
    /// - anchor overlap, newer durable rows → the advancement is appended to
    ///   the local transcript (loaded-earlier prefix untouched, persisted
    ///   window re-anchored) and the liveness adopted — still zero
    ///   `session.resume`, because the persisted-history source supplied
    ///   everything a completed turn needs;
    /// - inconclusive (rotated anchor, no tail contract, foreign resolved id,
    ///   unanchored foreign tail, a SECOND user-turn boundary behind an
    ///   optimistic tail — a later turn exists) → the existing bounded resume
    ///   refresh, the authoritative fallback that re-anchors the whole
    ///   conversation (and, for a live runtime, returns the in-flight
    ///   projection);
    /// - structurally absent source → the same authoritative refresh, hinted
    ///   so it skips the doomed history request and resumes non-compact
    ///   exactly once;
    /// - transient read failure → the authoritative liveness adoption with
    ///   the transcript-freshness marker SET: freshness is unresolved, never
    ///   claimed current, and the next authoritative source re-confirms.
    /// `resumeFallbackAllowed`, when given, is asked before any fallback to
    /// a resume; a no settles the boundary instead and returns false (the
    /// open chat's read of another device's turn, ChatSync).
    @discardableResult
    func reconcileForegroundCrossSurfaceActivity(
        livenessIsRunning: Bool,
        requestedSessionID: String,
        probeRow: LiveSessionStatus,
        reconciliationToken token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?,
        resumeFallbackAllowed: (@MainActor () async -> Bool)? = nil
    ) async -> Bool {
        /// Whether a fallback resume may run; settles the boundary when not.
        func mayResume() async -> Bool {
            guard let resumeFallbackAllowed else { return true }
            if await resumeFallbackAllowed() { return true }
            settleForegroundBoundary(token, automaticWorkToken: automaticWorkToken)
            return false
        }
        let recoveryPurpose = foregroundRecoveryPurpose
        let bridge = dashboardTicketBridge
        let localFrontier = durablePersistedRowIDs
        let localMessageIDs = Set(messages.map { $0.id })
        let lastLocalMessageID = messages.last?.id
        let locallyOwnedTurn = locallyOwnedFreshnessTurnEvidence(
            forRequested: requestedSessionID
        )
        // A bot chat's persisted tail lives in the BOT's store; the scope
        // must follow the active conversation, not the dashboard default.
        let profile = persistedTailProfile(for: requestedSessionID)
        let outcome = await foregroundPersistedTailOutcome(
            sessionId: requestedSessionID,
            profile: profile,
            using: bridge
        )
        guard foregroundRefreshOwnsReconciliation(token),
              automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
            settleReconciliation(token)
            return true
        }
        // The composer stays enabled during the bounded read: a submit that
        // landed mid-read appends an optimistic row and would invert the
        // merge order. The transcript moved, so the append-only merge can no
        // longer be proven safe — the bounded resume refresh converges it.
        guard messages.last?.id == lastLocalMessageID,
              durablePersistedRowIDs == localFrontier else {
            lifecycleLog.notice(
                "Foreground freshness: session=\(requestedSessionID, privacy: .private(mask: .hash)) transcript moved during read → bounded resume refresh"
            )
            guard await mayResume() else { return false }
            await syncSession(
                purpose: recoveryPurpose,
                using: token,
                automaticWorkToken: automaticWorkToken
            )
            return true
        }
        switch foregroundFreshnessVerdict(
            outcome,
            localFrontier: localFrontier,
            localMessageIDs: localMessageIDs,
            lastLocalMessageID: lastLocalMessageID,
            requestedSessionID: requestedSessionID,
            runtimeSessionID: probeRow.runtimeSessionId,
            livenessIsRunning: livenessIsRunning,
            locallyOwnedTurn: locallyOwnedTurn
        ) {
        case let .advanced(transcript, newRows):
            if livenessIsRunning {
                // A running turn whose persisted history advanced beyond the
                // frontier cannot be proven same-turn, and the page cannot
                // supply its in-flight projection: the authoritative attach
                // (compact resume + reconcile) owns both the advancement and
                // the live projection.
                lifecycleLog.notice(
                    "Foreground freshness: probe=running session=\(requestedSessionID, privacy: .private(mask: .hash)) verdict=advanced rows=\(newRows.count, privacy: .public) → authoritative attach"
                )
                await syncSession(
                    purpose: recoveryPurpose,
                    using: token,
                    automaticWorkToken: automaticWorkToken
                )
                return true
            }
            lifecycleLog.notice(
                "Foreground freshness: probe=idle session=\(requestedSessionID, privacy: .private(mask: .hash)) verdict=advanced rows=\(newRows.count, privacy: .public) → merge persisted advancement"
            )
            applyPersistedForegroundAdvancement(
                requestedSessionID: requestedSessionID,
                transcript: transcript,
                newRows: newRows,
                runtimeSessionID: probeRow.runtimeSessionId,
                profile: profile
            )
            adoptForegroundAuthoritativeIdle(
                token: token,
                automaticWorkToken: automaticWorkToken
            )
        case let .unchanged(observedOrderingFrontier, observedNewUserBoundaries):
            lifecycleLog.notice(
                "Foreground freshness: probe=\(livenessIsRunning ? "running" : "idle", privacy: .public) session=\(requestedSessionID, privacy: .private(mask: .hash)) verdict=unchanged → observational adopt"
            )
            // The bounded read proved the durable conversation current (an
            // optimistic locally-owned tail is live-turn content, not
            // divergence). The visible transcript stays untouched, but the
            // read's validated ordering evidence advances the persisted
            // ordering frontier — pure metadata the NEXT locally-owned turn
            // anchors against.
            transcriptFreshnessIsStale = false
            // Re-anchor the ordering frontier on this read's own validated
            // observation (see PersistedOrderingFrontier for the
            // non-monotonicity rationale).
            persistedOrderingFrontier = observedOrderingFrontier
            if let observedNewUserBoundaries, observedNewUserBoundaries > 0 {
                // The read positively observed the locally-owned turn's
                // persisted boundary. If the turn is still running this does
                // NOT prove its final durable tail.
                locallyOwnedInFlightTurn?.persistedBoundaryObserved = true
            }
            adoptForegroundLiveness(
                livenessIsRunning,
                token: token,
                automaticWorkToken: automaticWorkToken
            )
        case .unresolvedTransient:
            lifecycleLog.notice(
                "Foreground freshness: probe=\(livenessIsRunning ? "running" : "idle", privacy: .public) session=\(requestedSessionID, privacy: .private(mask: .hash)) verdict=transient-failure → liveness adopt, freshness unresolved"
            )
            adoptForegroundLiveness(
                livenessIsRunning,
                token: token,
                automaticWorkToken: automaticWorkToken
            )
            // The bounded read failed transiently: transcript freshness is
            // UNRESOLVED — tracked separately from turn-state staleness
            // (liveness was just adopted authoritatively above). The
            // pre-send freshness retry and the next background's freshness
            // check re-confirm; a registry probe alone can never clear this.
            transcriptFreshnessIsStale = true
        case .sourceUnavailable:
            // Positively structural: the authoritative refresh re-anchors
            // the conversation, hinted to skip the history request that just
            // proved absent and resume non-compact exactly once.
            lifecycleLog.notice(
                "Foreground freshness: probe=\(livenessIsRunning ? "running" : "idle", privacy: .public) session=\(requestedSessionID, privacy: .private(mask: .hash)) verdict=source-unavailable → single authoritative resume"
            )
            guard await mayResume() else { return false }
            await syncSession(
                purpose: recoveryPurpose,
                using: token,
                automaticWorkToken: automaticWorkToken,
                historySourceUnavailable: true
            )
        case .inconclusive:
            lifecycleLog.notice(
                "Foreground freshness: probe=\(livenessIsRunning ? "running" : "idle", privacy: .public) session=\(requestedSessionID, privacy: .private(mask: .hash)) verdict=inconclusive → bounded resume refresh"
            )
            guard await mayResume() else { return false }
            await syncSession(
                purpose: recoveryPurpose,
                using: token,
                automaticWorkToken: automaticWorkToken
            )
        }
        return true
    }

    /// Ordering evidence for the locally-owned optimistic tail, captured by
    /// `locallyOwnedFreshnessTurnEvidence` at freshness time. Non-nil means
    /// the trailing unpersisted rows belong to this surface's in-flight
    /// turn; `baseline` is the submit-time ordering anchor the bounded tail
    /// is classified against.
    struct LocallyOwnedTurnTailEvidence {
        let baseline: PersistedOrderingBaseline
    }

    /// Non-nil when the transcript's trailing unpersisted rows belong to a
    /// turn THIS surface submitted and the local turn state still agrees the
    /// turn is in flight: the recorded optimistic user row is still present
    /// and unpersisted, and every row after it is unpersisted too.
    ///
    /// The residual window this cannot close: a turn this surface submitted
    /// that never persisted anything server-side (accepted, then lost) is
    /// indistinguishable from our own twin when exactly ONE `.user` row
    /// follows the anchor — the app stays observational until the next
    /// authoritative sync converges and drops the phantom row. Turn A's
    /// completion, a second user turn, idle liveness, and buffered settle
    /// edges all still force the authoritative path.
    private func locallyOwnedFreshnessTurnEvidence(
        forRequested sessionID: String
    ) -> LocallyOwnedTurnTailEvidence? {
        guard turnState.isRunning,
              let marker = locallyOwnedInFlightTurn,
              marker.sessionIDs.contains(sessionID),
              !durablePersistedRowIDs.contains(marker.optimisticUserRowID),
              let userIndex = messages.lastIndex(where: {
                  $0.id == marker.optimisticUserRowID
              }),
              messages[userIndex...].allSatisfy({
                  !durablePersistedRowIDs.contains($0.id)
              }) else {
            return nil
        }
        return LocallyOwnedTurnTailEvidence(
            baseline: marker.preSubmitOrderingBaseline
        )
    }

    /// Chronological page rows strictly after `anchorIndex` whose ids the
    /// local transcript does not already hold — rows streamed in live under
    /// any identity dedupe by id, in both verdict paths.
    func persistedRowsAfter(
        _ anchorIndex: Int?,
        in transcript: PersistedSessionTranscript,
        heldIDs: Set<String>
    ) -> [ChatMessage] {
        var knownIDs = heldIDs
        var newRows: [ChatMessage] = []
        let firstCandidateIndex = anchorIndex.map { $0 + 1 }
            ?? transcript.messages.startIndex
        for row in transcript.messages[firstCandidateIndex...]
        where knownIDs.insert(row.id).inserted {
            newRows.append(row)
        }
        return newRows
    }

    /// Adopts the freshly-decided foreground liveness after a freshness
    /// verdict: the merged transcript / unchanged snapshot is the OLDER
    /// observation, so buffered events replay after it (newer edges win) and
    /// the boundary settles last.
    private func adoptForegroundLiveness(
        _ running: Bool,
        token: UUID,
        automaticWorkToken: ChatResumeAutomaticWorkToken?
    ) {
        if running {
            adoptForegroundRunningState(
                reconciliationToken: token,
                automaticWorkToken: automaticWorkToken
            )
        } else {
            adoptForegroundAuthoritativeIdle(
                token: token,
                automaticWorkToken: automaticWorkToken
            )
        }
    }

    /// Appends cross-surface persisted advancement to the live transcript.
    /// Append-only by construction: the verdict selected rows strictly after
    /// the newest local durable anchor, deduplicated against every held row
    /// id, so the loaded-earlier prefix and any durably-anchored tail remain
    /// exactly as they were. The persisted window is re-anchored to the
    /// fetched page (same coverage-reset semantics as a reconcile refresh:
    /// subsequent backfills retrace deduped page-sized increments), keeping
    /// "Load earlier messages" coherent without a resume.
    func applyPersistedForegroundAdvancement(
        requestedSessionID: String,
        transcript: PersistedSessionTranscript,
        newRows: [ChatMessage],
        runtimeSessionID: String,
        profile: String
    ) {
        var knownIDs = Set(messages.map { $0.id })
        var merged = messages
        merged.reserveCapacity(merged.count + newRows.count)
        for row in newRows where knownIDs.insert(row.id).inserted {
            // The persisted twin of a steer Conduit already confirmed
            // locally takes the local row's place instead of repeating it.
            if row.isSteer,
               let localIndex = merged.firstIndex(where: { Self.isLocalSteerTwin($0, of: row) }) {
                merged[localIndex] = row
                continue
            }
            merged.append(row)
        }
        messages = merged
        // The bounded read just proved exactly which persisted rows were
        // missing and merged them: transcript freshness is restored, the
        // accepted page re-establishes the persisted ordering frontier, and
        // that page covers any outstanding local ordering debt.
        transcriptFreshnessIsStale = false
        persistedOrderingFrontier = Self.orderingFrontier(from: transcript)
        pendingLocalOrderingDebt = nil
        // The merge just made the newest persisted page local: adopt its
        // durable ids as the frontier (same per-hydration replacement
        // semantics as reconcile) so the next freshness check anchors
        // against the rows this merge added.
        durablePersistedRowIDs = transcript.durableRowIDs
        let priorOwned: PersistedTranscriptWindowState? = priorWindowOwnsThisConversation(
            persistedTranscriptWindow,
            requestedSessionId: requestedSessionID,
            resolvedSessionId: transcript.resolvedSessionId,
            runtimeSessionId: runtimeSessionID,
            profile: profile
        ) ? persistedTranscriptWindow : nil
        if let page = transcript.page, page.honorsTailContract {
            persistedTranscriptWindow = PersistedTranscriptWindowState(
                requestedSessionID: requestedSessionID,
                profile: profile,
                pageSize: PersistedTranscriptPagination.pageSize,
                resolvedSessionID: transcript.resolvedSessionId,
                runtimeSessionID: runtimeSessionID,
                nextOffset: page.rawReturned,
                canLoadEarlier: page.mayHaveOlderRows(fetchedRowCount: page.rawReturned),
                hasBackfilledPrefix: priorOwned?.hasBackfilledPrefix ?? false,
                loadedPageStarts: priorOwned?.pageStartsCarried(into: page.rawReturned) ?? []
            )
        }
    }

    func verifyChatResumeTransportHealth(_ client: HermesClient) async throws {
        if let verifyTransportHealth = chatResumeLifecycleOperations.verifyTransportHealth {
            try await verifyTransportHealth(client)
        } else {
            let startedAt = Date()
            do {
                try await client.healthCheck()
                noteConnectionStep("Connection check", since: startedAt)
            } catch {
                noteConnectionStep("Connection check", since: startedAt, error: error)
                throw error
            }
        }
    }

    /// Continuation guard for the foreground refresh: the refresh decision may
    /// only mutate state while its reconciliation token still owns the
    /// boundary (a newer transition rotates the token and cancels the task).
    func foregroundRefreshOwnsReconciliation(_ token: UUID) -> Bool {
        token == reconciliationToken && !Task.isCancelled
    }
}

extension AppState {
    // MARK: - Checking the transcript is fresh before a send

    /// Outcome of the pre-send transcript-freshness gate.
    enum TranscriptFreshnessGateOutcome {
        /// Ordering is proven current (or the concern no longer applies):
        /// proceed with the ordinary new-turn submission.
        case proceed
        /// The recovery revealed a live turn: route the text through the
        /// configured busy submission instead of a new-turn prompt.
        case routeToBusySubmission
        /// Freshness could not be restored; do not append into an unresolved
        /// ordering. Associated value is the user-facing message.
        case blocked(String)
    }

    /// Exactly one bounded tail-only persisted read before an ordinary
    /// NEW-TURN submit while `transcriptFreshnessIsStale` (a foreground
    /// freshness read failed transiently on a real background return) OR
    /// local ordering debt is outstanding (foreground-only settled turns
    /// whose persisted boundaries no read has observed). Debt reconciliation
    /// runs first; both concerns consume this one read. Never polls: a
    /// transient failure blocks the send rather than silently appending
    /// into an unresolved ordering (for debt, on the FIRST failure — debt is
    /// a positive claim about persisted content, not a suspicion worth a
    /// second chance), and structural absence takes the existing
    /// authoritative recovery (a non-compact resume needs no history
    /// endpoint) before the send proceeds.
    func confirmTranscriptFreshnessBeforeSend(
        using submissionContext: ComposerSubmissionContext
    ) async -> TranscriptFreshnessGateOutcome {
        guard client != nil, let sessionId = activeSessionId else {
            // Nothing to verify against; the ordinary send path owns the
            // no-client outcome.
            return .proceed
        }
        // A bot chat's persisted tail lives in the BOT's store (see the
        // cross-surface freshness path); scope to the active conversation.
        let profile = persistedTailProfile(for: sessionId)
        let bridge = dashboardTicketBridge
        let localFrontier = durablePersistedRowIDs
        let localMessageIDs = Set(messages.map { $0.id })
        let lastLocalMessageID = messages.last?.id
        lifecycleLog.notice(
            "submitComposer: pre-send persisted evidence unresolved (freshness or local ordering debt); one bounded retry session=\(sessionId, privacy: .private(mask: .hash))"
        )
        let outcome = await foregroundPersistedTailOutcome(
            sessionId: sessionId,
            profile: profile,
            using: bridge
        )
        // Ownership re-check after the await, SPLIT from the turn state. A
        // session/profile/viewport handoff SUPERSEDES this gate: the old
        // operation must mutate nothing in the newly selected conversation,
        // and the ordinary flow's own ownership guards own that outcome. But
        // a turn-state change on the SAME conversation is this submission's
        // business: a busy edge that raced the read must route through the
        // configured busy submission — never fall through to an ordinary
        // new-turn prompt.submit into an already-running turn.
        guard isCurrentComposerSubmission(submissionContext),
              activeSessionId == sessionId else {
            return .proceed
        }
        if turnState.isRunning {
            lifecycleLog.notice(
                "submitComposer: conversation turned busy during pre-send freshness read → busy submission session=\(sessionId, privacy: .private(mask: .hash))"
            )
            return .routeToBusySubmission
        }
        guard turnState == .idle else {
            // A recovery boundary (.synchronizing/.reconnecting) or an
            // unsupported gateway is in flight: neither proves the
            // transcript ordering, and neither may blind-send.
            lifecycleLog.notice(
                "submitComposer: pre-send freshness read superseded by \(self.turnStateLogValue, privacy: .public); blocking send session=\(sessionId, privacy: .private(mask: .hash))"
            )
            return .blocked(AppLocalization.string("Unable to refresh this conversation. Try again."))
        }
        switch outcome {
        case .failed:
            // Second transient failure: no loop, no escalation, no silently
            // claimed freshness — block the new-turn prompt instead.
            return .blocked(AppLocalization.string("Unable to refresh this conversation. Try again."))
        case .unavailable:
            // Positively structural: the authoritative reconcile is the
            // recovery path that still converges the transcript (a
            // non-compact resume needs no history endpoint), hinted to skip
            // the doomed history request.
            await syncSession(
                purpose: .preserveCurrent,
                using: nil,
                automaticWorkToken: nil,
                historySourceUnavailable: true
            )
            return postRecoveryFreshnessGateOutcome(
                submissionContext: submissionContext,
                sessionID: sessionId
            )
        case .unsupportedTailContract:
            // A shapeless page: no comparable evidence either way — the
            // authoritative reconcile re-classifies the source itself.
            await syncSession(
                purpose: .preserveCurrent,
                using: nil,
                automaticWorkToken: nil
            )
            return postRecoveryFreshnessGateOutcome(
                submissionContext: submissionContext,
                sessionID: sessionId
            )
        case .hydrated(let transcript):
            // The transcript moved under the gate (a stream edge landed):
            // the comparison evidence is stale — converge authoritatively.
            guard messages.last?.id == lastLocalMessageID,
                  durablePersistedRowIDs == localFrontier else {
                await syncSession(
                    purpose: .preserveCurrent,
                    using: nil,
                    automaticWorkToken: nil
                )
                return postRecoveryFreshnessGateOutcome(
                    submissionContext: submissionContext,
                    sessionID: sessionId
                )
            }
            // Identity first: a page echoing a foreign conversation id is
            // never evidence — for the freshness verdict or debt
            // reconciliation alike. (Pages echoing no session id at all
            // match by construction.)
            guard transcriptMatchesSession(
                transcript,
                requestedSessionId: sessionId,
                resumedSessionId: canonicalSessionID(for: sessionId)
                    ?? persistedTranscriptWindow?.runtimeSessionID
                    ?? sessionId
            ) else {
                lifecycleLog.notice(
                    "submitComposer: pre-send read answered for a different conversation → authoritative reconcile session=\(sessionId, privacy: .private(mask: .hash))"
                )
                await syncSession(
                    purpose: .preserveCurrent,
                    using: nil,
                    automaticWorkToken: nil
                )
                return postRecoveryFreshnessGateOutcome(
                    submissionContext: submissionContext,
                    sessionID: sessionId
                )
            }
            // Debt reconciliation FIRST: ordering metadata is counted
            // against the frontier the settled turns were recorded against,
            // and both concerns consume this one read.
            if let debt = pendingLocalOrderingDebt {
                switch localOrderingDebtOutcome(transcript, debt: debt) {
                case .satisfied:
                    pendingLocalOrderingDebt = nil
                    persistedOrderingFrontier = Self.orderingFrontier(from: transcript)
                case .exceeded, .notCaughtUp, .unprovable:
                    lifecycleLog.notice(
                        "submitComposer: pre-send ordering debt not reconcilable → authoritative reconcile session=\(sessionId, privacy: .private(mask: .hash))"
                    )
                    await syncSession(
                        purpose: .preserveCurrent,
                        using: nil,
                        automaticWorkToken: nil
                    )
                    return postRecoveryFreshnessGateOutcome(
                        submissionContext: submissionContext,
                        sessionID: sessionId
                    )
                }
            }
            if transcriptFreshnessIsStale {
                let verdict = foregroundFreshnessVerdict(
                    outcome,
                    localFrontier: localFrontier,
                    localMessageIDs: localMessageIDs,
                    lastLocalMessageID: lastLocalMessageID,
                    requestedSessionID: sessionId,
                    runtimeSessionID: canonicalSessionID(for: sessionId)
                        ?? persistedTranscriptWindow?.runtimeSessionID
                        ?? sessionId,
                    livenessIsRunning: false,
                    locallyOwnedTurn: nil
                )
                switch verdict {
                case let .unchanged(observedOrderingFrontier, _):
                    transcriptFreshnessIsStale = false
                    // Re-anchor the ordering frontier on the read's validated
                    // observation (non-monotonic by design).
                    persistedOrderingFrontier = observedOrderingFrontier
                    return .proceed
                case let .advanced(transcript, newRows):
                    applyPersistedForegroundAdvancement(
                        requestedSessionID: sessionId,
                        transcript: transcript,
                        newRows: newRows,
                        runtimeSessionID: persistedTranscriptWindow?.runtimeSessionID
                            ?? transcript.resolvedSessionId
                            ?? sessionId,
                        profile: profile
                    )
                    return .proceed
                case .inconclusive:
                    await syncSession(
                        purpose: .preserveCurrent,
                        using: nil,
                        automaticWorkToken: nil
                    )
                    return postRecoveryFreshnessGateOutcome(
                        submissionContext: submissionContext,
                        sessionID: sessionId
                    )
                case .sourceUnavailable, .unresolvedTransient:
                    // Unreachable for a `.hydrated` outcome (both are produced
                    // only from the fetch-level cases above); kept as defensive
                    // exhaustiveness. Blocking is the safe direction regardless.
                    return .blocked(AppLocalization.string("Unable to refresh this conversation. Try again."))
                }
            }
            return .proceed
        }
    }

    /// Outcome of reconciling outstanding local ordering debt against one
    /// validated bounded page.
    private enum LocalOrderingDebtOutcome {
        /// Exactly the expected number of canonical user-turn boundaries
        /// follow the frontier: the debt is satisfied and the frontier may
        /// re-anchor on this page.
        case satisfied
        /// More user boundaries than outstanding locally-owned turns:
        /// foreign activity exists — authoritative reconcile before any
        /// local send.
        case exceeded
        /// Fewer boundaries than expected (or an anomalous leading row):
        /// persisted state has not caught up — conservative recovery.
        case notCaughtUp
        /// No ordering anchor to count against (unknown frontier, or it
        /// rotated out of the page).
        case unprovable
        // notCaughtUp and unprovable deliberately share the conservative
        // recovery routing at the caller; the split exists for field triage
        // in the logs only.
    }

    /// Counts canonical user-turn boundaries after the ordering frontier and
    /// compares them with the outstanding locally-owned settled-turn count.
    /// Never advances anything: the caller owns frontier/debt mutation.
    private func localOrderingDebtOutcome(
        _ transcript: PersistedSessionTranscript,
        debt: PendingLocalOrderingDebt
    ) -> LocalOrderingDebtOutcome {
        let heldIDs = Set(messages.map { $0.id })
        switch persistedOrderingFrontier.baseline {
        case .unknown:
            return .unprovable
        case .positivelyEmpty:
            // The whole transcript follows the empty baseline; the page must
            // be complete or the boundary count understates.
            guard let page = transcript.page,
                  !page.mayHaveOlderRows(fetchedRowCount: page.rawReturned) else {
                return .unprovable
            }
            return Self.classifyDebtCandidates(
                persistedRowsAfter(nil, in: transcript, heldIDs: heldIDs),
                expected: debt.expectedUserTurnCount,
                allowTrailingRowsWithoutNewUserBoundary: debt.allowTrailingRowsWithoutNewUserBoundary
            )
        case .anchored(let anchorID):
            guard let anchorIndex = transcript.messages.lastIndex(where: {
                $0.id == anchorID
            }) else {
                return .unprovable
            }
            return Self.classifyDebtCandidates(
                persistedRowsAfter(anchorIndex, in: transcript, heldIDs: heldIDs),
                expected: debt.expectedUserTurnCount,
                allowTrailingRowsWithoutNewUserBoundary: debt.allowTrailingRowsWithoutNewUserBoundary
            )
        }
    }

    private static func classifyDebtCandidates(
        _ candidates: [ChatMessage],
        expected: Int,
        allowTrailingRowsWithoutNewUserBoundary: Bool = false
    ) -> LocalOrderingDebtOutcome {
        let boundaries = candidates.filter { $0.role == .user }
        if expected == 0, allowTrailingRowsWithoutNewUserBoundary {
            // Settled-tail debt: trailing assistant/tool rows (or no rows at
            // all) are exactly what the bounded read is meant to absorb. A
            // canonical user boundary cannot belong to that already-settled
            // turn and therefore proves foreign/new activity.
            return boundaries.isEmpty ? .satisfied : .exceeded
        }
        if allowTrailingRowsWithoutNewUserBoundary {
            if boundaries.count == expected { return .satisfied }
            return boundaries.count > expected ? .exceeded : .notCaughtUp
        }
        guard let firstRow = candidates.first, firstRow.role == .user else {
            // Nothing after the frontier yet, or an assistant/tool row
            // precedes the first boundary: the persisted state has not
            // caught up (or ordering is anomalous) — conservative.
            return boundaries.isEmpty ? .notCaughtUp : .unprovable
        }
        if boundaries.count == expected { return .satisfied }
        return boundaries.count > expected ? .exceeded : .notCaughtUp
    }

    /// Shared post-recovery checks for the freshness gate: a converged
    /// authoritative reconcile cleared `transcriptFreshnessIsStale` (via
    /// `applyChatResume`); anything else means recovery did not converge and
    /// the send must not proceed into an unresolved ordering.
    private func postRecoveryFreshnessGateOutcome(
        submissionContext: ComposerSubmissionContext,
        sessionID: String
    ) -> TranscriptFreshnessGateOutcome {
        guard isCurrentComposerSubmission(submissionContext),
              activeSessionId == sessionID else {
            return .proceed
        }
        if turnState.isRunning {
            return .routeToBusySubmission
        }
        if transcriptFreshnessIsStale || pendingLocalOrderingDebt != nil {
            // Either recovery was superseded (a newer boundary owns the
            // conversation) or it genuinely failed to converge; both must
            // not send into an unresolved ordering — freshness and local
            // ordering debt alike.
            lifecycleLog.notice(
                "submitComposer: pre-send freshness recovery did not converge; blocking send session=\(sessionID, privacy: .private(mask: .hash))"
            )
            return .blocked(AppLocalization.string("Unable to refresh this conversation. Try again."))
        }
        return .proceed
    }
}
