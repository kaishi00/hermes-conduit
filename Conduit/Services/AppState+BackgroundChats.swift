//
//  AppState+BackgroundChats.swift
//  Conduit
//
//  A chat left while its reply was still coming keeps following that reply
//  (all-live stage 2, BackgroundChat.swift): its own state takes the rest of
//  its turn as it streams on the shared socket, and going back to it shows
//  its rows at once.
//

import Foundation

/// The left chat the app acts on while one of its events applies
/// (`AppState.act(on:)`): who it is, in place of the chat on screen's ids
/// and profile.
struct LiveChatScope: Equatable {
    let sessionIDs: Set<String>
    let profile: String
}

extension AppState {
    /// Whether the app acts on the chat on screen, as it does except while
    /// a left chat's event applies to that chat (`act(on:)`). What a turn
    /// does to the screen, rather than to its chat, checks this: Voice,
    /// haptics, Read Aloud, suggested replies, the saved presentation, the
    /// viewport, the message waiting to send.
    var actingOnChatOnScreen: Bool { liveChatScope == nil }

    /// The profile of the chat acted on, which a left chat's rows are
    /// written by: a profile switch can leave one in another profile.
    var actingProfile: String { liveChatScope?.profile ?? activeProfile }

    /// Runs `body` with `chat`'s own state as the chat acted on, so the
    /// stream handling written for the chat on screen applies to it.
    /// Nothing awaits inside, so nothing on screen draws in between.
    func act(on chat: BackgroundChat, _ body: () -> Void) {
        let screen = shownChat
        let scope = liveChatScope
        shownChat = chat.state
        liveChatScope = LiveChatScope(sessionIDs: chat.sessionIDs, profile: chat.profile)
        defer {
            shownChat = screen
            liveChatScope = scope
        }
        body()
    }

    /// Applies a left chat's event to its own state (inside `act(on:)`):
    /// its reply's words, thinking and tool steps, through the same steps
    /// as the chat on screen. The model, context and other runtime events
    /// are the chat on screen's, and decision cards show once Hermes' rows
    /// land.
    private func applyLeftChatEvent(_ event: StreamEvent, sessionID: String) {
        switch event {
        case .messageStart:
            finalizePendingStreamingCompletion()
            settleReasoningSegmentIntoTranscript()
            resetReasoningTurn()
            keepWordsOfAnUnfinishedReply()
            setRunning(true)
        case .messageDelta(_, let text):
            finalizePendingStreamingCompletion()
            shownChat.streamingBuffer += text
            setRunning(true)
        case .messageInterim(_, let text, let alreadyStreamed):
            finalizePendingStreamingCompletion()
            settleReasoningSegmentIntoTranscript()
            resetReasoningSegment()
            sealInterimCommentary(text, alreadyStreamed: alreadyStreamed)
            setRunning(true)
        case .reasoningDelta(_, let text):
            finalizePendingStreamingCompletion()
            shownChat.receivedReasoningForCurrentTurn = true
            appendReasoning(text)
            setRunning(true)
        case .messageComplete(_, let messageId, let content, let reasoning, let alreadyShown):
            // Settles at once off screen: no tail to drain.
            scheduleStreamingCompletion(
                sessionId: sessionID,
                messageId: messageId,
                content: content,
                reasoning: reasoning,
                alreadyShown: alreadyShown
            )
        case .messageError, .messageInterrupted:
            // A reply that never finished keeps the words that came.
            settleReasoningSegmentIntoTranscript()
            resetReasoningTurn()
            flushStreamingPartial()
            clearStreamingText()
            setRunning(false)
        case .sessionBusy(_, let busy):
            if busy {
                // A turn starting in the chat kept beside the one on screen,
                // before any word of it: the pane says it works, and
                // closing the pane goes on following the reply. Any other
                // left chat's turn only ever ends.
                if actingOnBesideChat, !shownChat.turnState.isRunning { setRunning(true) }
                break
            }
            // The end of its turn.
            guard shownChat.turnState.isRunning else { break }
            settleReasoningSegmentIntoTranscript()
            // The segment ends, the turn's flag stays: a completion that
            // carries the reasoning already streamed mustn't add it again.
            resetReasoningSegment()
            // The words so far stay the reply's: a completion that comes
            // after with no words of its own settles them as its row.
            setRunning(false)
        case .toolStart(_, let name, let input, let eventToolID):
            applyToolStart(name: name, input: input, eventToolID: eventToolID, streamSessionId: sessionID)
        case .toolComplete(_, let name, let output, let eventToolID):
            applyToolComplete(name: name, output: output, eventToolID: eventToolID, streamSessionId: sessionID)
        default:
            break
        }
    }

