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
        case .sessionInfo(_, let snapshot):
            // Hermes says the turn isn't running: it ended where no event
            // of its end reached here.
            // As the turn's own end does: the words so far stay in the
            // buffer, so a completion after it with no words of its own
            // still settles them as its row.
            guard snapshot.running == false, shownChat.turnState.isRunning else { break }
            settleReasoningSegmentIntoTranscript()
            resetReasoningSegment()
            setRunning(false)
        default:
            break
        }
    }

    /// Ends a left chat's turn as far as this phone knows, with no
    /// completion still to come: its words so far become its row, its flag
    /// goes.
    private func settleKeptChatTurn() {
        settleReasoningSegmentIntoTranscript()
        resetReasoningSegment()
        flushStreamingPartial()
        clearStreamingText()
        setRunning(false)
    }

    /// The socket closed: a left chat's turn is followed no more (a new
    /// socket isn't attached to it, and Hermes doesn't replay its end), so
    /// it stops counting as running and its message box sends again. Its
    /// words so far stay; opening it reads the rest.
    /// Only the chats of the dashboard whose socket closed (the one in
    /// scope by default): another combined dashboard's go on streaming.
    func settleKeptChatTurnsAfterDisconnect(of dashboardID: UUID? = nil) {
        let closed = dashboardID ?? activeDashboardID
        for chat in backgroundChats where chat.isRunning && (closed == nil || chat.dashboardID == closed) {
            act(on: chat) { settleKeptChatTurn() }
        }
        besideChatLive.moved(keeping: backgroundChats)
    }

    /// The chat on screen is being left for `newID` (setActiveSessionState).
    /// While its reply is still coming, its rows and the reply so far are
    /// kept and follow the rest of the reply. A chat being opened stays
    /// followed until its open lands (releaseFollowedChat), so an open that
    /// fails or is overtaken leaves it followed.
    func followLeftChatIfItsReplyRuns(leaving oldID: String?, for newID: String?) {
        guard let oldID, let newID, oldID != newID else { return }
        let ids = followedSessionIDs(forChatOpenAs: oldID)
        // The same conversation under a new runtime id (a resume or a
        // voice thread's rebind) isn't a chat being left.
        guard !isSameConversation(ids, as: newID) else { return }
        // A chat kept beside the next one (the pane or a chat window,
        // keptChatIDs) is followed whether or not a reply runs in it.
        let staysBeside = keptChatIDs.map { !$0.isDisjoint(with: ids) } == true
        // Followed already by a New Chat under way (it follows the chat
        // before its create, and the create's adoption leaves it again):
        // that copy has taken every event since and keeps the chat's own
        // title, where the screen's rows stopped at the create (issue
        // 2523). A reply that ended while the chat was still on screen took
        // the on-screen branch, which leaves the save to the screen; the
        // copy is the complete one, so it's saved now that the chat is
        // left. Any other leave, and the chat kept beside, takes a fresh
        // copy of what's on screen, since what was sent there reached only
        // the screen. Only the copy this run of New Chats followed: one
        // followed before it never took the rows a later open brought to
        // the screen, and saving it would replace the fuller saved copy
        // (issue 2617).
        if !staysBeside, newSessionCreationsInFlight > 0, let run = newChatRunFollowedIDs,
           let chat = followedChat(answering: ids), !chat.sessionIDs.isDisjoint(with: run) {
            if !chat.isRunning { saveBackgroundChatCopy(chat) }
        } else {
            followChatOnScreen(answering: ids, openAs: oldID, turnRunning: turnState == .running, staysBeside: staysBeside)
        }
        // One that couldn't be followed (a saved copy, a room) isn't beside.
        closeBesideChatWithoutItsChat()
    }

    /// A profile switch, or New Chat, leaves the chat on screen. Called
    /// before either changes anything, so the chat is followed under the
    /// profile it belongs to. Both set the turn to synchronizing first, so
    /// the caller says whether the chat's turn was running: one that hasn't
    /// streamed words yet (just sent, or a tool step) is followed too.
    /// Returns the ids it followed, so a New Chat that starts nothing can
    /// let go of them. `joiningCreation`: a New Chat tapped while another's
    /// create is under way, which keeps the copy that one followed.
    @discardableResult
    func followChatBeingLeft(turnWasRunning: Bool, joiningCreation: Bool = false) -> Set<String>? {
        guard let oldID = activeSessionId else { return nil }
        let ids = followedSessionIDs(forChatOpenAs: oldID)
        if joiningCreation, followedChat(answering: ids) != nil { return nil }
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

    /// Hermes has bound `id`, one of the ids `chat` was left with, to
    /// another chat since: the identity index names another conversation
    /// for it, as the kept chat's send target checks (issue 2603).
    func idBoundToAnotherChat(_ id: String, than chat: BackgroundChat) -> Bool {
        if let durable = conversationIdentityIndex.durableID(forRuntime: id, profile: chat.profile), durable != id {
            return !followedChat(chat, isConversation: durable)
        }
        // Not rebound in the index: an id that is another listed chat's own
        // now (an alias the chat kept that Hermes made a chat of its own),
        // or one another row now carries too, isn't this one's either. The
        // catalog is the profile on screen's, so a copy of another
        // profile's chat (or a Bot Chat, with no durable id) goes by its
        // ids alone, as followedChat(_:isConversation:) does.
        guard let own = chat.durableSessionID, chat.profile == activeProfile else { return false }
        if isSharedAlias(id), own != id { return true }
        guard let row = owningSessionRow(for: id) else { return false }
        if row.id == id || row.storedSessionId == id { return !followedChat(chat, isConversation: id) }
        // An alias only another listed chat's row carries now (Hermes moved
        // it there) is that chat's (issue 2655).
        // Its own row unlisted (a page the catalog hasn't read) doesn't make
        // the alias its own either, nor does a row that lists its durable id
        // only as an alias, as this one does (issue 2764).
        guard own != id else { return false }
        guard let ownRow = owningSessionRow(for: own), ownRow.id == own || ownRow.storedSessionId == own else { return true }
        return ownRow.id != row.id
    }

    /// `durable` is `chat`'s own conversation. A listed chat's is its
    /// durable id (or another id of the same row): an alias it was left
    /// with that Hermes later makes a chat of its own isn't it. A chat with
    /// no durable id (a Bot Chat) goes by the ids it answers to.
    func followedChat(_ chat: BackgroundChat, isConversation durable: String) -> Bool {
        guard let own = chat.durableSessionID else { return chat.sessionIDs.contains(durable) }
        if own == durable { return true }
        // Its own row: one whose id or stored id its durable id is, never
        // one that only lists it among its aliases (issue 2764).
        guard chat.profile == activeProfile,
              let durableRow = owningSessionRow(for: durable),
              durableRow.id == durable || durableRow.storedSessionId == durable,
              let ownRow = owningSessionRow(for: own), ownRow.id == own || ownRow.storedSessionId == own else { return false }
        // The same chat under two rows (or a row re-listed under a new
        // runtime id) has one stored id (issue 2767).
        return ownRow.durableKey == durableRow.durableKey
    }

    /// Records the chat on screen's row as it opens (setActiveSessionState).
    /// The same conversation under a new runtime id that no row lists yet
    /// keeps the row it had, judged only by the ids still the chat's: one
    /// Hermes has since handed to another chat doesn't carry the old row
    /// over to it (issue 2764).
    func noteRowOfChatOnScreen(leaving oldID: String?, for newID: String?) {
        guard let newID, !newID.isEmpty else {
            rowOfChatOnScreen = nil
            return
        }
        // A resume onto the same id keeps the recorded row while it's still
        // listed under that id, though another row lists the id too (one
        // Hermes gave it to): the first such row isn't the chat's for it
        // (issue 2767).
        if let kept = rowOfChatOnScreen, kept.dashboardID == activeDashboardID, kept.profile == activeProfile,
           oldID == newID, kept.openIDs.contains(newID) {
            let row = listedRow(kept.row)
            let owners = [sessions, cronSessions].joined().filter { $0.id == newID || $0.storedSessionId == newID }
            if owners.count > 1, owners.contains(where: { $0.durableKey == row.durableKey }) {
                rowOfChatOnScreen = (row, kept.openIDs, kept.dashboardID, kept.profile)
                return
            }
            // A row read with no stored id keeps itself over the one listing
            // under the id when the index binds the id to another chat than
            // that listing's (#2794 review), as `listedRow` refused it.
            if row.storedSessionId == nil, !owners.isEmpty, !owners.contains(where: { $0.durableKey == row.durableKey }),
               let durable = conversationIdentityIndex.durableID(forRuntime: newID, profile: activeProfile),
               owners.allSatisfy({ durable != $0.durableKey && durable != $0.id }) {
                rowOfChatOnScreen = (row, kept.openIDs, kept.dashboardID, kept.profile)
                return
            }
        }
        if let row = owningSessionRow(for: newID) {
            rowOfChatOnScreen = (row, [newID], activeDashboardID, activeProfile)
            return
        }
        if let kept = rowOfChatOnScreen, kept.dashboardID == activeDashboardID, kept.profile == activeProfile,
           let oldID, kept.openIDs.contains(oldID) {
            let row = listedRow(kept.row)
            // Its own and stored ids and the ids it was open under, still
            // its: never an alias, which may be a chat of its own (issue 2764).
            let ownIDs = Set([row.id, row.storedSessionId].compactMap { $0 }).union(kept.openIDs)
            let chatIDs = idsStillTheChat(ofRow: row, openIDs: kept.openIDs).intersection(ownIDs)
            // The id it was left under is still its, or Hermes bound the new
            // one to its own or stored id.
            let newDurable = conversationIdentityIndex.durableID(forRuntime: newID, profile: activeProfile)
            let boundToRow = newDurable.map { $0 == row.id || $0 == row.storedSessionId } == true
            // The same id again (a resume onto it) stays the chat's while it's still its.
            let same = oldID == newID && chatIDs.contains(newID)
            if same || ((chatIDs.contains(oldID) || boundToRow) && isSameConversation(chatIDs, as: newID)) {
                rowOfChatOnScreen = (row, kept.openIDs.union([newID]), kept.dashboardID, kept.profile)
                return
            }
        }
        rowOfChatOnScreen = nil
    }

    /// A chat restored or opened before the catalog listed its row (a
    /// restore with an empty catalog) records the row once a catalog
    /// commit lists it (issue 2764).
    /// A recorded row the catalog lists again is kept as it's listed now.
    func noteRowOfChatOnScreenOnceListed() {
        if let recorded = rowOfChatOnScreen {
            guard recorded.dashboardID == activeDashboardID, recorded.profile == activeProfile else { return }
            let listed = listedRow(recorded.row)
            if listed != recorded.row { rowOfChatOnScreen?.row = listed }
            return
        }
        guard let id = activeSessionId, !id.isEmpty, let row = owningSessionRow(for: id) else { return }
        rowOfChatOnScreen = (row, [id], activeDashboardID, activeProfile)
    }

    /// `row` as the catalog lists it now, else as it was read. A row under
    /// the same id with another stored id is another chat's, which Hermes
    /// gave the runtime id to (issue 2764).
    /// A listing with no stored id keeps the one it was read with. A row
    /// read with none takes a listing's only while the identity index binds
    /// the row's id to no other chat: a listing under that id may be the
    /// chat Hermes gave it to (issue 2767).
    private func listedRow(_ row: SessionSummary) -> SessionSummary {
        let durable = conversationIdentityIndex.durableID(forRuntime: row.id, profile: activeProfile)
        guard var listed = [sessions, cronSessions].joined().first(where: { listed in
            guard listed.id == row.id else { return false }
            guard let listedStored = listed.storedSessionId else { return true }
            guard let readStored = row.storedSessionId else {
                return durable.map { $0 == row.id || $0 == listedStored } ?? true
            }
            return listedStored == readStored
        }) else { return row }
        if listed.storedSessionId == nil { listed.storedSessionId = row.storedSessionId }
        return listed
    }

    /// The ids other chats than `row`'s answer to: the other listed rows'
    /// (sessionIDsOfOtherRows), and a listed row's under `row`'s own id
    /// with another stored id, the chat Hermes gave that runtime id to
    /// (issue 2764).
    private func idsOfOtherChats(than row: SessionSummary) -> Set<String> {
        let reused = [sessions, cronSessions].joined().filter { listed in
            listed.id == row.id && listed.storedSessionId != nil && row.storedSessionId != nil
                && listed.storedSessionId != row.storedSessionId
        }
        return sessionIDsOfOtherRows(than: row).union(reused.flatMap(\.nestingIDs))
            .subtracting([row.storedSessionId].compactMap { $0 })
    }

    /// The ids of `row`'s chat, with the ids it was open under, that are
    /// still its: none another listed row answers to, nor one the identity
    /// index has bound to a conversation outside them.
    private func idsStillTheChat(ofRow row: SessionSummary, openIDs: Set<String>) -> Set<String> {
        let others = idsOfOtherChats(than: row)
        let ids = Set(row.nestingIDs).union(openIDs).subtracting(others)
        let index = conversationIdentityIndex
        let profile = activeProfile
        return ids.filter { id in
            guard let durable = index.durableID(forRuntime: id, profile: profile) else { return true }
            return ids.contains(durable)
        }
    }

    /// The row of the chat open as `id`: the one recorded when the chat on
    /// screen opened, as listed now or else as it was read (a row that
    /// left the catalog stays the chat's, never the row of a chat Hermes
    /// later gave its id to), else the row that owns the id now (issues
    /// 2655 and 2764).
    func rowOfChat(openAs id: String) -> SessionSummary? {
        if id == activeSessionId, let recorded = rowOfChatOnScreen, recorded.openIDs.contains(id),
           recorded.dashboardID == activeDashboardID, recorded.profile == activeProfile {
            return listedRow(recorded.row)
        }
        return owningSessionRow(for: id)
    }

    /// The ids a followed copy of the chat open as `id` answers to, from
    /// the row it opened as: `id` itself is left out once another listed
    /// chat owns it or carries it too (issue 2655).
    func followedSessionIDs(forChatOpenAs id: String) -> Set<String> {
        guard let row = rowOfChat(openAs: id) else { return [id] }
        let others = idsOfOtherChats(than: row)
        let own = Set(row.nestingIDs.filter { !others.contains($0) })
        return others.contains(id) ? own : own.union([id])
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
        // Its own row, never one that only borrows its id (issue 2602), and
        // the one it opened as, never a chat Hermes since handed its id to.
        let listed = rowOfChat(openAs: oldID)
        let isBotChat = botStoreProfile(forSessionIDs: Array(ids)) != nil
            || botConversationProfile(for: oldID) != nil
        let others = listed.map { idsOfOtherChats(than: $0) } ?? []
        let ownIDs = listed.map { Set($0.nestingIDs).subtracting(others) }
        // The chat the screen's id stands for in the identity index is
        // this one: kept, so a later rebind of one of its ids to another
        // chat shows as one (issue 2603). Not when the index has already
        // bound it to a chat other than its own row's.
        let indexed = conversationIdentityIndex.durableID(forRuntime: oldID, profile: activeProfile)
            .flatMap { durable in ownIDs.map { $0.contains(durable) ? durable : nil } ?? durable }
        // What the caller passed, less any id another listed row owns or
        // carries too, so a borrowed or shared id never reaches this copy.
        let chat = BackgroundChat(
            sessionIDs: ids.union(ownIDs ?? []).union([indexed].compactMap { $0 }).subtracting(others),
            durableSessionID: isBotChat ? nil : listed.map { $0.storedSessionId ?? $0.id },
            title: activeSessionTitle,
            dashboardID: dashboardID,
            profile: activeProfile,
            isBotChat: isBotChat,
            botChatCopyOwner: isBotChat
                ? ChatResumeStore.rpcProfileName(botChatCopyOwner(openAs: oldID))
                    .map { BackgroundChat.BotChatCopyOwner(bot: $0, openAs: oldID) }
                : nil,
            state: leftChatState(turnRunning: turnRunning)
        )
        backgroundChats = BackgroundChat.adding(chat, to: currentBackgroundChats(), keeping: keptChatIDs)
        if staysBeside { besideChatLive.moved(keeping: backgroundChats) }
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

    /// The followed chats of the dashboard acted on, any of its profiles
    /// (a profile switch leaves one), and of the other live dashboards (the
    /// one on screen, kept ones): a chat left on another combined
    /// dashboard's runtime follows on there (no-switch stage 2). Those of a
    /// dashboard no longer connected are let go.
    func currentBackgroundChats() -> [BackgroundChat] {
        backgroundChats.filter {
            $0.dashboardID == activeDashboardID || $0.dashboardID == dashboardIDOnScreen
                || keptDashboardRuntimes[$0.dashboardID] != nil
        }
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
        var onScreen = eventBelongsToActiveSession(id)
        // A rebound id reaches the followed copy on screen too, as its own
        // ids do, so the copy is current if the open is overtaken.
        // An id it was left with that Hermes has since bound to another
        // chat reaches that chat's copy, never this one (issue 2603).
        // The dashboard in scope's own chat first: one id can name chats on
        // two Hermes, each followed on its own runtime.
        let answers: (BackgroundChat) -> Bool = { $0.answers(to: id) && !self.idBoundToAnotherChat(id, than: $0) }
        let ownIndex = backgroundChats.firstIndex(where: { $0.dashboardID == self.activeDashboardID && answers($0) })
            ?? backgroundChats.firstIndex(where: answers)
        guard let index = ownIndex ?? followedChatIndex(reboundTo: id) else { return false }
        let chat = backgroundChats[index]
        // Hermes bound the chat being opened to a new runtime id while it
        // was away, and its events arrive under that id before the open
        // knows it: they're the screen's too, so the open's reconcile
        // buffer takes them as well as the copy (issue 2503).
        if !onScreen, ownIndex == nil, let activeSessionId, chat.profile == activeProfile,
           !chat.sessionIDs.isDisjoint(with: knownSessionIDs(for: activeSessionId).union([activeSessionId])) {
            onScreen = true
            // The open's reconcile accepts it from now on, across the
            // resume's narrowing too, so the screen gets it live or replayed.
            if var open = reconciliation {
                open.reboundSessionIDs[id] = activeSessionId
                open.acceptedSessionIDs.insert(id)
                reconciliation = open
            }
        }
        guard chat.dashboardID == activeDashboardID else {
            // Another live dashboard's chat follows on its own runtime's
            // events; one whose dashboard is gone is let go.
            if chat.dashboardID != dashboardIDOnScreen, keptDashboardRuntimes[chat.dashboardID] == nil {
                backgroundChats.remove(at: index)
            }
            return false
        }
        if onScreen {
            // The chat on screen saves its own copy, once its open lands.
            let wasRunning = chat.isRunning
            act(on: chat) { applyLeftChatEvent(event, sessionID: id) }
            // Still showing the followed copy while its open is in flight:
            // the screen has recorded nothing newer, and a leave before the
            // open lands keeps nothing of the screen's, so the copy's
            // finished reply is saved now (issue 2577).
            var isCompletion = false
            if case .messageComplete = event { isCompletion = true }
            if offlineChatPresentation != nil, !chat.isRunning, wasRunning || isCompletion, !predatesNewChatRun(chat) {
                saveBackgroundChatCopy(chat)
            }
            return false
        }
        let wasRunning = chat.isRunning
        act(on: chat) { applyLeftChatEvent(event, sessionID: id) }
        if keptChatIDs.map({ !chat.sessionIDs.isDisjoint(with: $0) }) == true {
            besideChatLive.moved(chat)
            // A turn sent from its message box has a Live Activity too.
            LiveTurnActivities.shared?.observe(event, sessionID: id)
            noteKeptChatEvent(chat, sessionID: id)
        }
        // Saved as its turn ends, and again for a completion that lands
        // after the turn's end (sessionBusy came first), whose final row
        // takes the cut-off words' place.
        var isCompletion = false
        if case .messageComplete = event { isCompletion = true }
        if !chat.isRunning, wasRunning || isCompletion, !predatesNewChatRun(chat) {
            saveBackgroundChatCopy(chat)
        }
        return true
    }

    /// A copy followed before the New Chat run under way, which never took
    /// the rows a later open brought to the screen: its save would replace
    /// the fuller saved copy, so it isn't saved while the run's create is
    /// under way (issue 2617, from #2645's review; issue 2655).
    func predatesNewChatRun(_ chat: BackgroundChat) -> Bool {
        guard newSessionCreationsInFlight > 0 else { return false }
        guard let run = newChatRunFollowedIDs else { return true }
        return chat.sessionIDs.isDisjoint(with: run)
    }

    /// The followed chat a runtime id Hermes bound while it was away
    /// belongs to (another device resumed it, say), by the conversation
    /// index. Looked up on every event and never kept, so an id the index
    /// later binds to another chat stops reaching this one.
    /// A rebound id the open's reconcile took for the chat it was routed for
    /// stops being accepted once the identity index binds it to another
    /// chat, so that chat's words and cards never reach this open (#2610's
    /// review). Run on every event before a followed chat takes it, so a
    /// rebind to a chat that is itself followed is noticed too. Its words
    /// buffered so far stay out of the replay with it, and a side agent's
    /// completion held for it is let go.
    @discardableResult
    func dropReboundIDIfMovedOn(_ id: String) -> Bool {
        guard var open = reconciliation, let routedFor = open.reboundSessionIDs[id] else { return false }
        let index = conversationIdentityIndex
        // Kept while the index still binds it there, or no longer knows it.
        guard let durableID = index.durableID(forRuntime: id, profile: activeProfile) else { return false }
        // The index's own binding for the chat it was routed for wins; the
        // catalog row's ids, its stored id included, stand in when the index
        // doesn't know that chat (or the row is away mid-refresh).
        if let routedDurableID = index.durableID(forRuntime: routedFor, profile: activeProfile) {
            guard routedDurableID != durableID else { return false }
        } else {
            let row = [sessions, cronSessions].joined().first { $0.nestingIDs.contains(routedFor) }
            let routedIDs = knownSessionIDs(for: routedFor).union([routedFor]).union(row?.nestingIDs ?? [])
            guard !routedIDs.contains(durableID) else { return false }
        }
        open.reboundSessionIDs[id] = nil
        open.acceptedSessionIDs.remove(id)
        open.movedOnSessionIDs.insert(id)
        reconciliation = open
        shownChat.heldSideAgentCompletions.removeAll { sessionID(for: $0) == id }
        return true
    }

    func followedChatIndex(reboundTo id: String) -> Int? {
        let index = conversationIdentityIndex
        let matches: (BackgroundChat) -> Bool = { chat in
            guard let durableID = index.durableID(forRuntime: id, profile: chat.profile) else { return false }
            return self.followedChat(chat, isConversation: durableID)
        }
        // The dashboard in scope's first: one id can name chats on two Hermes.
        return backgroundChats.firstIndex { $0.dashboardID == activeDashboardID && matches($0) }
            ?? backgroundChats.firstIndex(where: matches)
    }

    /// A finished reply's rows become the chat's saved copy, so it shows
    /// even once the chat is no longer followed. A Bot Chat's go to its own
    /// copy (`keepBotChatCopy`), never a profile's saved chats, and the copy
    /// doesn't become the one a cold launch shows first.
    private func saveBackgroundChatCopy(_ chat: BackgroundChat) {
        if chat.isBotChat {
            guard let owner = chat.botChatCopyOwner else { return }
            keepBotChatCopy(
                of: chat.rows,
                bot: owner.bot,
                dashboardID: chat.dashboardID,
                sessionIDs: chat.sessionIDs,
                openAs: owner.openAs,
                title: chat.title
            )
            return
        }
        guard let durableSessionID = chat.durableSessionID else { return }
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
