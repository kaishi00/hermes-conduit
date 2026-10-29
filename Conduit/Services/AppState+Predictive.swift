//
//  AppState+Predictive.swift
//  Conduit
//
//  Settings > Chat > Predictive (Predictive.swift): suggested replies once
//  a reply settles, guesses for a paused draft, and Hermes following up
//  while the chat sits on screen. Each question goes to the plugin's
//  `POST /predict`, which answers only this device.
//

import Foundation

@MainActor
extension AppState {
    /// Whether the connected plugin answers predictions.
    var predictiveIsServed: Bool {
        predictiveSender != nil || notifierPlugin.reports(Predictive.capability)
    }

    /// The open chat's last reply, while guesses may show for it: the chat
    /// on screen with Conduit in front, nothing running, no call, and its
    /// last row a reply (not a question or an approval Hermes waits on).
    var predictiveAnchor: PredictiveStore.Anchor? {
        guard predictiveIsServed, isSceneActive, !showSidebar, activeRoomSurface == nil,
              let sessionID = activeSessionId, !sessionID.isEmpty,
              composerChatOnScreen == .live(sessionID),
              !isBusy, !turnState.isRunning, !isVoiceInUse,
              let last = messages.last, last.role == .assistant,
              last.content.contains(where: { !$0.isWhitespace }),
              // A system notice merged into the last row isn't a reply to answer.
              MessageNormalizer.systemNoticeText(fromText: last.rawContent ?? last.content) == nil else { return nil }
        return PredictiveStore.Anchor(sessionID: sessionID, messageID: last.id)
    }

    /// On each change of the open chat, the scene and the turn
    /// (updateChatOnScreen): the row follows what is on screen, and a new
    /// reply is asked about.
    /// `fresh`: the screen changed for the user (a new reply, the chat
    /// opened or back in front), so the idle time starts over. A turn that
    /// ended without a reply of its own returns to the reply it left.
    func updatePredictiveScreen(fresh: Bool = true) {
        // Left the chat Hermes was following up in (another chat, the
        // sidebar, a room, Conduit in the background): its reply is no
        // longer watched, so it neither holds pushes nor gets the tag.
        if let turn = predictiveFollowUpTurn,
           turn.sessionID != activeSessionId || !isSceneActive || showSidebar || activeRoomSurface != nil {
            predictiveFollowUpTurn = nil
            predictiveFollowUpQueued = false
        }
        let anchor = predictiveAnchor
        let previous = predictive.screen
        predictive.setScreen(anchor)
        guard anchor != previous else { return }
        stopPredictiveFollowUpClock()
        guard let anchor else { return }
        // Back on screen: the idle time counts from now.
        if fresh || predictiveFollowUp.anchor != anchor { predictiveFollowUp.idleSince = Date() }
        requestPredictedReplies(for: anchor)
        startPredictiveFollowUpClock(for: anchor)
    }

