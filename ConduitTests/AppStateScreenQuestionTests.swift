//
//  AppStateScreenQuestionTests.swift
//  ConduitTests
//
//  Ask Hermes About Screen in AppState: a screenshot waits on its chat and
//  rides, once, on the next new turn sent there (typed or spoken). Slash
//  commands and steers leave it waiting, a failed send puts it back, and a
//  launch Hermes couldn't take keeps it parked until Hermes connects.
//

import XCTest
@testable import Conduit

@MainActor
final class AppStateScreenQuestionTests: XCTestCase {

    // MARK: - Sending

    func testFirstNewTurnCarriesTheScreenshotOnce() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")

        let first = await harness.appState.submitComposer(text: "What does this error mean?")

        XCTAssertTrue(first)
        XCTAssertEqual(recorder.uploads.map { $0.attachment.uri }, [shot.uri])
        XCTAssertEqual(recorder.uploads.first?.sessionID, "composer-origin")
        XCTAssertEqual(recorder.prompts.map { $0.text }, ["What does this error mean?"])
        XCTAssertEqual(harness.appState.messages.last?.attachments?.map(\.uri), [shot.uri])
        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "composer-origin"))
        XCTAssertTrue(harness.appState.pendingScreenshots.isEmpty)

        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "composer-origin", busy: true))
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: "composer-origin", messageId: nil, content: "It means…", reasoning: nil
        ))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "composer-origin", busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        let second = await harness.appState.submitComposer(text: "Thanks")

        XCTAssertTrue(second)
        XCTAssertEqual(recorder.uploads.count, 1, "The screenshot rides on one turn only")
        XCTAssertEqual(recorder.prompts.map { $0.text }, ["What does this error mean?", "Thanks"])
        XCTAssertNil(harness.appState.messages.last?.attachments)
    }

    func testScreenshotAloneCanBeSent() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")

        let sent = await harness.appState.submitComposer(text: "")

        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.uploads.map { $0.attachment.uri }, [shot.uri])
        XCTAssertEqual(recorder.prompts.count, 1)
    }

    func testSpokenTurnCarriesTheScreenshot() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")

        let sent = await harness.appState.submitVoiceTranscript("Which button do I press?")

        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.uploads.map { $0.attachment.uri }, [shot.uri])
        XCTAssertEqual(recorder.prompts.map { $0.text }, ["Which button do I press?"])
        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "composer-origin"))
    }

    func testScreenshotStaysWithItsChat() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        harness.appState.sessions = [session("chat-a"), session("chat-b")]
        harness.appState.activeSessionId = "chat-b"
        installComposerClient(in: harness)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "chat-a")

        let sent = await harness.appState.submitComposer(text: "Unrelated")

        XCTAssertTrue(sent)
        XCTAssertTrue(recorder.uploads.isEmpty, "Another chat's screenshot never rides along")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "chat-a"), shot)
    }

    func testSlashCommandLeavesTheScreenshotPending() async throws {
        let recorder = ScreenQuestionCallRecorder()
        var operations = ChatResumeLifecycleOperations(
            sendPrompt: { _, sessionID, text in
                recorder.prompts.append((sessionID, text))
                return .accepted
            },
            compressSession: { _, _, _ in
                recorder.compressions += 1
                return SessionCompressResult(from: .object(["status": .string("compressed")]))
            }
        )
        operations.uploadAttachment = { _, sessionID, attachment in
            recorder.uploads.append((sessionID, attachment))
        }
        let harness = makeHarness(lifecycleOperations: operations)
        openChat("composer-origin", in: harness)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")

        _ = await harness.appState.submitComposer(text: "/compress")

        XCTAssertEqual(recorder.compressions, 1)
        XCTAssertTrue(recorder.uploads.isEmpty)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
    }

    func testSteerIntoRunningTurnLeavesTheScreenshotPending() async throws {
        let recorder = ScreenQuestionCallRecorder()
        var operations = ChatResumeLifecycleOperations(
            sendPrompt: { _, sessionID, text in
                recorder.prompts.append((sessionID, text))
                return .accepted
            },
            steer: { _, sessionID, text in
                recorder.steers.append((sessionID, text))
            }
        )
        operations.uploadAttachment = { _, sessionID, attachment in
            recorder.uploads.append((sessionID, attachment))
        }
        let harness = makeHarness(lifecycleOperations: operations)
        openChat("composer-origin", in: harness)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "composer-origin", busy: true))
        XCTAssertTrue(harness.appState.turnState.isRunning)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")

        _ = await harness.appState.submitComposer(text: "Also look at the footer")

        XCTAssertEqual(recorder.steers.map { $0.text }, ["Also look at the footer"])
        XCTAssertTrue(recorder.uploads.isEmpty)
        XCTAssertTrue(recorder.prompts.isEmpty)
        XCTAssertEqual(
            harness.appState.pendingScreenshot(forSession: "composer-origin"), shot,
            "A steer has no attachments; the screenshot waits for the next new turn"
        )
    }

    func testFailedUploadPutsTheScreenshotBack() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let origin = session("composer-origin")
        var operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [origin] },
            openSession: { _, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in .unavailable },
            refreshContext: { _, _ in },
            sendPrompt: { _, sessionID, text in
                recorder.prompts.append((sessionID, text))
                return .accepted
            }
        )
        operations.uploadAttachment = { _, sessionID, attachment in
            recorder.uploads.append((sessionID, attachment))
            throw URLError(.networkConnectionLost)
        }
        let harness = makeHarness(lifecycleOperations: operations)
        openChat("composer-origin", in: harness)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")

        let sent = await harness.appState.submitComposer(text: "What is this?")

        XCTAssertFalse(sent)
        XCTAssertEqual(recorder.uploads.count, 1)
        XCTAssertTrue(recorder.prompts.isEmpty)
        XCTAssertEqual(
            harness.appState.pendingScreenshot(forSession: "composer-origin"), shot,
            "A send that failed puts the screenshot back on its chat"
        )
        let url = try XCTUnwrap(URL(string: shot.uri))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedSendPutsTheScreenshotBackUnderItsOwnID() async throws {
        let reopened = session("runtime-new", storedID: "stored-a")
        var operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [reopened] },
            openSession: { _, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in .unavailable },
            refreshContext: { _, _ in },
            sendPrompt: { _, _, _ in .accepted }
        )
        operations.uploadAttachment = { _, _, _ in
            throw URLError(.networkConnectionLost)
        }
        let harness = makeHarness(lifecycleOperations: operations)
        openChat("runtime-new", in: harness)
        harness.appState.sessions = [reopened]
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "stored-a")

        let sent = await harness.appState.submitComposer(text: "What is this?")

        XCTAssertFalse(sent)
        XCTAssertEqual(harness.appState.pendingScreenshots, [PendingScreenshot(sessionID: "stored-a", attachment: shot)])
    }

    // MARK: - The pending screenshot store

    func testNewerScreenshotReplacesOlderAndDeletesItsFile() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let older = try stagedScreenshot()
        let newer = try stagedScreenshot()

        harness.appState.setPendingScreenshot(older, forSession: "chat-a")
        harness.appState.setPendingScreenshot(newer, forSession: "chat-a")

        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "chat-a"), newer)
        XCTAssertEqual(harness.appState.pendingScreenshots.count, 1)
        XCTAssertFalse(fileExists(older), "The replaced screenshot never leaves the phone")
        XCTAssertTrue(fileExists(newer))
    }

    func testRestoreDoesNotOverrideNewerScreenshot() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let sending = try stagedScreenshot()
        let newer = try stagedScreenshot()
        harness.appState.setPendingScreenshot(sending, forSession: "chat-a")
        XCTAssertEqual(harness.appState.takePendingScreenshot(forSession: "chat-a"), sending)
        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "chat-a"))

        harness.appState.setPendingScreenshot(newer, forSession: "chat-a")
        harness.appState.restorePendingScreenshot(sending, forSession: "chat-a")

        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "chat-a"), newer)
        XCTAssertEqual(harness.appState.pendingScreenshots.count, 1)
        XCTAssertFalse(fileExists(sending), "The screenshot that will never be sent is deleted")
        XCTAssertTrue(fileExists(newer))
    }

    func testRestoreKeepsTheCap() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let sending = try stagedScreenshot()
        harness.appState.setPendingScreenshot(sending, forSession: "sending-chat")
        XCTAssertEqual(harness.appState.takePendingScreenshot(forSession: "sending-chat"), sending)
        var others: [Attachment] = []
        for index in 0..<ScreenQuestionPolicy.maximumPendingScreenshots {
            let shot = try stagedScreenshot()
            others.append(shot)
            harness.appState.setPendingScreenshot(shot, forSession: "chat-\(index)")
        }

        harness.appState.restorePendingScreenshot(sending, forSession: "sending-chat")

        XCTAssertEqual(harness.appState.pendingScreenshots.count, ScreenQuestionPolicy.maximumPendingScreenshots)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "sending-chat"), sending)
        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "chat-0"), "The oldest is dropped")
        XCTAssertFalse(fileExists(others[0]))
    }

    func testDiscardDeletesTheStagedFile() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "chat-a")

        harness.appState.discardPendingScreenshot(forSession: "chat-a")

        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "chat-a"))
        XCTAssertFalse(fileExists(shot))
    }

    func testPendingScreenshotsAreCapped() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        var shots: [Attachment] = []
        for index in 0...ScreenQuestionPolicy.maximumPendingScreenshots {
            let shot = try stagedScreenshot()
            shots.append(shot)
            harness.appState.setPendingScreenshot(shot, forSession: "chat-\(index)")
        }

        XCTAssertEqual(harness.appState.pendingScreenshots.count, ScreenQuestionPolicy.maximumPendingScreenshots)
        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "chat-0"), "The oldest is dropped")
        XCTAssertFalse(fileExists(shots[0]))
        XCTAssertEqual(
            harness.appState.pendingScreenshot(forSession: "chat-\(ScreenQuestionPolicy.maximumPendingScreenshots)"),
            shots.last
        )
    }

    func testReopenedChatFindsItsScreenshotByStoredID() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "stored-a")
        harness.appState.sessions = [session("runtime-new", storedID: "stored-a")]

        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "runtime-new"), shot)
        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "runtime-other"))
    }

    // MARK: - Opening and parking

    func testLaunchWhileDisconnectedReportsNotOpened() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot))

        XCTAssertFalse(opened, "The router fails the launch and the screenshot is parked")
        XCTAssertTrue(harness.appState.pendingScreenshots.isEmpty)
        XCTAssertTrue(fileExists(shot))
    }

    func testParkingKeepsNewestAndDeletesOlderFile() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let older = try stagedScreenshot()
        let newer = try stagedScreenshot()
        let revision = harness.appState.parkedScreenQuestionRevision

        harness.appState.parkScreenQuestion(request(for: older), profile: nil)
        harness.appState.parkScreenQuestion(request(for: newer), profile: nil)

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, newer)
        XCTAssertEqual(harness.appState.parkedScreenQuestionRevision, revision &+ 2)
        XCTAssertFalse(fileExists(older))
        XCTAssertTrue(fileExists(newer))
    }

    func testParkingAnOlderScreenshotKeepsTheNewer() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let older = try stagedScreenshot()
        let newer = try stagedScreenshot()
        let now = Date()

        harness.appState.parkScreenQuestion(request(for: newer, enqueuedAt: now), profile: nil)
        harness.appState.parkScreenQuestion(request(for: older, enqueuedAt: now.addingTimeInterval(-10)), profile: nil)

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, newer, "The newest wins")
        XCTAssertFalse(fileExists(older))
        XCTAssertTrue(fileExists(newer))
    }

    func testParkingKeepsTheProfileTheShortcutNamed() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let shot = try stagedScreenshot()

        harness.appState.parkScreenQuestion(request(for: shot), profile: "work")

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.profile, "work")
        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, shot)
    }

    func testParkedScreenshotWaitsWhileDisconnected() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let shot = try stagedScreenshot()
        harness.appState.parkScreenQuestion(request(for: shot), profile: nil)

        await harness.appState.resumeParkedScreenQuestion()

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, shot)
        XCTAssertTrue(harness.appState.pendingScreenshots.isEmpty)
    }

    func testParkedScreenshotJoinsOpenChatWithQuestionInComposer() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        let shot = try stagedScreenshot()
        harness.appState.parkScreenQuestion(request(
            for: shot,
            question: "Why is this greyed out?",
            enqueuedAt: Date(timeIntervalSinceNow: -3_600)
        ), profile: nil)
        harness.appState.isConnected = true

        await harness.appState.resumeParkedScreenQuestion()

        XCTAssertNil(harness.appState.parkedScreenQuestion)
        XCTAssertEqual(harness.appState.activeSessionId, "composer-origin", "The user is in Conduit now: the chat on screen")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
        XCTAssertTrue(recorder.prompts.isEmpty, "A question from before the outage is not sent by itself")
        XCTAssertEqual(harness.appState.composerPrefillText, "Why is this greyed out?")
    }

    func testParkedScreenshotBackWithinTheLaunchWindowStartsAsAsked() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()
        harness.appState.parkScreenQuestion(request(
            for: shot,
            question: "What does this setting do?",
            enqueuedAt: now.addingTimeInterval(-10)
        ), profile: nil)
        harness.appState.isConnected = true

        await harness.appState.resumeParkedScreenQuestion(now: now)

        XCTAssertNil(harness.appState.parkedScreenQuestion)
        XCTAssertEqual(
            recorder.prompts.map { $0.text }, ["What does this setting do?"],
            "Hermes came back while the press was fresh: it starts as the press asked"
        )
        XCTAssertEqual(recorder.uploads.map { $0.attachment.uri }, [shot.uri])
    }

    func testReconnectKeepsAScreenshotWaiting() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let launch = intent(for: try stagedScreenshot())
        // A reconnect keeps isConnected while it runs.
        harness.appState.isConnected = true
        harness.appState.isConnecting = true

        let reconnecting = harness.appState.voiceLaunchConnectionSnapshot()
        XCTAssertEqual(reconnecting.phase, .connected)
        XCTAssertTrue(reconnecting.isSettling)
        XCTAssertEqual(PendingVoiceLaunchPolicy.readiness(for: launch, connection: reconnecting, now: Date()), .waiting)

        harness.appState.isConnecting = false

        let settled = harness.appState.voiceLaunchConnectionSnapshot()
        XCTAssertFalse(settled.isSettling)
        XCTAssertEqual(PendingVoiceLaunchPolicy.readiness(for: launch, connection: settled, now: Date()), .ready)
    }

    func testParkedScreenshotWaitsForTheForegroundRefresh() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let shot = try stagedScreenshot()
        harness.appState.parkScreenQuestion(request(for: shot), profile: nil)

        // Back in the foreground: the refresh may yet reconnect and replace
        // the chat on screen.
        let refresh = harness.appState.handleScenePhase(.active)
        XCTAssertTrue(harness.appState.isSettlingConnection)

        await harness.appState.resumeParkedScreenQuestion()

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, shot, "Kept until Conduit settles")
        XCTAssertTrue(harness.appState.pendingScreenshots.isEmpty)
        // Ends the refresh before it reaches the network.
        harness.appState.disconnect()
        await refresh?.value
    }

    func testParkedScreenshotIsAttachedOnceConduitSettles() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness, withMessages: true)
        let shot = try stagedScreenshot()
        harness.appState.parkScreenQuestion(request(for: shot, enqueuedAt: Date(timeIntervalSinceNow: -3_600)), profile: nil)
        // A reconnect keeps isConnected while it runs.
        harness.appState.isConnected = true
        harness.appState.isConnecting = true

        let resume = Task { await harness.appState.resumeParkedScreenQuestionOnceSettled(recheck: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, shot, "Waits while Conduit settles")

        harness.appState.isConnecting = false
        await resume.value

        XCTAssertNil(harness.appState.parkedScreenQuestion)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
    }

    func testParkedScreenshotHasOneWaiter() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness, withMessages: true)
        let shot = try stagedScreenshot()
        harness.appState.parkScreenQuestion(request(for: shot, enqueuedAt: Date(timeIntervalSinceNow: -3_600)), profile: nil)
        harness.appState.isConnected = true
        harness.appState.isConnecting = true

        harness.appState.scheduleParkedScreenQuestionResume(recheck: .milliseconds(10))
        let waiter = try XCTUnwrap(harness.appState.parkedScreenQuestionResumeTask)
        harness.appState.scheduleParkedScreenQuestionResume(recheck: .milliseconds(10))
        XCTAssertEqual(harness.appState.parkedScreenQuestionResumeTask, waiter, "A second wake-up keeps the running waiter")

        harness.appState.isConnecting = false
        await waiter.value

        XCTAssertNil(harness.appState.parkedScreenQuestionResumeTask, "The waiter clears itself when it ends")
        XCTAssertNil(harness.appState.parkedScreenQuestion)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
    }

    func testScreenshotParkedWhileOneIsPlacedIsPlacedNext() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()
        let newer = try stagedScreenshot()
        let newerRequest = request(for: newer, startWith: .keyboard, enqueuedAt: now.addingTimeInterval(-5))
        harness.appState.parkScreenQuestion(request(
            for: shot,
            question: "What does this setting do?",
            enqueuedAt: now.addingTimeInterval(-10)
        ), profile: nil)
        harness.appState.isConnected = true
        // A newer press lands while the first screenshot is being sent,
        // and wakes the waiter as the app does.
        recorder.onPrompt = { [weak recorder] in
            recorder?.onPrompt = nil
            harness.appState.parkScreenQuestion(newerRequest, profile: nil)
            harness.appState.scheduleParkedScreenQuestionResume(recheck: .milliseconds(10))
        }

        harness.appState.scheduleParkedScreenQuestionResume(recheck: .milliseconds(10))
        let waiter = try XCTUnwrap(harness.appState.parkedScreenQuestionResumeTask)
        await waiter.value

        XCTAssertEqual(recorder.uploads.map { $0.attachment.uri }, [shot.uri])
        XCTAssertNil(harness.appState.parkedScreenQuestion, "The newer screenshot isn't left waiting")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), newer)
        XCTAssertNil(harness.appState.parkedScreenQuestionResumeTask)
    }

    func testRecentLaunchJoinsOpenChatAndFocusesComposer() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, startWith: .keyboard, enqueuedAt: now))

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "composer-origin")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
        XCTAssertEqual(harness.appState.composerFocusRequest?.sessionID, "composer-origin")
        XCTAssertTrue(recorder.prompts.isEmpty)
    }

    func testRecentLaunchWithQuestionSendsItWithTheScreenshot() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(
            for: shot,
            question: "What does this setting do?",
            enqueuedAt: now
        ))

        XCTAssertTrue(opened)
        XCTAssertEqual(recorder.prompts.map { $0.text }, ["What does this setting do?"])
        XCTAssertEqual(recorder.uploads.map { $0.attachment.uri }, [shot.uri])
        XCTAssertTrue(harness.appState.pendingScreenshots.isEmpty)
    }

    func testLeavingCountsOnlyAfterTheSceneWasOnScreen() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())

        harness.appState.handleScenePhase(.inactive)
        XCTAssertNil(
            harness.appState.lastLeftForegroundAt,
            "A launch that never reached the foreground has not left it"
        )

        harness.appState.handleScenePhase(.active)
        let onScreenSince = try XCTUnwrap(harness.appState.sceneActiveSince)
        harness.appState.handleScenePhase(.active)
        XCTAssertEqual(harness.appState.sceneActiveSince, onScreenSince, "Still on screen: the stretch has not restarted")
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.lastLeftForegroundAt)
    }

    func testFailedQuestionSendLeavesQuestionInComposer() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let origin = session("composer-origin")
        var operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [origin] },
            openSession: { _, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in .unavailable },
            refreshContext: { _, _ in },
            sendPrompt: { _, sessionID, text in
                recorder.prompts.append((sessionID, text))
                return .accepted
            }
        )
        operations.uploadAttachment = { _, sessionID, attachment in
            recorder.uploads.append((sessionID, attachment))
            throw URLError(.networkConnectionLost)
        }
        let harness = makeHarness(lifecycleOperations: operations)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(
            for: shot,
            question: "What does this setting do?",
            enqueuedAt: now
        ))

        XCTAssertTrue(opened)
        XCTAssertEqual(recorder.uploads.count, 1)
        XCTAssertTrue(recorder.prompts.isEmpty)
        XCTAssertEqual(
            harness.appState.composerPrefillText, "What does this setting do?",
            "A question that could not be sent waits in the composer"
        )
        XCTAssertEqual(
            harness.appState.composerFocusRequest?.sessionID, "composer-origin",
            "The keyboard comes up once the composer unlocks"
        )
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
        XCTAssertTrue(fileExists(shot))
    }

    func testSlashQuestionWaitsInComposer() async throws {
        let recorder = ScreenQuestionCallRecorder()
        var operations = ChatResumeLifecycleOperations(
            sendPrompt: { _, sessionID, text in
                recorder.prompts.append((sessionID, text))
                return .accepted
            },
            compressSession: { _, _, _ in
                recorder.compressions += 1
                return SessionCompressResult(from: .object(["status": .string("compressed")]))
            }
        )
        operations.uploadAttachment = { _, sessionID, attachment in
            recorder.uploads.append((sessionID, attachment))
        }
        let harness = makeHarness(lifecycleOperations: operations)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(
            for: shot,
            question: "/compress",
            enqueuedAt: now
        ))

        XCTAssertTrue(opened)
        XCTAssertTrue(recorder.prompts.isEmpty)
        XCTAssertEqual(recorder.compressions, 0, "A question is never run as a command")
        XCTAssertEqual(harness.appState.composerPrefillText, "/compress")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
    }

    func testProfileThatCannotOpenKeepsTheScreenshotHere() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        // No saved connection: the switch to "work" cannot happen.
        harness.appState.sessions = [session("composer-origin")]
        harness.appState.activeSessionId = "composer-origin"
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, profile: "work", enqueuedAt: now))

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeProfile, "default")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
        XCTAssertTrue(fileExists(shot), "The screenshot is kept, never dropped")
        XCTAssertNotNil(harness.appState.errorMessage)
    }

    func testNewChatThatCannotStartKeepsTheScreenshot() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        // Connected, but no client: no chat can be started.
        harness.appState.isConnected = true
        let shot = try stagedScreenshot()
        let revision = harness.appState.parkedScreenQuestionRevision

        let opened = await harness.appState.openScreenQuestion(intent(for: shot))

        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.pendingScreenshots.isEmpty)
        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, shot)
        XCTAssertTrue(fileExists(shot), "The screenshot is kept, never dropped")
        XCTAssertNotNil(harness.appState.errorMessage)

        await harness.appState.resumeParkedScreenQuestion()

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, shot, "Still kept for later")
        XCTAssertEqual(
            harness.appState.parkedScreenQuestionRevision, revision,
            "Kept without a revision bump, so it is not retried in a loop"
        )
    }

    func testNewChatOptionSkipsTheRecentChat() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChatWithoutClient("recent", in: harness)
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, enqueuedAt: now, startsNewChat: true))

        XCTAssertTrue(opened)
        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "recent"), "The recent chat is passed over")
        XCTAssertEqual(
            harness.appState.parkedScreenQuestion?.request.attachment, shot,
            "It waited for a new chat, which couldn't start here"
        )
    }

    func testNewChatOptionUsesAnEmptyOpenChat() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("fresh-chat", in: harness)
        harness.appState.isConnected = true
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, startWith: .keyboard, startsNewChat: true))

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "fresh-chat"), shot, "An empty chat is already new")
    }

    func testNewChatOptionLeavesTheScreenshotWithOpenVoice() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        harness.appState.showVoiceSheet = true
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, startsNewChat: true))

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
    }

    func testNewChatButtonShowsOnlyBesideAChatInUse() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("fresh-chat", in: harness)
        harness.appState.isConnected = true
        let shot = try stagedScreenshot()
        XCTAssertFalse(harness.appState.canMoveComposerScreenshotToNewChat, "No screenshot")

        harness.appState.setPendingScreenshot(shot, forSession: "fresh-chat")
        XCTAssertFalse(harness.appState.canMoveComposerScreenshotToNewChat, "An empty chat is already new")
        XCTAssertFalse(harness.appState.canMoveVoiceScreenshotToNewChat)

        harness.appState.messages = [ChatMessage(id: "m1", role: .user, content: "Earlier", timestamp: "1")]
        XCTAssertTrue(harness.appState.canMoveComposerScreenshotToNewChat)
        XCTAssertTrue(harness.appState.canMoveVoiceScreenshotToNewChat)

        harness.appState.showVoiceSheet = true
        XCTAssertFalse(harness.appState.canMoveComposerScreenshotToNewChat, "Voice is asking about it: it moves from there")
        XCTAssertTrue(harness.appState.canMoveVoiceScreenshotToNewChat)
        harness.appState.showVoiceSheet = false

        harness.appState.isConnected = false
        XCTAssertFalse(harness.appState.canMoveComposerScreenshotToNewChat, "No new chat starts while disconnected")
    }

    func testNewChatThatCannotStartPutsTheScreenshotAndTextBack() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChatWithoutClient("recent", in: harness)
        harness.appState.isConnected = true
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "recent")

        let moved = await harness.appState.moveComposerScreenshotToNewChat(carrying: "What does this setting do?")

        XCTAssertFalse(moved)
        XCTAssertEqual(harness.appState.activeSessionId, "recent")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "recent"), shot)
        XCTAssertTrue(fileExists(shot), "Moving never deletes the screenshot")
        XCTAssertEqual(harness.appState.composerPrefillText, "What does this setting do?", "The typed text comes back")
        XCTAssertNotNil(harness.appState.errorMessage)
    }

    func testNewChatThatHermesRefusesNamesTheScreenshot() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        // A client whose socket never opened: Hermes refuses the new chat.
        openChat("recent", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "recent")

        let moved = await harness.appState.moveComposerScreenshotToNewChat()

        XCTAssertFalse(moved)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "recent"), shot)
        XCTAssertEqual(
            harness.appState.errorMessage,
            AppLocalization.string("Hermes could not start a new chat, so the screenshot is still in this one."),
            "Says where the screenshot is, not only that a chat failed"
        )
    }

    func testVoiceNewChatThatCannotStartOffersTheScreenshotAgain() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChatWithoutClient("recent", in: harness)
        harness.appState.isConnected = true
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "recent")

        let moved = await harness.appState.moveVoiceScreenshotToNewChat()

        XCTAssertFalse(moved)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "recent"), shot)
        XCTAssertTrue(fileExists(shot), "Moving never deletes the screenshot")
        XCTAssertEqual(
            harness.appState.composerFocusRequest?.sessionID, "recent",
            "Input starts again on the screenshot where it was (the keyboard: no voice is set up here)"
        )
        XCTAssertNotNil(harness.appState.errorMessage)
    }

    func testNewChatTappedAsHermesDisconnectsSaysSo() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChatWithoutClient("recent", in: harness)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "recent")
        // Shown while connected; the connection dropped before the tap.
        harness.appState.isConnected = false

        let moved = await harness.appState.moveComposerScreenshotToNewChat(carrying: "Typed")
        let movedFromVoice = await harness.appState.moveVoiceScreenshotToNewChat()

        XCTAssertFalse(moved)
        XCTAssertFalse(movedFromVoice)
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "recent"), shot)
        XCTAssertEqual(harness.appState.composerPrefillText, "Typed")
        XCTAssertNotNil(harness.appState.errorMessage, "Not a silent tap")
    }

    func testNewChatWithNoScreenshotKeepsTheText() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChatWithoutClient("recent", in: harness)
        harness.appState.isConnected = true

        let moved = await harness.appState.moveComposerScreenshotToNewChat(carrying: "Typed")

        XCTAssertFalse(moved)
        XCTAssertEqual(harness.appState.composerPrefillText, "Typed")
    }

    func testHeldScreenshotKeepsTheProfileTheShortcutNamed() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        // Connected, but no saved connection or client: neither the switch
        // to "work" nor a new chat can happen yet.
        harness.appState.isConnected = true
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, profile: "work"))

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.parkedScreenQuestion?.profile, "work", "The resume tries that profile again")
        XCTAssertTrue(fileExists(shot))
    }

    // MARK: - Superseded launches

    func testSupersededByANewerScreenshotDropsTheOlder() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let older = try stagedScreenshot()
        let newer = try stagedScreenshot()
        let now = Date()
        harness.appState.parkScreenQuestion(request(for: newer, enqueuedAt: now), profile: nil)

        harness.appState.settleSupersededScreenQuestion(
            request(for: older, enqueuedAt: now.addingTimeInterval(-10)),
            profile: nil,
            newerScreenQuestionPending: false
        )

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, newer, "The newest wins")
        XCTAssertFalse(fileExists(older))
        XCTAssertTrue(fileExists(newer))
    }

    func testSupersededWhileANewerScreenshotWaitsDropsTheOlder() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let older = try stagedScreenshot()

        harness.appState.settleSupersededScreenQuestion(request(for: older), profile: nil, newerScreenQuestionPending: true)

        XCTAssertNil(harness.appState.parkedScreenQuestion)
        XCTAssertFalse(fileExists(older))
    }

    func testSupersededByAVoiceLaunchKeepsTheScreenshot() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let shot = try stagedScreenshot()

        harness.appState.settleSupersededScreenQuestion(request(for: shot), profile: "work", newerScreenQuestionPending: false)

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, shot, "Kept, never dropped")
        XCTAssertEqual(harness.appState.parkedScreenQuestion?.profile, "work")
        XCTAssertTrue(fileExists(shot))
    }

    func testOlderLaunchLeavesANewerScreenshotAlone() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let older = try stagedScreenshot()
        let newer = try stagedScreenshot()
        harness.appState.parkScreenQuestion(request(for: newer, enqueuedAt: now), profile: nil)

        let opened = await harness.appState.openScreenQuestion(intent(for: older, enqueuedAt: now.addingTimeInterval(-10)))

        XCTAssertTrue(opened)
        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "composer-origin"))
        XCTAssertEqual(harness.appState.parkedScreenQuestion?.request.attachment, newer, "The newest wins")
        XCTAssertFalse(fileExists(older))
        XCTAssertTrue(fileExists(newer))
    }

    func testSignOutDiscardsWaitingScreenshots() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let pending = try stagedScreenshot()
        let parked = try stagedScreenshot()
        harness.appState.setPendingScreenshot(pending, forSession: "chat-a")
        harness.appState.parkScreenQuestion(request(for: parked), profile: nil)

        harness.appState.disconnect()

        XCTAssertTrue(harness.appState.pendingScreenshots.isEmpty)
        XCTAssertNil(harness.appState.parkedScreenQuestion, "Never attached to the next account's chat")
        XCTAssertNil(harness.appState.newestScreenQuestionAt)
        XCTAssertFalse(fileExists(pending))
        XCTAssertFalse(fileExists(parked))
    }

    func testScreenshotTakenInConduitJoinsTheChatOnScreen() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let now = Date()
        // Last left an hour ago and on screen since: the press came from
        // inside Conduit, so nothing stamped a departure.
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-3_600)
        harness.appState.sceneActiveSince = now.addingTimeInterval(-600)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, startWith: .keyboard, enqueuedAt: now))

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "composer-origin")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
    }

    func testEmptyOpenChatIsReusedWhenNotRecent() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("fresh-chat", in: harness)
        harness.appState.isConnected = true
        harness.appState.lastLeftForegroundAt = nil
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, startWith: .keyboard))

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "fresh-chat", "An empty new chat is as good as a fresh one")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "fresh-chat"), shot)
    }

    func testQuestionDuringRunningTurnWaitsInComposer() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "composer-origin", busy: true))
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-30)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(
            for: shot,
            question: "And this one?",
            enqueuedAt: now
        ))

        XCTAssertTrue(opened)
        XCTAssertTrue(recorder.prompts.isEmpty)
        XCTAssertTrue(recorder.steers.isEmpty, "A screenshot question is a new turn, never a steer")
        XCTAssertEqual(harness.appState.composerPrefillText, "And this one?")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
        XCTAssertEqual(
            harness.appState.composerFocusRequest?.sessionID, "composer-origin",
            "A locked composer still gets the keyboard once it unlocks"
        )
    }

    // MARK: - Voice

    func testVoiceWithoutClassicVoiceFallsBackToKeyboard() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, enqueuedAt: now))

        XCTAssertTrue(opened)
        XCTAssertFalse(harness.appState.showVoiceSheet, "No classic voice is set up here")
        XCTAssertNotNil(harness.appState.composerFocusRequest, "The chat opens with the keyboard instead")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
    }

    func testRunningTurnGetsKeyboardInsteadOfVoice() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "composer-origin", busy: true))
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-30)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, enqueuedAt: now))

        XCTAssertTrue(opened)
        XCTAssertFalse(harness.appState.showVoiceSheet)
        XCTAssertNotNil(harness.appState.composerFocusRequest)
        XCTAssertTrue(recorder.steers.isEmpty)
    }

    func testScreenshotChatAttachesLiveCallAndTellsTheModel() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        XCTAssertNil(harness.appState.liveVoiceThreadForOpenChat(), "An empty chat's call works on its own")
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")

        let thread = try XCTUnwrap(
            harness.appState.liveVoiceThreadForOpenChat(),
            "A call started for a screenshot chat works in that chat"
        )
        harness.appState.voiceBackgroundJobSupervisor.attachLiveThread(thread)

        XCTAssertTrue(harness.appState.liveVoiceThreadInstructions(delegation: false).contains("with ask_thread as they asked it"))
        XCTAssertTrue(harness.appState.liveVoiceThreadInstructions(delegation: true).contains("delegate their question about their screen"))
        XCTAssertEqual(harness.appState.pendingScreenshot(forThread: thread), shot)

        _ = harness.appState.takePendingScreenshot(forSession: "composer-origin")
        XCTAssertFalse(harness.appState.liveVoiceThreadInstructions(delegation: false).contains("shared a screenshot"))
    }

    func testRunningCallHearsQuietlyAboutTheScreenshot() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        let supervisor = harness.appState.voiceBackgroundJobSupervisor
        let shot = try stagedScreenshot()
        supervisor.noteScreenshotShared(attachmentURI: shot.uri)
        XCTAssertNil(supervisor.takePendingChatContext(), "No call is attached to a chat")

        let thread = VoiceThreadTarget(runtimeSessionID: "composer-origin", storedSessionID: nil, title: "Chat")
        supervisor.attachLiveThread(thread)
        harness.appState.noteScreenshot(shot, on: "composer-origin", toCallIn: thread)

        let note = supervisor.takePendingChatContext()
        XCTAssertEqual(note, VoiceBackgroundJobSupervisor.screenshotSharedPrompt)
        XCTAssertTrue(note?.hasPrefix("[Background only.") == true)
    }

    func testCallWhoseChatIsOffScreenSendsTheUserToTheScreenshot() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        // A Bot Chat, or a chat that couldn't open: not the one on screen.
        let thread = VoiceThreadTarget(runtimeSessionID: "bot-chat", storedSessionID: nil, title: "Chat")
        harness.appState.voiceBackgroundJobSupervisor.attachLiveThread(thread)
        let shot = try stagedScreenshot()

        harness.appState.noteScreenshot(shot, on: "composer-origin", toCallIn: thread)

        let note = harness.appState.voiceBackgroundJobSupervisor.takePendingChatContext()
        XCTAssertEqual(note, VoiceBackgroundJobSupervisor.screenshotInAnotherChatPrompt)
        XCTAssertTrue(note?.hasPrefix("[Background only.") == true)
    }

    func testRemovingTheScreenshotTakesBackTheCallsNote() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        let supervisor = harness.appState.voiceBackgroundJobSupervisor
        let thread = VoiceThreadTarget(runtimeSessionID: "composer-origin", storedSessionID: nil, title: "Chat")
        supervisor.attachLiveThread(thread)

        // The composer chip's ×, before the call heard the note.
        let first = try stagedScreenshot()
        harness.appState.setPendingScreenshot(first, forSession: "composer-origin")
        harness.appState.noteScreenshot(first, on: "composer-origin", toCallIn: thread)
        harness.appState.discardPendingScreenshot(forSession: "composer-origin")
        XCTAssertNil(supervisor.takePendingChatContext(), "A note not yet heard is dropped")

        // The voice banner's ×, after the call heard it.
        let second = try stagedScreenshot()
        harness.appState.setPendingScreenshot(second, forSession: "composer-origin")
        harness.appState.noteScreenshot(second, on: "composer-origin", toCallIn: thread)
        XCTAssertEqual(supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotSharedPrompt)
        harness.appState.discardVoiceScreenshot()
        XCTAssertEqual(
            supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotRemovedPrompt,
            "A note already heard is answered"
        )
    }

    func testRetakenScreenshotLeavesTheCallOneNote() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        let supervisor = harness.appState.voiceBackgroundJobSupervisor
        let thread = VoiceThreadTarget(runtimeSessionID: "composer-origin", storedSessionID: nil, title: "Chat")
        supervisor.attachLiveThread(thread)
        let first = try stagedScreenshot()
        let retake = try stagedScreenshot()
        harness.appState.setPendingScreenshot(first, forSession: "composer-origin")
        harness.appState.noteScreenshot(first, on: "composer-origin", toCallIn: thread)
        harness.appState.setPendingScreenshot(retake, forSession: "composer-origin")
        harness.appState.noteScreenshot(retake, on: "composer-origin", toCallIn: thread)

        XCTAssertEqual(supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotSharedPrompt)
        XCTAssertNil(supervisor.takePendingChatContext(), "The retake's note replaces the first one's")

        harness.appState.discardPendingScreenshot(forSession: "composer-origin")
        XCTAssertEqual(supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotRemovedPrompt)
    }

    func testRemovingARetakeBeforeTheCallHearsLeavesNoNote() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        let supervisor = harness.appState.voiceBackgroundJobSupervisor
        let thread = VoiceThreadTarget(runtimeSessionID: "composer-origin", storedSessionID: nil, title: "Chat")
        supervisor.attachLiveThread(thread)
        let first = try stagedScreenshot()
        let retake = try stagedScreenshot()
        harness.appState.setPendingScreenshot(first, forSession: "composer-origin")
        harness.appState.noteScreenshot(first, on: "composer-origin", toCallIn: thread)
        harness.appState.setPendingScreenshot(retake, forSession: "composer-origin")
        harness.appState.noteScreenshot(retake, on: "composer-origin", toCallIn: thread)

        harness.appState.discardPendingScreenshot(forSession: "composer-origin")

        XCTAssertNil(supervisor.takePendingChatContext(), "The call never heard of either screenshot")
    }

    func testRemovingARetakeAfterTheCallHeardOfTheFirstTellsTheCall() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        let supervisor = harness.appState.voiceBackgroundJobSupervisor
        let thread = VoiceThreadTarget(runtimeSessionID: "composer-origin", storedSessionID: nil, title: "Chat")
        supervisor.attachLiveThread(thread)
        let first = try stagedScreenshot()
        let retake = try stagedScreenshot()
        harness.appState.setPendingScreenshot(first, forSession: "composer-origin")
        harness.appState.noteScreenshot(first, on: "composer-origin", toCallIn: thread)
        XCTAssertEqual(supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotSharedPrompt)
        harness.appState.setPendingScreenshot(retake, forSession: "composer-origin")
        harness.appState.noteScreenshot(retake, on: "composer-origin", toCallIn: thread)

        harness.appState.discardPendingScreenshot(forSession: "composer-origin")

        XCTAssertEqual(
            supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotRemovedPrompt,
            "The retake's note is dropped, and the call that heard of a screenshot hears it's gone"
        )
        XCTAssertNil(supervisor.takePendingChatContext())
    }

    func testRemovingAScreenshotTheCallStartedWithTellsTheCall() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")
        // The call's instructions named it: no note was needed.
        let supervisor = harness.appState.voiceBackgroundJobSupervisor
        supervisor.attachLiveThread(VoiceThreadTarget(runtimeSessionID: "composer-origin", storedSessionID: nil, title: "Chat"))

        harness.appState.discardPendingScreenshot(forSession: "composer-origin")

        XCTAssertEqual(supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotRemovedPrompt)
    }

    func testRemovingAnotherChatsScreenshotLeavesTheCallsNote() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        let supervisor = harness.appState.voiceBackgroundJobSupervisor
        let thread = VoiceThreadTarget(runtimeSessionID: "composer-origin", storedSessionID: nil, title: "Chat")
        supervisor.attachLiveThread(thread)
        let shot = try stagedScreenshot()
        let other = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")
        harness.appState.noteScreenshot(shot, on: "composer-origin", toCallIn: thread)
        harness.appState.setPendingScreenshot(other, forSession: "chat-b")

        harness.appState.discardPendingScreenshot(forSession: "chat-b")

        XCTAssertEqual(supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotSharedPrompt)
        XCTAssertNil(supervisor.takePendingChatContext(), "Nothing about a screenshot the call never knew")
    }

    func testScreenshotDroppedByTheCapTellsTheCall() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        let supervisor = harness.appState.voiceBackgroundJobSupervisor
        let thread = VoiceThreadTarget(runtimeSessionID: "composer-origin", storedSessionID: nil, title: "Chat")
        supervisor.attachLiveThread(thread)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")
        harness.appState.noteScreenshot(shot, on: "composer-origin", toCallIn: thread)
        XCTAssertEqual(supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotSharedPrompt)

        for index in 0..<ScreenQuestionPolicy.maximumPendingScreenshots {
            let other = try stagedScreenshot()
            harness.appState.setPendingScreenshot(other, forSession: "chat-\(index)")
        }

        XCTAssertNil(harness.appState.pendingScreenshot(forSession: "composer-origin"), "The oldest is dropped")
        XCTAssertEqual(supervisor.takePendingChatContext(), VoiceBackgroundJobSupervisor.screenshotRemovedPrompt)
    }

    func testVoiceSheetShowsAndDiscardsTheChatsScreenshot() throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        openChat("composer-origin", in: harness)
        XCTAssertNil(harness.appState.voiceScreenshot)
        let shot = try stagedScreenshot()
        harness.appState.setPendingScreenshot(shot, forSession: "composer-origin")

        XCTAssertEqual(harness.appState.voiceScreenshot, shot)
        harness.appState.discardVoiceScreenshot()

        XCTAssertNil(harness.appState.voiceScreenshot)
        XCTAssertFalse(fileExists(shot))
    }

    // MARK: - Harness

    private typealias Harness = (appState: AppState, defaults: UserDefaults)

    private func makeHarness(recorder: ScreenQuestionCallRecorder) -> Harness {
        var operations = ChatResumeLifecycleOperations(
            sendPrompt: { _, sessionID, text in
                recorder.prompts.append((sessionID, text))
                recorder.onPrompt?()
                return .accepted
            },
            steer: { _, sessionID, text in
                recorder.steers.append((sessionID, text))
            }
        )
        operations.uploadAttachment = { _, sessionID, attachment in
            recorder.uploads.append((sessionID, attachment))
        }
        return makeHarness(lifecycleOperations: operations)
    }

    private func makeHarness(lifecycleOperations: ChatResumeLifecycleOperations) -> Harness {
        let suite = "AppStateScreenQuestionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = ChatResumeStore(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        return (appState, defaults)
    }

    private func installComposerClient(in harness: Harness) {
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
    }

    private func openChat(_ id: String, in harness: Harness, withMessages: Bool = false) {
        installComposerClient(in: harness)
        harness.appState.sessions = [session(id)]
        harness.appState.activeSessionId = id
        if withMessages {
            harness.appState.messages = [
                ChatMessage(id: "m1", role: .user, content: "Earlier", timestamp: "1"),
                ChatMessage(id: "m2", role: .assistant, content: "Earlier answer", timestamp: "2")
            ]
        }
    }

    private func session(_ id: String, storedID: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: storedID,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    /// A real file in the staging folder, like the one the action writes.
    private func stagedScreenshot() throws -> Attachment {
        let url = try AttachmentStaging.destination(for: "Screenshot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Attachment(
            id: UUID().uuidString,
            name: "Screenshot.png",
            uri: url.absoluteString,
            mimeType: "image/png",
            kind: .image
        )
    }

    private func fileExists(_ attachment: Attachment) -> Bool {
        guard let url = URL(string: attachment.uri) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func request(
        for attachment: Attachment,
        question: String? = nil,
        startWith: ScreenQuestionStart? = nil,
        enqueuedAt: Date = Date(),
        startsNewChat: Bool = false
    ) -> ScreenQuestionRequest {
        ScreenQuestionRequest(
            attachment: attachment,
            question: question,
            startWith: startWith,
            enqueuedAt: enqueuedAt,
            startsNewChat: startsNewChat
        )
    }

    private func intent(
        for attachment: Attachment,
        question: String? = nil,
        startWith: ScreenQuestionStart? = nil,
        profile: String? = nil,
        enqueuedAt: Date = Date(),
        startsNewChat: Bool = false
    ) -> PendingVoiceIntent {
        PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(
            request(for: attachment, question: question, startWith: startWith, enqueuedAt: enqueuedAt, startsNewChat: startsNewChat),
            profile: profile
        )
    }

    /// A chat with a conversation in it and no client, so a new chat
    /// can't start.
    private func openChatWithoutClient(_ id: String, in harness: Harness) {
        harness.appState.sessions = [session(id)]
        harness.appState.activeSessionId = id
        harness.appState.messages = [
            ChatMessage(id: "m1", role: .user, content: "Earlier", timestamp: "1"),
            ChatMessage(id: "m2", role: .assistant, content: "Earlier answer", timestamp: "2")
        ]
    }
}

/// Seam calls for one test. The seams and the test body all run on the
/// MainActor, so plain stored properties are confinement-correct.
@MainActor
private final class ScreenQuestionCallRecorder {
    var uploads: [(sessionID: String, attachment: Attachment)] = []
    var prompts: [(sessionID: String, text: String)] = []
    var steers: [(sessionID: String, text: String)] = []
    var compressions = 0
    var onPrompt: (() -> Void)?
}
