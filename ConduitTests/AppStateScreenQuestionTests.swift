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

        harness.appState.parkScreenQuestion(request(for: older))
        harness.appState.parkScreenQuestion(request(for: newer))

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.attachment, newer)
        XCTAssertEqual(harness.appState.parkedScreenQuestionRevision, revision &+ 2)
        XCTAssertFalse(fileExists(older))
        XCTAssertTrue(fileExists(newer))
    }

    func testParkedScreenshotWaitsWhileDisconnected() async throws {
        let harness = makeHarness(recorder: ScreenQuestionCallRecorder())
        let shot = try stagedScreenshot()
        harness.appState.parkScreenQuestion(request(for: shot))

        await harness.appState.resumeParkedScreenQuestion()

        XCTAssertEqual(harness.appState.parkedScreenQuestion?.attachment, shot)
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
        ))
        harness.appState.isConnected = true

        await harness.appState.resumeParkedScreenQuestion()

        XCTAssertNil(harness.appState.parkedScreenQuestion)
        XCTAssertEqual(harness.appState.activeSessionId, "composer-origin", "The user is in Conduit now: the chat on screen")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
        XCTAssertTrue(recorder.prompts.isEmpty, "A question from before the outage is not sent by itself")
        XCTAssertEqual(harness.appState.composerPrefillText, "Why is this greyed out?")
    }

    func testRecentLaunchJoinsOpenChatAndFocusesComposer() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("composer-origin", in: harness, withMessages: true)
        harness.appState.isConnected = true
        let now = Date()
        harness.appState.lastLeftForegroundAt = now.addingTimeInterval(-60)
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot, enqueuedAt: now))

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "composer-origin")
        XCTAssertEqual(harness.appState.pendingScreenshot(forSession: "composer-origin"), shot)
        XCTAssertNotNil(harness.appState.composerFocusRequest)
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

    func testEmptyOpenChatIsReusedWhenNotRecent() async throws {
        let recorder = ScreenQuestionCallRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("fresh-chat", in: harness)
        harness.appState.isConnected = true
        harness.appState.lastLeftForegroundAt = nil
        let shot = try stagedScreenshot()

        let opened = await harness.appState.openScreenQuestion(intent(for: shot))

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
    }

    // MARK: - Harness

    private typealias Harness = (appState: AppState, defaults: UserDefaults)

    private func makeHarness(recorder: ScreenQuestionCallRecorder) -> Harness {
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
        enqueuedAt: Date = Date()
    ) -> ScreenQuestionRequest {
        ScreenQuestionRequest(attachment: attachment, question: question, startWith: nil, enqueuedAt: enqueuedAt)
    }

    private func intent(
        for attachment: Attachment,
        question: String? = nil,
        enqueuedAt: Date = Date()
    ) -> PendingVoiceIntent {
        PendingVoiceLaunchPolicy.makeScreenQuestionPendingIntent(
            request(for: attachment, question: question, enqueuedAt: enqueuedAt),
            profile: nil
        )
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
}