    /// A turn settled. `isReply`: it ended in a reply of its own, not a
    /// system notice merged into the last row.
    func predictiveTurnSettled(sessionId: String, isReply: Bool = true) {
        if let turn = predictiveFollowUpTurn, turn.sessionID == sessionId,
           predictiveFollowUpQueued || predictiveFollowUpSending {
            // The turn the follow-up waited behind: the next one is Hermes'.
            predictiveFollowUpQueued = false
            if predictiveFollowUpSending { predictiveFollowUpAheadEnded = true }
            predictiveFollowUpTurn = (sessionId, turn.why, messages.last?.id)
        } else if let turn = predictiveFollowUpTurn, turn.sessionID == sessionId,
                  let queuedAt = predictiveFollowUpQueuedAt,
                  Self.messagesSentAhead(after: turn.after, before: queuedAt, noted: predictiveFollowUpUnreadMessages,
                                         in: messages) > predictiveFollowUpTurnsAhead {
            // A message someone sent before the hidden prompt was queued
            // (another client's, ahead of it) wrote this reply, not Hermes on
            // its own: the follow-up's turn is still to come, up to a few
            // turns on. One sent later runs after the follow-up. `after`
            // stays put: each such message's reply is counted off once, in
            // whatever order its row and the replies arrived.
            // A turn that ends in a notice counts too: it answered their
            // message, not the hidden prompt.
            predictiveFollowUpTurnsAhead += 1
            if predictiveFollowUpTurnsAhead > Self.predictiveFollowUpMaximumTurnsAhead {
                predictiveFollowUpTurn = nil
            }
        } else if let turn = predictiveFollowUpTurn, turn.sessionID == sessionId,
                  predictiveFollowUpUnreadMessages.contains(where: { row in !messages.contains { $0.rowId == row } })
                    || turn.after.map({ id in !messages.contains { $0.id == id } }) == true {
            // Someone sent a message elsewhere that the chat hasn't read yet,
            // or the row the follow-up was sent after is gone (a reload):
            // whose reply this is can't be told, so nothing is tagged.
            predictiveFollowUpTurn = nil
        } else if let turn = predictiveFollowUpTurn, turn.sessionID == sessionId {
            predictiveFollowUpTurn = nil
            // Only a reply the turn wrote: a [SILENT] one leaves no row, and
            // a system notice isn't Hermes following up.
            if isReply, let reply = messages.last, reply.role == .assistant, reply.id != turn.after {
                predictive.noteFollowUp(messageID: reply.id, why: turn.why)
                objectWillChange.send()
            }
        }
        // The reply on screen ended now only when this turn wrote it.
        if isReply, let anchor = predictiveAnchor, anchor.sessionID == sessionId {
            predictiveReplyEnded = (anchor, Date())
        }
        updatePredictiveScreen(fresh: isReply)
    }

    /// Turns someone else's message can run ahead of a queued follow-up
    /// before Conduit stops waiting for its reply.
    static let predictiveFollowUpMaximumTurnsAhead = 3

    /// Messages people sent before `queuedAt` that sit after `after`, or
    /// that another client sent while the follow-up waited (`noted` row
    /// ids, read in before the turn it waited behind ended): each runs
    /// ahead of the hidden prompt, which leaves no row. A row `after` no
    /// longer names (the chat reloaded) proves nothing.
    static func messagesSentAhead(after id: String?, before queuedAt: Date, noted: Set<Int> = [],
                                  in messages: [ChatMessage]) -> Int {
        var start = 0
        if let id {
            start = messages.lastIndex(where: { $0.id == id }).map { $0 + 1 } ?? messages.count
        }
        return messages.indices.filter { index in
            let message = messages[index]
            guard index >= start || message.rowId.map(noted.contains) == true,
                  message.role == .user,
                  let sent = MessageTimestampFormatter.date(from: message.timestamp) else { return false }
            return sent <= queuedAt
        }.count
    }

    /// Stops watching for the follow-up's reply: nothing is tagged or held.
    func stopWaitingForPredictiveFollowUp() {
        predictiveFollowUpTurn = nil
        predictiveFollowUpQueued = false
        predictiveFollowUpSending = false
        predictiveFollowUpAheadEnded = false
        predictiveFollowUpTurnsAhead = 0
        predictiveFollowUpQueuedAt = nil
        predictiveFollowUpUnreadMessages = []
        predictiveFollowUpSend &+= 1
    }

    /// Another client sent a message in the chat Hermes is following up
    /// in: until its row is read, a reply ending may be its.
    func notePredictiveFollowUpMessageElsewhere(sessionId: String, rowId: Int?) {
        guard predictiveFollowUpTurn?.sessionID == sessionId else { return }
        // No row id: never found, so the follow-up's tag stops for good.
        predictiveFollowUpUnreadMessages.insert(rowId ?? -1)
    }

