//
//  ShortcutSendTests.swift
//  ConduitTests
//
//  The "Send to Hermes" Shortcuts action: which chat a run goes to, what it
//  hands back, and how long it waits for Hermes's reply. An extension of
//  ScreenQuestionTests (the other Shortcuts action) so the test plan gains
//  no class.
//

import XCTest
@testable import Conduit

/// A scripted Hermes with a clock that moves only when the run sleeps.
private final class FakeHermes {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var connects = true
    var created: [(profile: String, title: String)] = []
    var resumed: [VoiceThreadTarget] = []
    var resumeFails = false
    var submitted: [(runtimeID: String, text: String)] = []
    var submitOutcome: PromptSubmissionOutcome = .accepted
    /// Runtimes Hermes no longer has: a send to one answers "session not found".
    var goneRuntimes: Set<String> = []
    var reopened: [VoiceThreadTarget] = []
    /// One list per poll; the last one repeats.
    var polls: [[LiveSessionStatus]] = []
    var replies: [ShortcutReply?] = []
    var replyReads = 0
    /// iOS ends the run while it waits.
    var cancelsSleep = false

    func backend() -> ShortcutSendBackend {
        ShortcutSendBackend(
            connect: { _ in self.connects },
            activeProfile: { "default" },
            createChat: { profile, title in
                self.created.append((profile, title))
                let id = "run-\(self.created.count)"
                return VoiceThreadTarget(runtimeSessionID: id, storedSessionID: "stored-\(self.created.count)",
                                         title: title, profile: profile)
            },
            resumeChat: { chat in
                self.resumed.append(chat)
                if self.resumeFails { throw HermesError.invalidResponse }
                return "resumed-\(self.resumed.count)"
            },
            reopenChat: { chat in
                self.reopened.append(chat)
                return "reopened-\(self.reopened.count)"
            },
            submit: { _, runtimeID, text in
                if self.goneRuntimes.contains(runtimeID) {
                    throw RpcError(code: 4001, message: "session not found")
                }
                self.submitted.append((runtimeID, text))
                return self.submitOutcome
            },
            liveSessions: { _ in
                let rows = self.polls.first ?? []
                if self.polls.count > 1 { self.polls.removeFirst() }
                return rows
            },
            latestReply: { _ in
                defer { self.replyReads += 1 }
                guard !self.replies.isEmpty else { return nil }
                return self.replies.count > 1 ? self.replies.removeFirst() : self.replies[0]
            },
            sleep: { seconds in
                if self.cancelsSleep { throw CancellationError() }
                self.now = self.now.addingTimeInterval(seconds)
            },
            now: { self.now }
        )
    }
}

extension ScreenQuestionTests {
    /// A chat list of its own for each test, removed when the test ends.
    private func shortcutChats() -> ShortcutChatStore {
        let suite = "ShortcutSendTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ShortcutChatStore(defaults: defaults)
    }

    @MainActor
    private func sender(_ hermes: FakeHermes, _ chats: ShortcutChatStore) -> ShortcutSender {
        ShortcutSender(backend: hermes.backend(), chats: chats)
    }

    private func shortcutRequest(_ text: String, chat: String? = nil, profile: String? = nil, wait: Bool = false) -> ShortcutSendRequest {
        ShortcutSendRequest(text: text, chatName: chat, profile: profile, waitsForAnswer: wait)
    }

    private func liveRow(_ id: String, _ status: String) -> LiveSessionStatus {
        LiveSessionStatus(runtimeSessionId: id, storedSessionId: "", status: status)
    }

    // MARK: - Which chat

    @MainActor
    func testEachRunWithoutAChatNameStartsANewChatTitledFromTheText() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let deadline = hermes.now.addingTimeInterval(25)
        let first = try await sender(hermes, chats).send(shortcutRequest("  Weather: rain at 4\nmore  "), deadline: deadline)
        _ = try await sender(hermes, chats).send(shortcutRequest("Second"), deadline: deadline)

