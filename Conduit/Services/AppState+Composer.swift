//
//  AppState+Composer.swift
//  Conduit
//
//  The composer: quoting and replying into it, prefills and drops, and
//  submitting what it holds (the submission's ownership and identity,
//  starting a chat for it, a send while busy). Moved out of AppState.swift
//  (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Quoting into the composer (#385)

    /// The transcript offers Quote only while the composer takes input: not
    /// in the read-only saved copy, nor while the chat is reconnecting.
    func canQuoteIntoComposer() -> Bool {
        composerIsEnabled
    }

    /// Selected transcript text goes into the draft as a `>` quote.
    func quoteIntoComposer(_ selectedText: String) {
        guard canQuoteIntoComposer() else { return }
        let quote = ChatQuote.blockquote(selectedText)
        guard !quote.isEmpty else { return }
        composerQuoteRequest = ComposerQuoteRequest(content: .text(quote))
    }

    /// A reply's Quote button: the whole reply rides along with the next
    /// message, shown in the composer as a removable "Replying to…" chip.
    func replyInComposer(to message: ChatMessage) {
        guard canQuoteIntoComposer() else { return }
        guard message.content.contains(where: { !$0.isWhitespace }) else { return }
        let reference = ComposerReplyReference(
            authorName: conversationAgentIdentity.name,
            text: message.content
        )
        composerQuoteRequest = ComposerQuoteRequest(content: .reply(reference))
    }

    /// A sent message's own Quote: its words go into the draft as a `>`
    /// quote, as a selection's Quote does.
    func quoteOwnMessageIntoComposer(_ message: ChatMessage) {
        quoteIntoComposer(UserMessageCopyButton.copyText(for: message))
    }

    /// A "Replying to" card's tap: scrolls to the reply it quoted, when the
    /// transcript still holds it. False when it doesn't.
    @discardableResult
    func showQuotedReply(_ quote: String, quotedIn messageID: String) -> Bool {
        guard let id = Self.quotedReplyMessageID(quote: quote, quotedIn: messageID, in: messages) else { return false }
        pendingQuotedReplyJump = QuotedReplyJump(messageID: id)
        return true
    }

    /// A room's "Replying to" card: scrolls to the member message it quoted.
    @discardableResult
    func showQuotedRoomMessage(_ quote: String, quotedIn eventID: String) -> Bool {
        let events = activeRoomReplay.events.filter(GroupRoomTurns.isVisible)
        guard let id = Self.quotedRoomMessageID(quote: quote, quotedIn: eventID, in: events) else { return false }
        pendingQuotedReplyJump = QuotedReplyJump(messageID: id)
        return true
    }

    /// The newest member message before `eventID` whose words are `quote`,
    /// as `quotedReplyMessageID` finds a chat's reply.
    static func quotedRoomMessageID(quote: String, quotedIn eventID: String, in events: [GroupEvent]) -> String? {
        let quoted = ChatQuote.blockquote(quote)
        guard !quoted.isEmpty else { return nil }
        // A message still sending isn't in the room's events yet: it comes last.
        let index = events.firstIndex { $0.id == eventID } ?? events.endIndex
        return events[..<index].last {
            $0.isMemberMessage && ChatQuote.blockquote(GroupMessageParts($0.messageText ?? "").text) == quoted
        }?.id
    }

    /// The newest reply before `messageID` whose words are `quote`. The
    /// envelope carries only the words, so a reply is found by them, as
    /// a Markdown quote compares them (trailing spaces and blank edges
    /// dropped).
    static func quotedReplyMessageID(quote: String, quotedIn messageID: String, in transcript: [ChatMessage]) -> String? {
        let quoted = ChatQuote.blockquote(quote)
        guard !quoted.isEmpty else { return nil }
        // A waiting message isn't in the transcript yet: it comes last.
        let index = transcript.firstIndex { $0.id == messageID } ?? transcript.endIndex
        return transcript[..<index].last {
            $0.role == .assistant && ChatQuote.blockquote($0.content) == quoted
        }?.id
    }

    /// The newest reply, when no message was sent after it: the turn /retry
    /// takes back and sends again is the one it answered.
    static func retryableReplyID(in transcript: [ChatMessage]) -> String? {
        guard let index = transcript.lastIndex(where: { $0.role == .assistant }),
              !transcript[(index + 1)...].contains(where: { $0.role == .user }) else { return nil }
        return transcript[index].id
    }

    /// Whether the newest reply's turn ran tools, which Retry runs again:
    /// a step between the last message sent and the end of the transcript.
    static func latestTurnRanTools(in transcript: [ChatMessage]) -> Bool {
        let start = transcript.lastIndex { $0.role == .user }.map { $0 + 1 } ?? transcript.startIndex
        return transcript[start...].contains { $0.role == .tool || $0.tool != nil }
    }

    /// A guess from the suggestion row for the composer to send, edit or
    /// insert (Predictive.swift).
    func requestPredictiveComposer(_ action: PredictiveComposerRequest.Action, text: String) {
        // The row's guesses are for the reply it shows, in the open chat.
        guard let shown = predictive.screen, shown.sessionID == activeSessionId else { return }
        predictiveComposerRequest = PredictiveComposerRequest(
            action: action, text: text, draft: predictive.draft, sessionID: shown.sessionID,
            draftKey: ComposerBar.composerDraftKey(for: shown.sessionID, profile: activeProfile)
        )
    }

    /// A board's follow-up (conduit_show's next): tap sends it as the
    /// user's message, long-press puts it in the composer, the same way a
    /// suggested reply does.
    func requestBoardFollowUp(_ action: PredictiveComposerRequest.Action, text: String) {
        guard let session = activeSessionId, !session.isEmpty else { return }
        predictiveComposerRequest = PredictiveComposerRequest(
            action: action, text: text, draft: "", sessionID: session,
            draftKey: ComposerBar.composerDraftKey(for: session, profile: activeProfile)
        )
    }

    /// The composer took the guess.
    func consumePredictiveComposerRequest(_ id: UUID) {
        guard predictiveComposerRequest?.id == id else { return }
        predictiveComposerRequest = nil
    }

    /// Sign-out or removal of the open dashboard: nothing Predictive knew
    /// of its chats stays for the next account.
    func forgetPredictiveState() {
        predictiveGeneration &+= 1
        predictivePauseTask?.cancel()
        predictivePauseTask = nil
        predictiveFollowUpTask?.cancel()
        predictiveFollowUpTask = nil
        predictiveRepliesAsked = nil
        predictiveDraftAsked = nil
        predictiveFollowUp = PredictiveFollowUpState()
        stopWaitingForPredictiveFollowUp()
        predictiveReplyEnded = nil
        predictiveComposerRequest = nil
        predictive.forgetAll()
    }

    /// Puts `text` in the open chat's composer, replacing the draft, and
    /// focuses it.
    func prefillComposer(_ text: String) {
        composerPrefillDraftKey = ComposerBar.composerDraftKey(for: activeSessionId, profile: activeProfile)
        composerPrefillText = text
        composerPrefillToken = UUID()
    }

    /// The composer put the prefill in, or moved to a chat it wasn't for.
    func consumeComposerPrefill(_ token: UUID) {
        guard composerPrefillToken == token else { return }
        composerPrefillDraftKey = nil
    }

    /// Files dropped on the open chat go to its composer, which stages them
    /// as attachments for the user to send.
    func dropIntoComposer(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let owner = composerDraftKeyOnScreen
        // A second drop on the same chat before the composer took the
        // first adds to it; one left by another chat is dropped.
        let pending = composerDropRequest?.owner == AnyHashable(owner) ? composerDropRequest?.providers ?? [] : []
        composerDropRequest = AttachmentDropRequest(owner: owner, providers: pending + providers)
    }

    /// Whether the request was still the pending one for the chat on
    /// screen: a drop that came on top of it replaced it with both, so its
    /// composer stages that, and one dropped on another chat is discarded.
    func consumeComposerDropRequest(_ id: UUID) -> Bool {
        guard let request = composerDropRequest, request.id == id else { return false }
        composerDropRequest = nil
        guard let owner = request.owner.base as? ComposerDraftKey else { return false }
        return composerDraftKeysAreSameChat(owner, composerDraftKeyOnScreen)
    }

    /// Files dropped on the open group room go to its composer.
    func dropIntoRoomComposer(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty, let surface = activeRoomSurface else { return }
        let owner = "\(surface.dashboardID.uuidString)/\(surface.room.roomID)"
        // A second drop on the same room before the composer took the
        // first adds to it.
        let pending = roomDropRequest?.owner == AnyHashable(owner) ? roomDropRequest?.providers ?? [] : []
        roomDropRequest = AttachmentDropRequest(owner: owner, providers: pending + providers)
    }

    /// Whether the request was still the pending one for the open room.
    func consumeRoomDropRequest(_ id: UUID) -> Bool {
        guard let request = roomDropRequest, request.id == id else { return false }
        roomDropRequest = nil
        guard let surface = activeRoomSurface else { return false }
        return request.owner == AnyHashable("\(surface.dashboardID.uuidString)/\(surface.room.roomID)")
    }

    /// The composer took the quote: drop it, so the quoted text is not kept
    /// around after it has landed.
    func consumeComposerQuoteRequest(_ id: UUID) {
        guard composerQuoteRequest?.id == id else { return }
        composerQuoteRequest = nil
    }

    /// A genuine composer edit is explicit ownership of the visible
    /// conversation, exactly like sending, navigating, or scrolling: any
    /// automatic-return work still in flight (a foreground health check that
    /// may yet fall back to a reconnect, an in-flight `.automaticReturn`
    /// reconnect or sync, an armed retry timer, an unconsumed restoration
    /// request) loses its authority to select a different session. Transport
    /// recovery itself is not stopped — `cancelChatResumeRestoration()`
    /// demotes the in-flight and queued purpose to `.preserveCurrent`, so a
    /// reconnect that is already running hands off and preserves this
    /// session, and a foreground attempt whose health check fails after the
    /// edit repairs the transport with `.preserveCurrent` instead of
    /// `.automaticReturn`.
    ///
    /// At most one cancellation lands per automatic-work generation: the
    /// first edit that finds work outstanding claims it, later edits during
    /// the same window are latched no-ops (`chatResumeRestorationRequest` is
    /// `@Published`, so a per-keystroke nil write would re-render ChatView),
    /// and a new foreground/reconnect generation re-arms through
    /// `beginAutomaticChatResumeWork()`. With nothing outstanding this is a
    /// pure no-op, so calling it per keystroke publishes no state and cannot
    /// invalidate the viewport that a later, unrelated foreground return
    /// will need.
    func noteComposerUserEdit() {
        if composerNotice != nil { composerNotice = nil }
        // Saved copies and pending New Chats need their loading work to
        // continue. An edit in an already-live chat still claims that chat
        // from automatic selection, preserving it through the reconnect.
        if composerWaitsForChat {
            switch composerChatOnScreen {
            case .savedCopy:
                noteComposerEditOverSavedCopy()
                return
            case .newChat:
                return
            case .live, .none:
                break
            }
        }
        guard automaticChatResumeWorkMayStillSelectSession else { return }
        guard !composerEditClaimedAutomaticWork else { return }
        composerEditClaimedAutomaticWork = true
#if DEBUG
        composerEditCancellationCount += 1
#endif
        cancelChatResumeRestoration()
    }

    // MARK: - Composer actions

    func composerSubmissionContext() -> ComposerSubmissionContext {
        ComposerSubmissionContext(
            profile: activeProfile,
            sessionID: activeSessionId,
            durableSessionID: activeSessionId.flatMap { canonicalSessionID(for: $0) },
            clientIdentity: client.map(ObjectIdentifier.init),
            clientEpoch: activeClientEpoch,
            viewportTransitionGeneration: chatViewportTransitionGeneration
        )
    }

    /// A failed send that said nothing: its chat was left (or the
    /// connection changed) before Hermes refused it, and Hermes didn't get
    /// it. One whose reply was lost after its chat was left may have gone,
    /// so it isn't announced as unsent.
    func composerSubmissionStoppedQuietly(_ context: ComposerSubmissionContext) -> Bool {
        if takeComposerSubmissionOfUnknownDelivery(context) { return false }
        return !isCurrentComposerSubmission(context)
    }

    /// The failed send may have reached Hermes: its reply was lost after
    /// its chat was left. Asked once per failed send.
    func takeComposerSubmissionOfUnknownDelivery(_ context: ComposerSubmissionContext) -> Bool {
        guard let index = composerSubmissionsOfUnknownDelivery.firstIndex(of: context) else { return false }
        composerSubmissionsOfUnknownDelivery.remove(at: index)
        return true
    }

    /// A dashboard left or signed out of: nobody asks about its sends again.
    func forgetComposerSubmissionsOfUnknownDelivery() {
        composerSubmissionsOfUnknownDelivery.removeAll()
    }

    func isCurrentComposerSubmission(_ context: ComposerSubmissionContext) -> Bool {
        guard context.profile == activeProfile,
              context.clientIdentity == client.map(ObjectIdentifier.init),
              context.clientEpoch == activeClientEpoch,
              context.viewportTransitionGeneration == chatViewportTransitionGeneration else {
            return false
        }
        // A captured nil session (pristine new-chat canvas) only stays valid
        // while no session was selected since; any active session means the
        // canvas was replaced.
        guard let capturedSessionID = context.sessionID else {
            return activeSessionId == nil
        }
        guard let activeSessionId else { return false }
        if capturedSessionID == activeSessionId {
            // Exact routing-string equality alone is not proof the suspended
            // work still belongs to the same durable conversation — catalog
            // re-attribution can hand the same runtime string to a different
            // conversation. The exact path therefore requires durable
            // ownership proven strictly (see
            // composerExactMatchDurableIdentityMatches).
            return composerExactMatchDurableIdentityMatches(context)
        }
        return currentComposerSubmissionContextIfOwnedAndAliased(context) != nil
    }

    private func composerSubmissionOwnershipIsCurrent(
        _ context: ComposerSubmissionContext
    ) -> Bool {
        context.profile == activeProfile
            && context.clientIdentity == client.map(ObjectIdentifier.init)
            && context.clientEpoch == activeClientEpoch
            && context.viewportTransitionGeneration == chatViewportTransitionGeneration
    }

    func composerSessionIDsAreEquivalent(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs || activeChatScrollSessionIdentity.areEquivalent(lhs, rhs) {
            return true
        }
        guard let session = (sessions + cronSessions).first(where: { session in
            let ids = Set([session.id] + session.alternateIds)
            return ids.contains(lhs) || ids.contains(rhs)
        }) else {
            return false
        }
        let ids = Set([session.id] + session.alternateIds)
        return ids.contains(lhs) && ids.contains(rhs)
    }

    func isCurrentOrAliasedComposerSubmission(
        _ context: ComposerSubmissionContext
    ) -> Bool {
        currentComposerSubmissionContextIfOwnedAndAliased(context) != nil
    }

    func currentComposerSubmissionContextIfOwnedAndAliased(
        _ context: ComposerSubmissionContext
    ) -> ComposerSubmissionContext? {
        guard composerSubmissionOwnershipIsCurrent(context),
              let activeSessionId,
              composerSessionIDsAreEquivalent(context.sessionID, activeSessionId),
              composerDurableIdentityMatches(context) else {
            return nil
        }
        return ComposerSubmissionContext(
            profile: context.profile,
            sessionID: activeSessionId,
            durableSessionID: context.durableSessionID,
            clientIdentity: context.clientIdentity,
            clientEpoch: context.clientEpoch,
            viewportTransitionGeneration: context.viewportTransitionGeneration
        )
    }

    /// Defense-in-depth durable fence for the alias path: the equivalence
    /// check above admits positively confirmed aliases, and this additionally
    /// requires the captured submission to belong to the conversation the
    /// aliases mean. Never overrides the profile/client/epoch/viewport
    /// generation fences — a navigation handoff (A → B → A) is rejected by
    /// the viewport generation fence even though the durable id matches
    /// again on return.
    private func composerDurableIdentityMatches(_ context: ComposerSubmissionContext) -> Bool {
        guard let capturedDurable = context.durableSessionID else { return true }
        guard let activeSessionId,
              let currentDurable = canonicalSessionID(for: activeSessionId) else {
            return true
        }
        return capturedDurable == currentDurable
            || composerSessionIDsAreEquivalent(capturedDurable, currentDurable)
    }

    /// Durable fence for the EXACT session-ID path. Strict on purpose: when
    /// the routing strings still match, the only way the durable ownership
    /// could have drifted is catalog re-attribution (the same runtime string
    /// now resolving to a different row), so the comparison must not bridge
    /// through scroll-identity alias history — that history is precisely
    /// what the re-attribution pollutes. Either the durable ids are equal,
    /// one catalog row POSITIVELY contains both ids (confirming the same
    /// conversation under its refreshed identity), or the catalog is silent
    /// on the captured durable id (the expected state of a just-established
    /// row-less durable key — no positive separation evidence, so no
    /// rejection). A row that knows the current durable but not the captured
    /// one is positive separation and fails the fence.
    private func composerExactMatchDurableIdentityMatches(_ context: ComposerSubmissionContext) -> Bool {
        guard let capturedDurable = context.durableSessionID else { return true }
        guard let activeSessionId,
              let currentDurable = canonicalSessionID(for: activeSessionId) else {
            return true
        }
        if capturedDurable == currentDurable { return true }
        let rows = sessions + cronSessions
        if let row = rows.first(where: {
            $0.id == capturedDurable || $0.alternateIds.contains(capturedDurable)
        }) {
            return Set([row.id] + row.alternateIds).contains(currentDurable)
        }
        return !rows.contains(where: {
            $0.id == currentDurable || $0.alternateIds.contains(currentDurable)
        })
    }

    /// Most callers only need the sync; the returned context is for the ones
    /// that send again from where the submission recovered.
    @discardableResult
    func recoverComposerSubmission(
        using context: ComposerSubmissionContext
    ) async -> ComposerSubmissionContext? {
        // Keep recovery owned by the submission that produced the error. The
        // active actor may have moved to another session while the RPC waited.
        guard isCurrentOrAliasedComposerSubmission(context) else { return nil }
        await syncSession()
        return currentComposerSubmissionContextIfOwnedAndAliased(context)
    }

    /// `onBusy`, when given, replaces the composer's Steer/Interrupt routing:
    /// a submission that finds a turn running (directly or after a stale-idle
    /// probe) calls it and sends nothing. A live call's turn uses it to wait
    /// for typed work instead of steering it. `busyMode`, when given, is the
    /// long-press choice for this message only, over the profile's mode.
    func submitComposer(
        text: String,
        attachments: [Attachment] = [],
        context: ComposerSubmissionContext? = nil,
        onBusy: (() -> Void)? = nil,
        busyMode: BusyInputMode? = nil,
        runsSlashCommands: Bool = true
    ) async -> Bool {
        noteUserWordsSent()
        var submissionContext = context ?? composerSubmissionContext()
        // The canvas a closed chat leaves (archive, delete) has no chat
        // behind it: the first message starts one, as New Chat would, and
        // goes into it rather than nowhere.
        if composerSubmissionStartsChat(text: text, attachments: attachments, context: submissionContext) {
            guard let started = await checkingBeforeSend(submissionContext, startsChat: true, {
                await startChatForComposerSubmission()
            }) else { return false }
            submissionContext = started
        }
        let sent = await performComposerSubmission(
            text: text,
            attachments: attachments,
            submissionContext: submissionContext,
            onBusy: onBusy,
            busyMode: busyMode ?? busyInputMode,
            runsSlashCommands: runsSlashCommands
        )
        // Only something Hermes took moves the registry's count; a refused
        // or busy-diverted submission leaves another device's turn due. A
        // slash command reports true even when it ran only here, so it
        // marks nothing: missing a mark costs one extra read, a wrong mark
        // hides the other device's turn.
        let isSlashCommand = runsSlashCommands && attachments.isEmpty && Self.parseSlashCommand(text) != nil
        // One left waiting for a reconnect (keepComposerSendForReconnect)
        // isn't Hermes' yet.
        if sent, !isSlashCommand, activeSessionId == submissionContext.sessionID, pendingComposerSendOnScreen == nil {
            noteOpenChatSentHere()
        }
        return sent
    }

    /// Nothing is on screen to send into: no chat, nor one on its way.
    /// A slash command runs as before; it needs no chat.
    private func composerSubmissionStartsChat(
        text: String,
        attachments: [Attachment],
        context: ComposerSubmissionContext
    ) -> Bool {
        guard context.sessionID == nil, composerChatOnScreen == .none,
              isCurrentComposerSubmission(context), composerIsEnabled else { return false }
        return !(attachments.isEmpty && Self.parseSlashCommand(text) != nil)
    }

    /// Starts the chat a message sent from the empty canvas goes into, and
    /// the submission context for it. Nil, with the reason shown, when no
    /// chat could start: the composer then keeps the message.
    private func startChatForComposerSubmission() async -> ComposerSubmissionContext? {
        guard canStartNewChatNow, !isStartingNewChat else {
            // Said only when the connection is what's missing, over any
            // older message: this one is why the message didn't go. A
            // chat starting, a sync or a profile switch passes on its own.
            if !isConnected || client == nil {
                errorMessage = AppLocalization.string("Connect to Hermes to start a conversation.")
            }
            return nil
        }
        // A chat that didn't start has already said why (createNewSession).
        // Only the chat this submission's own creation opened takes the
        // message, and only while it is still open. Another chat opened or
        // created meanwhile (a voice action, a screen question, a Hermes
        // call) gets nothing, and the composer keeps the words: the shared
        // newChatOpenedSessionID would name that other creation's chat.
        guard let created = await createNewSessionMarkingStart(),
              newChatOpenedSessionID == created, activeSessionId == created else { return nil }
        return composerSubmissionContext()
    }

    /// Creates a chat as New Chat does, marked as starting until it is
    /// done, so neither New Chat nor a send starts a second one meanwhile.
    /// Returns the chat it created and opened, as createNewSession does.
    @discardableResult
    func createNewSessionMarkingStart() async -> String? {
        isStartingNewChat = true
        defer { isStartingNewChat = false }
        return await createNewSession()
    }

    func performComposerSubmission(
        text: String,
        attachments: [Attachment],
        submissionContext: ComposerSubmissionContext,
        onBusy: (() -> Void)?,
        busyMode: BusyInputMode,
        runsSlashCommands: Bool = true
    ) async -> Bool {
        guard isCurrentComposerSubmission(submissionContext) else { return false }

        // The gateway is already idle while the final visual tail drains.
        // If the user acts first, commit that response synchronously so the
        // new outgoing message retains correct transcript order.
        finalizePendingStreamingCompletion()
        guard composerIsEnabled else { return false }

        // Slash command intercept — handle before normal message/steer logic
        if runsSlashCommands, attachments.isEmpty, let command = Self.parseSlashCommand(text) {
            // /steer and /queue are sends: a failed one keeps the draft.
            if Self.composerRoutedSlashNames.contains(command.name) {
                guard isCurrentComposerSubmission(submissionContext) else { return false }
                return await submitSteerOrQueueSlash(name: command.name, argument: command.argument, context: submissionContext)
            }
            await executeSlashCommand(text, context: submissionContext)
            return true
        }
        // The canonical-chat `/new` reroute is a compaction, which carries no
        // attachments; refuse rather than submit a literal `/compact` turn.
        if !attachments.isEmpty, isCanonicalForeverChatReset(text) {
            errorMessage = AppLocalization.string(
                "This bot chat never resets. Remove the attachments to compact it instead."
            )
            return false
        }

        if isBusy {
            if let onBusy { onBusy(); return false }
            return await submitWhileBusy(text, attachments: attachments, mode: busyMode, context: submissionContext)
        }

        // A lifecycle/recovery boundary (scene dip, reconnect, ambiguous
        // submission) may have left the local idle state stale while Hermes
        // still considers the session running. Submitting blind would enter
        // Hermes' server-side busy policy with a message the user meant as a
        // new turn — the queued/steered follow-up the user never asked for.
        // One authoritative read-only probe corrects the state before the
        // routing decision. Trusted state never pays for the probe.
        if turnState == .idle, turnStateIsStale,
           await checkingBeforeSend(submissionContext, { await correctStaleIdleTurnState(using: submissionContext) }) {
            if let onBusy { onBusy(); return false }
            lifecycleLog.notice("submitComposer: stale-idle corrected to running → busy \(busyMode.rawValue, privacy: .public)")
            return await submitWhileBusy(text, attachments: attachments, mode: busyMode, context: submissionContext)
        }

        // The stale-idle probe above can lose a race with a live busy edge:
        // its post-await ownership check refuses to mutate a non-idle state
        // and returns false, so without this re-route the submission would
        // fall through to an ordinary prompt.submit into the now-running
        // turn — the same busy-edge rule the freshness gate enforces.
        if turnState.isRunning {
            if let onBusy { onBusy(); return false }
            lifecycleLog.notice("submitComposer: busy edge raced the stale-idle probe → busy \(busyMode.rawValue, privacy: .public)")
            return await submitWhileBusy(text, attachments: attachments, mode: busyMode, context: submissionContext)
        }

        // Transcript freshness is a separate concern from turn-state
        // staleness: the registry probe above proves whether Hermes is busy,
        // never whether the visible transcript is missing persisted rows. A
        // foreground freshness read that failed transiently left that
        // uncertainty open — resolve it with exactly one bounded tail-only
        // retry before appending a new-turn prompt into a possibly-reordered
        // transcript.
        if turnState == .idle,
           transcriptFreshnessIsStale || shownChat.pendingLocalOrderingDebt != nil {
            switch await checkingBeforeSend(submissionContext, {
                await confirmTranscriptFreshnessBeforeSend(using: submissionContext)
            }) {
            case .proceed:
                break
            case .routeToBusySubmission:
                // The authoritative recovery revealed a live turn: the text
                // routes through the configured busy submission, exactly like
                // a stale-idle correction to running.
                if let onBusy { onBusy(); return false }
                lifecycleLog.notice(
                    "submitComposer: freshness recovery found live turn → busy \(busyMode.rawValue, privacy: .public)"
                )
                return await submitWhileBusy(text, attachments: attachments, mode: busyMode, context: submissionContext)
            case .blocked(let message):
                errorMessage = message
                return false
            }
        }

        // A screenshot waiting on this chat rides on its next new turn,
        // whichever path sent it (typed, classic voice, a live call's
        // ask_thread). Busy routes and slash commands above leave it.
        let screenshot = takePendingScreenshotEntry(forSession: submissionContext.sessionID)
        let sent = await sendMessage(
            text,
            attachments: attachments + [screenshot?.attachment].compactMap { $0 },
            context: submissionContext
        )
        if !sent, let screenshot {
            restorePendingScreenshot(screenshot)
        }
        return sent
    }

    /// A check Hermes answers before a send's message shows. On a slow or
    /// dropped connection it can take seconds, and the field is empty by
    /// then: without a word from the composer the message looked as if it
    /// went nowhere, and leaving the chat to retry dropped it (#1401).
    /// `startsChat`: the check is starting the chat from the empty canvas,
    /// which opens a new viewport of its own on the way.
    private func checkingBeforeSend<T>(
        _ context: ComposerSubmissionContext,
        startsChat: Bool = false,
        _ check: () async -> T
    ) async -> T {
        let marker = ComposerSendCheck(
            sessionID: context.sessionID,
            viewportTransitionGeneration: context.viewportTransitionGeneration,
            startsChat: startsChat,
            earlierNewChat: newChatOpenedSessionID
        )
        composerSendChecks.append(marker)
        defer { composerSendChecks.removeAll { $0.id == marker.id } }
        return await check()
    }

    /// The chat on screen has a send still checking Hermes.
    var composerSendIsChecking: Bool {
        composerSendChecks.contains { check in
            if check.startsChat, isStartingNewChat {
                // The chat this check starts, never one an earlier New Chat made.
                return activeSessionId == nil
                    || (activeSessionId == newChatOpenedSessionID && activeSessionId != check.earlierNewChat)
            }
            return check.sessionID == activeSessionId
                && check.viewportTransitionGeneration == chatViewportTransitionGeneration
        }
    }

    /// A typed message while a turn runs, by `mode`: into the turn, as a
    /// new turn after stopping it, or kept by Hermes as the next turn
    /// (#842), so it goes even if the app closes. Attachments always go
    /// as Queue (#1146): steer and redirect take text alone.
    private func submitWhileBusy(
        _ text: String,
        attachments: [Attachment] = [],
        mode: BusyInputMode,
        context: ComposerSubmissionContext
    ) async -> Bool {
        if !attachments.isEmpty {
            return await sendMessage(text, attachments: attachments, context: context, queued: true)
        }
        // A steer or redirect waits behind an open connect card too.
        if let sessionId = activeSessionId { continueOpenConnections(beforeSendingIn: sessionId) }
        switch mode {
        case .steer:
            return await steer(text, context: context)
        case .interrupt:
            return await redirectOrInterruptAndSend(text, context: context)
        case .queue:
            return await sendMessage(text, context: context, queued: true)
        }
    }

    /// Read-only authoritative correction of a possibly stale local idle
    /// state, OWNED BY THIS SUBMISSION. Returns true when the gateway proves
    /// the session is RUNNING (the caller must use the configured busy
    /// action); false when the session is idle (safe to send a new turn) or
    /// the state could not be verified (do not add RPC chatter — fall through
    /// to the ordinary send, whose typed outcome reconciles). If ownership of
    /// the submission was lost across the probe's await (session/profile
    /// handoff), NOTHING is mutated: the session the user switched to keeps
    /// its own stale marker and will run its own correction.
    private func correctStaleIdleTurnState(
        using submissionContext: ComposerSubmissionContext
    ) async -> Bool {
        guard let client, let sessionId = activeSessionId else {
            // Nothing to probe; leave the stale marker for the real owner.
            return false
        }
        // Capture the probe identity BEFORE the await — never re-derive it
        // from the mutable active session afterwards.
        let acceptedIDs = acceptedIdentitySessionIDs(forRequested: sessionId)
        let evidenceProfile = activeProfile
        let evidenceServerIdentity = defaults.string(forKey: Self.chatResumeServerIdentityKey)
        let rows: [LiveSessionStatus]
        do {
            if let probeActiveSessions = chatResumeLifecycleOperations.probeActiveSessions {
                rows = try await probeActiveSessions(client)
            } else {
                rows = try await client.activeSessions()
            }
            // Currency fence (see probeForegroundRuntime): a server change
            // during the await discards its in-flight rows.
            guard evidenceProfile == activeProfile,
                  defaults.string(forKey: Self.chatResumeServerIdentityKey) == evidenceServerIdentity else {
                lifecycleLog.notice(
                    "submitComposer: stale-idle probe superseded by connection change; no evidence recorded"
                )
                return false
            }
            recordActiveListEvidence(rows, profile: evidenceProfile)
        } catch {
            // The registry could not be read (older gateway, transient
            // failure). Proceed with the ordinary send rather than blocking
            // the user; the submission's own typed outcome will reconcile.
            // The one-time stale clear is submission-owned so an unsupported
            // gateway does not turn every later submit into probe chatter.
            lifecycleLog.notice(
                "submitComposer: stale-idle probe unavailable; proceeding with send session=\(sessionId, privacy: .private(mask: .hash))"
            )
            if isCurrentComposerSubmission(submissionContext) {
                turnStateIsStale = false
            }
            return false
        }
        // Ownership re-check AFTER the await: if the user switched sessions or
        // profiles while the probe was suspended, this result belongs to the
        // OLD conversation and must not mutate the new one's turn state — nor
        // clear its stale marker.
        guard isCurrentComposerSubmission(submissionContext),
              turnState == .idle, turnStateIsStale else {
            lifecycleLog.notice(
                "submitComposer: stale-idle probe superseded by session handoff; no state mutation session=\(sessionId, privacy: .private(mask: .hash))"
            )
            return false
        }
        let row = rows.first(where: {
            acceptedIDs.contains($0.runtimeSessionId) || acceptedIDs.contains($0.storedSessionId)
        })
        if let row, row.isRunning {
            lifecycleLog.notice(
                "submitComposer: authoritative probe=live status=\(row.status, privacy: .public) corrects stale idle session=\(sessionId, privacy: .private(mask: .hash))"
            )
            // setRunning also clears the pending-decision restoration guard,
            // exactly like a live sessionBusy(true) edge would.
            setRunning(true)
            turnStateIsStale = false
            return true
        }
        // Authoritative idle/absent/starting for THIS submission: the local
        // idle state is confirmed and a starting runtime is not committed
        // busy (pre-warm builds report it too), so send as an ordinary new
        // turn — the typed prompt.submit outcome catches a genuine busy race.
        turnStateIsStale = false
        return false
    }
}
