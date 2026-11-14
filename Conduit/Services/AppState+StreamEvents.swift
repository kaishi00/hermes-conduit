//
//  AppState+StreamEvents.swift
//  Conduit
//
//  Applying a turn's stream events: status updates, server compaction
//  claims, buffering while reconciling, and each event's effect on the
//  open chat. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Stream event handling

    /// `turnGeneration`: the execution generation the event names, when
    /// the server numbers turns.
    func handleStreamEvent(_ event: StreamEvent, turnGeneration: Int? = nil) {
        // A step summary's answer is never a /btw reply, in any chat.
        if takeStepSummaryAnswer(event) { return }
        // Voice background jobs are not the active conversation, so they
        // observe every event before the active-session filter below.
        voiceBackgroundJobSupervisor.observe(event)
        // A Local Live call's reply streams back to the speech server.
        if isLocalLiveActive { localLiveTurns.observe(event) }
        notePresentedCardEvent(event)
        if case .sessionTitle(let runtimeSessionId, let storedSessionId, let title) = event {
            let taskKey = Self.secondaryTitleRecoveryTaskKey(
                profile: activeProfile,
                sessionID: runtimeSessionId
            )
            sessionTitleRecoveryTracker.cancel(taskKey)
            applyRecoveredSessionTitle(
                title,
                sessionIDs: [runtimeSessionId, storedSessionId]
            )
            return
        }
        // Compaction lifecycle edges are session-scoped bookkeeping, not
        // transcript projection: they must run for background conversations
        // too (clearing state, driving the active conversation's refresh)
        // and are never buffered into a reconcile.
        if case .statusUpdate(let sessionId, let kind, let text) = event {
            applyStatusUpdate(sessionId: sessionId, kind: kind, text: text)
            return
        }
        // Signals that another client or process changed a chat: they ask
        // for reads (ChatSync.swift), and never touch the transcript.
        switch event {
        case .sessionsChanged:
            noteCatalogChanged()
            return
        case .userMessage(let sessionId, let rowId, let text, _):
            noteUserMessageElsewhere(sessionId: sessionId, rowId: rowId, text: text)
            return
        case .sessionControl(let sessionId, let snapshot):
            applySessionControl(snapshot, for: sessionId)
            return
        default:
            break
        }
        releaseServerCompactionClaimOnAgentOutput(event)
        if bufferIfReconciling(event, turnGeneration: turnGeneration) { return }
        applyNumberedStreamEvent(event, turnGeneration: turnGeneration)
    }

    /// Applies an event with the turn it named, live or replayed after a
    /// resume, so Voice tells the turns apart the same way (`takeVoiceEventAfterCancel`).
    func applyNumberedStreamEvent(
        _ event: StreamEvent,
        turnGeneration: Int?,
        authoritativeYolo: Bool? = nil,
        authoritativeApprovalsMode: String? = nil
    ) {
        handledStreamEventGeneration = turnGeneration
        defer { handledStreamEventGeneration = nil }
        applyStreamEvent(
            event,
            authoritativeYolo: authoritativeYolo,
            authoritativeApprovalsMode: authoritativeApprovalsMode
        )
    }

    /// Gateway compression lifecycle edges (`status.update`):
    /// - `compacting` — server-side compaction active for that conversation.
    /// - `compacted` — terminal edge: the persisted history was rewritten.
    /// Unrelated kinds are ignored; they never masquerade as compaction.
    private func applyStatusUpdate(sessionId: String, kind: StatusUpdateKind, text: String?) {
        // `text` is display-only upstream; Conduit's compression affordance
        // is driven by the kind, not by gateway copy.
        switch kind {
        case .compacting:
            // Upstream re-tags every `lifecycle` line mentioning compression
            // as `compacting`, including one-shot diagnostics (compression
            // feasibility notices, "Session compressed N times") replayed at
            // the start of a turn. Those are warnings, not a running
            // compaction, and no `compacted` edge ever follows them.
            if Self.isCompressionDiagnosticStatus(text) { return }
            establishServerCompactionClaim(
                sessionId: sessionId,
                generation: terminalServerCompactionGeneration(for: sessionId)
            )
        case .compacted:
            // Equivalence-aware: a terminal edge addressed to any runtime
            // alias of the conversation clears its server-side claim.
            clearServerCompactionClaim(sessionId: sessionId)
            applyCompactionCompleted(sessionId: sessionId)
        case .other:
            break
        }
    }

    /// Upstream one-shot compression diagnostics are warnings (`⚠`, possibly
    /// after the agent's log prefix, e.g. "Session compressed N times") or
    /// info notices (`ℹ`, the Codex auto-raise notice). Real compaction
    /// progress lines lead with `🗜️`, `📦` or `💤` and never carry either.
    static func isCompressionDiagnosticStatus(_ text: String?) -> Bool {
        guard let body = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        // Compare scalars, not Characters: "⚠️" (with VS16) is a different
        // grapheme from a bare "⚠", so String.contains would miss it.
        return body.unicodeScalars.contains("\u{26A0}") || body.unicodeScalars.first == "\u{2139}"
    }

    /// Compaction runs synchronously inside the agent loop, and a manual
    /// compression still running on the host holds the session's
    /// compression lock, so the agent producing output for a conversation
    /// proves its compaction (if any) is over. A `compacting` edge that never
    /// gets its `compacted` partner (a misclassified status line, a skipped
    /// idle pass) must not keep "Compressing…" up while the reply streams.
    private func releaseServerCompactionClaimOnAgentOutput(_ event: StreamEvent) {
        let sessionId: String
        switch event {
        case .messageStart(let id):
            sessionId = id
        case .messageDelta(let id, _), .reasoningDelta(let id, _), .messageInterim(let id, _, _):
            sessionId = id
        case .messageComplete(let id, _, _, _, _):
            sessionId = id
        case .toolStart(let id, _, _, _):
            sessionId = id
        default:
            return
        }
        guard !sessionId.isEmpty,
              serverCompactingSessionIDs.contains(where: { composerSessionIDsAreEquivalent($0, sessionId) })
        else { return }
        // Not terminal: the generation stays, so this is no compaction
        // completion signal for any pending-continuation bookkeeping.
        dropServerCompactionClaims(equivalentTo: sessionId)
    }

    /// Removes the live claim, its expiry tasks and its spinner entry for
    /// every runtime alias of `sessionId`.
    private func dropServerCompactionClaims(equivalentTo sessionId: String) {
        for (taskKey, task) in serverCompactionClaimExpiryTasks
        where composerSessionIDsAreEquivalent(taskKey, sessionId) {
            task.cancel()
            serverCompactionClaimExpiryTasks.removeValue(forKey: taskKey)
        }
        let cleared = serverCompactingSessionIDs.filter {
            composerSessionIDsAreEquivalent($0, sessionId)
        }
        if !cleared.isEmpty { serverCompactingSessionIDs.subtract(cleared) }
        serverCompactionClaims = serverCompactionClaims.filter {
            !composerSessionIDsAreEquivalent($0.key, sessionId)
        }
    }

    /// The storage key for a conversation's compaction generation: the
    /// positively confirmed durable identity when the index knows one, else
    /// the canonical catalog id. Keying by durable identity makes
    /// alias-addressed terminal edges and pending continuations share one
    /// counter across runtime rebinds.
    func serverCompactionGenerationKey(for sessionId: String) -> String {
        // A bot chat's runtime->durable mapping is indexed under the BOT
        // profile; ordinary sessions keep the dashboard lookup. Try the
        // conversation's own scope first, then the dashboard scope as a
        // fallback so a pre-existing mapping is never orphaned.
        let scopeProfile = persistedTailProfile(for: sessionId)
        if let durable = conversationIdentityIndex.durableID(
            forRuntime: sessionId,
            profile: scopeProfile
        ) {
            return durable
        }
        if let durable = conversationIdentityIndex.durableID(
            forRuntime: sessionId,
            profile: activeProfile
        ) {
            return durable
        }
        return canonicalSessionID(for: sessionId) ?? sessionId
    }

    /// The conversation's terminal-compaction generation: the value stored
    /// under its durable-generation key.
    func terminalServerCompactionGeneration(for sessionId: String) -> Int {
        serverCompactionTerminalGenerations[serverCompactionGenerationKey(for: sessionId)] ?? 0
    }

    /// A terminal compaction signal (the gateway's `compacted` edge, or an
    /// authoritative terminal `session.compress` result) ends any server-side
    /// claim for the conversation and bumps its terminal generation so a
    /// stale `pending` continuation cannot resurrect the claim.
    func clearServerCompactionClaim(sessionId: String) {
        let key = serverCompactionGenerationKey(for: sessionId)
        serverCompactionTerminalGenerations[key, default: 0] += 1
        // Every equivalent alias, not just the addressed id — a re-homed
        // runtime's expiry task is inert after this.
        dropServerCompactionClaims(equivalentTo: sessionId)
    }

    /// Establishes (or refreshes) the server-side claim for `sessionId`.
    /// Callers decide freshness: a `pending` continuation only reaches here
    /// when no terminal edge landed during its RPC await. `lifetime` bounds
    /// the claim (see `expireServerCompactionClaim`); production always uses
    /// the compression budget, tests shrink it to observe the expiry.
    func establishServerCompactionClaim(
        sessionId: String,
        generation: Int,
        lifetime: TimeInterval = HermesClient.sessionCompressTimeout
    ) {
        if !serverCompactingSessionIDs.contains(where: {
            composerSessionIDsAreEquivalent($0, sessionId)
        }) {
            serverCompactingSessionIDs.insert(sessionId)
        }
        serverCompactionClaims[sessionId] = ServerCompactionClaim(
            generation: generation,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        // Replace any prior expiry task for this conversation so repeated
        // compactions never accumulate sleeping tasks.
        serverCompactionClaimExpiryTasks[sessionId]?.cancel()
        let expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard let self, !Task.isCancelled else { return }
            self.expireServerCompactionClaim(sessionId: sessionId, generation: generation)
        }
        serverCompactionClaimExpiryTasks[sessionId] = expiryTask
    }

    /// Bounded expiry for a lost terminal edge: a claim that reaches the end
    /// of one full compression budget without a `compacted` edge (or a newer
    /// terminal result) is dropped — the gateway either lost the edge or the
    /// session, and neither may keep "Compressing…" alive for the whole
    /// connection. Session-scoped: only the claim whose generation still
    /// matches is removed, so unrelated conversations are never touched, and
    /// genuinely active local RPC claims (`compressingSessionIDs`) are never
    /// affected — they are bounded by their own request timeout.
    private func expireServerCompactionClaim(sessionId: String, generation: Int) {
        guard let claim = serverCompactionClaims[sessionId],
              claim.generation == generation,
              claim.expiresAt <= Date() else { return }
        serverCompactionClaims.removeValue(forKey: sessionId)
        serverCompactionClaimExpiryTasks.removeValue(forKey: sessionId)
        // Keep the spinner only while a newer equivalent claim (established
        // under another runtime alias) is still live.
        let equivalentStillClaimed = serverCompactionClaims.contains {
            composerSessionIDsAreEquivalent($0.key, sessionId)
        }
        if !equivalentStillClaimed {
            let stale = serverCompactingSessionIDs.filter {
                composerSessionIDsAreEquivalent($0, sessionId)
            }
            serverCompactingSessionIDs.subtract(stale)
        }
    }

    /// The `compacted` edge means the gateway just rewrote that
    /// conversation's persisted history — the same server-side rewrite PR
    /// #168's adoption path guards against, minus the local RPC. Upstream
    /// Desktop drives a transcript refresh here because a manual `/compress`
    /// may have returned `pending`: with no normal turn-end event, nothing
    /// else would surface the summarized transcript.
    private func applyCompactionCompleted(sessionId: String) {
        // Only the affected conversation's invariants die with the rewrite.
        // A background conversation's next open/resume hydrates
        // authoritatively.
        guard composerSessionIDsAreEquivalent(sessionId, activeSessionId) else { return }
        invalidatePersistedHistoryInvariants()
        // A live turn owns the transcript: never replace it underneath the
        // turn. Freshness-stale routes the post-turn authoritative path here.
        if turnState == .running || shownChat.locallyOwnedInFlightTurn != nil {
            transcriptFreshnessIsStale = true
            // Fence: a reconcile that fetched pre-compaction rows must not
            // commit them underneath the live turn after this rewrite.
            invalidateReconciliation()
            return
        }
        // Idle: drive the authoritative transcript reconciliation now — the
        // user sees the compressed transcript without leaving the session.
        Task { [weak self] in
            await self?.syncSession()
        }
    }

    /// A resume that fails drops what it buffered, and streamed text comes
    /// back with the next resume. A decision prompt does not: Hermes
    /// announces an approval, clarify or input request once and then waits,
    /// so dropping it leaves the chat without the card Hermes is waiting
    /// on. Replay those (and their withdrawals, in order) while the
    /// reconciliation's accepted ids still route them to this chat.
    func replayBufferedDecisionPrompts(for token: UUID) {
        guard let reconciliation, reconciliation.token == token else { return }
        for event in reconciliation.bufferedEvents {
            switch event {
            case .approval, .approvalWithdrawn, .clarify, .clarifyExpire,
                    .inputPrompt, .inputPromptExpire, .connection:
                applyStreamEvent(event)
            default:
                continue
            }
        }
    }

    private func bufferIfReconciling(_ event: StreamEvent, turnGeneration: Int?) -> Bool {
        guard var reconciliation else { return false }
        guard reconciliation.accepts(sessionID(for: event)) else { return false }
        if case .sideAgentComplete = event {
            shownChat.heldSideAgentCompletions.append(event)
            return true
        }
        if reconciliation.bufferedGenerations.count != reconciliation.bufferedEvents.count {
            reconciliation.bufferedGenerations = Array(repeating: nil, count: reconciliation.bufferedEvents.count)
        }
        reconciliation.bufferedEvents.append(event)
        reconciliation.bufferedGenerations.append(turnGeneration)
        self.reconciliation = reconciliation
        return true
    }

    func sessionID(for event: StreamEvent) -> String {
        switch event {
        case .messageStart(let sessionId), .messageDelta(let sessionId, _),
                .reasoningDelta(let sessionId, _),
                .messageComplete(let sessionId, _, _, _, _), .messageInterim(let sessionId, _, _),
                .messageError(let sessionId, _),
                .messageReaction(let sessionId, _, _, _),
                .userMessage(let sessionId, _, _, _),
                .messageInterrupted(let sessionId), .sessionBusy(let sessionId, _),
                .sessionInfo(let sessionId, _), .sessionTitle(let sessionId, _, _),
                .toolStart(let sessionId, _, _, _),
                .toolComplete(let sessionId, _, _, _), .reviewSummary(let sessionId, _), .clarify(let sessionId, _), .clarifyExpire(let sessionId, _, _),
                .approval(let sessionId, _), .approvalWithdrawn(let sessionId, _, _),
                .inputPrompt(let sessionId, _), .inputPromptExpire(let sessionId, _, _),
                .connection(let sessionId, _),
                .contextUpdate(let sessionId, _, _, _), .cwdUpdate(let sessionId, _),
                .modelUpdate(let sessionId, _, _), .agentCount(let sessionId, _),
                .delegateAgent(let sessionId, _), .statusUpdate(let sessionId, _, _),
                .sideAgentComplete(let sessionId, _, _, _, _),
                .sessionControl(let sessionId, _):
            // `.sessionTitle` and `.statusUpdate` never reach
            // bufferIfReconciling (handleStreamEvent returns early for them).
            return sessionId
        case .sessionsChanged, .unparsed:
            return ""
        }
    }

    func eventBelongsToActiveSession(_ sessionId: String) -> Bool {
        guard let activeSessionId, !sessionId.isEmpty else { return false }
        if sessionId == activeSessionId { return true }

        // Every delta of a chat running in the background lands here: search
        // the two lists in place rather than copying them into one.
        func isActive(_ session: SessionSummary) -> Bool {
            session.id == activeSessionId || session.alternateIds.contains(activeSessionId)
        }
        if let activeSession = sessions.first(where: isActive) ?? cronSessions.first(where: isActive) {
            let activeIDs = Set([activeSession.id] + activeSession.alternateIds)
            if activeIDs.contains(sessionId) { return true }
        }

        // During resume, the gateway may switch between the requested and
        // runtime IDs before the catalog has caught up. Only accept those
        // aliases when the active ID is part of the same reconciliation set;
        // this prevents a prior session's buffered events from leaking into a
        // newly selected transcript.
        guard let reconciliation,
              reconciliation.acceptedSessionIDs.contains(activeSessionId) else {
            return false
        }
        return reconciliation.acceptedSessionIDs.contains(sessionId)
    }

    func applyStreamEvent(
        _ event: StreamEvent,
        authoritativeYolo: Bool? = nil,
        authoritativeApprovalsMode: String? = nil
    ) {
        let streamSessionId = sessionID(for: event)
        guard eventBelongsToActiveSession(streamSessionId) else { return }
        defer { schedulePresentationCacheFlush(for: streamSessionId) }
        noteOpenChatStreamEvent()
        LiveTurnActivities.shared?.observe(event, sessionID: streamSessionId)
        if let signal = ResponseHapticPolicy.signal(for: event) {
            applyResponseHapticSignal(signal)
        }

        switch event {
        case .messageStart:
            finalizePendingStreamingCompletion()
            // A new turn ends any live reasoning card; settle first so the
            // previous segment keeps its exact buffered text in the
            // transcript.
            settleReasoningSegmentIntoTranscript()
            resetReasoningTurn()
            setRunning(true)
            notifyVoiceAssistant(.started(sessionID: streamSessionId))

        case .messageDelta(_, let text):
            finalizePendingStreamingCompletion()
            shownChat.streamingBuffer += text
            scheduleStreamingPublish()
            setRunning(true)
            notifyVoiceAssistant(.delta(sessionID: streamSessionId, text: text))

        case .messageInterim(_, let text, let alreadyStreamed):
            finalizePendingStreamingCompletion()
            // Commentary ends the reasoning segment, as a tool start does.
            settleReasoningSegmentIntoTranscript()
            resetReasoningSegment()
            sealInterimCommentary(text, alreadyStreamed: alreadyStreamed)
            setRunning(true)
            notifyVoiceAssistant(.interim(sessionID: streamSessionId, text: text, alreadyStreamed: alreadyStreamed))

        case .reasoningDelta(_, let text):
            finalizePendingStreamingCompletion()
            shownChat.receivedReasoningForCurrentTurn = true
            appendReasoning(text)
            setRunning(true)

        case .messageComplete(_, let messageId, let content, let reasoning, let alreadyShown):
            scheduleStreamingCompletion(
                sessionId: streamSessionId,
                messageId: messageId,
                content: content,
                reasoning: reasoning,
                alreadyShown: alreadyShown
            )
            notifyVoiceAssistant(.completed(sessionID: streamSessionId, content: content, alreadyShown: alreadyShown))

        case .messageReaction(_, let rowId, let reactions, let role):
            applyAgentReaction(rowId: rowId, reactions: reactions, role: role)

        case .messageError(_, let message):
            settleReasoningSegmentIntoTranscript()
            resetReasoningTurn()
            clearStreamingText()
            errorMessage = message
            setRunning(false)
            // A follow-up that failed wrote nothing to tag.
            predictiveTurnEnded(sessionId: streamSessionId)
            notifyVoiceAssistant(.failed(sessionID: streamSessionId, message: message))

        case .messageInterrupted:
            settleReasoningSegmentIntoTranscript()
            resetReasoningTurn()
            clearStreamingText()
            setRunning(false)
            predictiveTurnEnded(sessionId: streamSessionId)
            notifyVoiceAssistant(.interrupted(sessionID: streamSessionId))

        case .sessionBusy(_, let busy):
            setRunning(busy)
            if ResponseHapticPolicy.shouldScheduleIdleConclusion(
                isBusy: busy,
                hasPendingConclusion: responseHaptics.pendingConclusion != nil,
                awaitsUserInput: responseAwaitsUserInput
            ) {
                scheduleResponseHapticConclusion(after: 180)
            }

        case .sessionInfo(let sessionID, let snapshot):
            applyRuntime(
                snapshot,
                for: sessionID,
                authoritativeYolo: authoritativeYolo,
                authoritativeApprovalsMode: authoritativeApprovalsMode
            )
            // Some gateway generations also carry `pending_clarify` on the
            // session.info snapshot; wherever it appears it is the same
            // authoritative state as the resume copy.
            if let pendingClarify = snapshot.pendingClarify {
                applyClarifyActivity(pendingClarify, source: .authoritativeSnapshot)
            }
            // Empty from current Hermes (open requests ride session.resume
            // only); applied for parity should a gateway include them.
            for prompt in snapshot.pendingInputPrompts {
                applyInputPromptActivity(prompt, authoritative: true)
            }
            if let payload = snapshot.pendingApprovalPayload,
               let pendingApproval = MessageNormalizer.approvalActivity(
                   from: payload,
                   sessionId: sessionID
               ) {
                applyApprovalActivity(pendingApproval, authoritative: true)
            }
            if let running = snapshot.running {
                setRunning(running)
            }

        case .sessionTitle:
            // Title pushes are catalog events and are handled before the
            // active-session stream gate in handleStreamEvent(_:).
            break

        case .toolStart(_, let name, let input, let eventToolID):
            if name.lowercased() == "conduit_present" {
                // The tool may wait for the answer: show it once stored.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await syncPresentedScreens()
                }
            }
            if name.lowercased() == "clarify" { break }
            let toolID = eventToolID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableToolID = toolID?.isEmpty == false ? toolID : nil
            // Tool lifecycle events can be replayed after a resume. A stable
            // gateway id makes a repeated start idempotent without splitting
            // the current reasoning or text projection. For legacy events
            // without a tool ID, avoid duplicating an active running card for
            // the same tool and input.
            if let stableToolID {
                if messages.contains(where: { $0.tool?.id == stableToolID }) {
                    break
                }
            } else if let lastRunningTool = messages.last(where: { $0.role == .tool && $0.tool?.status == .running })?.tool,
                      lastRunningTool.name == name,
                      lastRunningTool.input == input {
                break
            }
            // The tool card must land after a complete reasoning card; commit
            // the coalesced segment before the boundary reorders the
            // transcript. A tool ends the reasoning SEGMENT only — the turn
            // flag survives so completion-carried reasoning cannot duplicate
            // this segment.
            settleReasoningSegmentIntoTranscript()
            resetReasoningSegment()
            flushStreamingPartial()
            let message = ChatMessage(
                id: "tool-start-\(Date().timeIntervalSince1970)",
                role: .tool,
                content: "",
                timestamp: Self.localTimestamp(),
                tool: ToolActivity(id: stableToolID, name: name, input: input, output: nil, status: .running)
            )
            messages.append(message)
            sessionPresentationCache.recordPendingToolStart(
                message,
                profile: presentationProfile(for: streamSessionId),
                sessionIDs: presentationCacheSessionIDs(for: streamSessionId)
            )

        case .toolComplete(_, let name, let output, let eventToolID):
            if name.lowercased() == "clarify" { break }
            // Hermes may have changed files an open Folder tab shows.
            noteWorkspaceToolCompleted(name)
            // Hermes just read or asked to change Conduit's settings.
            if name.lowercased() == "conduit_settings" { Task { await syncAgentSettings() } }
            // A confirmation Hermes just asked for shows without waiting on the push.
            if name.lowercased() == "conduit_present" { Task { await syncPresentedScreens() } }
            // Hermes asked to open Apple Maps from the chat on screen.
            // Only a result seen for the first time: a replay after a
            // reconnect finds its card already complete.
            if name.lowercased() == "conduit_maps", let promptID = Self.mapsNavigatePromptID(output),
               let callID = eventToolID?.trimmingCharacters(in: .whitespacesAndNewlines), !callID.isEmpty,
               !messages.contains(where: { $0.role == .tool && $0.tool?.id == callID && $0.tool?.status == .complete }) {
                noteMapsNavigateExpected(promptID)
            }
            settleReasoningSegmentIntoTranscript()
            resetReasoningSegment()
            let toolID = eventToolID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableToolID = toolID?.isEmpty == false ? toolID : nil
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Update the matching running tool card in place instead of
            // appending a duplicate. This keeps input + output together in
            // one chronological entry, matching how the HTTP API returns
            // stored messages on reload.
            let matchingIndex: Int?
            var resolvedCacheToolID = stableToolID
            var adoptedMessageID: String? = nil
            if let stableToolID {
                if let exactIndex = messages.lastIndex(where: {
                    $0.role == .tool && $0.tool?.id == stableToolID
                }) {
                    matchingIndex = exactIndex
                    adoptedMessageID = messages[exactIndex].id
                } else {
                    // No exact tool-ID match. Check if there is an unambiguous
                    // running card for the same tool name — regardless of whether
                    // the card already carries a different stable tool ID or none.
                    // If exactly one exists, adopt it; if multiple, do not guess.
                    let candidates = messages.indices.filter { idx in
                        guard messages[idx].role == .tool,
                              let tool = messages[idx].tool,
                              tool.status == .running,
                              tool.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName else {
                            return false
                        }
                        return true
                    }
                    if candidates.count == 1 {
                        matchingIndex = candidates[0]
                        adoptedMessageID = messages[candidates[0]].id
                        // Preserve the card's existing tool ID when the
                        // completion's stableToolID didn't match any card.
                        resolvedCacheToolID = messages[candidates[0]].tool?.id
                    } else {
                        matchingIndex = nil
                    }
                }
            } else {
                // ID-less completion: gather ALL running same-name transcript
                // candidates regardless of whether they carry a stable tool ID.
                // If exactly one exists, adopt it (preserving its existing tool
                // ID). If multiple exist (or none), do not guess.
                let candidates = messages.indices.filter { idx in
                    guard messages[idx].role == .tool,
                          let tool = messages[idx].tool,
                          tool.status == .running,
                          tool.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName else {
                        return false
                    }
                    return true
                }
                if candidates.count == 1 {
                    matchingIndex = candidates[0]
                    adoptedMessageID = messages[candidates[0]].id
                } else {
                    matchingIndex = nil
                }
            }
            if let index = matchingIndex {
                let existing = messages[index].tool
                // A completion that names no tool, or only Tool Search's
                // wrapper, keeps the tool its start named.
                let keepsName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (ToolSearchBridge.isWrapper(name) && ToolSearchBridge.isConcrete(existing?.name))
                messages[index].tool = ToolActivity(
                    id: stableToolID ?? existing?.id,
                    name: keepsName ? (existing?.name ?? "") : name,
                    input: existing?.input,
                    output: output,
                    status: .complete,
                    // The card was stamped when the call started.
                    duration: existing?.duration
                        ?? ChatStepTiming.elapsed(from: messages[index].timestamp, to: Date())
                )
            } else {
                messages.append(ChatMessage(
                    id: "tool-complete-\(Date().timeIntervalSince1970)",
                    role: .tool,
                    content: "",
                    timestamp: Self.localTimestamp(),
                    tool: ToolActivity(id: stableToolID, name: name, input: nil, output: output, status: .complete)
                ))
            }
            sessionPresentationCache.resolvePendingTool(
                named: name,
                toolID: resolvedCacheToolID,
                messageID: adoptedMessageID,
                profile: presentationProfile(for: streamSessionId),
                sessionIDs: presentationCacheSessionIDs(for: streamSessionId)
            )

        case .reviewSummary(let sessionId, let activity):
            let id = "review-summary-\(sessionId)-\(UUID().uuidString)"
            // Each review is its own event even when the text repeats (the
            // default mode always reads "Memory updated"); only an immediate
            // repeat with nothing in between is treated as a duplicate
            // delivery. Known limit: two genuine reviews with identical
            // text and nothing between them collapse into one row. The event
            // carries no server sequence to dedupe on,
            // and Conduit does not replay session events on reconnect
            // (`session.events.since` is used for rooms only), so a
            // non-adjacent replay is not a path this has to absorb.
            if let last = messages.last, last.review == activity { return }
            // A mid-turn row must not land below the live reasoning card's
            // eventual commit — settle first so chronology matches the
            // pre-projection transcript.
            settleReasoningSegmentIntoTranscript()
            // To the millisecond: a review placed among Hermes' rows on a
            // reload must not land before a row from the same second.
            let reviewTimestamp = Self.reviewTimestampFormatter.string(from: Date())
            messages.append(ChatMessage(
                id: id,
                role: .system,
                content: activity.summary,
                timestamp: reviewTimestamp,
                review: activity
            ))
            persistReview(ReviewSummaryRecord(
                id: id,
                profile: activeProfile,
                sessionId: reviewRecordSessionID(eventSessionId: sessionId),
                timestamp: reviewTimestamp,
                activity: activity
            ))

        case .clarify(_, let activity):
            applyClarifyActivity(activity, source: .streamEvent)
            setRunning(true)
            noteHermesCallChatWaiting(sessionID: streamSessionId)
            noteClarifyForClassicVoice(activity, sessionID: streamSessionId)

        case .clarifyExpire(_, let requestId, let reason):
            expireClarifyRequest(requestId: requestId, reason: reason)

        case .approval(_, let activity):
            applyApprovalActivity(activity, authoritative: false, commitsStreamedText: true)
            setRunning(true)
            noteApprovalForClassicVoice(activity, sessionID: streamSessionId)
            noteHermesCallChatWaiting(sessionID: streamSessionId)

        case .inputPrompt(_, let activity):
            applyInputPromptActivity(activity, authoritative: false, commitsStreamedText: true)
            setRunning(true)

        case .inputPromptExpire(_, let requestId, let reason):
            expireInputPrompt(requestId: requestId, reason: reason)

        case .connection(_, let activity):
            // An older frame moves nothing, so it marks no turn running.
            if applyConnectionActivity(activity, commitsStreamedText: true), activity.isOpen { setRunning(true) }

        case .approvalWithdrawn(_, let requestId, let reason):
            withdrawApproval(requestId: requestId, reason: reason)

        // These arrive with most gateway frames of a turn, mostly unchanged:
        // each is written once, and only when it changes, since every write
        // publishes AppState and redraws what observes it (issue 1722).
        case .contextUpdate(_, let percent, let used, let max):
            var updated = runtime
            updated.contextPercent = normalizedContextPercent(percent, used: used, max: max)
            updated.contextUsed = used
            updated.contextMax = max
            setRuntime(updated)

        case .cwdUpdate(_, let cwd):
            var updated = runtime
            updated.cwd = cwd
            setRuntime(updated)

        case .modelUpdate(_, let model, let provider):
            var updated = runtime
            updated.model = model
            updated.provider = provider
            setRuntime(updated)

        case .agentCount(_, let count):
            setActiveAgents(count)

        case .delegateAgent(let sessionId, var activity):
            activity.sessionId = sessionId
            delegateAgentSeenAt[activity.id] = activity.updatedAt
            var updated = delegateAgents
            if let index = updated.firstIndex(where: { $0.id == activity.id }) {
                let card = updated[index].merged(with: activity)
                // Every event stamps a fresh time: an event that changes
                // nothing the card shows leaves the cards unpublished.
                var unstamped = card
                unstamped.updatedAt = updated[index].updatedAt
                guard unstamped != updated[index] else { break }
                updated[index] = card
            } else {
                updated.append(activity)
            }
            delegateAgents = updated
            setActiveAgents(updated.filter { $0.status.isActive }.count)

        case .statusUpdate:
            // Lifecycle bookkeeping — handled in handleStreamEvent before
            // the active-session gate; never a transcript projection.
            break

        case .sideAgentComplete(_, let kind, let taskId, let text, let question):
            // Beside the main turn: a note in the chat, as Desktop and the
            // TUI show it, leaving the stream and running state alone.
            appendSlashOutput(Self.sideAgentNote(kind: kind, taskId: taskId, text: text, question: question))

        case .userMessage, .sessionsChanged, .sessionControl:
            // Handled in handleStreamEvent.
            break

        case .unparsed:
            break
        }
    }
}