    /// A turn failed or was interrupted: a follow-up it carried is over,
    /// with nothing to tag.
    func predictiveTurnEnded(sessionId: String) {
        if predictiveFollowUpTurn?.sessionID == sessionId {
            // The turn ahead of a queued follow-up ending leaves the follow-up to run.
            if predictiveFollowUpQueued || predictiveFollowUpSending {
                predictiveFollowUpQueued = false
                if predictiveFollowUpSending { predictiveFollowUpAheadEnded = true }
                predictiveFollowUpTurn?.after = messages.last?.id
            } else if let turn = predictiveFollowUpTurn, let queuedAt = predictiveFollowUpQueuedAt,
                      Self.messagesSentAhead(after: turn.after, before: queuedAt, noted: predictiveFollowUpUnreadMessages,
                                             in: messages) > predictiveFollowUpTurnsAhead {
                // A message queued ahead of it failed: the follow-up still runs.
                predictiveFollowUpTurnsAhead += 1
                if predictiveFollowUpTurnsAhead > Self.predictiveFollowUpMaximumTurnsAhead {
                    predictiveFollowUpTurn = nil
                }
            } else {
                predictiveFollowUpTurn = nil
            }
        }
        updatePredictiveScreen(fresh: false)
    }

    // MARK: - Asking

    /// Asks the plugin; nil when it can't answer (no plugin, an error, too
    /// slow), which shows nothing.
    func askPredictive(_ body: [String: Any], profile: String, wait: TimeInterval) async -> [String: Any]? {
        if let predictiveSender { return try? await predictiveSender(body) }
        guard let bridge = dashboardTicketBridge else { return nil }
        let path = DashboardPath.withProfile(Predictive.path, profile: profile, parameter: notifierPlugin.dashboardProfileParameter)
        return try? await bridge.requestJSON(
            path: path, method: "POST", body: body,
            timeoutMilliseconds: Int((wait + 2) * 1_000)
        )
    }

    /// Suggested replies for `anchor`, asked once per reply.
    func requestPredictedReplies(for anchor: PredictiveStore.Anchor, again: Bool = false) {
        guard Predictive.repliesEnabled(), !predictive.hiddenSessions.contains(anchor.sessionID),
              again || predictiveRepliesAsked != anchor else { return }
        predictiveRepliesAsked = anchor
        let count = Predictive.replyCount()
        let body = Predictive.body(
            kind: .replies, sessionID: anchor.sessionID, count: count,
            language: ChatStepSummaries.languageName, model: Predictive.model(), wait: Predictive.repliesWait
        )
        let profile = activeProfile
        let generation = predictiveGeneration
        Task { [weak self] in
            guard let answer = await self?.askPredictive(body, profile: profile, wait: Predictive.repliesWait),
                  let self, self.predictiveGeneration == generation, Predictive.repliesEnabled(),
                  self.predictiveAnchor == anchor else { return }
            let guesses = Array(Predictive.guesses(answer["replies"]).prefix(count))
            guard !guesses.isEmpty else { return }
            self.predictive.showReplies(guesses, for: anchor)
        }
    }