    /// The chat on screen is being left for `newID` (setActiveSessionState).
    /// While its reply is still coming, its rows and the reply so far are
    /// kept and follow the rest of the reply. A chat being opened stays
    /// followed until its open lands (releaseFollowedChat), so an open that
    /// fails or is overtaken leaves it followed.
    func followLeftChatIfItsReplyRuns(leaving oldID: String?, for newID: String?) {
        guard let oldID, let newID, oldID != newID else { return }
        let ids = knownSessionIDs(for: oldID).union([oldID])
        // The same conversation under a new runtime id (a resume or a
        // voice thread's rebind) isn't a chat being left.
        guard !isSameConversation(ids, as: newID) else { return }
        // The chat picked to stay beside the next one is followed whether
        // or not a reply runs in it.
        let staysBeside = keptChatIDs.map { !$0.isDisjoint(with: ids) } == true
        followChatOnScreen(answering: ids, openAs: oldID, turnRunning: turnState == .running, staysBeside: staysBeside)
        // One that couldn't be followed (a saved copy, a room) isn't beside.
        closeBesideChatWithoutItsChat()
    }

    /// A profile switch, or New Chat, leaves the chat on screen. Called
    /// before either changes anything, so the chat is followed under the
    /// profile it belongs to. Both set the turn to synchronizing first, so
    /// the caller says whether the chat's turn was running: one that hasn't
    /// streamed words yet (just sent, or a tool step) is followed too.
    /// Returns the ids it followed, so a New Chat that starts nothing can
    /// let go of them.
    @discardableResult
    func followChatBeingLeft(turnWasRunning: Bool) -> Set<String>? {
        guard let oldID = activeSessionId else { return nil }
        let ids = knownSessionIDs(for: oldID).union([oldID])
        let before = backgroundChats
        followChatOnScreen(answering: ids, openAs: oldID, turnRunning: turnWasRunning)
        return backgroundChats == before ? nil : ids
    }

    /// The chat a profile switch opens on, when it's one a switch left
    /// mid-reply: its rows and the reply so far show. It stays followed
    /// until the switch lands (releaseFollowedChatOnScreen), so a switch
    /// that fails or that a newer navigation overtakes leaves it followed.
    /// False when it isn't one.
    func presentFollowedChatAfterProfileChange(_ sessionID: String) -> Bool {
        // Only a switch that shows a followed copy has one to release; an
        // earlier switch that never landed leaves none behind.
        followedChatShownBySwitch = nil
        guard let left = followedChat(answering: knownSessionIDs(for: sessionID).union([sessionID])) else {
            return false
        }
        guard presentBackgroundChat(left, openedAs: sessionID) else { return false }
        // Released by its own ids: the switch's resume can move the chat on
        // screen to a runtime id the entry never knew.
        followedChatShownBySwitch = left.sessionIDs
        return true
    }

    /// The chat a profile switch showed from a followed copy, once the
    /// switch lands on it, is followed no longer: its own transcript has
    /// taken over.
    func releaseFollowedChatOnScreen() {
        guard let ids = followedChatShownBySwitch else { return }
        followedChatShownBySwitch = nil
        releaseFollowedChat(answering: ids)
    }

    /// The followed chat of this dashboard and profile that answers to any
    /// of `ids`, left on the list: an open shows it while it loads.
    func followedChat(answering ids: Set<String>) -> BackgroundChat? {
        backgroundChats.first {
            $0.dashboardID == activeDashboardID && $0.profile == activeProfile
                && !$0.sessionIDs.isDisjoint(with: ids)
        }
    }

    /// The chat an open (or a switch) landed on is followed no longer: the
    /// one of this dashboard and profile that answers to any of `ids`, as
    /// `followedChat(answering:)` finds it. An open that lands after a switch
    /// to another dashboard leaves the first dashboard's chat followed.
    func releaseFollowedChat(answering ids: Set<String>) {
        backgroundChats.removeAll {
            $0.dashboardID == activeDashboardID && $0.profile == activeProfile
                && !$0.sessionIDs.isDisjoint(with: ids)
        }
        // The chat beside the one on screen, opened there, is beside no longer.
        closeBesideChatWithoutItsChat()
    }

    private func isSameConversation(_ ids: Set<String>, as newID: String) -> Bool {
        if ids.contains(newID) { return true }
        let index = conversationIdentityIndex
        let profile = activeProfile
        let durableIDs = Set(ids.compactMap { index.durableID(forRuntime: $0, profile: profile) })
        if durableIDs.contains(newID) { return true }
        guard let newDurableID = index.durableID(forRuntime: newID, profile: profile) else { return false }
        return durableIDs.contains(newDurableID) || ids.contains(newDurableID)
    }