        XCTAssertEqual(first, .sent)
        XCTAssertEqual(hermes.created.map(\.title), ["Shortcut: Weather: rain at 4", "Shortcut: Second"])
        XCTAssertEqual(hermes.created.map(\.profile), ["default", "default"])
        XCTAssertEqual(hermes.submitted.map(\.runtimeID), ["run-1", "run-2"])
        XCTAssertEqual(hermes.submitted.first?.text, "Weather: rain at 4\nmore")
        XCTAssertTrue(hermes.resumed.isEmpty)
    }

    @MainActor
    func testANamedChatIsReusedPerProfileWhateverTheCase() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let deadline = hermes.now.addingTimeInterval(25)
        _ = try await sender(hermes, chats).send(shortcutRequest("one", chat: "Morning notes"), deadline: deadline)
        _ = try await sender(hermes, chats).send(shortcutRequest("two", chat: " morning NOTES "), deadline: deadline)
        _ = try await sender(hermes, chats).send(shortcutRequest("three", chat: "Morning notes", profile: "work"), deadline: deadline)

        XCTAssertEqual(hermes.created.map(\.title), ["Morning notes", "Morning notes"])
        XCTAssertEqual(hermes.created.map(\.profile), ["default", "work"])
        XCTAssertEqual(hermes.resumed.map(\.storedSessionID), ["stored-1"])
        XCTAssertEqual(hermes.submitted.map(\.runtimeID), ["run-1", "resumed-1", "run-2"])
    }

    @MainActor
    func testANamedChatThatCannotBeResumedIsReplacedByANewOne() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let deadline = hermes.now.addingTimeInterval(25)
        _ = try await sender(hermes, chats).send(shortcutRequest("one", chat: "Log"), deadline: deadline)
        hermes.resumeFails = true
        _ = try await sender(hermes, chats).send(shortcutRequest("two", chat: "Log"), deadline: deadline)
        hermes.resumeFails = false
        _ = try await sender(hermes, chats).send(shortcutRequest("three", chat: "Log"), deadline: deadline)

        XCTAssertEqual(hermes.created.count, 2)
        XCTAssertEqual(hermes.resumed.map(\.storedSessionID), ["stored-1", "stored-2"])
        XCTAssertEqual(hermes.submitted.map(\.runtimeID), ["run-1", "run-2", "resumed-2"])
    }

    @MainActor
    func testARuntimeHermesNoLongerHasIsReopenedAndTheTextSentOnce() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let deadline = hermes.now.addingTimeInterval(25)
        _ = try await sender(hermes, chats).send(shortcutRequest("one", chat: "Drop box"), deadline: deadline)
        // A cold launch: the chat's runtime is the one from before.
        hermes.goneRuntimes = ["resumed-1"]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("two", chat: "Drop box"), deadline: deadline)
        _ = try await sender(hermes, chats).send(shortcutRequest("three", chat: "Drop box"), deadline: deadline)

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(hermes.created.count, 1)
        XCTAssertEqual(hermes.reopened.map(\.storedSessionID), ["stored-1"])
        XCTAssertEqual(hermes.submitted.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(hermes.submitted.map(\.runtimeID), ["run-1", "reopened-1", "resumed-2"])
        XCTAssertEqual(chats.chat(named: "Drop box", profile: "default")?.storedSessionID, "stored-1")
    }

    @MainActor
    func testARunEndedWhileTheChatReopensSendsNothing() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let deadline = hermes.now.addingTimeInterval(25)
        _ = try await sender(hermes, chats).send(shortcutRequest("one", chat: "Drop box"), deadline: deadline)
        hermes.goneRuntimes = ["resumed-1"]
        var backend = hermes.backend()
        backend.reopenChat = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return "reopened-1"
        }
        do {
            _ = try await ShortcutSender(backend: backend, chats: chats)
                .send(shortcutRequest("two", chat: "Drop box"), deadline: deadline)
            XCTFail("the run should end")
        } catch is CancellationError {}
        XCTAssertEqual(hermes.submitted.map(\.text), ["one"])
    }

    @MainActor
    func testOtherSendFailuresAreNotRetried() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let backend = hermes.backend()
        var failing = backend
        failing.submit = { _, _, _ in throw HermesError.invalidResponse }
        do {
            _ = try await ShortcutSender(backend: failing, chats: chats)
                .send(shortcutRequest("one", chat: "Drop box"), deadline: hermes.now.addingTimeInterval(25))
            XCTFail("the send should fail")
        } catch {}
        XCTAssertTrue(hermes.reopened.isEmpty)
    }

    @MainActor
    func testTheChatListKeepsOnlyTheMostRecentChats() {
        let store = shortcutChats()
        for index in 0...ShortcutChatStore.maximumChats {
            store.save(VoiceThreadTarget(runtimeSessionID: "r\(index)", title: "c\(index)", profile: "default"),
                       named: "c\(index)", profile: "default", at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertNil(store.chat(named: "c0", profile: "default"))
        XCTAssertEqual(store.chat(named: "c1", profile: "default")?.runtimeSessionID, "r1")
        store.forget(named: "c1", profile: "default")
        XCTAssertNil(store.chat(named: "c1", profile: "default"))
    }

    // MARK: - What comes back

    @MainActor
    func testWaitingReturnsTheReplyOnceTheTurnEnds() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        hermes.polls = [[liveRow("run-1", "working")], [liveRow("run-1", "working")], [liveRow("run-1", "idle")]]
        hermes.replies = [ShortcutReply(text: "It will rain at 4.")]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("Weather?", wait: true), deadline: hermes.now.addingTimeInterval(25))

        XCTAssertEqual(outcome, .answered("It will rain at 4."))
        XCTAssertEqual(outcome.text, "It will rain at 4.")
    }

    @MainActor
    func testAnIdleRowRightAfterTheSendIsNotTakenAsTheEnd() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        hermes.polls = [[liveRow("run-1", "idle")], [liveRow("run-1", "idle")], [liveRow("run-1", "working")], [liveRow("run-1", "idle")]]
        hermes.replies = [nil, nil, ShortcutReply(text: "Done.")]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("Go", wait: true), deadline: hermes.now.addingTimeInterval(25))

        XCTAssertEqual(outcome, .answered("Done."))
        XCTAssertEqual(hermes.replyReads, 3, "Each early idle poll only looked for a reply")
    }

    @MainActor
    func testAReusedChatsOldReplyIsNotTakenAsTheAnswer() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let deadline = hermes.now.addingTimeInterval(25)
        _ = try await sender(hermes, chats).send(shortcutRequest("one", chat: "Log"), deadline: deadline)
        hermes.polls = [[liveRow("resumed-1", "working")], [liveRow("resumed-1", "idle")]]
        hermes.replies = [ShortcutReply(text: "Old reply.", rowID: 7)]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("two", chat: "Log", wait: true), deadline: hermes.now.addingTimeInterval(25))

        XCTAssertEqual(outcome, .stillWorking)
    }

    @MainActor
    func testANewReplyWordedLikeTheOldOneIsStillTheAnswer() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let deadline = hermes.now.addingTimeInterval(25)
        _ = try await sender(hermes, chats).send(shortcutRequest("Lights off", chat: "Home"), deadline: deadline)
        hermes.polls = [[liveRow("resumed-1", "working")], [liveRow("resumed-1", "idle")]]
        // Read before sending, then the new turn's reply: a row of its own.
        hermes.replies = [ShortcutReply(text: "Done.", rowID: 7), ShortcutReply(text: "Done.", rowID: 9)]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("Lights off", chat: "Home", wait: true), deadline: hermes.now.addingTimeInterval(25))

        XCTAssertEqual(outcome, .answered("Done."))
    }

    func testARepliesIdentityDecidesBeforeItsWording() {
        let saved = ShortcutReply(text: "Done.", rowID: 7)
        XCTAssertTrue(ShortcutReply(text: "Done.", rowID: 7).mayBe(saved))
        XCTAssertFalse(ShortcutReply(text: "Done.", rowID: 9).mayBe(saved), "a newer row")
        XCTAssertFalse(ShortcutReply(text: "Done.", openChatID: "live").mayBe(ShortcutReply(text: "Done.", rowID: 7, openChatID: "7")),
                       "streaming in the open chat after a saved reply")
        XCTAssertFalse(ShortcutReply(text: "Done.", openChatID: "b").mayBe(ShortcutReply(text: "Done.", openChatID: "a")))
        XCTAssertTrue(ShortcutReply(text: "Done.", openChatID: "a").mayBe(ShortcutReply(text: "Done.", openChatID: "a")))
        // The streamed reply was saved since: only its text can say.
        XCTAssertTrue(ShortcutReply(text: "Done.", rowID: 7, openChatID: "7").mayBe(ShortcutReply(text: "Done.", openChatID: "live")))
        XCTAssertFalse(ShortcutReply(text: "On it.", rowID: 7).mayBe(ShortcutReply(text: "Done.")))
        XCTAssertTrue(ShortcutReply(text: "Done.").mayBe(ShortcutReply(text: "Done.")))
    }

    @MainActor
    func testAQuestionFromHermesSaysTheChatNeedsAnAnswer() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        hermes.polls = [[liveRow("run-1", "working")], [liveRow("run-1", "waiting")]]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("Book it", wait: true), deadline: hermes.now.addingTimeInterval(25))

        XCTAssertEqual(outcome, .needsInput)
    }

    @MainActor
    func testALongTurnRunsOutOfTimeAndSaysWhereTheAnswerWillBe() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let start = hermes.now
        hermes.polls = [[liveRow("run-1", "working")]]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("Research", wait: true), deadline: start.addingTimeInterval(25))

        XCTAssertEqual(outcome, .stillWorking)
        XCTAssertLessThanOrEqual(hermes.now.timeIntervalSince(start), 25)
        XCTAssertEqual(hermes.replyReads, 1, "Only the last look when time is up")
    }

    @MainActor
    func testABusyNamedChatQueuesWithoutWaiting() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        hermes.submitOutcome = .queued
        let queued = try await sender(hermes, chats).send(shortcutRequest("Later", wait: true), deadline: hermes.now.addingTimeInterval(25))
        hermes.submitOutcome = .steered
        let joined = try await sender(hermes, chats).send(shortcutRequest("Also", wait: true), deadline: hermes.now.addingTimeInterval(25))

        XCTAssertEqual(queued, .queued)
        XCTAssertEqual(joined, .joinedRunningReply)
        XCTAssertEqual(hermes.replyReads, 0)
    }

    @MainActor
    func testEmptyTextAndNoConnectionFailWithoutSending() async {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        let deadline = hermes.now.addingTimeInterval(25)
        do {
            _ = try await sender(hermes, chats).send(shortcutRequest(" \n "), deadline: deadline)
            XCTFail("empty text was sent")
        } catch {
            XCTAssertEqual(error as? ShortcutSendError, .empty)
        }
        hermes.connects = false
        do {
            _ = try await sender(hermes, chats).send(shortcutRequest("Hello"), deadline: deadline)
            XCTFail("sent without a connection")
        } catch {
            XCTAssertEqual(error as? ShortcutSendError, .notConnected)
        }
        XCTAssertTrue(hermes.submitted.isEmpty)
        XCTAssertTrue(hermes.created.isEmpty)
    }

    @MainActor
    func testACancelledRunEndsAsCancelledNotAsSent() async {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        hermes.cancelsSleep = true
        do {
            _ = try await sender(hermes, chats).send(shortcutRequest("Wait", wait: true), deadline: hermes.now.addingTimeInterval(25))
            XCTFail("a cancelled run reported an outcome")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testATurnThatEndsBetweenPollsStillAnswers() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        // Never seen running: idle, idle, then the reply is there.
        hermes.polls = [[liveRow("run-1", "idle")]]
        hermes.replies = [nil, nil, ShortcutReply(text: "Quick answer.")]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("Hi", wait: true), deadline: hermes.now.addingTimeInterval(25))
        XCTAssertEqual(outcome, .answered("Quick answer."))
    }

    @MainActor
    func testAReplyThatLandsAsTimeRunsOutStillAnswers() async throws {
        let hermes = FakeHermes()
        let chats = shortcutChats()
        hermes.polls = [[liveRow("run-1", "working")]]
        hermes.replies = [ShortcutReply(text: "Made it.")]
        let outcome = try await sender(hermes, chats).send(shortcutRequest("Long", wait: true), deadline: hermes.now.addingTimeInterval(25))
        XCTAssertEqual(outcome, .answered("Made it."))
        XCTAssertEqual(hermes.replyReads, 1, "Read once, at the end")
    }

    @MainActor
    func testSiriSpeaksAShortenedLongAnswer() {
        XCTAssertEqual(SendToHermesIntent.spoken("Short."), "Short.")
        XCTAssertEqual(SendToHermesIntent.spoken(String(repeating: "a", count: 700)).count, 600)
    }

    @MainActor
    func testALongFirstLineIsShortenedInTheTitle() {
        let title = ShortcutSender.title(for: String(repeating: "a", count: 100))
        XCTAssertEqual(title, "Shortcut: " + String(repeating: "a", count: 59) + "…")
    }
}
