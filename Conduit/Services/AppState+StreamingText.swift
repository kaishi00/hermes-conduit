//
//  AppState+StreamingText.swift
//  Conduit
//
//  Publishing a turn's streamed text and reasoning to the transcript:
//  coalesced publishes, completion, partials and interim commentary.
//  Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Publishing streamed text and reasoning

    /// A reasoning delta belongs exactly where Hermes emitted it. Gateways can
    /// send either deltas or repeated cumulative snapshots, so merge both into
    /// one live card rather than creating duplicate thinking boxes. The first
    /// delta of a segment mounts the live projection immediately so the
    /// thinking box appears promptly; every later delta coalesces through
    /// `reasoningBuffer` and republishes the PROJECTION at display cadence.
    /// The settled transcript is touched only once per segment, at the
    /// boundary commit.
    func appendReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        shownChat.reasoningBuffer = mergedReasoning(
            existing: shownChat.reasoningBuffer,
            incoming: text
        )
        guard shownChat.activeReasoningMessageId != nil else {
            let id = "reasoning-\(Date().timeIntervalSince1970)"
            shownChat.activeReasoningMessageId = id
            TranscriptPerf.note(.reasoningProjectionPublish)
            liveReasoningSegment = LiveReasoningSegment(
                id: id,
                timestamp: Self.localTimestamp(),
                content: shownChat.reasoningBuffer
            )
            return
        }
        scheduleReasoningPublish()
    }

    private func scheduleReasoningPublish() {
        guard !liveRowsHidden, !shownChat.hasScheduledReasoningPublish else { return }
        shownChat.hasScheduledReasoningPublish = true
        let cardID = shownChat.activeReasoningMessageId

        shownChat.reasoningPublishTask = Task { @MainActor [weak self] in
            do {
                // Reasoning updates republish the live projection at this
                // cadence; an expanded ThinkingCard restyles its attributed
                // text and remeasures a growing height on every commit, so
                // ~20 fps keeps the stream readable while leaving the main
                // actor free between layout passes.
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }

            guard !Task.isCancelled, let self else { return }
            self.shownChat.hasScheduledReasoningPublish = false
            self.shownChat.reasoningPublishTask = nil
            self.publishReasoningBuffer(liveCardID: cardID)
        }
    }

    /// Stale publish tasks are structurally inert: once a boundary or session
    /// switch has ended the live card, the captured id no longer matches, so
    /// nothing can mutate a finalized or replaced transcript.
    private func publishReasoningBuffer(liveCardID: String?) {
        guard let liveCardID, liveCardID == shownChat.activeReasoningMessageId,
              var segment = liveReasoningSegment, segment.id == liveCardID,
              segment.content != shownChat.reasoningBuffer else { return }
        TranscriptPerf.note(.reasoningProjectionPublish)
        segment.content = shownChat.reasoningBuffer
        liveReasoningSegment = segment
    }

    /// Publish any coalesced reasoning into the live projection immediately.
    /// Non-boundary callers (the sidebar closing) keep the segment streaming;
    /// boundary callers need `settleReasoningSegmentIntoTranscript()`.
    ///
    /// Internal (not private) as the deterministic test seam: performance
    /// fixtures flush each fed delta through this SAME production path, so
    /// a measured window contains exactly the publications the deltas imply
    /// instead of racing the ~50 ms coalescing task's scheduler timing.
    func flushReasoningPublish() {
        shownChat.reasoningPublishTask?.cancel()
        shownChat.reasoningPublishTask = nil
        shownChat.hasScheduledReasoningPublish = false
        publishReasoningBuffer(liveCardID: shownChat.activeReasoningMessageId)
    }

    /// Commit the live reasoning segment into the settled transcript EXACTLY
    /// ONCE at a semantic boundary: tool card, completion, error,
    /// interruption, or a new turn. `explicitContent` supersedes the buffered
    /// text (the completion-carried trace replaces what streamed, exactly as
    /// it replaced the in-transcript card content before the projection
    /// existed). Paired with the boundary's `resetReasoning*` call, this
    /// preserves the pre-projection transcript shape: the card is in
    /// `messages`, complete, and no stale publish can touch it afterwards.
    func settleReasoningSegmentIntoTranscript(explicitContent: String? = nil) {
        shownChat.reasoningPublishTask?.cancel()
        shownChat.reasoningPublishTask = nil
        shownChat.hasScheduledReasoningPublish = false

        func commit(id: String, timestamp: String, content: String) {
            guard !content.isEmpty else { return }
            // Commit and the projection clear below must stay in ONE
            // transaction: ChatView relies on the committed row's id equaling
            // the live segment's id for a seamless live→settled transition —
            // splitting them would transiently duplicate ids in the
            // LazyVStack. The card keeps its mount timestamp; `author`
            // reflects the profile at settle time (indistinguishable unless
            // the profile switches mid-stream).
            TranscriptPerf.note(.reasoningTranscriptMutation)
            var settled = ChatMessage(
                id: id,
                role: .reasoning,
                content: content,
                timestamp: timestamp,
                author: activeProfile
            )
            settled.stepDuration = ChatStepTiming.elapsed(from: timestamp, to: Date())
            messages.append(settled)
            shownChat.reasoningBuffer = ""
            shownChat.activeReasoningMessageId = nil
            liveReasoningSegment = nil
        }

        if let segment = liveReasoningSegment, shownChat.activeReasoningMessageId == segment.id {
            commit(id: segment.id, timestamp: segment.timestamp, content: explicitContent ?? shownChat.reasoningBuffer)
        } else if let text = explicitContent {
            commit(
                id: "reasoning-\(Date().timeIntervalSince1970)",
                timestamp: Self.localTimestamp(),
                content: text
            )
        }
    }

    /// End the active reasoning SEGMENT without publishing. Used at tool
    /// boundaries: the tool card ends the current thinking card, but the
    /// assistant TURN continues — reasoning may resume in a fresh segment, and
    /// reasoning already streamed this turn still counts at completion.
    func resetReasoningSegment() {
        shownChat.reasoningPublishTask?.cancel()
        shownChat.reasoningPublishTask = nil
        shownChat.hasScheduledReasoningPublish = false
        shownChat.reasoningBuffer = ""
        shownChat.activeReasoningMessageId = nil
        liveReasoningSegment = nil
    }

    /// Restore the ENTIRE per-turn reasoning state machine to its initial
    /// condition. Used when the turn or transcript itself is being replaced
    /// (message boundaries, completion, disconnect, session switch): the old
    /// card must not receive further updates — including from an in-flight
    /// publish — and the next turn's completion-carried reasoning must not
    /// look already-streamed.
    func resetReasoningTurn() {
        resetReasoningSegment()
        shownChat.receivedReasoningForCurrentTurn = false
    }

    private func mergedReasoning(existing: String, incoming: String) -> String {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }
        if incoming.hasPrefix(existing) { return incoming }
        if existing.hasSuffix(incoming) { return existing }
        return existing + incoming
    }

    /// Completion sometimes carries the full reasoning trace as well as the
    /// deltas. Prefer that complete value without duplicating an already
    /// streamed card; gateways that only provide completion still get a card
    /// immediately before their final answer. Completion is a boundary: the
    /// trace commits straight into the settled transcript rather than the
    /// live projection. Reachable only when nothing streamed this turn (the
    /// caller gates on `receivedReasoningForCurrentTurn`), so there is never
    /// a live segment to supersede here — `explicitContent` always mounts a
    /// fresh settled card.
    private func finalizeReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        settleReasoningSegmentIntoTranscript(explicitContent: text)
    }

    func scheduleStreamingPublish() {
        guard !liveRowsHidden, !shownChat.hasScheduledStreamingPublish else { return }
        shownChat.hasScheduledStreamingPublish = true

        shownChat.streamingPublishTask = Task { [weak self] in
            do {
                // Coalesce raw deltas just enough to avoid invalidating the
                // transcript for every WebSocket frame. Character pacing is
                // owned by StreamingText after this projection is published.
                try await Task.sleep(for: .milliseconds(33))
            } catch {
                return
            }

            guard !Task.isCancelled, let self else { return }
            let projectedText = self.shownChat.streamingBuffer
            self.shownChat.lastStreamingPublishBurst = max(
                projectedText.count - self.streamingText.count,
                0
            )
            self.shownChat.lastStreamingPublishDate = Date()
            self.streamingText = projectedText
            self.shownChat.hasScheduledStreamingPublish = false
            self.shownChat.streamingPublishTask = nil
        }
    }

    func scheduleStreamingCompletion(
        sessionId: String,
        messageId: String?,
        content: String?,
        reasoning: String?,
        alreadyShown: Bool = false
    ) {
        // messageComplete is a semantic boundary: the thinking card must show
        // its full buffered reasoning immediately, not one cadence later.
        settleReasoningSegmentIntoTranscript()
        shownChat.streamingCompletionTask?.cancel()
        shownChat.streamingPublishTask?.cancel()
        shownChat.streamingPublishTask = nil
        shownChat.hasScheduledStreamingPublish = false

        let finalContent = content ?? shownChat.streamingBuffer
        let hasPartials = messages.contains { $0.role == .partial }
        let shownRowID = alreadyShown
            ? shownChat.interimRowID.flatMap { id in messages.contains { $0.id == id } ? id : nil }
            : nil
        // Text already on screen as an interim row is not drawn again as the tail.
        let finalProjection = hasPartials || shownRowID != nil ? shownChat.streamingBuffer : finalContent
        let newlyPublishedCharacters = max(finalProjection.count - streamingText.count, 0)
        let recentPublishBurst: Int
        if let lastStreamingPublishDate = shownChat.lastStreamingPublishDate,
           Date().timeIntervalSince(lastStreamingPublishDate) < 0.25 {
            recentPublishBurst = shownChat.lastStreamingPublishBurst
        } else {
            recentPublishBurst = 0
        }
        let charactersToDrain = max(newlyPublishedCharacters, recentPublishBurst)
        if !finalProjection.isEmpty {
            streamingText = finalProjection
        }
        shownChat.pendingStreamingCompletion = PendingStreamingCompletion(
            sessionId: sessionId,
            messageId: messageId,
            finalContent: finalContent,
            reasoning: reasoning,
            shownRowID: shownRowID
        )
        // The gateway turn is complete immediately; only its final visual tail
        // remains buffered. This keeps Send/Stop/Steer state truthful.
        setRunning(false)

        // Completed streams use StreamingText's fast reveal batch. Keep enough
        // time for its per-character fade while capping the visual tail.
        let drainMilliseconds = min(
            1_200,
            max(180, Int((Double(charactersToDrain) / 540.0) * 1_000) + 180)
        )
        scheduleResponseHapticConclusion(after: drainMilliseconds)

        shownChat.streamingCompletionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(drainMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionId == sessionId else { return }
            self.finalizePendingStreamingCompletion(cancelResponseHapticConclusion: false)
        }
    }

    func finalizePendingStreamingCompletion(
        cancelResponseHapticConclusion: Bool = true
    ) {
        guard let pendingStreamingCompletion = shownChat.pendingStreamingCompletion else { return }
        if cancelResponseHapticConclusion {
            cancelPendingResponseHapticConclusion()
        }
        shownChat.streamingCompletionTask?.cancel()
        shownChat.streamingCompletionTask = nil
        shownChat.pendingStreamingCompletion = nil
        finalizeStreamingCompletion(
            sessionId: pendingStreamingCompletion.sessionId,
            messageId: pendingStreamingCompletion.messageId,
            finalContent: pendingStreamingCompletion.finalContent,
            reasoning: pendingStreamingCompletion.reasoning,
            shownRowID: pendingStreamingCompletion.shownRowID
        )
    }

    private func finalizeStreamingCompletion(
        sessionId: String,
        messageId: String?,
        finalContent: String,
        reasoning: String?,
        shownRowID: String? = nil
    ) {
        // Reasoning that raced the drain window must not be discarded when
        // the pending completion finalizes.
        settleReasoningSegmentIntoTranscript()
        removeAllPartials()
        // Some gateways repeat the full trace in completion after already
        // emitting reasoning events. Use it only when streaming supplied no
        // reasoning so an existing card is not duplicated.
        if !shownChat.receivedReasoningForCurrentTurn, let reasoning, !reasoning.isEmpty {
            finalizeReasoning(reasoning)
        }

        let firstTurnUserMessage = messages.first(where: { $0.role == .user })?.content
        let isFirstUserTurn = messages.filter { $0.role == .user }.count == 1
        let trimmedMessageID = messageId
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let resolvedMessageID = trimmedMessageID
            ?? "assistant-\(Date().timeIntervalSince1970)"
        let systemNotice = MessageNormalizer.systemNoticeText(fromText: finalContent)
        let displayContent = systemNotice ?? finalContent
        let displayRole: MessageRole = systemNotice == nil ? .assistant : .system
        // In-place finalization only for GATEWAY-SUPPLIED ids: a cross-surface
        // persisted advancement can merge the persisted row before the live
        // completion arrives, and the completion must finalize that row in
        // place instead of appending a twin. The timestamp fallback id is
        // minted locally per completion — matching on it could overwrite an
        // unrelated same-second completion — so it keeps the historical
        // append semantics.
        if let trimmedMessageID,
           let existingIndex = messages.lastIndex(where: { $0.id == trimmedMessageID }) {
            if !displayContent.isEmpty {
                messages[existingIndex].content = displayContent
                messages[existingIndex].rawContent = systemNotice == nil ? nil : finalContent
            }
        } else if let shownRowID,
                  let shownIndex = messages.lastIndex(where: { $0.id == shownRowID }) {
            // Hermes says this answer is the one its interim already showed.
            let shownText = displayContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shownText.isEmpty, systemNotice == nil {
                messages[shownIndex].content = shownText
            }
        } else if !displayContent.isEmpty,
                  (messages.last?.role != displayRole || messages.last?.content != displayContent) {
            messages.append(ChatMessage(
                id: resolvedMessageID,
                role: displayRole,
                content: displayContent,
                rawContent: systemNotice == nil ? nil : finalContent,
                timestamp: Self.localTimestamp(),
                author: activeProfile
            ))
        }

        // A reply read aloud as it streamed: the button under its row shows Stop.
        if let rowID = (trimmedMessageID.flatMap { id in messages.last(where: { $0.id == id })?.id })
            ?? shownRowID.flatMap({ id in messages.contains { $0.id == id } ? id : nil })
            ?? messages.last(where: { $0.role == .assistant })?.id {
            messageReadAloudController.adoptLiveReply(sessionID: sessionId, messageID: rowID)
        }
        clearStreamingText()
        shownChat.activeAssistantMessageId = nil
        resetReasoningTurn()
        setRunning(false)
        // The turn has settled, its reply in place.
        requestStepSummaryIfWanted(sessionId: sessionId)
        // Suggested replies and the follow-up clock for the new reply; a
        // system notice merged into the last row isn't one.
        predictiveTurnSettled(sessionId: sessionId, isReply: systemNotice == nil)
        // Cancel any pending coalesced flush and write immediately — the
        // turn is complete so all messages are in their final state. One
        // write covering the stream's session id too; this used to write the
        // whole cache twice back to back.
        flushPendingPresentationCache(for: [sessionId])

        if displayRole == .assistant,
           isFirstUserTurn,
           let firstTurnUserMessage,
           !finalContent.isEmpty {
            scheduleSecondaryProfileTitleRecovery(
                sessionId: sessionId,
                userMessage: firstTurnUserMessage,
                assistantMessage: finalContent
            )
        }
    }

    /// Flush any accumulated streaming text as a .partial message so tool cards
    /// interleave correctly with assistant text during a turn.
    func flushStreamingPartial() {
        let buffer = shownChat.streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !buffer.isEmpty else { return }
        messages.append(ChatMessage(
            id: "partial-\(Date().timeIntervalSince1970)",
            role: .partial,
            content: buffer,
            timestamp: Self.localTimestamp()
        ))
        shownChat.streamingBuffer = ""
        streamingText = ""
    }

    /// Remove all .partial messages and reset streaming state. Called when
    /// the final assistant message arrives to replace partials with one clean entry.
    private func removeAllPartials() {
        messages.removeAll { $0.role == .partial }
    }

    /// Seals `message.interim` commentary as its own assistant row, so it
    /// outlives the partials the completion removes. Streamed commentary is
    /// already in the buffer (or the partial a boundary flushed it into):
    /// that copy becomes the row instead of being repeated.
    func sealInterimCommentary(_ text: String, alreadyStreamed: Bool) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if alreadyStreamed {
            if !shownChat.streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shownChat.streamingBuffer = ""
                streamingText = ""
            } else if messages.last?.role == .partial, messages.last?.content == content {
                messages.removeLast()
            }
        } else {
            flushStreamingPartial()
        }
        let id = "interim-\(Date().timeIntervalSince1970)"
        messages.append(ChatMessage(
            id: id,
            role: .assistant,
            content: content,
            timestamp: Self.localTimestamp(),
            author: activeProfile
        ))
        shownChat.interimRowID = id
        shownChat.runningTurnNoteIDs.insert(id)
    }

    func clearStreamingText() {
        shownChat.interimRowID = nil
        shownChat.streamingCompletionTask?.cancel()
        shownChat.streamingCompletionTask = nil
        shownChat.pendingStreamingCompletion = nil
        shownChat.streamingPublishTask?.cancel()
        shownChat.streamingPublishTask = nil
        shownChat.hasScheduledStreamingPublish = false
        shownChat.lastStreamingPublishBurst = 0
        shownChat.lastStreamingPublishDate = nil
        shownChat.streamingBuffer = ""
        streamingText = ""
    }
}