    /// `staysBeside`: the chat stays beside the next one, so it's followed
    /// with no reply running too.
    func followChatOnScreen(answering ids: Set<String>, openAs oldID: String, turnRunning: Bool, staysBeside: Bool = false) {
        guard isConnected,
              staysBeside || turnRunning || !shownChat.streamingBuffer.isEmpty,
              offlineChatPresentation == nil,
              activeRoomSurface == nil,
              !messages.isEmpty || !shownChat.streamingBuffer.isEmpty,
              let dashboardID = activeDashboardID else { return }
        let listed = (sessions + cronSessions).first { session in
            ids.contains(session.id)
                || session.storedSessionId.map(ids.contains) == true
                || !ids.isDisjoint(with: session.alternateIds)
        }
        let isBotChat = botStoreProfile(forSessionIDs: Array(ids)) != nil
            || botConversationProfile(for: oldID) != nil
        let chat = BackgroundChat(
            sessionIDs: ids.union(listed?.nestingIDs ?? []),
            durableSessionID: isBotChat ? nil : listed.map { $0.storedSessionId ?? $0.id },
            title: activeSessionTitle,
            dashboardID: dashboardID,
            profile: activeProfile,
            isBotChat: isBotChat,
            state: leftChatState(turnRunning: turnRunning)
        )
        backgroundChats = BackgroundChat.adding(chat, to: currentBackgroundChats(), keeping: keptChatIDs)
        if staysBeside { besideChatLive.moved() }
        // A reply that finished while its last words drained on screen
        // settles in the left chat's own rows.
        if chat.state.pendingStreamingCompletion != nil {
            act(on: chat) { finalizePendingStreamingCompletion(cancelResponseHapticConclusion: false) }
            saveBackgroundChatCopy(chat)
        }
    }

    /// A new turn on a left chat whose last reply never completed (its
    /// turn ended without a completion): those words stay as a row of
    /// their own rather than running into the new reply.
    private func keepWordsOfAnUnfinishedReply() {
        // Words a tool step cut off before it ended are the reply's too:
        // the next completion removes partials, so they become its rows.
        if messages.contains(where: { $0.role == .partial }) {
            messages = messages.map { row in
                guard row.role == .partial else { return row }
                var kept = ChatMessage(id: row.id, role: .assistant, content: row.content, timestamp: row.timestamp, author: row.author ?? actingProfile)
                kept.reasoning = row.reasoning
                return kept
            }
        }
        let words = shownChat.streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        messages.append(ChatMessage(
            id: "assistant-\(Date().timeIntervalSince1970)",
            role: .assistant,
            content: words,
            timestamp: Self.localTimestamp(),
            author: actingProfile
        ))
        clearStreamingText()
    }

    /// A state of its own for the chat on screen as it's left mid-reply:
    /// its rows and its turn as far as it got, the reply streaming, the
    /// thinking card live, the interim notes and a completion still
    /// draining. The screen's own state then goes on to the next chat.
    private func leftChatState(turnRunning: Bool) -> ChatState {
        let screen = shownChat
        let left = ChatState()
        left.messages = screen.messages
        left.streamingBuffer = screen.streamingBuffer
        left.activeAssistantMessageId = screen.activeAssistantMessageId
        left.interimRowID = screen.interimRowID
        left.runningTurnNoteIDs = screen.runningTurnNoteIDs
        left.receivedReasoningForCurrentTurn = screen.receivedReasoningForCurrentTurn
        left.reasoningBuffer = screen.reasoningBuffer
        left.activeReasoningMessageId = screen.activeReasoningMessageId
        left.liveTurn.reasoningSegment = screen.liveTurn.reasoningSegment
        left.pendingStreamingCompletion = screen.pendingStreamingCompletion
        // Its reply is still coming, whether or not it has words yet; one
        // only draining its last words has finished.
        // A chat kept beside the next one may have no reply at all.
        let replyStreams = !screen.streamingBuffer.isEmpty && screen.pendingStreamingCompletion == nil
        left.turnState = (turnRunning || replyStreams) ? .running : .idle
        return left
    }

    /// The followed chats of the dashboard on screen, any of its profiles
    /// (a profile switch leaves one); other dashboards' are let go.
    func currentBackgroundChats() -> [BackgroundChat] {
        backgroundChats.filter { $0.dashboardID == activeDashboardID }
    }

