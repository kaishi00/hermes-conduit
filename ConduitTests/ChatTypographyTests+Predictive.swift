import XCTest
import SwiftUI
@testable import Conduit

/// Settings > Chat > Predictive (Predictive.swift): what Conduit asks the
/// plugin, how its answers are read, and what the suggestion row offers.
extension ChatTypographyTests {
    func testPredictiveSwitchesAreOffUntilTurnedOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PredictiveTests-\(UUID().uuidString)"))
        XCTAssertFalse(Predictive.repliesEnabled(defaults))
        XCTAssertFalse(Predictive.pauseEnabled(defaults))
        XCTAssertFalse(Predictive.followUpEnabled(defaults))
        XCTAssertEqual(Predictive.replyCount(defaults), 3)
        XCTAssertEqual(Predictive.pauseDelay(defaults), 1.2)
        XCTAssertEqual(Predictive.followUpDelay(defaults), 60)
        XCTAssertEqual(Predictive.model(defaults), .fast)
        // A stored value off the menu reads as the default.
        defaults.set(4, forKey: Predictive.replyCountKey)
        XCTAssertEqual(Predictive.replyCount(defaults), 3)
    }

    func testAFollowUpCheckSendsWhatConduitMeasured() throws {
        let facts = Predictive.TurnFacts(lastReplySeconds: 192, onScreenSeconds: 160, check: 2, localTime: "Sunday 09:14")
        let body = Predictive.body(
            kind: .turn, sessionID: "s1", count: 1, facts: facts,
            language: "French", model: .chat, wait: Predictive.turnWait
        )
        XCTAssertEqual(body["kind"] as? String, "turn")
        XCTAssertEqual(body["session_id"] as? String, "s1")
        XCTAssertEqual(body["model"] as? String, "chat")
        let measured = try XCTUnwrap(body["facts"] as? [String: Any])
        XCTAssertEqual(measured["last_reply_s"] as? Int, 192)
        XCTAssertEqual(measured["on_screen_s"] as? Int, 160)
        XCTAssertEqual(measured["check"] as? Int, 2)
        XCTAssertEqual(measured["max_checks"] as? Int, Predictive.maximumChecks)
        XCTAssertEqual(measured["local_time"] as? String, "Sunday 09:14")
        XCTAssertNil(body["draft"])
    }

    func testGuessesComeBestFirst() {
        let guesses = Predictive.guesses([
            ["text": "Remind me tonight", "p": 0.2],
            ["text": "Raise the quota", "p": 0.7],
            ["text": "   ", "p": 0.9],
            ["p": 0.5],
            // Too long for a chip: dropped, never cut short.
            ["text": String(repeating: "a", count: Predictive.maxGuessLength + 1), "p": 0.95],
        ])
        XCTAssertEqual(guesses.map(\.text), ["Raise the quota", "Remind me tonight"])
        XCTAssertEqual(Predictive.guesses(nil), [])
        XCTAssertEqual(Predictive.guesses("not a list"), [])
    }

    func testAFollowUpIsOnlyTakenWithItsHiddenTurn() {
        let yes = Predictive.turnAnswer(["take_turn": true, "why": "Worth a check.", "nudge": "[Conduit] …", "ask_again_in_seconds": NSNull()])
        XCTAssertTrue(yes.takeTurn)
        XCTAssertEqual(yes.why, "Worth a check.")
        XCTAssertEqual(yes.nudge, "[Conduit] …")
        XCTAssertFalse(Predictive.turnAnswer(["take_turn": true]).takeTurn)
        let later = Predictive.turnAnswer(["take_turn": false, "ask_again_in_seconds": 5])
        XCTAssertFalse(later.takeTurn)
        XCTAssertEqual(later.askAgain, 30)
        XCTAssertEqual(Predictive.turnAnswer(["take_turn": false, "ask_again_in_seconds": 99_999]).askAgain, 900)
        XCTAssertNil(Predictive.turnAnswer(["take_turn": false]).askAgain)
    }

    func testAContinuationFollowsTheDraftAsItIsTyped() {
        // As asked.
        XCTAssertEqual(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Can you delete"), " the share")
        // The user typed its start meanwhile: the rest is offered.
        XCTAssertEqual(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Can you delete th"), "e share")
        // Typed all of it, or went elsewhere: nothing.
        XCTAssertNil(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Can you delete the share"))
        XCTAssertNil(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Can you delete my"))
        XCTAssertNil(Predictive.remainder(of: " the share", askedFor: "Can you delete", draft: "Could you"))
        XCTAssertEqual(Predictive.inserting(" the share", into: "Can you delete"), "Can you delete the share")
    }

    func testTheLocalTimeNamesTheDayInEnglish() throws {
        let date = try XCTUnwrap(Predictive.date(fromTimestamp: "2026-10-25T13:14:00Z"))
        let toronto = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        XCTAssertEqual(Predictive.localTime(date, timeZone: toronto), "Sunday 09:14")
        XCTAssertNotNil(Predictive.date(fromTimestamp: "2026-10-25T13:14:00.250Z"))
        XCTAssertNil(Predictive.date(fromTimestamp: "yesterday"))
    }

    @MainActor
    func testTheRowShowsRepliesUntilTypingAndTheDraftsGuessesWhileItFits() {
        let store = PredictiveStore()
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        store.setScreen(anchor)
        XCTAssertFalse(store.isShowing)
        store.showReplies([.init(text: "Thanks!", p: 0.8)], for: anchor)
        XCTAssertTrue(store.isShowing)
        XCTAssertEqual(store.currentReplies.map(\.text), ["Thanks!"])

        // Typing folds the row; the replies wait behind its button.
        store.draftChanged("Can you delete")
        XCTAssertTrue(store.isFolded)
        XCTAssertEqual(store.currentReplies, [])
        store.showDraftGuesses(next: [.init(text: " the share", p: 0.6)],
                               replies: [.init(text: "Can you delete old snapshots?", p: 0.5)],
                               for: "Can you delete")
        XCTAssertFalse(store.isFolded)
        XCTAssertEqual(store.currentNext.map(\.text), [" the share"])
        XCTAssertEqual(store.currentReplies.map(\.text), ["Can you delete old snapshots?"])
        store.draftChanged("Can you delete th")
        XCTAssertEqual(store.currentNext.map(\.text), ["e share"])

        // An emptied composer brings the replies back.
        store.draftChanged("")
        XCTAssertFalse(store.isFolded)
        XCTAssertEqual(store.currentReplies.map(\.text), ["Thanks!"])

        // Another reply on screen: the old guesses go.
        store.setScreen(.init(sessionID: "s1", messageID: "a2"))
        XCTAssertFalse(store.isShowing)
        // Hidden in a chat: nothing shows there.
        store.showReplies([.init(text: "Okay", p: 0.5)], for: .init(sessionID: "s1", messageID: "a2"))
        store.hide(sessionID: "s1")
        XCTAssertFalse(store.isShowing)
    }

    @MainActor
    func testGuessesForADraftTypedOnMeanwhileWaitBehindTheButton() {
        let store = PredictiveStore()
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        store.setScreen(anchor)
        store.draftChanged("Can you delete")
        store.draftChanged("Can you delete th")
        store.showDraftGuesses(next: [.init(text: " the share", p: 0.6)], replies: [], for: "Can you delete")
        XCTAssertTrue(store.isFolded)
        XCTAssertEqual(store.currentNext.map(\.text), ["e share"])
    }

    @MainActor
    func testAFollowUpThatFailedOrWasInterruptedEnds() {
        let events: [StreamEvent] = [
            .messageError(sessionId: "s1", message: "gateway exploded"),
            .messageInterrupted(sessionId: "s1"),
        ]
        for event in events {
            let defaults = makeScratchDefaults("PredictiveFollowUpTests")
            let state = AppState(
                defaults: defaults,
                loadSavedConnection: false,
                sessionPresentationCache: SessionPresentationCache(defaults: defaults)
            )
            state.sessions = [SessionSummary(
                id: "s1", alternateIds: [], title: "s1", model: "Hermes", updatedLabel: "now",
                profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil
            )]
            state.activeSessionId = "s1"
            state.predictiveFollowUpTurn = ("s1", "Worth a check.", nil)
            state.handleStreamEvent(event)
            XCTAssertNil(state.predictiveFollowUpTurn, "\(event)")
            XCTAssertTrue(state.predictive.followUpReasons.isEmpty)
        }
    }

    @MainActor
    func testAQueuedFollowUpTagsItsOwnReplyNotTheTurnAhead() {
        let defaults = makeScratchDefaults("PredictiveQueuedTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpQueued = true

        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "Another client's reply.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty, "the turn ahead isn't Hermes following up")
        XCTAssertEqual(state.predictiveFollowUpTurn?.after, "a2")
        XCTAssertFalse(state.predictiveFollowUpQueued)

        state.messages.append(ChatMessage(id: "a3", role: .assistant, content: "One more thing.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertEqual(state.predictive.followUpReasons["a3"], "Worth a check.")
        XCTAssertNil(state.predictiveFollowUpTurn)
    }

    /// A system notice merged into the last row anchors no guesses and no
    /// follow-up clock.
    @MainActor
    func testASystemNoticeInTheLastRowIsNotAnAnchor() {
        let defaults = makeScratchDefaults("PredictiveNoticeTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.predictiveSender = { _ in [:] }
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        XCTAssertEqual(state.predictiveAnchor?.messageID, "a1", "a reply anchors")
        state.messages[0].content = "Context compacted."
        state.messages[0].rawContent = "[System: Context compacted.]"
        XCTAssertNil(state.predictiveAnchor)
    }

    /// While a follow-up waits its turn in a chat, no second one is
    /// checked for there: it would restart the count of messages ahead.
    @MainActor
    func testNoSecondFollowUpIsCheckedWhileOneWaits() throws {
        UserDefaults.standard.set(true, forKey: Predictive.followUpKey)
        defer { UserDefaults.standard.removeObject(forKey: Predictive.followUpKey) }
        let defaults = makeScratchDefaults("PredictiveSecondFollowUpTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.predictiveSender = { _ in [:] }
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        let anchor = try XCTUnwrap(state.predictiveAnchor)
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a0")
        state.startPredictiveFollowUpClock(for: anchor)
        XCTAssertNil(state.predictiveFollowUpTask)
        state.predictiveFollowUpTurn = nil
        state.startPredictiveFollowUpClock(for: anchor)
        XCTAssertNotNil(state.predictiveFollowUpTask, "the clock runs once nothing waits")
        state.stopPredictiveFollowUpClock()
    }

    /// A turn ending while the hidden prompt is still on its way is the one
    /// ahead: it isn't tagged, and the follow-up isn't counted as queued
    /// behind another.
    @MainActor
    func testATurnEndingWhileTheFollowUpIsSentIsTheTurnAhead() {
        let defaults = makeScratchDefaults("PredictiveSendingTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpSending = true

        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "Another client's reply.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty, "the turn ahead isn't Hermes following up")
        XCTAssertEqual(state.predictiveFollowUpTurn?.after, "a2")
        XCTAssertTrue(state.predictiveFollowUpAheadEnded)
    }

    /// A reply to a message someone sent, queued ahead of the hidden
    /// prompt, isn't Hermes following up: the tag waits for the reply after.
    @MainActor
    func testAQueuedFollowUpTwoTurnsBehindTagsItsOwnReply() {
        let defaults = makeScratchDefaults("PredictiveTwoAheadTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        let queuedAt = Date()
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Working on it.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpQueued = true
        state.predictiveFollowUpQueuedAt = queuedAt

        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "Done.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        state.messages.append(ChatMessage(id: "u1", role: .user, content: "And the other one?",
                                          timestamp: Self.isoTimestamp(queuedAt.addingTimeInterval(-5))))
        state.messages.append(ChatMessage(id: "a3", role: .assistant, content: "That too.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty, "a reply to someone's message isn't a follow-up")
        XCTAssertEqual(state.predictiveFollowUpTurn?.after, "a2")
        XCTAssertEqual(state.predictiveFollowUpTurnsAhead, 1)

        state.messages.append(ChatMessage(id: "a4", role: .assistant, content: "One more thing.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertEqual(state.predictive.followUpReasons["a4"], "Worth a check.")
        XCTAssertNil(state.predictiveFollowUpTurn)
    }

    /// A follow-up whose reply was never seen to end stops waiting after a
    /// few turns of other messages.
    @MainActor
    func testAFollowUpStopsWaitingAfterAFewTurnsOfOtherMessages() {
        let defaults = makeScratchDefaults("PredictiveTurnsAheadTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        let queuedAt = Date()
        state.messages = [ChatMessage(id: "a0", role: .assistant, content: "Done.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a0")
        state.predictiveFollowUpQueuedAt = queuedAt
        for turn in 1...(AppState.predictiveFollowUpMaximumTurnsAhead + 1) {
            state.messages.append(ChatMessage(id: "u\(turn)", role: .user, content: "Next?",
                                              timestamp: Self.isoTimestamp(queuedAt.addingTimeInterval(-10))))
            state.messages.append(ChatMessage(id: "a\(turn)", role: .assistant, content: "Sure.", timestamp: "now"))
            state.predictiveTurnSettled(sessionId: "s1")
        }
        XCTAssertNil(state.predictiveFollowUpTurn)
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty)
    }

    /// A message sent after the hidden prompt runs after it: the reply
    /// that ends first is still Hermes following up.
    @MainActor
    func testAMessageSentAfterTheFollowUpDoesNotMoveItsTag() {
        for queued in [false, true] {
            let defaults = makeScratchDefaults("PredictiveSentAfterTests\(queued)")
            let state = AppState(
                defaults: defaults,
                loadSavedConnection: false,
                sessionPresentationCache: SessionPresentationCache(defaults: defaults)
            )
            let sentAt = Date()
            state.activeSessionId = "s1"
            state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
            state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
            // Queued behind a turn that has since ended, or run at once.
            state.predictiveFollowUpQueuedAt = queued ? sentAt : nil
            state.messages.append(ChatMessage(id: "u1", role: .user, content: "Also, the list?",
                                              timestamp: Self.isoTimestamp(sentAt.addingTimeInterval(2))))
            state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "One more thing.", timestamp: "now"))
            state.predictiveTurnSettled(sessionId: "s1")
            XCTAssertEqual(state.predictive.followUpReasons["a2"], "Worth a check.", "queued: \(queued)")
            XCTAssertNil(state.predictiveFollowUpTurn)
        }
    }

    /// A row the follow-up was sent after that's gone from the chat (a
    /// reload) proves nothing about who wrote the reply, so it's not tagged.
    @MainActor
    func testAMissingStartingRowFindsNoMessageAhead() {
        let queuedAt = Date()
        let messages = [
            ChatMessage(id: "u1", role: .user, content: "Hi", timestamp: Self.isoTimestamp(queuedAt.addingTimeInterval(-60))),
            ChatMessage(id: "a1", role: .assistant, content: "Hello.", timestamp: "now"),
        ]
        XCTAssertEqual(AppState.messagesSentAhead(after: "gone", before: queuedAt, in: messages), 0)
        XCTAssertEqual(AppState.messagesSentAhead(after: nil, before: queuedAt, in: messages), 1)
        XCTAssertEqual(AppState.messagesSentAhead(after: "u1", before: queuedAt, in: messages), 0)

        // Nor does the reply after it get the tag.
        let defaults = makeScratchDefaults("PredictiveMissingRowTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        state.messages = messages
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "gone")
        state.predictiveFollowUpQueuedAt = queuedAt
        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "One more thing.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty)
        XCTAssertNil(state.predictiveFollowUpTurn)
    }

    /// Two messages queued ahead whose rows land together, before either
    /// reply: both replies are theirs, and the one after is Hermes'.
    @MainActor
    func testTwoMessagesQueuedAheadAreBothCountedOff() {
        let defaults = makeScratchDefaults("PredictiveTwoRowsAheadTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let queuedAt = Date()
        let before = Self.isoTimestamp(queuedAt.addingTimeInterval(-5))
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpQueuedAt = queuedAt
        state.messages.append(ChatMessage(id: "u1", role: .user, content: "First?", timestamp: before))
        state.messages.append(ChatMessage(id: "u2", role: .user, content: "Second?", timestamp: before))
        for reply in ["a2", "a3"] {
            state.messages.append(ChatMessage(id: reply, role: .assistant, content: "Sure.", timestamp: "now"))
            state.predictiveTurnSettled(sessionId: "s1")
        }
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty)
        state.messages.append(ChatMessage(id: "a4", role: .assistant, content: "One more thing.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertEqual(state.predictive.followUpReasons["a4"], "Worth a check.")
    }

    /// A message another client sent that the chat hasn't read yet: the
    /// reply ending next may be its, so nothing is tagged. Once its row is
    /// read and runs after the follow-up, the follow-up's reply is tagged.
    @MainActor
    func testAMessageSentElsewhereAndNotYetReadStopsTheTag() {
        for read in [false, true] {
            let defaults = makeScratchDefaults("PredictiveElsewhereTests\(read)")
            let state = AppState(
                defaults: defaults,
                loadSavedConnection: false,
                sessionPresentationCache: SessionPresentationCache(defaults: defaults)
            )
            let sentAt = Date()
            state.activeSessionId = "s1"
            state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
            state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
            state.predictiveFollowUpQueuedAt = sentAt
            state.handleStreamEvent(.userMessage(sessionId: "s1", rowId: 42, text: "From the desktop", origin: nil))
            if read {
                state.messages.append(ChatMessage(id: "u1", role: .user, content: "From the desktop",
                                                  timestamp: Self.isoTimestamp(sentAt.addingTimeInterval(2)), rowId: 42))
            }
            state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "One more thing.", timestamp: "now"))
            state.predictiveTurnSettled(sessionId: "s1")
            XCTAssertEqual(state.predictive.followUpReasons["a2"], read ? "Worth a check." : nil, "read: \(read)")
            XCTAssertNil(state.predictiveFollowUpTurn)
        }
    }

    /// A message another client queued ahead of the follow-up, read in
    /// before the turn the follow-up waited behind ended: its reply still
    /// isn't tagged, and the one after is.
    @MainActor
    func testAMessageReadInBeforeTheTurnAheadEndsIsStillCountedOff() {
        let defaults = makeScratchDefaults("PredictiveReadEarlyTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let queuedAt = Date()
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Working on it.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpQueued = true
        state.predictiveFollowUpQueuedAt = queuedAt
        state.handleStreamEvent(.userMessage(sessionId: "s1", rowId: 7, text: "And the other one?", origin: nil))
        state.messages.append(ChatMessage(id: "u1", role: .user, content: "And the other one?",
                                          timestamp: Self.isoTimestamp(queuedAt.addingTimeInterval(-5)), rowId: 7))
        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "Done.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        state.messages.append(ChatMessage(id: "a3", role: .assistant, content: "That too.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty)
        state.messages.append(ChatMessage(id: "a4", role: .assistant, content: "One more thing.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertEqual(state.predictive.followUpReasons["a4"], "Worth a check.")
    }

    /// This device's own message, announced back to it, isn't someone
    /// else's: the follow-up's reply is still tagged.
    @MainActor
    func testThisDevicesOwnMessageAnnouncedBackKeepsTheTag() {
        let defaults = makeScratchDefaults("PredictiveOwnEchoTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let sentAt = Date()
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpQueuedAt = sentAt
        state.messages.append(ChatMessage(id: "u1", role: .user, content: "Also, the list?",
                                          timestamp: Self.isoTimestamp(sentAt.addingTimeInterval(2))))
        state.handleStreamEvent(.userMessage(sessionId: "s1", rowId: 42, text: "Also, the list?", origin: nil))
        XCTAssertTrue(state.predictiveFollowUpUnreadMessages.isEmpty)
        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "One more thing.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertEqual(state.predictive.followUpReasons["a2"], "Worth a check.")
    }

    /// Someone else sending the same words as this device's last message,
    /// already stored under its own row: still someone else's.
    @MainActor
    func testTheSameWordsSentElsewhereAreStillSomeoneElses() {
        let defaults = makeScratchDefaults("PredictiveSameWordsTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        state.messages = [
            ChatMessage(id: "u1", role: .user, content: "Thanks!", timestamp: "now", rowId: 41),
            ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now"),
        ]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpQueuedAt = Date()
        state.handleStreamEvent(.userMessage(sessionId: "s1", rowId: 42, text: "Thanks!", origin: nil))
        XCTAssertEqual(state.predictiveFollowUpUnreadMessages, [42])
    }

    /// A message queued ahead of the follow-up whose turn fails: the
    /// follow-up still runs, and its reply is tagged.
    @MainActor
    func testAFailedTurnQueuedAheadKeepsTheFollowUp() {
        let defaults = makeScratchDefaults("PredictiveAheadFailedTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let queuedAt = Date()
        state.activeSessionId = "s1"
        state.messages = [ChatMessage(id: "a1", role: .assistant, content: "Done.", timestamp: "now")]
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", "a1")
        state.predictiveFollowUpQueuedAt = queuedAt
        state.messages.append(ChatMessage(id: "u1", role: .user, content: "First?",
                                          timestamp: Self.isoTimestamp(queuedAt.addingTimeInterval(-5))))
        state.predictiveTurnEnded(sessionId: "s1")
        XCTAssertNotNil(state.predictiveFollowUpTurn)
        state.messages.append(ChatMessage(id: "a2", role: .assistant, content: "One more thing.", timestamp: "now"))
        state.predictiveTurnSettled(sessionId: "s1")
        XCTAssertEqual(state.predictive.followUpReasons["a2"], "Worth a check.")
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    @MainActor
    func testLeavingTheChatForTheSidebarDropsAFollowUpsTag() {
        let defaults = makeScratchDefaults("PredictiveSidebarTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        state.activeSessionId = "s1"
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", nil)
        state.updatePredictiveScreen()
        XCTAssertNotNil(state.predictiveFollowUpTurn, "still on screen")
        state.showSidebar = true
        XCTAssertNil(state.predictiveFollowUpTurn)
    }

    @MainActor
    func testSigningOutForgetsWhatPredictiveKnewOfTheChats() {
        let defaults = makeScratchDefaults("PredictiveSignOutTests")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        state.predictive.setScreen(anchor)
        state.predictive.showReplies([.init(text: "Thanks!", p: 0.8)], for: anchor)
        state.predictive.draftChanged("Can you delete")
        state.predictive.noteFollowUp(messageID: "a1", why: "Worth a check.")
        state.predictive.hide(sessionID: "s2")
        state.predictiveRepliesAsked = anchor
        state.predictiveDraftAsked = ("s1", "Can you delete")
        state.predictiveFollowUp.anchor = anchor
        state.predictiveFollowUpTurn = ("s1", "Worth a check.", nil)
        state.predictiveReplyEnded = (anchor, Date())
        let pause = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        state.predictivePauseTask = pause
        let generation = state.predictiveGeneration

        state.forgetPredictiveState()

        XCTAssertNotEqual(state.predictiveGeneration, generation, "answers asked before are dropped")

        XCTAssertFalse(state.predictive.isShowing)
        XCTAssertEqual(state.predictive.draft, "")
        XCTAssertTrue(state.predictive.followUpReasons.isEmpty)
        XCTAssertTrue(state.predictive.hiddenSessions.isEmpty)
        XCTAssertNil(state.predictiveRepliesAsked)
        XCTAssertNil(state.predictiveDraftAsked)
        XCTAssertNil(state.predictiveFollowUp.anchor)
        XCTAssertNil(state.predictiveFollowUpTurn)
        XCTAssertNil(state.predictiveReplyEnded)
        XCTAssertNil(state.predictivePauseTask)
        XCTAssertTrue(pause.isCancelled)
    }

    @MainActor
    func testRefreshedChipsAreGuardedAgain() {
        let store = PredictiveStore()
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        store.setScreen(anchor)
        store.showReplies([.init(text: "Thanks!", p: 0.8)], for: anchor)
        let later = Date().addingTimeInterval(Predictive.tapGuard + 0.1)
        XCTAssertFalse(store.tapIsGuarded(now: later))
        store.showReplies([.init(text: "Do it", p: 0.7)], for: anchor)
        XCTAssertTrue(store.tapIsGuarded())
    }

    @MainActor
    func testATapOnARowThatJustAppearedIsIgnored() {
        let store = PredictiveStore()
        let anchor = PredictiveStore.Anchor(sessionID: "s1", messageID: "a1")
        store.setScreen(anchor)
        store.showReplies([.init(text: "Thanks!", p: 0.8)], for: anchor)
        XCTAssertTrue(store.tapIsGuarded())
        XCTAssertFalse(store.tapIsGuarded(now: Date().addingTimeInterval(Predictive.tapGuard + 0.1)))
    }

    /// A reply chip sends its whole text, so in the row's horizontal scroll
    /// view (no width offered) a long guess wraps at 250 pt instead of being
    /// cut to one line, and a short one keeps its own width.
    @MainActor
    func testAReplyChipWrapsItsWholeTextPastItsWidth() {
        func size(_ text: String) -> CGSize {
            let host = UIHostingController(rootView: WrapsPastWidth(maxWidth: 250) { Text(text) }.fixedSize())
            return host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        }
        let short = size("Oui")
        let long = size("Vérifie s'il reste des billets pour le Can Can de 6 PM samedi soir")
        XCTAssertLessThan(short.width, 100)
        XCTAssertLessThanOrEqual(long.width, 250)
        XCTAssertGreaterThan(long.height, short.height * 1.5, "the long guess takes a second line")

        // Offered less than 250 pt, it wraps at what it's offered.
        let narrowHost = UIHostingController(rootView: WrapsPastWidth(maxWidth: 250) {
            Text("Vérifie s'il reste des billets pour le Can Can de 6 PM samedi soir")
        })
        let narrow = narrowHost.sizeThatFits(in: CGSize(width: 120, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertLessThanOrEqual(narrow.width, 120)
        XCTAssertGreaterThan(narrow.height, long.height, "narrower takes more lines")
    }
}