    /// The row's ⋯ > Refresh.
    func refreshPredictions() {
        guard let anchor = predictiveAnchor else { return }
        if predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestPredictedReplies(for: anchor, again: true)
        } else {
            predictiveDraftAsked = nil
            askAboutDraft(predictive.draft, sessionID: anchor.sessionID)
        }
    }

    /// The row's ⋯ > Hide for this chat.
    func hidePredictionsInOpenChat() {
        guard let sessionID = activeSessionId else { return }
        predictive.hide(sessionID: sessionID)
        predictivePauseTask?.cancel()
        predictivePauseTask = nil
        stopPredictiveFollowUpClock()
    }

    // MARK: - While I pause

    /// The composer's text changed: typing folds the row, stops the
    /// follow-up clock and, once it pauses, asks about the draft.
    func predictiveDraftChanged(_ text: String) {
        let wasEmpty = predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        predictive.draftChanged(text)
        predictivePauseTask?.cancel()
        predictivePauseTask = nil
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // An emptied composer starts a new draft, asked about afresh.
        if isEmpty { predictiveDraftAsked = nil }
        if !isEmpty || !wasEmpty {
            // Writing is the opposite of sitting idle: the clock starts over
            // once the composer is empty again.
            predictiveFollowUp.idleSince = Date()
            stopPredictiveFollowUpClock()
            if isEmpty, let anchor = predictiveAnchor { startPredictiveFollowUpClock(for: anchor) }
        }
        guard Predictive.pauseEnabled(), predictiveIsServed, !isEmpty, !text.hasPrefix("/"),
              text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Predictive.minimumDraftCharacters,
              let sessionID = activeSessionId, !sessionID.isEmpty,
              predictiveDraftAsked?.sessionID != sessionID || predictiveDraftAsked?.draft != text,
              !predictive.hiddenSessions.contains(sessionID), !isBusy, !turnState.isRunning,
              !isVoiceInUse else { return }
        let delay = Predictive.pauseDelay()
        predictivePauseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            // Still on, shown and on screen: a draft is never asked about
            // once the switch is off, the chat hidden or covered.
            guard let self, self.predictive.draft == text, self.activeSessionId == sessionID,
                  !self.isBusy, !self.turnState.isRunning, Predictive.pauseEnabled(), self.predictiveIsServed,
                  !self.predictive.hiddenSessions.contains(sessionID), self.isSceneActive, !self.showSidebar,
                  self.activeRoomSurface == nil, self.composerChatOnScreen == .live(sessionID),
                  !self.isVoiceInUse else { return }
            self.askAboutDraft(text, sessionID: sessionID)
        }
    }

    /// Asks about `draft` once. The answer counts while it comes within
    /// the wait and the draft still starts with what was asked.
    private func askAboutDraft(_ draft: String, sessionID: String) {
        // Asked once per draft in each chat.
        guard predictiveDraftAsked?.sessionID != sessionID || predictiveDraftAsked?.draft != draft else { return }
        predictiveDraftAsked = (sessionID, draft)
        let body = Predictive.body(
            kind: .draft, sessionID: sessionID, count: Predictive.replyCount(), draft: draft,
            language: ChatStepSummaries.languageName, model: Predictive.model(), wait: Predictive.draftWait
        )
        let profile = activeProfile
        let asked = Date()
        let generation = predictiveGeneration
        // Not cancelled by more typing: an answer for the start of the draft
        // still offers the rest of a continuation the user is typing.
        Task { [weak self] in
            guard let answer = await self?.askPredictive(body, profile: profile, wait: Predictive.draftWait),
                  let self, self.predictiveGeneration == generation, self.activeSessionId == sessionID,
                  Date().timeIntervalSince(asked) <= Predictive.draftWait + 1 else { return }
            self.predictive.showDraftGuesses(
                next: Predictive.guesses(answer["next"]),
                replies: Array(Predictive.guesses(answer["replies"]).prefix(Predictive.replyCount())),
                for: draft
            )
        }
    }

    // MARK: - Hermes follows up

    /// Starts (or resumes) the checks for `anchor`'s reply, while the
    /// switch is on and Hermes hasn't spent its follow-up on the user's
    /// last message.
    func startPredictiveFollowUpClock(for anchor: PredictiveStore.Anchor) {
        guard Predictive.followUpEnabled(), predictiveIsServed, client?.gatewayRefusesHiddenPrompts != true,
              !predictive.hiddenSessions.contains(anchor.sessionID),
              predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if predictiveFollowUp.anchor != anchor {
            let spent = predictiveFollowUp.spentOn
            predictiveFollowUp = PredictiveFollowUpState(anchor: anchor, spentOn: spent)
        }
        guard !predictiveFollowUp.stopped, predictiveFollowUp.checks < Predictive.maximumChecks,
              predictiveFollowUp.spentOn != predictiveUserMessageKey(anchor.sessionID),
              // A follow-up still waiting its turn here: another can't be
              // told from it.
              predictiveFollowUpTurn?.sessionID != anchor.sessionID else { return }
        let due = predictiveFollowUp.nextCheck
            ?? predictiveFollowUp.idleSince.addingTimeInterval(TimeInterval(Predictive.followUpDelay()))
        predictiveFollowUpTask?.cancel()
        predictiveFollowUpTask = Task { [weak self] in
            let wait = max(0, due.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            await self?.checkPredictiveFollowUp(for: anchor)
        }
    }

    func stopPredictiveFollowUpClock() {
        predictiveFollowUpTask?.cancel()
        predictiveFollowUpTask = nil
    }

    /// The chat and its user's last message, as a follow-up is spent on it.
    private func predictiveUserMessageKey(_ sessionID: String) -> String {
        "\(sessionID)|\(messages.last(where: { $0.role == .user })?.id ?? "")"
    }

    /// One check: asks whether Hermes wants a turn, with what Conduit
    /// measured, and sends the hidden turn or waits as Hermes asked.
    private func checkPredictiveFollowUp(for anchor: PredictiveStore.Anchor) async {
        guard predictiveAnchor == anchor, predictiveFollowUp.anchor == anchor,
              Predictive.followUpEnabled(),
              predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        predictiveFollowUp.checks += 1
        let now = Date()
        let ended = predictiveReplyEnded.flatMap { $0.anchor == anchor ? $0.at : nil }
            ?? messages.last.flatMap { Predictive.date(fromTimestamp: $0.timestamp) }
            ?? predictiveFollowUp.idleSince
        let facts = Predictive.TurnFacts(
            lastReplySeconds: Int(now.timeIntervalSince(ended)),
            onScreenSeconds: Int(now.timeIntervalSince(predictiveFollowUp.idleSince)),
            check: predictiveFollowUp.checks,
            localTime: Predictive.localTime(now)
        )
        let body = Predictive.body(
            kind: .turn, sessionID: anchor.sessionID, count: 1, facts: facts,
            language: ChatStepSummaries.languageName, model: Predictive.model(), wait: Predictive.turnWait
        )
        let generation = predictiveGeneration
        let answer = await askPredictive(body, profile: activeProfile, wait: Predictive.turnWait)
        // Still the same reply on screen, nobody writing, nothing started,
        // the switch still on and the chat not hidden meanwhile.
        guard !Task.isCancelled, predictiveGeneration == generation, predictiveAnchor == anchor, predictiveFollowUp.anchor == anchor,
              Predictive.followUpEnabled(), !predictive.hiddenSessions.contains(anchor.sessionID),
              predictive.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let answer else {
            // A failed check isn't retried for this reply.
            predictiveFollowUp.stopped = true
            return
        }
        let decision = Predictive.turnAnswer(answer)
        if decision.takeTurn, let nudge = decision.nudge {
            predictiveFollowUp.spentOn = predictiveUserMessageKey(anchor.sessionID)
            predictiveFollowUp.stopped = true
            // Its own task: the turn starting stops the follow-up clock,
            // and that must not cancel the send it started.
            Task { [weak self] in
                await self?.sendPredictiveFollowUp(nudge, why: decision.why, sessionID: anchor.sessionID, generation: generation)
            }
        } else if let again = decision.askAgain, predictiveFollowUp.checks < Predictive.maximumChecks {
            predictiveFollowUp.nextCheck = Date().addingTimeInterval(TimeInterval(again))
            startPredictiveFollowUpClock(for: anchor)
        } else {
            predictiveFollowUp.stopped = true
        }
    }

    /// The hidden turn: Hermes sees it, the chat doesn't show it, and its
    /// reply wears "Hermes followed up".
    private func sendPredictiveFollowUp(_ nudge: String, why: String, sessionID: String, generation: Int) async {
        // One follow-up waiting in this chat at a time: a second would
        // restart the count of messages queued ahead of the first.
        guard predictiveGeneration == generation, predictiveFollowUpTurn?.sessionID != sessionID else { return }
        // Still watched: the chat on screen, not covered, Conduit in front.
        guard let client, activeSessionId == sessionID, !isBusy, !turnState.isRunning,
              isSceneActive, !showSidebar, activeRoomSurface == nil, composerChatOnScreen == .live(sessionID),
              !isVoiceInUse, Predictive.followUpEnabled(), !predictive.hiddenSessions.contains(sessionID) else {
            // Not sent: the user's message keeps its follow-up, checked
            // again when the chat is back on screen.
            predictiveFollowUp.spentOn = nil
            predictiveFollowUp.stopped = false
            return
        }
        predictiveFollowUpTurn = (sessionID, why, messages.last?.id)
        predictiveFollowUpTurnsAhead = 0
        predictiveFollowUpQueuedAt = nil
        predictiveFollowUpUnreadMessages = []
        predictiveFollowUpSend &+= 1
        let send = predictiveFollowUpSend
        let sentAt = Date()
        predictiveFollowUpSending = true
        predictiveFollowUpAheadEnded = false
        predictive.clear()
        // A follow-up that leaves no reply of its own ([SILENT], steered)
        // brings the same reply back: its guesses are asked for again.
        predictiveRepliesAsked = nil
        do {
            let outcome = try await client.sendPrompt(sessionID, text: nudge, hidden: true)
            // Forgotten meanwhile (sign-out), or stopped waiting (a
            // reconnect) with maybe another follow-up sent since: nothing
            // of it is kept.
            guard predictiveGeneration == generation, predictiveFollowUpSend == send else { return }
            predictiveFollowUpSending = false
            // A turn running meanwhile took it in: there's no reply of its
            // own to mark. A queued one runs as its own next turn.
            if outcome == .steered || outcome == .redirected { predictiveFollowUpTurn = nil }
            // Queued behind a turn that already ended on the way: the next
            // turn to end is Hermes'.
            let queued = outcome == .queued && predictiveFollowUpTurn != nil
            predictiveFollowUpQueued = queued && !predictiveFollowUpAheadEnded
            predictiveFollowUpQueuedAt = queued ? sentAt : nil
        } catch {
            guard predictiveGeneration == generation, predictiveFollowUpSend == send else { return }
            predictiveFollowUpSending = false
            // Nothing reached Hermes (a gateway without hidden prompts stops
            // the checks for good): the user's message keeps its follow-up.
            predictiveFollowUpTurn = nil
            predictiveFollowUp.spentOn = nil
            // Checked again later, unless the gateway takes no hidden prompts.
            predictiveFollowUp.stopped = client.gatewayRefusesHiddenPrompts
        }
        // Its reply lands while the user watches: no push for it.
        updateChatOnScreen()
    }
}

@MainActor
extension AppState {
    /// Settings > Chat > Predictive's host line: the fast model, if the
    /// profile names one, and today's count. Nil without the plugin route.
    func loadPredictiveHostStatus() async -> Predictive.HostStatus? {
        guard predictiveIsServed, predictiveSender == nil, let bridge = dashboardTicketBridge else { return nil }
        let path = DashboardPath.withProfile(Predictive.path, profile: activeProfile, parameter: notifierPlugin.dashboardProfileParameter)
        guard let answer = try? await bridge.requestJSON(path: path, timeoutMilliseconds: 8_000) else { return nil }
        let model = (answer["fast_model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Predictive.HostStatus(fastModel: model, today: (answer["today"] as? NSNumber)?.intValue ?? 0)
    }
}