    /// Applies a stream event of a chat that was left mid-reply. True when
    /// the event was that chat's, so nothing else takes it: not the chat
    /// on screen, and not an open reconcile, which accepts any chat's
    /// events until it knows its own. A followed chat that is on screen
    /// again (its open hasn't landed yet) takes its events too, so it's
    /// current if the open is overtaken, and the screen still gets them.
    func applyBackgroundChatEvent(_ event: StreamEvent) -> Bool {
        guard !backgroundChats.isEmpty else { return false }
        let id = sessionID(for: event)
        guard !id.isEmpty else { return false }
        let onScreen = eventBelongsToActiveSession(id)
        // A rebound id reaches the followed copy on screen too, as its own
        // ids do, so the copy is current if the open is overtaken.
        guard let index = backgroundChats.firstIndex(where: { $0.answers(to: id) })
            ?? followedChatIndex(reboundTo: id) else { return false }
        let chat = backgroundChats[index]
        guard chat.dashboardID == activeDashboardID else {
            backgroundChats.remove(at: index)
            return false
        }
        if onScreen {
            // The chat on screen saves its own copy.
            act(on: chat) { applyLeftChatEvent(event, sessionID: id) }
            return false
        }
        let wasRunning = chat.isRunning
        act(on: chat) { applyLeftChatEvent(event, sessionID: id) }
        if keptChatIDs.map({ !chat.sessionIDs.isDisjoint(with: $0) }) == true { besideChatLive.moved() }
        // Saved as its turn ends, and again for a completion that lands
        // after the turn's end (sessionBusy came first), whose final row
        // takes the cut-off words' place.
        var isCompletion = false
        if case .messageComplete = event { isCompletion = true }
        if !chat.isRunning, wasRunning || isCompletion {
            saveBackgroundChatCopy(chat)
        }
        return true
    }

    /// The followed chat a runtime id Hermes bound while it was away
    /// belongs to (another device resumed it, say), by the conversation
    /// index. Looked up on every event and never kept, so an id the index
    /// later binds to another chat stops reaching this one.
    private func followedChatIndex(reboundTo id: String) -> Int? {
        let index = conversationIdentityIndex
        return backgroundChats.firstIndex { chat in
            guard let durableID = index.durableID(forRuntime: id, profile: chat.profile) else { return false }
            return chat.sessionIDs.contains(durableID) || chat.durableSessionID == durableID
        }
    }

    /// A finished reply's rows become the chat's saved copy, so it shows
    /// even once the chat is no longer followed. A Bot Chat keeps no copy
    /// on the phone (`keepBotChatCopy`), and the copy doesn't become the one
    /// a cold launch shows first.
    private func saveBackgroundChatCopy(_ chat: BackgroundChat) {
        guard !chat.isBotChat, let durableSessionID = chat.durableSessionID else { return }
        offlineChatCache.record(
            dashboardID: chat.dashboardID,
            profile: chat.profile,
            sessionID: durableSessionID,
            identities: chat.sessionIDs,
            title: chat.title,
            messages: chat.rows,
            // The list on screen is another scope's when the chat was left
            // by a profile switch: the copy then keeps its scope's own list.
            sessions: chat.profile == activeProfile ? sessions : [],
            becomesLastOpened: false
        )
    }

    /// Stops following the chats on `dashboardID` (every dashboard when
    /// nil) that answer to any of `sessionIDs` (all of them when nil): a
    /// deleted chat, a removed dashboard, a sign-out, Delete saved chats. Its
    /// reply's end then saves nothing.
    func stopFollowingChats(dashboardID: UUID?, sessionIDs: Set<String>? = nil) {
        backgroundChats.removeAll { chat in
            (dashboardID == nil || chat.dashboardID == dashboardID)
                && sessionIDs.map { !chat.sessionIDs.isDisjoint(with: $0) } != false
        }
        closeBesideChatWithoutItsChat()
    }

    /// Shows a followed chat's rows while it opens, as a saved copy shows
    /// (#1352): Hermes' rows replace them once they land. False when there
    /// is nothing to show here, so the open shows its saved copy instead.
    func presentBackgroundChat(_ chat: BackgroundChat, openedAs sessionID: String) -> Bool {
        guard chat.dashboardID == activeDashboardID,
              chat.profile == activeProfile,
              messages.isEmpty else { return false }
        let rows = OfflineChatCacheStore.keptRows(of: chat.rows)
        guard !rows.isEmpty else { return false }
        // Under the id the chat's saved copy and draft are kept by: a Bot
        // Chat's own id, as its kept copy is shown (presentKeptBotChatCopy).
        let durableSessionID = chat.durableSessionID ?? sessionID
        offlineChatPresentation = OfflineChatPresentation(
            dashboardID: chat.dashboardID,
            profile: chat.profile,
            snapshot: OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: []),
            displayedTranscript: OfflineCachedTranscript(
                sessionID: durableSessionID,
                title: chat.title,
                savedAt: Date(),
                messages: rows
            ),
            picked: OfflineChatPresentation.PickedChat(
                title: chat.title,
                sessionIDs: chat.sessionIDs.union([sessionID]),
                durableSessionID: durableSessionID
            )
        )
        return true
    }
}
