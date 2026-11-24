import UIKit
import SwiftUI
import XCTest
@testable import Conduit

/// Regression coverage for the foreground lifecycle contract: a healthy
/// foreground transition is observational (never a `session.resume` session
/// replacement), an ambiguous `prompt.submit` acknowledgement is recovered
/// through the authoritative runtime registry instead of a blind retry, and a
/// stale local idle state is corrected before the next submission is routed.
@MainActor
final class AppStateForegroundLifecycleTests: XCTestCase {
    func testForegroundAfterFailedInitialConnectPreservesRestoredVisibleSession() async {
        var scheduledCount = 0
        var connectCount = 0
        var openedSessionIDs: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in
                    connectCount += 1
                    if connectCount == 1 { throw NSError(domain: "connect", code: 1) }
                },
                loadCatalog: { _, _ in
                    [self.session("stored-newest"), self.session("stored-visible")]
                },
                mintTicket: { _ in "refreshed-ticket" },
                openSession: { _, sessionID, _ in
                    openedSessionIDs.append(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        storedSessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            ),
            configureDefaults: { defaults in
                defaults.set(
                    "https://one.example",
                    forKey: AppState.chatResumeServerIdentityKey
                )
                ChatResumeStore(defaults: defaults).setLastSessionID(
                    "stored-visible",
                    for: "default"
                )
            },
            reconnectScheduler: { _, _ in
                scheduledCount += 1
                return {}
            }
        )
        let visible = session("stored-visible")
        harness.appState.sessions = [visible]
        XCTAssertEqual(harness.appState.activeSessionId, visible.id)

        await harness.appState.connect(
            with: HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        )
        XCTAssertEqual(harness.appState.activeSessionId, visible.id)
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent)
        XCTAssertEqual(scheduledCount, 1)

        harness.appState.handleScenePhase(.background)
        let foreground = harness.appState.handleScenePhase(.active)
        await foreground?.value

        XCTAssertEqual(openedSessionIDs, [visible.id])
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(harness.appState.activeSessionId, visible.id)
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent)
    }

    func testFastSecondSendKeepsStoredConversationWhenRefreshedCatalogDropsRuntimeAlias() async {
        var resumes: [String] = []
        var sends: [String] = []
        let rows: [[String: Any]] = [
            ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"],
            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
        ]
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated"), self.session("stored-a")] },
            openSession: { _, id, _ in
                resumes.append(id)
                return SessionResumeResult(sessionId: id == "stored-a" ? "runtime-a" : id,
                    messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in .payload([
                "session_id": "stored-a", "messages": rows,
                "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
            ]) },
            refreshContext: { _, _ in },
            sendPrompt: { _, id, _ in sends.append(id); return .accepted },
            verifyTransportHealth: { _ in }
        ))
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        let first = await harness.appState.submitComposer(text: "First")
        XCTAssertTrue(first)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "runtime-a", busy: true))
        harness.appState.handleStreamEvent(.messageComplete(sessionId: "runtime-a", messageId: nil,
            content: "First answer", reasoning: nil))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "runtime-a", busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        let second = await harness.appState.submitComposer(text: "Second")

        XCTAssertTrue(second)
        XCTAssertEqual(resumes, ["stored-a", "stored-a"], "Lagging persistence must recover the selected conversation")
        XCTAssertEqual(sends, ["runtime-a", "runtime-a"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")
        XCTAssertEqual(harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a")
        XCTAssertEqual(harness.appState.messages.last?.content, "Second")
        box.client.disconnect()
    }

    func testSendRefusedByDesktopOwnershipOffersTakeover() async {
        // #304: Hermes Desktop owns the chat, so prompt.submit is refused with
        // SESSION_NOT_OWNED. Conduit offers "Take over" instead of a bare
        // send failure, naming the owner and every id the chat goes by.
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defaults.set(false, forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        var sends = 0
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("stored-a")] },
            openSession: { _, id, _ in
                SessionResumeResult(sessionId: "runtime-a", storedSessionId: "stored-a",
                    messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, _, _ in
                sends += 1
                throw RpcError(
                    code: 4090,
                    message: "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\nDetails: session stored-a opened by desktop 3m ago.",
                    reason: "SESSION_NOT_OWNED"
                )
            },
            verifyTransportHealth: { _ in }
        ))
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposer(text: "From my phone")

        XCTAssertFalse(submitted, "The refused draft goes back to the composer")
        XCTAssertEqual(sends, 1)
        let takeover = harness.appState.chatTakeover
        XCTAssertEqual(takeover?.sessionID, "runtime-a")
        XCTAssertEqual(takeover?.surface, "desktop")
        XCTAssertEqual(takeover?.phase, .offered)
        XCTAssertEqual(takeover?.sessionIDs.first, "runtime-a")
        XCTAssertTrue(takeover?.sessionIDs.contains("stored-a") ?? false)
        XCTAssertNil(harness.appState.errorMessage, "The takeover offer replaces the send failure")
        XCTAssertEqual(harness.appState.activeChatTakeover, takeover, "The open chat shows the offer")

        harness.appState.dismissChatTakeover()
        XCTAssertNil(harness.appState.chatTakeover)
        box.client.disconnect()
    }

    /// Operations for a chat Hermes Desktop holds until the takeover route
    /// answers (#1061): every send before it is refused.
    private func desktopHeldChatOperations(
        sends: @escaping (String) -> Void,
        takenOver: @escaping () -> Bool
    ) -> ChatResumeLifecycleOperations {
        ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("stored-a")] },
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", storedSessionId: "stored-a",
                    messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, _, text in
                sends(text)
                guard takenOver() else {
                    throw RpcError(
                        code: 4090,
                        message: "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\nDetails: session stored-a opened by desktop 3m ago.",
                        reason: "SESSION_NOT_OWNED"
                    )
                }
                return .accepted
            },
            verifyTransportHealth: { _ in }
        )
    }

    func testCallRequestRefusedByDesktopIsSentAgainAfterTakeover() async {
        // #1061: a call's first request in a chat Desktop still holds was
        // refused, the chat was taken over, and the request was lost. With
        // Take over automatically on, the call takes the chat over and sends
        // the same request once more.
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defaults.set(true, forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        var sent: [String] = []
        var takenOver = false
        var takeoverBodies: [[String: Any]] = []
        let harness = makeHarness(lifecycleOperations: desktopHeldChatOperations(
            sends: { sent.append($0) }, takenOver: { takenOver }
        ))
        harness.appState.chatTakeoverClient = ChatTakeoverClient(request: { path, method, body in
            XCTAssertTrue(path.hasPrefix(ChatTakeoverClient.path))
            XCTAssertEqual(method, "POST")
            takeoverBodies.append(body ?? [:])
            takenOver = true
            return ["ok": true, "status": "taken_over"]
        })
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposerForCall(text: "What's on my calendar")

        XCTAssertTrue(submitted, "The call's request goes through after the takeover")
        XCTAssertEqual(sent, ["What's on my calendar", "What's on my calendar"])
        XCTAssertEqual(takeoverBodies.count, 1)
        let ids = takeoverBodies.first?["session_ids"] as? [String] ?? []
        XCTAssertTrue(ids.contains("runtime-a") && ids.contains("stored-a"))
        XCTAssertNil(harness.appState.chatTakeover, "No notice is left for the composer to resend")
        XCTAssertNil(harness.appState.errorMessage)
        box.client.disconnect()
    }

    func testBotChatTakeoverAsksTheBotsProfile() async {
        // A Bot Chat's claim is in its bot's registry. The takeover asked the
        // workspace profile, which found nobody holding the chat, so every
        // resend was refused again and the offer never went away.
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defaults.set(true, forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        var sent: [String] = []
        var takenOver = false
        var takeoverPaths: [String] = []
        let harness = makeHarness(lifecycleOperations: desktopHeldChatOperations(
            sends: { sent.append($0) }, takenOver: { takenOver }
        ))
        harness.appState.chatTakeoverClient = ChatTakeoverClient(request: { path, _, _ in
            takeoverPaths.append(path)
            takenOver = path.contains("profile=nahida")
            return ["ok": true, "status": takenOver ? "taken_over" : "free"]
        })
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        harness.appState.noteBotChatSessionForTesting("stored-a", profile: "nahida")
        harness.appState.noteBotChatSessionForTesting("runtime-a", profile: "nahida")

        let submitted = await harness.appState.submitComposerForCall(text: "Hi Nahida")

        XCTAssertTrue(submitted, "The request goes through once the bot's claim is dropped")
        XCTAssertEqual(sent, ["Hi Nahida", "Hi Nahida"])
        XCTAssertEqual(takeoverPaths.count, 1)
        XCTAssertTrue(takeoverPaths.first?.contains("profile=nahida") ?? false, "Asked of \(takeoverPaths)")
        XCTAssertNil(harness.appState.chatTakeover)
        box.client.disconnect()
    }

    func testCallRequestTakesOverEvenWithAutomaticTakeoverOff() async {
        // Starting a call in the chat already says the user wants it here:
        // the call takes over whatever the composer's setting says.
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defaults.set(false, forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        var sent: [String] = []
        var takenOver = false
        let harness = makeHarness(lifecycleOperations: desktopHeldChatOperations(
            sends: { sent.append($0) }, takenOver: { takenOver }
        ))
        harness.appState.chatTakeoverClient = ChatTakeoverClient(request: { _, _, _ in
            takenOver = true
            return ["ok": true, "status": "taken_over"]
        })
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposerForCall(text: "What's on my calendar")

        XCTAssertTrue(submitted)
        XCTAssertEqual(sent, ["What's on my calendar", "What's on my calendar"])
        XCTAssertNil(harness.appState.chatTakeover)
        box.client.disconnect()
    }

    /// A typed send refused in a chat Desktop holds, with Take over
    /// automatically on: what the composer does with a send that didn't go,
    /// handing its words back to AppState.
    private func refuseTypedSendInDesktopChat(
        _ text: String,
        sends: @escaping (String) -> Void,
        takenOver: @escaping () -> Bool,
        takeover: @escaping () -> [String: Any]
    ) async -> (harness: (
        appState: AppState,
        coordinator: ChatResumeCoordinator,
        store: ChatResumeStore,
        recoverySequence: ChatResumeRecoverySequence
    ), box: ConnectedClientBox) {
        let harness = makeHarness(lifecycleOperations: desktopHeldChatOperations(sends: sends, takenOver: takenOver))
        harness.appState.chatTakeoverClient = ChatTakeoverClient(request: { _, _, _ in takeover() })
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        let key = harness.appState.durableComposerDraftKeyOnScreen

        let submitted = await harness.appState.submitComposer(text: text)

        XCTAssertFalse(submitted)
        XCTAssertEqual(harness.appState.chatTakeover?.phase, .waiting, "Take over automatically started")
        harness.appState.returnFailedComposerSubmission(
            ComposerDraft(text: text, attachments: []),
            key: key, dashboardID: harness.appState.activeDashboardID ?? UUID(), title: "Trip plans", stoppedQuietly: false
        )
        return (harness, box)
    }

    func testTypedSendRefusedByDesktopIsSentByConduitAfterTheAutomaticTakeover() async {
        // Issue 2140: the takeover worked, but the composer only resent when
        // its field still held the refused message. Its words came back
        // somewhere else, so the field was empty under "This chat is yours
        // now. Send your message again." Conduit now keeps them and sends
        // them itself, as a call does its request (#1061).
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defaults.set(true, forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        var sent: [String] = []
        var takenOver = false
        let (harness, box) = await refuseTypedSendInDesktopChat(
            "From my phone", sends: { sent.append($0) }, takenOver: { takenOver },
            takeover: {
                takenOver = true
                return ["ok": true, "status": "taken_over"]
            }
        )

        XCTAssertTrue(harness.appState.composerRestoreRequests.isEmpty, "Conduit keeps the words while it takes the chat over")
        for _ in 0..<300 where sent.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(sent, ["From my phone", "From my phone"], "Sent again once the chat is Conduit's")
        XCTAssertNil(harness.appState.chatTakeover, "No notice asks to send again")
        XCTAssertTrue(harness.appState.composerRestoreRequests.isEmpty, "Nothing comes back to send twice")
        box.client.disconnect()
    }

    func testKeptTypedMessageComesBackWhenTheTakeoverDoesNotHappen() async {
        // Conduit on another device holds the chat, so the host never hands
        // it over: the kept words go back to the composer, never lost.
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defaults.set(true, forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        var sent: [String] = []
        let (harness, box) = await refuseTypedSendInDesktopChat(
            "From my phone", sends: { sent.append($0) }, takenOver: { false },
            takeover: { ["ok": true, "status": "same_host"] }
        )
        for _ in 0..<300 where harness.appState.chatTakeover?.phase == .waiting {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(harness.appState.chatTakeover?.phase, .heldHere)
        XCTAssertEqual(harness.appState.composerRestoreRequests.map(\.draft.text), ["From my phone"])
        XCTAssertEqual(sent, ["From my phone"])
        box.client.disconnect()
    }

    func testKeptTypedMessageComesBackWhenTheTakeoverIsDismissed() async {
        // Desktop is still replying, so Conduit waits; closing the notice
        // stops the takeover and the words go back to the composer.
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defaults.set(true, forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        var sent: [String] = []
        let (harness, box) = await refuseTypedSendInDesktopChat(
            "From my phone", sends: { sent.append($0) }, takenOver: { false },
            takeover: { ["ok": true, "status": "busy", "surface": "desktop"] }
        )
        XCTAssertTrue(harness.appState.composerRestoreRequests.isEmpty)

        harness.appState.dismissChatTakeover()

        XCTAssertEqual(harness.appState.composerRestoreRequests.map(\.draft.text), ["From my phone"])
        XCTAssertEqual(sent, ["From my phone"])
        box.client.disconnect()
    }

    func testCallRequestRefusedAgainAfterTakeoverStopsAndALaterOneTriesAgain() async {
        // Desktop took the chat straight back: one resend, no third send,
        // and the call says the chat is open there. The next request takes
        // over again rather than being blocked for the rest of the call.
        var sent: [String] = []
        var takeovers = 0
        let harness = makeHarness(lifecycleOperations: desktopHeldChatOperations(
            sends: { sent.append($0) }, takenOver: { false }
        ))
        harness.appState.chatTakeoverClient = ChatTakeoverClient(request: { _, _, _ in
            takeovers += 1
            return ["ok": true, "status": "taken_over"]
        })
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let first = await harness.appState.submitComposerForCall(text: "What's on my calendar")

        XCTAssertFalse(first)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(takeovers, 1)
        XCTAssertEqual(
            harness.appState.callRefusalMessageForOpenChat(),
            AppLocalization.string("This chat is open in Hermes Desktop. Take it over to send from here.", table: .chat)
        )

        let second = await harness.appState.submitComposerForCall(text: "Any new email")

        XCTAssertFalse(second)
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(takeovers, 2)
        box.client.disconnect()
    }

    func testCallRequestThatCannotTakeOverSaysWhy() async {
        // Conduit on another device holds the chat: the host never takes it
        // from there, and the call says so instead of a bare failure.
        var sent: [String] = []
        let harness = makeHarness(lifecycleOperations: desktopHeldChatOperations(
            sends: { sent.append($0) }, takenOver: { false }
        ))
        harness.appState.chatTakeoverClient = ChatTakeoverClient(request: { _, _, _ in
            ["ok": true, "status": "same_host"]
        })
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposerForCall(text: "What's on my calendar")

        XCTAssertFalse(submitted)
        XCTAssertEqual(sent, ["What's on my calendar"])
        XCTAssertEqual(harness.appState.chatTakeover?.phase, .heldHere)
        XCTAssertEqual(harness.appState.callRefusalMessageForOpenChat(), ChatTakeoverState.heldHereMessage)
        box.client.disconnect()
    }

    func testCallRequestRefusedAgainAfterTakeoverStopsWithTheReason() async {
        // Desktop took the chat straight back: one resend, then the call
        // says the chat is open there instead of the raw refusal.
        let harness = makeHarness()
        harness.appState.chatTakeoverClient = ChatTakeoverClient(request: { _, _, _ in
            ["ok": true, "status": "taken_over"]
        })
        var sends = 0
        do {
            _ = try await harness.appState.sendCallPromptTakingOver(
                runtimeID: "runtime-b", otherSessionIDs: [], profile: nil
            ) {
                sends += 1
                throw RpcError(code: 4090, message: "Details: session stored-b opened by desktop 1m ago.", reason: "SESSION_NOT_OWNED")
            }
            XCTFail("A second refusal fails the request")
        } catch {
            XCTAssertEqual(error as? VoiceAudioError, .unavailable(
                AppLocalization.string("This chat is open in Hermes Desktop. Take it over to send from here.", table: .chat)
            ))
        }
        XCTAssertEqual(sends, 2)
    }

    func testTakeOverAutomaticallyIsOnUntilTurnedOff() {
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        let appState = makeHarness().appState
        defaults.removeObject(forKey: ChatTakeoverPreference.automaticKey)
        XCTAssertTrue(appState.takesOverChatsAutomatically)
        defaults.set(false, forKey: ChatTakeoverPreference.automaticKey)
        XCTAssertFalse(appState.takesOverChatsAutomatically)
    }

    func testCallRequestToAChatOffScreenIsSentAgainAfterTakeover() async throws {
        // The same for a call attached to a chat that isn't on screen.
        let defaults = UserDefaults.standard
        let savedAutomatic = defaults.object(forKey: ChatTakeoverPreference.automaticKey)
        defaults.set(true, forKey: ChatTakeoverPreference.automaticKey)
        defer { defaults.set(savedAutomatic, forKey: ChatTakeoverPreference.automaticKey) }
        let harness = makeHarness()
        var takeoverIDs: [String] = []
        harness.appState.chatTakeoverClient = ChatTakeoverClient(request: { _, _, body in
            takeoverIDs = body?["session_ids"] as? [String] ?? []
            return ["ok": true, "status": "taken_over"]
        })
        var sends = 0
        let outcome = try await harness.appState.sendCallPromptTakingOver(
            runtimeID: "runtime-b", otherSessionIDs: ["stored-b"], profile: nil
        ) {
            sends += 1
            if sends == 1 {
                throw RpcError(code: 4090, message: "Details: session stored-b opened by desktop 1m ago.", reason: "SESSION_NOT_OWNED")
            }
            return .accepted
        }
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(sends, 2)
        XCTAssertEqual(takeoverIDs, ["runtime-b", "stored-b"])
    }

    func testComposerSubmissionSurvivesLegitimateRuntimeRotationDuringRecovery() async {
        // Hermes legitimately rotates stored-a: runtime-old → runtime-new
        // during the second send's freshness recovery. The in-flight
        // submission keeps ownership (same profile, client, epoch, viewport
        // generation, durable conversation) and routes to the NEW runtime id.
        var resumes: [String] = []
        var sends: [String] = []
        let rows: [[String: Any]] = [
            ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"],
            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
        ]
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("unrelated"), self.session("stored-a")] },
            openSession: { _, id, _ in
                resumes.append(id)
                let rotated = resumes.count > 1
                return SessionResumeResult(
                    sessionId: id == "stored-a" ? (rotated ? "runtime-new" : "runtime-old") : id,
                    storedSessionId: id == "stored-a" && rotated ? "stored-a" : nil,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in .payload([
                "session_id": "stored-a", "messages": rows,
                "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
            ]) },
            refreshContext: { _, _ in },
            sendPrompt: { _, id, _ in sends.append(id); return .accepted },
            verifyTransportHealth: { _ in }
        ))
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [self.session("stored-a", alternateIDs: ["runtime-old"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-old")
        let first = await harness.appState.submitComposer(text: "First")
        XCTAssertTrue(first)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "runtime-old", busy: true))
        harness.appState.handleStreamEvent(.messageComplete(sessionId: "runtime-old", messageId: nil,
            content: "First answer", reasoning: nil))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: "runtime-old", busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        let second = await harness.appState.submitComposer(text: "Second")

        XCTAssertTrue(second)
        XCTAssertEqual(resumes, ["stored-a", "stored-a"])
        XCTAssertEqual(sends, ["runtime-old", "runtime-new"], "The rebound submission routes to the new runtime id")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-new")
        XCTAssertEqual(
            harness.appState.activeChatScrollSessionIdentity.canonicalSessionID, "stored-a",
            "Rotation is a routing rebind, not navigation to another conversation"
        )
        XCTAssertEqual(harness.appState.messages.last?.content, "Second")
        box.client.disconnect()
    }

    func testNavigationHandoffToSameConversationStillInvalidatesSubmission() async {
        // A → B → A is a navigation handoff, not a runtime rebind: each
        // explicit open bumps the viewport generation, so a suspended
        // submission captured on A stays invalid even though the durable
        // conversation is A again.
        var sends: [String] = []
        let a = self.session("stored-a")
        let b = self.session("stored-b")
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [a, b] },
            openSession: { _, id, _ in
                SessionResumeResult(sessionId: "runtime-\(id)", messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, id, _ in sends.append(id); return .accepted }
        ))
        _ = await installConnectedClient(into: harness)
        harness.appState.sessions = [a, b]
        let openedA = await harness.appState.openSession("stored-a")
        XCTAssertTrue(openedA)
        let handoffContext = harness.appState.composerSubmissionContext()

        let openedB = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedB)
        let reopenedA = await harness.appState.openSession("stored-a")
        XCTAssertTrue(reopenedA)

        let submitted = await harness.appState.submitComposer(text: "Stale", context: handoffContext)

        XCTAssertFalse(submitted, "Suspended work from before the handoff must not send after returning to A")
        XCTAssertTrue(sends.isEmpty)

        // Positive control: a FRESH context captured after reopening A sends
        // normally — proving the rejection above comes from the ownership
        // generation fence, not from a broken composer path.
        let freshContext = harness.appState.composerSubmissionContext()
        let freshSubmitted = await harness.appState.submitComposer(text: "Fresh after return", context: freshContext)
        XCTAssertTrue(freshSubmitted)
        XCTAssertEqual(sends, ["runtime-stored-a"])
    }


    // MARK: - A. Healthy socket + active turn

    func testForegroundWithHealthySocketAndActiveTurnDoesNotResume() async {
        let active = session("stored-a")
        var healthChecks = 0
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    // The bounded tail always matches what the device last
                    // hydrated: same-turn continuity, provably unchanged.
                    return .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in healthChecks += 1 },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path so the durable frontier covers
        // the turn Conduit is about to own.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let seedMessages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        XCTAssertEqual(harness.appState.messages, seedMessages)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(healthChecks, 1, "The foreground must verify the transport health once")
        XCTAssertEqual(probeCount, 1, "The foreground must query the authoritative runtime registry")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "A healthy foreground must never issue session.resume"
        )
        XCTAssertEqual(catalogCount, 0, "A healthy foreground must not reload the session catalog")
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertEqual(harness.appState.activeSessionId, active.id)
        XCTAssertEqual(harness.appState.messages, seedMessages, "Foregrounding must not replace the transcript")
        XCTAssertFalse(harness.appState.turnStateIsStale)

        // The stream gate is open again after the observational settle: later
        // turn events land without a transcript replacement. The streaming
        // projection publishes on a short coalescing cadence, so poll briefly.
        harness.appState.handleStreamEvent(.messageDelta(sessionId: active.id, text: " more"))
        let published = await waitForStreamingText(" more", in: harness.appState)
        XCTAssertTrue(published, "The post-foreground delta must land in the streaming projection")
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling
        )
        box.client.disconnect()
    }

    /// Issue 1727: the registry probe goes out beside the health ping
    /// instead of after it, and its rows count only once the ping passed.
    func testForegroundProbeOverlapsTheHealthPing() async {
        let active = session("stored-a")
        let healthGate = LifecycleSuspension()
        var probeCount = 0
        var probesBeforeHealthAnswered: Int?
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in
                    await healthGate.suspend()
                    probesBeforeHealthAnswered = probeCount
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        probeCount = 0
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        let activation = harness.appState.handleScenePhase(.active)
        await healthGate.waitUntilSuspended()
        for _ in 0..<50 where probeCount == 0 { await Task.yield() }
        healthGate.resume()
        if let activation { await activation.value }

        XCTAssertEqual(probesBeforeHealthAnswered, 1, "The probe must go out while the ping is still out")
        XCTAssertEqual(probeCount, 1, "One registry read serves the foreground")
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "A healthy foreground must never issue session.resume")
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    // MARK: - One chat on two devices (ChatSync.swift)

    /// What the server holds for "stored-a", and the clock the open chat's
    /// checks read.
    private final class TwoDeviceServer {
        var rows: [[String: Any]] = [
            ["id": "1", "role": "user", "content": "Question", "timestamp": "1"],
        ]
        var live: [LiveSessionStatus] = []
        /// What the registry answers on a given probe (1-based), else `live`.
        var liveOnProbe: [Int: [LiveSessionStatus]] = [:]
        var probes = 0
        var resumes = 0
        var transcriptReads = 0
        var sends = 0
        /// The dashboard has no bounded history read (a v0.19 gateway).
        var transcriptUnavailable = false
        /// The chat's stored message count in the catalog.
        var catalogCount: Int?
        var now = Date(timeIntervalSince1970: 3_000_000)

        var payload: [String: Any] {
            [
                "messages": rows,
                "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": rows.count],
            ]
        }
    }

    private func twoDeviceHarness(_ server: TwoDeviceServer) -> (
        appState: AppState,
        coordinator: ChatResumeCoordinator,
        store: ChatResumeStore,
        recoverySequence: ChatResumeRecoverySequence
    ) {
        let active = session("stored-a")
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    var listed = active
                    listed.messageCount = server.catalogCount
                    return [listed]
                },
                openSession: { _, sessionID, _ in
                    server.resumes += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    server.transcriptReads += 1
                    return server.transcriptUnavailable ? .unavailable : .payload(server.payload)
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    server.sends += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    server.probes += 1
                    return server.liveOnProbe[server.probes] ?? server.live
                }
            )
        )
        harness.appState.chatSyncNow = { server.now }
        return harness
    }

    private func openTwoDeviceChat(
        _ harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence
        )
    ) async -> ConnectedClientBox {
        let box = await installConnectedClient(into: harness)
        let active = session("stored-a")
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        harness.appState.isConnected = true
        return box
    }

    private func tick(_ appState: AppState, after seconds: TimeInterval, _ server: TwoDeviceServer) async {
        server.now += seconds
        await appState.openChatSyncTick()
        await appState.openChatSyncRead?.value
    }

    /// The overlap repro: this device sent a turn, another device sent
    /// right after it, and Hermes streamed the merged reply there. Here the
    /// turn went quiet. While the registry shows it running the chat says
    /// another device is replying and never resumes (that would take the
    /// stream back); once two snapshots show it over, one read brings the
    /// reply and Working ends.
    func testAQuietTurnSettlesOnlyAfterTheRegistryShowsItOver() async {
        let server = TwoDeviceServer()
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let resumesAtOpen = server.resumes
        appState.handleStreamEvent(.sessionBusy(sessionId: "stored-a", busy: true))
        XCTAssertEqual(appState.turnState, .running)

        await tick(appState, after: 0, server)
        await tick(appState, after: 10, server)
        XCTAssertEqual(server.probes, 0, "A turn that streams normally isn't checked")

        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "working",
            messageCount: 1, preview: "MANGO **Rings of the Main: A History of the Montreal bagel"
        )]
        for _ in 0..<20 { // over two and a half minutes
            await tick(appState, after: 8, server)
        }
        XCTAssertGreaterThan(server.probes, 0)
        XCTAssertTrue(appState.activeChatRepliesElsewhere)
        XCTAssertEqual(server.resumes, resumesAtOpen, "Never resumed while another device gets the reply")
        XCTAssertEqual(appState.turnState, .running)

        // The reply is done and stored.
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 4
        )]
        server.rows += [
            ["id": "2", "role": "user", "content": "Overlap test B: reply only with MANGO", "timestamp": "2"],
            ["id": "3", "role": "assistant", "content": "MANGO", "timestamp": "3"],
        ]
        await tick(appState, after: 8, server)
        XCTAssertEqual(server.resumes, resumesAtOpen, "One idle snapshot isn't enough")
        await tick(appState, after: 8, server)

        XCTAssertEqual(server.resumes, resumesAtOpen + 1)
        XCTAssertEqual(appState.turnState, .idle)
        XCTAssertFalse(appState.activeChatRepliesElsewhere)
        XCTAssertEqual(appState.messages.last?.content, "MANGO")
        box.client.disconnect()
    }

    /// A turn can stream nothing for minutes (a long tool, a slow model);
    /// the registry still shows it, so nothing happens however long it
    /// runs, and its preview is this device's own prompt.
    func testAQuietTurnTheRegistryShowsRunningIsLeftAlone() async {
        let server = TwoDeviceServer()
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let resumesAtOpen = server.resumes
        appState.handleStreamEvent(.sessionBusy(sessionId: "stored-a", busy: true))
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "working", preview: "Question"
        )]

        for _ in 0..<40 {
            await tick(appState, after: 8, server)
        }

        XCTAssertEqual(server.resumes, resumesAtOpen)
        XCTAssertEqual(server.transcriptReads, 1, "Only the open read the transcript")
        XCTAssertEqual(appState.turnState, .running)
        XCTAssertFalse(appState.activeChatRepliesElsewhere, "Its preview is this device's own turn")
        box.client.disconnect()
    }

    /// A voice runtime and the chat's own can share its ids: an idle row
    /// beside a working one doesn't settle the turn.
    func testAQuietTurnWithAnyRowRunningIsLeftAlone() async {
        let server = TwoDeviceServer()
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let resumesAtOpen = server.resumes
        appState.handleStreamEvent(.sessionBusy(sessionId: "stored-a", busy: true))
        server.live = [
            LiveSessionStatus(runtimeSessionId: "runtime-voice", storedSessionId: "stored-a", status: "idle"),
            LiveSessionStatus(runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "working"),
        ]

        for _ in 0..<10 {
            await tick(appState, after: 8, server)
        }

        XCTAssertGreaterThan(server.probes, 2)
        XCTAssertEqual(server.resumes, resumesAtOpen)
        XCTAssertEqual(appState.turnState, .running)
        box.client.disconnect()
    }

    /// One device alone: a quick turn sent here moves the registry's count,
    /// and that is no reason to read or resume anything.
    func testAQuickTurnSentHereReadsNothing() async {
        let server = TwoDeviceServer()
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let resumesAtOpen = server.resumes
        let readsAtOpen = server.transcriptReads
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 1
        )]
        await tick(appState, after: 0, server)

        let sent = await appState.submitComposer(text: "Quick one")
        XCTAssertTrue(sent)
        appState.handleStreamEvent(.sessionBusy(sessionId: "stored-a", busy: true))
        appState.handleStreamEvent(.messageComplete(sessionId: "stored-a", messageId: nil, content: "Done", reasoning: nil))
        appState.handleStreamEvent(.sessionBusy(sessionId: "stored-a", busy: false))
        XCTAssertEqual(appState.turnState, .idle)
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 3
        )]
        for _ in 0..<4 {
            await tick(appState, after: 15, server)
        }

        XCTAssertEqual(server.sends, 1)
        XCTAssertGreaterThanOrEqual(server.probes, 4)
        XCTAssertEqual(server.resumes, resumesAtOpen)
        XCTAssertLessThanOrEqual(server.transcriptReads, readsAtOpen + 1, "At most the send's own freshness read")
        box.client.disconnect()
    }

    /// On a dashboard without the bounded history read, reading another
    /// device's turn means resuming the idle chat. The registry is asked
    /// right before: a turn begun meanwhile calls the resume off (it would
    /// take that turn's stream), and the read happens once it is over.
    func testAReadThatWouldResumeWaitsForATurnBegunMeanwhile() async {
        let server = TwoDeviceServer()
        server.transcriptUnavailable = true
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let resumesAtOpen = server.resumes
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 1
        )]
        await tick(appState, after: 0, server)
        let probesBefore = server.probes

        // Another device's turn moved the count; it sends again right away.
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 3
        )]
        server.liveOnProbe[probesBefore + 2] = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "working", messageCount: 3
        )]
        await tick(appState, after: 15, server)
        XCTAssertEqual(server.probes, probesBefore + 2, "The snapshot, then the check before resuming")
        XCTAssertEqual(server.resumes, resumesAtOpen, "No resume while a turn runs")
        XCTAssertFalse(appState.activeChatScrollSessionIdentity.isReconciling)

        // That turn is over: the next idle check reads it.
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 5
        )]
        await tick(appState, after: 15, server)
        XCTAssertEqual(server.resumes, resumesAtOpen + 1)
        box.client.disconnect()
    }

    /// The PINEAPPLE repro: the chat sits idle here while another device
    /// sends in it. Once the registry's count moves, the new rows are read
    /// (bounded and read-only: no resume) and show here.
    func testAnIdleChatReadsTheTurnAnotherDeviceRan() async {
        let server = TwoDeviceServer()
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let resumesAtOpen = server.resumes
        let readsAtOpen = server.transcriptReads
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 1
        )]
        await tick(appState, after: 0, server)
        XCTAssertEqual(server.probes, 1)
        await tick(appState, after: 5, server)
        XCTAssertEqual(server.probes, 1, "An idle chat is checked every 15 s")

        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 3
        )]
        server.rows += [
            ["id": "2", "role": "user", "content": "QA step-on test: reply only with PINEAPPLE", "timestamp": "2"],
            ["id": "3", "role": "assistant", "content": "PINEAPPLE", "timestamp": "3"],
        ]
        await tick(appState, after: 10, server)

        XCTAssertEqual(server.probes, 2)
        XCTAssertEqual(server.transcriptReads, readsAtOpen + 1)
        XCTAssertEqual(server.resumes, resumesAtOpen, "A read, not a resume")
        XCTAssertEqual(appState.messages.map(\.content), [
            "Question", "QA step-on test: reply only with PINEAPPLE", "PINEAPPLE",
        ])
        XCTAssertEqual(appState.turnState, .idle)

        await tick(appState, after: 15, server)
        XCTAssertEqual(server.transcriptReads, readsAtOpen + 1, "Nothing new: nothing read")
        box.client.disconnect()
    }

    /// #1026: a message sent from the TUI on the gateway's computer runs in
    /// another process. This gateway's registry row for the chat stays idle
    /// with its old count, so its checks never see the turn; Hermes'
    /// `sessions.changed` and the stored count do, and the rows show without
    /// a pull to refresh.
    func testATurnTheRegistryNeverSawShowsWhenHermesSaysTheChatMoved() async {
        let server = TwoDeviceServer()
        server.catalogCount = 1
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let resumesAtOpen = server.resumes
        let readsAtOpen = server.transcriptReads
        server.live = [LiveSessionStatus(
            runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle", messageCount: 1
        )]
        await tick(appState, after: 0, server)
        server.now += 10
        appState.handleStreamEvent(.sessionsChanged)
        await appState.leaveCatalogRefreshTask?.value
        XCTAssertEqual(server.transcriptReads, readsAtOpen, "Nothing moved yet")

        // The TUI's turn: stored, and never in this gateway's registry.
        server.rows += [
            ["id": "2", "role": "user", "content": "Sent from the TUI", "timestamp": "2"],
            ["id": "3", "role": "assistant", "content": "PAPAYA", "timestamp": "3"],
        ]
        server.catalogCount = 3
        for _ in 0..<4 {
            await tick(appState, after: 15, server)
        }
        XCTAssertEqual(server.transcriptReads, readsAtOpen, "The registry alone never sees it")

        appState.handleStreamEvent(.sessionsChanged)
        await appState.leaveCatalogRefreshTask?.value
        await appState.openChatCatalogCheck?.value
        await appState.openChatSyncRead?.value

        XCTAssertEqual(server.transcriptReads, readsAtOpen + 1)
        XCTAssertEqual(server.resumes, resumesAtOpen, "A read, not a resume")
        XCTAssertEqual(appState.messages.map(\.content), ["Question", "Sent from the TUI", "PAPAYA"])
        XCTAssertEqual(appState.turnState, .idle)
        box.client.disconnect()
    }

    /// The same with no live runtime of the chat on this gateway: the TUI's
    /// turn may still be running in its own process, out of this registry's
    /// sight, so the rows are read and the chat is never resumed (a resume
    /// could take it from that process).
    func testATurnTheRegistryNeverSawIsReadWithoutResumingAChatWithNoLiveRuntime() async {
        let server = TwoDeviceServer()
        server.catalogCount = 1
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let resumesAtOpen = server.resumes
        let readsAtOpen = server.transcriptReads
        await tick(appState, after: 0, server)
        server.now += 10
        appState.handleStreamEvent(.sessionsChanged)
        await appState.leaveCatalogRefreshTask?.value

        server.rows += [
            ["id": "2", "role": "user", "content": "Sent from the TUI", "timestamp": "2"],
            ["id": "3", "role": "assistant", "content": "PAPAYA", "timestamp": "3"],
        ]
        server.catalogCount = 3
        server.now += 10
        appState.handleStreamEvent(.sessionsChanged)
        await appState.leaveCatalogRefreshTask?.value
        await appState.openChatCatalogCheck?.value
        await appState.openChatSyncRead?.value

        XCTAssertEqual(server.transcriptReads, readsAtOpen + 1)
        XCTAssertEqual(server.resumes, resumesAtOpen, "Never resumed")
        XCTAssertEqual(appState.messages.map(\.content), ["Question", "Sent from the TUI", "PAPAYA"])
        XCTAssertEqual(appState.turnState, .idle)
        box.client.disconnect()
    }

    /// Another combined dashboard's chat opened in place under the same id
    /// isn't in this dashboard's catalog: Hermes' word that the chat moved
    /// reads nothing from this dashboard's Hermes.
    func testAnotherDashboardsChatUnderTheSameIdIsNotReadFromThisCatalog() async {
        let server = TwoDeviceServer()
        server.catalogCount = 1
        let harness = twoDeviceHarness(server)
        let box = await openTwoDeviceChat(harness)
        let appState = harness.appState
        let readsAtOpen = server.transcriptReads
        await tick(appState, after: 0, server)
        server.now += 10
        appState.handleStreamEvent(.sessionsChanged)
        await appState.leaveCatalogRefreshTask?.value

        server.rows += [
            ["id": "2", "role": "user", "content": "Sent from the TUI", "timestamp": "2"],
            ["id": "3", "role": "assistant", "content": "PAPAYA", "timestamp": "3"],
        ]
        server.catalogCount = 3
        appState.farChat = FarChatOwner(dashboardID: UUID(), profile: "work")
        server.now += 10
        appState.handleStreamEvent(.sessionsChanged)
        await appState.leaveCatalogRefreshTask?.value
        await appState.openChatCatalogCheck?.value
        await appState.openChatSyncRead?.value

        XCTAssertNil(appState.openChatCatalogCheck, "No check starts: this dashboard's registry isn't asked either")
        XCTAssertEqual(server.transcriptReads, readsAtOpen, "That chat is its own dashboard's to read")
        XCTAssertEqual(appState.messages.map(\.content), ["Question"])
        box.client.disconnect()
    }

    /// Bounded wait for the coalesced streaming publish (33 ms cadence).
    private func waitForStreamingText(
        _ expected: String,
        in appState: AppState,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if appState.streamingText == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return appState.streamingText == expected
    }

    // MARK: - B. Healthy socket + PR #121 live reasoning

    func testForegroundPreservesLiveReasoningSegmentOnHealthySocket() async {
        let active = session("stored-a")
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Step one."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(
            harness.appState.liveReasoningSegment, segmentBefore,
            "A harmless foreground cycle must not settle or reset the live reasoning segment"
        )
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "Proven same-turn continuity must not resume"
        )

        // Later reasoning deltas extend the SAME segment (a reset would nil
        // the projection or mint a new segment id on the next delta).
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " Step two."))
        await flushMainActor()
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentBefore?.id)
        XCTAssertNotNil(harness.appState.liveReasoningSegment)
        // No duplicate settled thinking row may appear in the transcript.
        XCTAssertEqual(harness.appState.messages.map(\.id), ["user"])
        box.client.disconnect()
    }

    // MARK: - C. Healthy idle session

    func testForegroundWithHealthyIdleSessionIsObservationalNoOp() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload(seedPayload)
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path so the freshness comparison
        // has a durable frontier to anchor against.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100"])
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read proves currency")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "An idle healthy session must not be resumed"
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertEqual(harness.appState.messages, messagesBefore, "The transcript must remain stable")
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling,
            "No reconciliation may remain open after the observational refresh"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    // MARK: - C2. Stale transitional state under an authoritative idle probe

    /// A recovery attempt parked mid-reconcile leaves the transitional
    /// `.synchronizing` state behind even though the socket is healthy. The
    /// next foreground cycle's authoritative idle observation must adopt
    /// idle — composer usable, no resume, transcript untouched — instead of
    /// settling the boundary around the stale state.
    func testForegroundWithStaleSynchronizingAndAuthoritativeIdleAdoptsIdle() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let parkedBranch = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                branchSession: { _, _, _, _, _ in
                    // The branch parks mid-flight AFTER flipping the turn
                    // state to .synchronizing — the transitional state the
                    // foreground must normalize, without the frontier-wiping
                    // reconcile a parked resume would run.
                    await parkedBranch.suspend()
                    throw HermesError.notConnected
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path: durable frontier covers the
        // transcript the freshness check will compare against.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let seedMessages = [
            ChatMessage(id: "100", role: .user, content: "Earlier question", timestamp: "1"),
            ChatMessage(id: "101", role: .assistant, content: "Earlier answer", timestamp: "2")
        ]
        XCTAssertEqual(harness.appState.messages, seedMessages)

        // A previous recovery attempt (a conversation branch) parks mid-flight
        // with the transitional state showing. The task is deliberately not
        // awaited: its unwinding is covered by the rotated-token guards.
        Task { @MainActor in
            await harness.appState.branchFromAssistantMessage("101")
        }
        await parkedBranch.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .synchronizing)
        let resumeCountBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read proves currency")
        XCTAssertEqual(
            resumeCount, resumeCountBeforeForeground,
            "The foreground refresh must not issue any resume of its own"
        )
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "An authoritative idle observation must clear the stale transitional state"
        )
        XCTAssertTrue(
            harness.appState.composerIsEnabled,
            "The composer must be usable once the registry says idle"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertEqual(harness.appState.messages, seedMessages, "The transcript must remain stable")
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling,
            "No reconciliation may remain open after the observational refresh"
        )

        // The abandoned branch unwinds through its rotated-token guards; it
        // must not undo the adopted idle state or the transcript.
        parkedBranch.resume()
        await flushMainActor()
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertEqual(
            harness.appState.messages, seedMessages,
            "The abandoned branch must not replace the transcript"
        )
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling
        )
        box.client.disconnect()
    }

    /// A recovery attempt parked while reconnecting (the ticket mint stands
    /// in for a slow dashboard handoff) leaves `.reconnecting` behind even
    /// though the socket is healthy. The next foreground cycle's
    /// authoritative idle observation must adopt idle with the same
    /// observational guarantees.
    func testForegroundWithStaleReconnectingAndAuthoritativeIdleAdoptsIdle() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let parkedReconnect = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in
                    await parkedReconnect.suspend()
                    return "ticket"
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path so the freshness comparison has
        // a durable frontier to anchor against.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let messagesBefore = harness.appState.messages

        // A previous connection/recovery attempt parks mid-reconnect, leaving
        // the transitional state showing. The gate is never released: the
        // foreground adoption must not depend on how the abandoned attempt
        // resolves.
        Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await parkedReconnect.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        let resumeCountBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read proves currency")
        XCTAssertEqual(
            resumeCount, resumeCountBeforeForeground,
            "An idle healthy session must not be resumed"
        )
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "An authoritative idle observation must clear the stale transitional state"
        )
        XCTAssertTrue(
            harness.appState.composerIsEnabled,
            "The composer must be usable once the registry says idle"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertEqual(harness.appState.messages, messagesBefore, "The transcript must remain stable")
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling,
            "No reconciliation may remain open after the observational refresh"
        )
        box.client.disconnect()
    }

    /// The adopted idle baseline is the OLDER observation: a busy edge that
    /// races the probe and lands in the boundary buffer must win when the
    /// buffer is replayed, instead of being discarded by the idle adoption.
    func testForegroundAdoptedIdleYieldsToNewerBufferedBusyEdge() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        let parkedProbe = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Earlier", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    await parkedProbe.suspend()
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path so the freshness comparison has
        // a durable frontier to anchor against.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        let activation = Task { @MainActor in
            await runSceneActivation(harness)
        }
        // Hold the foreground activation at the probe, then deliver a newer
        // busy edge while the reconciliation boundary is open.
        await parkedProbe.waitUntilSuspended()
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        parkedProbe.resume()
        await activation.value
        await flushMainActor()

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "An idle healthy session must not be resumed"
        )
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The newer buffered busy edge must win over the adopted idle baseline"
        )
        XCTAssertTrue(
            harness.appState.composerIsEnabled,
            "A running turn keeps composer actions (stop/steer) available"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    // MARK: - Round 6: cross-surface transcript freshness

    /// A foreground advance keeps the page starts Load earlier noted, each
    /// claiming no more coverage than the page it read, so a long chat can
    /// still cut back once the reader is at the newest row (issue 1828).
    func testAForegroundAdvanceKeepsTheLoadedPageStartsForALongChat() async {
        let active = session("stored-a")
        var transcriptReads = 0
        func rows(_ range: Range<Int>) -> [[String: Any]] {
            range.map { index in
                ["id": "\(index)", "role": index.isMultiple(of: 2) ? "user" : "assistant", "content": "Row \(index)", "timestamp": "\(index)"]
            }
        }
        func page(_ range: Range<Int>, offset: Int) -> PersistedTranscriptFetchOutcome {
            .payload([
                "messages": rows(range),
                "pagination": ["limit": 120, "offset": offset, "order": "latest", "returned": range.count]
            ])
        }
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    // Then another surface added two rows while Conduit was away.
                    return transcriptReads == 1 ? page(1880..<2000, offset: 0) : page(1882..<2002, offset: 0)
                },
                loadEarlierTranscriptPage: { _, _, offset in
                    page((1880 - offset)..<(2000 - offset), offset: offset)
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(runtimeSessionId: "runtime-a", storedSessionId: "stored-a", status: "idle")]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        for _ in 0..<9 { await harness.appState.loadEarlierMessages() }
        XCTAssertEqual(harness.appState.messages.count, 1_200)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(harness.appState.messages.count, 1_202, "The newer rows merged onto the loaded ones")
        let starts = harness.appState.persistedTranscriptWindow?.loadedPageStarts ?? []
        XCTAssertEqual(starts.count, 10, "The advance kept every page start")
        XCTAssertTrue(starts.allSatisfy { $0.nextOffset <= 120 }, "None claims more than the page the advance read")

        harness.appState.trimLoadedHistoryIfLong()
        XCTAssertEqual(harness.appState.messages.count, 1_082)
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 920")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 2001")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
        box.client.disconnect()
    }

    func testForegroundAdvanceKeepsCallBeforeFirstRowOfCompleteHistory() async throws {
        try await foregroundVoiceCoverageFixture(partial: false)
    }

    func testForegroundAdvanceDefersCallBeforeFirstRowOfPartialHistory() async throws {
        try await foregroundVoiceCoverageFixture(partial: true)
    }

    private func foregroundVoiceCoverageFixture(partial: Bool) async throws {
        let active = session("stored-a")
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        var reads = 0
        var resumes = 0
        func rows(_ range: Range<Int>) -> [[String: Any]] {
            range.map { id in ["id": String(id), "role": id.isMultiple(of: 2) ? "assistant" : "user",
                "content": "Foreground row \(id)", "timestamp": iso.string(from: epoch.addingTimeInterval(Double(id * 60)))] }
        }
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID, _ in
                resumes += 1
                return SessionResumeResult(sessionId: sessionID, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                reads += 1
                let range = partial ? (reads == 1 ? 1..<121 : 3..<123) : (reads == 1 ? 1..<3 : 1..<5)
                return .payload(["session_id": "stored-a", "messages": rows(range),
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": range.count]])
            },
            refreshContext: { _, _ in }, verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [LiveSessionStatus(runtimeSessionId: "stored-a", storedSessionId: "stored-a", status: "idle")] }
        ))
        let box = await installConnectedClient(into: harness)
        defer { box.client.disconnect() }
        let state = harness.appState
        state.sessions = [active]
        state.activeSessionId = active.id
        let opened = await state.openSession(active.id)
        XCTAssertTrue(opened)
        let retainedCallTime = epoch.addingTimeInterval(90)
        state.adoptHostChatCalls([
            VoiceHostChatCall(callID: "foreground-before-first", chatID: "stored-a", startedAt: epoch, endedAt: epoch),
            VoiceHostChatCall(callID: "foreground-retained-prefix", chatID: "stored-a", startedAt: retainedCallTime, endedAt: retainedCallTime)
        ], profile: "default")
        let links = state.voiceCallChatLinks.links
        XCTAssertEqual(state.messages.contains { $0.id == "voice-call-foreground-before-first" }, !partial)
        XCTAssertEqual(state.messages.filter { ["1", "2", "voice-call-foreground-retained-prefix"].contains($0.id) }.map(\.id),
            ["1", "voice-call-foreground-retained-prefix", "2"])
        state.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(reads, 2, "Exactly one foreground tail read")
        XCTAssertEqual(resumes, 1, "Must take the real append-only advancement, not resume")
        XCTAssertEqual(state.messages.filter { $0.role != .system }.map(\.id), (1..<(partial ? 123 : 5)).map(String.init))
        XCTAssertEqual(state.messages.filter { $0.id == "voice-call-foreground-before-first" }.count, partial ? 0 : 1,
            "FOREGROUND_VOICE_COVERAGE: before-first calls remain visible only on complete history")
        let retainedMarker = try XCTUnwrap(state.messages.firstIndex { $0.id == "voice-call-foreground-retained-prefix" })
        XCTAssertEqual(Array(state.messages.dropFirst(max(0, retainedMarker - 1)).prefix(3)).map(\.id),
            ["1", "voice-call-foreground-retained-prefix", "2"],
            "A call in the retained prefix stays bracketed after the real page advances to rows 3...122")
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, !partial)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, partial ? 120 : 4)
        XCTAssertEqual(state.voiceCallChatLinks.links, links)
    }

    /// A turn another surface completed while Conduit was backgrounded is
    /// invisible to the liveness probe (the runtime is idle). One bounded
    /// persisted-tail read must merge the missed rows into the local
    /// transcript on foreground — without a session.resume.
    func testForegroundMergesRemoteCompletedTurnAfterBackground() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // The seeding hydration: two durable rows held.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // A remote surface completed a turn while Conduit was
                    // suspended: rows beyond the local durable frontier.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read decides the foreground")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "Completed remote history must merge without a session.resume"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103"],
            "The remotely completed turn becomes visible immediately"
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.nextOffset, 4,
            "The persisted window must re-anchor to the fetched page"
        )

        // A live completion over a merged row finalizes it IN PLACE (same
        // gateway id) instead of appending a duplicate twin.
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: "103",
            content: "Remote full answer",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        XCTAssertEqual(
            harness.appState.messages.filter { $0.id == "103" }.count, 1,
            "The live completion must not duplicate the merged persisted row"
        )
        XCTAssertEqual(
            harness.appState.messages.first(where: { $0.id == "103" })?.content,
            "Remote full answer"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        box.client.disconnect()
    }

    /// A turn another surface STARTED while Conduit was idle-and-backgrounded
    /// is still running on foreground. Persisted history alone cannot supply
    /// the in-flight projection, so the authoritative attach runs: the compact
    /// resume returns the live runtime state and the reconcile merges the
    /// persisted prefix — exactly one session.resume.
    func testForegroundAttachesRemoteRunningTurnAuthoritatively() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        // The attach resume returns the live runtime: the
                        // remote turn is running.
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)]
                        )
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote partial", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "The attach reconcile performs its own bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "A turn this device never owned attaches through the compact resume"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The authoritative snapshot proves the remote turn is running"
        )
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)

        // Future stream events extend the attached turn.
        harness.appState.handleStreamEvent(.messageDelta(
            sessionId: active.id,
            text: " and more"
        ))
        let published = await waitForStreamingText(" and more", in: harness.appState)
        XCTAssertTrue(published, "Deltas must land on the attached live turn")
        box.client.disconnect()
    }

    /// The headline PR #122 behavior must not degrade: a Conduit-owned turn
    /// that was running before the background transition continues on the
    /// same runtime — fast observational path, zero freshness reads, zero
    /// resumes, reasoning and transcript untouched.
    func testForegroundOwnedTurnContinuityStaysFastPathObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 2,
            "One bounded freshness read proves same-turn continuity"
        )
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "Zero session.resume")
        XCTAssertEqual(harness.appState.messages, messagesBefore, "No transcript replacement")
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// A backgrounded idle conversation whose persisted tail did not advance:
    /// the freshness read returns unchanged and the foreground stays a pure
    /// observational no-op.
    func testForegroundIdleBackgroundReturnWithNoRemoteActivityStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload(seedPayload)
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "Zero session.resume")
        XCTAssertEqual(
            harness.appState.messages, messagesBefore,
            "An unchanged tail must not replace the transcript"
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    /// When the local durable frontier has rotated out of the newest bounded
    /// page, freshness cannot be proven — the bounded resume refresh (the
    /// existing reconcile, which re-anchors the whole conversation) must take
    /// over instead of a false no-op.
    func testForegroundFreshnessWithRotatedAnchorTakesBoundedRecovery() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Remote activity pushed the local frontier (rows 100/101)
                    // out of the newest page entirely: no overlap anchor.
                    let rotatedRows: [[String: Any]] = (200..<320).map { id in
                        [
                            "id": "\(id)",
                            "role": "assistant",
                            "content": "Remote row \(id)",
                            "timestamp": "\(id)"
                        ]
                    }
                    return .payload([
                        "messages": rotatedRows,
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 120]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the recovery reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "Anchor-less freshness must take the bounded resume recovery exactly once"
        )
        XCTAssertEqual(harness.appState.messages.count, 120, "No remote rows may be lost")
        XCTAssertEqual(harness.appState.messages.first?.id, "200")
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    /// Ordering invariant: the persisted tail is the OLDER observation. A
    /// stream event that arrives while the freshness read is in flight is
    /// buffered and replayed after the merge, so the final state reflects
    /// snapshot first, newer live edge second.
    func testForegroundFreshnessMergeYieldsToNewerBufferedBusyEdge() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Hold the foreground freshness read open while a newer
                    // live edge arrives.
                    await parkedRead.suspend()
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        harness.appState.handleScenePhase(.background)
        let activation = Task { @MainActor in
            await runSceneActivation(harness)
        }
        await parkedRead.waitUntilSuspended()
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        parkedRead.resume()
        await activation.value
        await flushMainActor()

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(resumeCount, 1, "The seeding reconcile owns the only resume")
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The newer buffered busy edge must win over the merged persisted snapshot"
        )
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// The freshness arming is consumed by one foreground return: an overlay
    /// dip after a completed background return must stay fully observational
    /// (the socket survived the dip, live events kept flowing), with zero
    /// freshness reads and zero resumes.
    func testForegroundFreshnessRunsOncePerBackgroundNotOnOverlayDips() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(transcriptReads, 2, "The armed background return runs the freshness check once")
        XCTAssertFalse(harness.appState.foregroundFreshnessCheckArmed)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        let resumesAfterBackgroundReturn = resumeCount

        // Overlay dip: observational only — no third read, no resume.
        harness.appState.handleScenePhase(.inactive)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(
            transcriptReads, 2,
            "An overlay dip must not run the freshness check"
        )
        XCTAssertEqual(resumeCount, resumesAfterBackgroundReturn)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// A composer submit landing during the bounded freshness read supersedes
    /// the foreground refresh: `sendMessage`'s recovery-intent cancellation
    /// advances the automatic-work epoch, so the freshness continuation's
    /// ownership guard fails and it stands down WITHOUT merging. Persisted
    /// rows can therefore never be appended after the newer optimistic row;
    /// convergence belongs to the submission's own outcome and the next
    /// bounded refresh.
    func testForegroundFreshnessStandsDownWhenSubmissionOwnsTheTranscript() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Hold only the freshness read; the recovery
                        // reconcile's own read must flow freely.
                        await parkedRead.suspend()
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        let activation = Task { @MainActor in
            await runSceneActivation(harness)
        }
        await parkedRead.waitUntilSuspended()
        let submitted = await harness.appState.submitComposer(text: "Mid-read send")
        XCTAssertTrue(submitted)
        parkedRead.resume()
        await activation.value
        await flushMainActor()

        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(
            resumeCount, resumesBefore,
            "The freshness continuation is token-dead: it must not resume"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id).first, "100",
            "The seeded prefix stands"
        )
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Mid-read send",
            "The optimistic local row stays the newest row — no inverted persisted append"
        )
        XCTAssertFalse(
            harness.appState.messages.contains { $0.id == "102" || $0.id == "103" },
            "The freshness merge must not append behind the newer local row"
        )
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The accepted submission owns the turn state"
        )
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    /// A positively empty persisted page behind an idle runtime proves the
    /// conversation has no rows at all: freshness is provably unchanged and
    /// an empty local transcript stays a pure observational no-op.
    func testForegroundArmedIdleWithPositivelyEmptyConversationStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 0]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 1)
        XCTAssertEqual(resumeCount, 0, "A provably empty conversation must not resume")
        XCTAssertTrue(harness.appState.messages.isEmpty)
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// Local chat activity since the last hydration leaves the transcript
    /// tail optimistically identified (the frontier cannot vouch for it), so
    /// the append-only merge stands down: one bounded resume refresh per
    /// background return converges the conversation. This pins the deliberate
    /// cost of the conservative route on the most common sequence.
    func testForegroundAfterLocalChatSinceHydrationTakesBoundedRecovery() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // A locally streamed turn completes after the hydration: its row is
        // optimistically identified, so the durable frontier cannot vouch
        // for the transcript tail.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Locally streamed answer",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.messages.last?.role, .assistant)
        XCTAssertNotEqual(
            harness.appState.messages.last?.id, "102",
            "The local completion row must be optimistically identified"
        )
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "The locally completed turn must settle before the background transition"
        )
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the recovery reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBefore + 1,
            "An unanchored tail takes the bounded resume recovery exactly once"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    // MARK: - Round 7: tail-only freshness, source classification, authoritative attach

    private let legacyShapedRows: [[String: Any]] = [
        ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
        ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
        ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
        ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
    ]

    /// A backend that pages from the oldest end (a pagination echo WITHOUT
    /// the `order=latest` contract) yields NO bounded freshness evidence, and
    /// the freshness check must NOT escalate into the legacy whole-transcript
    /// read. Arithmetic: seed(1) + freshness(2) + the recovery reconcile's
    /// own bounded read(3) + its designed legacy one-shot re-read(4) = 4
    /// calls. Had the FRESHNESS path performed a legacy fallback too, the
    /// total would be 5.
    func testForegroundFreshnessTailReadNeverFallsBackToLegacyHistory() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Oldest-anchored pagination echo: a pagination object
                    // WITHOUT the `order=latest` contract.
                    return .payload([
                        "messages": self.legacyShapedRows,
                        "pagination": ["limit": 120, "offset": 0, "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 4,
            "Exactly one freshness call (no legacy fallback) + the recovery reconcile's bounded read and its designed legacy re-read"
        )
        XCTAssertEqual(resumeCount, resumesBeforeForeground + 1)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        box.client.disconnect()
    }

    /// A structurally absent messages endpoint (404-class) means there is no
    /// bounded capability to compare with: the authoritative resume/reconcile
    /// fallback runs exactly once instead of silently adopting a possibly
    /// stale transcript as current.
    func testForegroundFreshnessStructuralSourceAbsenceTakesAuthoritativeFallback() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, compact in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        // A legacy (non-compact) resume carries the transcript
                        // itself — exactly what the structural fallback uses.
                        messages: compact ? [] : [
                            ChatMessage(id: "100", role: .user, content: "Earlier question", timestamp: "1"),
                            ChatMessage(id: "101", role: .assistant, content: "Earlier answer", timestamp: "2"),
                            ChatMessage(id: "102", role: .user, content: "Remote question", timestamp: "3"),
                            ChatMessage(id: "103", role: .assistant, content: "Remote answer", timestamp: "4")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 404,
                        detail: "no session-messages endpoint"
                    ))
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 2,
            "Seed hydration + the foreground freshness read only — the hinted reconcile skips the history request"
        )
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "Exactly one authoritative noncompact resume — no compact attempt, no second resume"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    /// A transiently failed bounded tail read must not claim currency, must
    /// not escalate to a full-transcript read, and must not loop: the
    /// authoritative liveness adopts while the stale marker is RETAINED so
    /// the next authoritative source re-confirms.
    func testForegroundFreshnessTransientFailureKeepsStaleMarker() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload(seedPayload)
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 2,
            "The failed bounded read must not be retried or escalated to a full read"
        )
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "No resume cascade")
        XCTAssertEqual(harness.appState.messages, messagesBefore)
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(
            harness.appState.turnStateIsStale,
            "Turn-state staleness is resolved: the registry's idle answer was adopted"
        )
        XCTAssertTrue(
            harness.appState.transcriptFreshnessIsStale,
            "Transcript freshness is unresolved: the freshness marker must be retained"
        )
        box.client.disconnect()
    }

    /// The transient-failure contract on the RUNNING liveness path: the
    /// observational adopt clears the stale marker and the reconcile must
    /// re-set it afterwards — a reorder would silently drop freshness
    /// resolution exactly where the in-flight projection makes it most
    /// valuable.
    func testForegroundFreshnessTransientFailureOnRunningTurnKeepsStaleMarker() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let midTurnPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload(midTurnPayload)
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.turnState, .running)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "No retry, no escalation")
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "No resume cascade")
        XCTAssertEqual(harness.appState.messages, messagesBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(
            harness.appState.turnStateIsStale,
            "Turn-state staleness is resolved: the registry's working answer was adopted"
        )
        XCTAssertTrue(
            harness.appState.transcriptFreshnessIsStale,
            "Transcript freshness is unresolved on the running path too: the freshness marker must be retained"
        )
        box.client.disconnect()
    }

    /// A remotely started RUNNING turn has an in-flight assistant/reasoning
    /// prefix persisted history cannot supply. The authoritative attach (the
    /// compact resume fast-path) returns that live projection on top of the
    /// merged persisted prefix, and future deltas extend it.
    func testForegroundRemoteRunningTurnAttachesUnpersistedLiveProjection() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        // The seeding resume finds the session idle; the
                        // authoritative attach returns the live runtime with
                        // the unpersisted in-flight projection.
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Remote partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(resumeCount, resumesBeforeForeground + 1, "Exactly one authoritative attach resume")
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102"],
            "The remote persisted prefix is visible"
        )
        XCTAssertEqual(
            harness.appState.streamingText, "Remote partial answer",
            "The unpersisted in-flight prefix attaches through the resume"
        )
        XCTAssertEqual(harness.appState.turnState, .running)

        // Future deltas extend the attached projection.
        harness.appState.handleStreamEvent(.messageDelta(
            sessionId: active.id,
            text: " continued"
        ))
        let published = await waitForStreamingText(
            "Remote partial answer continued", in: harness.appState
        )
        XCTAssertTrue(published, "Future stream events continue the attached turn")
        box.client.disconnect()
    }

    /// Turn A running before background, A completing and Turn B starting in
    /// the SAME session while suspended: same-session identity is not
    /// same-turn proof. The persisted tail advancement forces the
    /// authoritative attach — B becomes authoritative with no stale Turn A
    /// reasoning segment and no missing prefix.
    func testForegroundTurnBInSameSessionIsNotContinuationOfTurnA() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        // The seeding hydration happens MID-TURN-A: the
                        // runtime was already working.
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Turn A answer", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "Turn B question", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.turnState, .running, "Turn A is Conduit-owned")
        harness.appState.handleStreamEvent(.reasoningDelta(
            sessionId: active.id,
            text: "Turn A stale thinking"
        ))
        let staleSegment = harness.appState.liveReasoningSegment
        XCTAssertNotNil(staleSegment)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "Unprovable same-turn continuity takes the authoritative attach exactly once"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id),
            ["100", "101", "102", "103", "104"],
            "Turn A's completion and Turn B's prefix are both present"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "Turn A's stale reasoning segment must not survive the authoritative attach"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        box.client.disconnect()
    }

    /// Genuine Conduit-owned continuation after a mid-turn rehydration: the
    /// bounded freshness read proves same-turn continuity (unchanged tail),
    /// so the fast observational path keeps zero resumes, zero transcript
    /// replacement, and the identical live reasoning segment.
    func testForegroundGenuineContinuationAfterMidTurnRehydrationStaysZeroResume() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let midTurnPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload(midTurnPayload)
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102"])
        harness.appState.handleStreamEvent(.reasoningDelta(
            sessionId: active.id,
            text: "Continuing Turn A"
        ))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded read proves same-turn continuity")
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "Zero session.resume")
        XCTAssertEqual(harness.appState.messages, messagesBefore, "Zero transcript replacement")
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.id, segmentBefore?.id,
            "The live reasoning projection is untouched"
        )
        XCTAssertEqual(harness.appState.turnState, .running)

        // Future deltas continue the SAME segment.
        harness.appState.handleStreamEvent(.reasoningDelta(
            sessionId: active.id,
            text: " and more"
        ))
        await flushMainActor()
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentBefore?.id)
        box.client.disconnect()
    }

    /// `starting` is liveness-inconclusive — but a stale `.synchronizing`
    /// left by an aborted recovery is not stream-owned state either. The
    /// foreground normalizes it to a usable neutral baseline: composer
    /// usable, starting never classified as running, zero reads.
    func testForegroundStartingNormalizesStaleSynchronizingState() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        let parkedRefresh = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    if resumeCount > 1 {
                        await parkedRefresh.suspend()
                    }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await parkedRefresh.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .synchronizing)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "A stale transitional state must normalize under a starting runtime"
        )
        XCTAssertTrue(
            harness.appState.composerIsEnabled,
            "The composer must not stay disabled on a starting runtime"
        )
        box.client.disconnect()
    }

    /// Same normalization for `.reconnecting`, and the ordering invariant: a
    /// newer buffered busy edge still wins over the normalized baseline.
    func testForegroundStartingNormalizesStaleReconnectingAndBusyEdgeWins() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let parkedReconnect = LifecycleSuspension()
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in
                    await parkedReconnect.suspend()
                    return "ticket"
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    await probeGate.suspend()
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100"])

        Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await parkedReconnect.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .reconnecting)

        harness.appState.handleScenePhase(.background)
        let activation = Task { @MainActor in
            await runSceneActivation(harness)
        }
        await probeGate.waitUntilSuspended()
        // A turn starts remotely while the probe is in flight: the newer
        // live edge must win over the normalized baseline.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        probeGate.resume()
        await activation.value
        await flushMainActor()

        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The newer buffered busy edge wins over the normalized baseline"
        )
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertEqual(resumeCount, 1, "The seeding reconcile owns the only resume")
        XCTAssertEqual(transcriptReads, 1, "A starting runtime performs no freshness read")
        box.client.disconnect()
    }

    // MARK: - D. inactive → active only

    func testInactiveToActiveCycleDoesNotResumeOrResetReasoning() async {
        let active = session("stored-a")
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        let returnSurfaceBefore = harness.appState.preferredReturnSurfaceRequest

        harness.appState.handleScenePhase(.inactive)
        await runSceneActivation(harness)

        XCTAssertEqual(resumeCount, 0, "An overlay dip must not resume the session")
        XCTAssertEqual(harness.appState.messages.map(\.id), ["user"])
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertEqual(
            harness.appState.preferredReturnSurfaceRequest, returnSurfaceBefore,
            "An inactive → active cycle is not a background return"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    // MARK: - E. Dead socket

    func testForegroundWithDeadTransportReconnectsAndResumesOnce() async {
        let active = session("stored-a")
        var connects = 0
        var resumeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in connects += 1 },
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                mintTicket: { _ in "fresh-ticket" },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: "runtime-e",
                        messages: [
                            ChatMessage(
                                id: "assistant-e",
                                role: .assistant,
                                content: "Recovered",
                                timestamp: "2"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                setBusyInputMode: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(connects, 1, "The dead transport must be reconnected exactly once")
        XCTAssertEqual(resumeCount, 1, "Recovery must fall back to exactly one stored-session resume")
        XCTAssertEqual(catalogCount, 1)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["assistant-e"])
        XCTAssertEqual(harness.appState.turnState, .idle)
    }

    // MARK: - Offline return keeps the in-memory chat readable (#99)

    /// A short trip to another app while the server is unreachable must leave
    /// the conversation already in memory on screen: the failed foreground
    /// recovery may mark the transport as reconnecting, but it must not
    /// clear the transcript, switch sessions, or fall back to the sign-in
    /// screen.
    func testForegroundWithUnreachableServerKeepsInMemoryChatReadable() async {
        struct Scenario {
            let name: String
            let mintFails: Bool
            let connectFails: Bool
        }
        let scenarios = [
            Scenario(name: "ticket mint unreachable", mintFails: true, connectFails: false),
            Scenario(name: "socket connect unreachable", mintFails: false, connectFails: true),
        ]
        for scenario in scenarios {
            let active = session("stored-a")
            var scheduledReconnects = 0
            let harness = makeHarness(
                lifecycleOperations: ChatResumeLifecycleOperations(
                    connectClient: { _ in
                        if scenario.connectFails { throw URLError(.notConnectedToInternet) }
                    },
                    loadCatalog: { _, _ in
                        XCTFail("An offline return must not reload the catalog (\(scenario.name))")
                        throw URLError(.notConnectedToInternet)
                    },
                    mintTicket: { _ in
                        if scenario.mintFails { throw URLError(.notConnectedToInternet) }
                        return "fresh-ticket"
                    },
                    openSession: { _, _, _ in
                        XCTFail("An offline return must not resume (\(scenario.name))")
                        throw URLError(.notConnectedToInternet)
                    },
                    refreshContext: { _, _ in },
                    loadProfiles: {},
                    loadBusyInputMode: { _ in },
                    loadProfileDisplayPreferences: {},
                    loadSlashCommands: {}
                ),
                reconnectScheduler: { _, _ in
                    scheduledReconnects += 1
                    return {}
                }
            )
            installDisconnectedClient(into: harness)
            harness.appState.showLogin = false
            harness.appState.sessions = [active]
            harness.appState.activeSessionId = active.id
            let visible = [
                ChatMessage(id: "user-1", role: .user, content: "Question", timestamp: "1"),
                ChatMessage(id: "assistant-1", role: .assistant, content: "Answer", timestamp: "2"),
            ]
            harness.appState.messages = visible

            harness.appState.handleScenePhase(.inactive)
            harness.appState.handleScenePhase(.background)
            await runSceneActivation(harness)

            XCTAssertEqual(harness.appState.messages, visible, scenario.name)
            XCTAssertEqual(harness.appState.activeSessionId, active.id, scenario.name)
            XCTAssertNotNil(harness.appState.connection, scenario.name)
            XCTAssertNotNil(harness.appState.client, scenario.name)
            XCTAssertFalse(harness.appState.showLogin, scenario.name)
            XCTAssertFalse(harness.appState.isConnected, scenario.name)
            XCTAssertEqual(harness.appState.turnState, .reconnecting, scenario.name)
            XCTAssertEqual(scheduledReconnects, 1, scenario.name)
        }
    }

    // MARK: - F. Gateway restart (runtime gone, stored session remains)

    func testForegroundAfterGatewayRestartResumesStoredSessionOnce() async {
        let active = session("stored-a", alternateIDs: ["runtime-old"])
        var probeCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    XCTAssertEqual(sessionID, "stored-a")
                    return SessionResumeResult(
                        sessionId: "runtime-new",
                        messages: [
                            ChatMessage(
                                id: "restored",
                                role: .assistant,
                                content: "After restart",
                                timestamp: "3"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The gateway restarted: no live runtime exists for this
                    // session anymore.
                    return []
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = "runtime-old"
        harness.appState.messages = [
            ChatMessage(id: "stale", role: .user, content: "Before restart", timestamp: "1")
        ]

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(resumeCount, 1, "Exactly one stored-session resume must run")
        XCTAssertEqual(
            harness.appState.activeSessionId, "runtime-new",
            "The resumed runtime id must become authoritative"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["restored"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        box.client.disconnect()
    }

    func testForegroundWaitingWithoutVisibleDecisionResumesAndSettlesControls() async {
        let active = session("stored-a")
        var openedSessionIDs: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    openedSessionIDs.append(sessionID)
                    return SessionResumeResult(
                        sessionId: "runtime-a",
                        storedSessionId: active.id,
                        messages: [
                            ChatMessage(
                                id: "completed",
                                role: .assistant,
                                content: "Recovered after the decision cleared",
                                timestamp: "2"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: active.id,
                        status: "waiting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        // An inactive/active cycle leaves the transport alive, so this test
        // isolates decision hydration from the separate dead-transport path.
        harness.appState.handleScenePhase(.inactive)
        await runSceneActivation(harness)

        XCTAssertEqual(
            openedSessionIDs, [active.id],
            "Waiting without an answerable card must be rehydrated from session.resume"
        )
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertFalse(harness.appState.isChatRefreshing)
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "The authoritative resume must release a stale waiting composer state"
        )
        box.client.disconnect()
    }

    // MARK: - G. Ordinary successful prompt

    func testOrdinaryIdleSubmitStartsExactlyOneTurn() async {
        var submitCount = 0
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return []
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let submitted = await harness.appState.submitComposer(text: "Hello")

        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1, "An ordinary submit must issue exactly one prompt.submit")
        XCTAssertEqual(probeCount, 0, "Trusted state must not pay for an authoritative probe")
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Hello",
            "Exactly one optimistic user row is kept"
        )
        XCTAssertEqual(harness.appState.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(harness.appState.turnState, .running)
    }

    // MARK: - H. Ambiguous acknowledgement, server proves the turn is running

    func testAmbiguousPromptSubmissionWithRunningServerTurnIsAcceptedOnce() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    // The RPC reached Hermes, but the acknowledgement was lost.
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "earlier", role: .assistant, content: "Earlier", timestamp: "0")
        ]

        let submitted = await harness.appState.submitComposer(text: "Ambiguous send")

        XCTAssertTrue(submitted, "The accepted turn must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(resumeCount, 0, "The healthy transport must not be replaced")
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The optimistic user row must remain"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    // MARK: - I. Ambiguous submit, server proves the prompt was not accepted

    func testAmbiguousPromptSubmissionWithIdleServerRunsFailedSendRestorationOnce() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "persisted",
                                role: .assistant,
                                content: "Persisted history",
                                timestamp: "1"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        let submitted = await harness.appState.submitComposer(text: "Never delivered")

        XCTAssertFalse(submitted, "A provably undelivered prompt is a failed send")
        XCTAssertEqual(submitCount, 1, "No blind retry may follow the ambiguous failure")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(catalogCount, 1, "The failed-send restoration must run exactly once")
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["persisted"],
            "The optimistic row is restored away exactly once by the authoritative transcript"
        )
        XCTAssertTrue(
            harness.appState.errorMessage?.contains("Failed to send") == true
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        box.client.disconnect()
    }

    // MARK: - J. Local idle / server running mismatch

    func testStaleIdleSubmissionRoutesThroughConfiguredBusyAction() async {
        let active = session("stored-a")
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The suspected production divergence: Hermes still runs
                    // the session while Conduit believes it is idle.
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                },
                steer: { _, _, _ in steerCount += 1 }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // The lifecycle boundary marks the local turn state stale.
        harness.appState.handleScenePhase(.background)

        let submitted = await harness.appState.submitComposer(text: "Follow-up")

        XCTAssertTrue(submitted)
        XCTAssertEqual(probeCount, 1, "A stale idle state must be corrected before routing")
        XCTAssertEqual(
            submitCount, 0,
            "The message must NOT be sent as an ordinary new-turn prompt.submit"
        )
        XCTAssertEqual(
            steerCount, 1,
            "The corrected busy session must route the message through the configured busy action"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        let confirmation = harness.appState.messages.last
        XCTAssertEqual(confirmation?.isSteer, true, "An accepted steer is confirmed in the transcript (issue #337)")
        XCTAssertEqual(confirmation?.content, "Follow-up")
    }

    private func runStaleIdleSteer(
        seeded: [ChatMessage],
        beforeSend: @MainActor (AppState) -> Void = { _ in },
        duringSteer: @escaping @MainActor (AppState) -> Void = { _ in }
    ) async -> AppState {
        let active = session("stored-a")
        var appStateRef: AppState?
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in .accepted },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                },
                steer: { _, _, _ in
                    if let appStateRef { duringSteer(appStateRef) }
                }
            )
        )
        appStateRef = harness.appState
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = seeded
        harness.appState.handleScenePhase(.background)
        beforeSend(harness.appState)

        let submitted = await harness.appState.submitComposer(text: "Follow-up")
        XCTAssertTrue(submitted)
        return harness.appState
    }

    /// A steer that goes through ends the failed send's line shown when it
    /// set out (issue 2095, #2110).
    func testASteerThatGoesThroughClearsTheFailedSendsLine() async {
        let appState = await runStaleIdleSteer(seeded: [], beforeSend: { appState in
            appState.errorMessage = "Failed to send"
            appState.sendFailureShown = "Failed to send"
        })

        XCTAssertEqual(appState.messages.last?.isSteer, true)
        XCTAssertNil(appState.sendFailureShown)
        XCTAssertNil(appState.errorMessage)
    }

    /// Only the line shown when the steer set out is its to clear: a newer
    /// send's failure, shown while the steer was on its way, stays.
    func testASteerLeavesANewerFailedSendsLine() async {
        let appState = await runStaleIdleSteer(seeded: [], beforeSend: { appState in
            appState.errorMessage = "Failed to send"
            appState.sendFailureShown = "Failed to send"
        }, duringSteer: { appState in
            appState.errorMessage = "Failed to send the photo"
            appState.sendFailureShown = "Failed to send the photo"
        })

        XCTAssertEqual(appState.sendFailureShown, "Failed to send the photo")
        XCTAssertEqual(appState.errorMessage, "Failed to send the photo")
    }

    private func persistedSteer(_ id: String, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: .user, content: text, timestamp: "", displayKind: ChatMessage.steerDisplayKind)
    }

    func testRepeatingAnEarlierSteerStillGetsItsOwnConfirmation() async {
        let appState = await runStaleIdleSteer(seeded: [persistedSteer("90", "Follow-up")])

        XCTAssertEqual(appState.messages.count, 2)
        XCTAssertEqual(appState.messages.last?.isSteer, true)
        XCTAssertTrue(appState.messages.last?.id.hasPrefix("local-steer-") == true)
    }

    func testSteerPersistedDuringTheRPCIsNotConfirmedTwice() async {
        let appState = await runStaleIdleSteer(seeded: [], duringSteer: { appState in
            appState.messages.append(self.persistedSteer("91", "Follow-up"))
        })

        XCTAssertEqual(appState.messages.map(\.id), ["91"])
    }

    func testFailedSteerAddsNoTranscriptConfirmation() async {
        let active = session("stored-a")
        struct SteerFailure: Error {}
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in .accepted },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                },
                steer: { _, _, _ in throw SteerFailure() }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.handleScenePhase(.background)

        let submitted = await harness.appState.submitComposer(text: "Follow-up")

        XCTAssertFalse(submitted)
        XCTAssertFalse(harness.appState.messages.contains(where: \.isSteer))
    }

    func testLocalSteerTwinMatchesPersistedSteerByText() {
        let local = ChatMessage(
            id: "local-steer-1", role: .user, content: "Use staging", timestamp: "",
            displayKind: ChatMessage.steerDisplayKind
        )
        let persisted = ChatMessage(
            id: "412", role: .user, content: "Use staging\n", timestamp: "",
            displayKind: ChatMessage.steerDisplayKind
        )
        let ordinary = ChatMessage(id: "local-2", role: .user, content: "Use staging", timestamp: "")
        XCTAssertTrue(AppState.isLocalSteerTwin(local, of: persisted))
        XCTAssertFalse(AppState.isLocalSteerTwin(persisted, of: persisted), "A durable row is never a local twin")
        XCTAssertFalse(AppState.isLocalSteerTwin(ordinary, of: persisted))
    }

    // MARK: - K. Two genuinely idle turns stay independent

    func testSequentialIdleTurnsSubmitIndependently() async {
        var submitTexts: [String] = []
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, text in
                    submitTexts.append(text)
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return []
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let first = await harness.appState.submitComposer(text: "Message A")
        // Turn A completes authoritatively (server-driven busy=false edge).
        harness.appState.handleStreamEvent(
            .sessionBusy(sessionId: "stored-a", busy: false)
        )
        let second = await harness.appState.submitComposer(text: "Message B")

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(
            submitTexts, ["Message A", "Message B"],
            "Two idle turns must be two independent prompt submissions"
        )
        XCTAssertEqual(probeCount, 0, "No stale-state probe may run for trusted idle state")
        XCTAssertEqual(
            harness.appState.messages.filter { $0.role == .user }.map(\.content),
            ["Message A", "Message B"],
            "No client-side concatenation of the two submissions"
        )
    }

    // MARK: - Prompt outcome typing (HermesClient seam-level)

    func testPromptSubmissionOutcomeClassification() {
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "streaming"), .accepted)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "steered"), .steered)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "redirected"), .redirected)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "queued"), .queued)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "STREAMING"), .accepted)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: nil), .accepted)
        XCTAssertFalse(PromptSubmissionOutcome.accepted.isBusySubmission)
        XCTAssertTrue(PromptSubmissionOutcome.queued.isBusySubmission)
        XCTAssertTrue(PromptSubmissionOutcome.steered.isBusySubmission)
        XCTAssertTrue(PromptSubmissionOutcome.redirected.isBusySubmission)
    }

    func testLiveSessionStatusRowParsing() throws {
        let row = try XCTUnwrap(LiveSessionStatus(from: [
            "id": .string("runtime-1"),
            "session_key": .string("stored-1"),
            "status": .string("working"),
            "last_active": .number(1234.5)
        ]))
        XCTAssertEqual(
            row,
            LiveSessionStatus(
                runtimeSessionId: "runtime-1",
                storedSessionId: "stored-1",
                status: "working",
                lastActive: 1234.5
            )
        )
        XCTAssertTrue(row.isRunning)
        XCTAssertTrue(
            LiveSessionStatus(
                runtimeSessionId: "r", storedSessionId: "s", status: "waiting"
            ).isRunning,
            "A pending decision keeps the turn live"
        )
        XCTAssertFalse(
            LiveSessionStatus(
                runtimeSessionId: "r", storedSessionId: "s", status: "starting"
            ).isRunning,
            "Starting also covers promptless agent pre-warm — not committed busy"
        )
        XCTAssertFalse(
            LiveSessionStatus(
                runtimeSessionId: "r", storedSessionId: "s", status: "idle"
            ).isRunning
        )
        XCTAssertNil(
            LiveSessionStatus(from: ["session_key": .string("missing-runtime-id")]),
            "A row without a runtime id cannot be matched"
        )
    }

    // MARK: - Reviewer-hardening coverage

    func testForegroundWithStartingRuntimeLeavesStateStreamOwned() async {
        let active = session("stored-a")
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(
            resumeCount, 0,
            "A starting runtime must never manufacture a resume refresh"
        )
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "A starting row is liveness-inconclusive: local state stays stream-owned"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "An inconclusive probe must not mark the state trusted"
        )
        box.client.disconnect()
    }

    func testForegroundWithUnavailableProbeFallsBackToResumeRefresh() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "restored",
                                role: .assistant,
                                content: "From legacy refresh",
                                timestamp: "2"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // An older gateway without session.active_list.
                    throw HermesError.invalidResponse
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(resumeCount, 1, "An unreadable registry must fall back to the resume refresh")
        XCTAssertEqual(harness.appState.messages.map(\.id), ["restored"])
        box.client.disconnect()
    }

    func testForegroundWithIdleProbeAndLocalRunningRecoversCompletedTurn() async {
        let active = session("stored-a")
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "completed",
                                role: .assistant,
                                content: "Finished while away",
                                timestamp: "2"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(
            resumeCount, 1,
            "A missed turn-end edge must recover through the authoritative transcript refresh"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["completed"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        box.client.disconnect()
    }

    func testDefinitiveNotConnectedFailureSkipsAuthoritativeProbe() async {
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [self.session("stored-a")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    // rpc() throws notConnected before any bytes are written,
                    // so the outcome is definitive, not ambiguous.
                    throw HermesError.notConnected
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return []
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let submitted = await harness.appState.submitComposer(text: "Unsent")

        XCTAssertFalse(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(
            probeCount, 0,
            "A provably undelivered prompt must not pay for an authoritative probe"
        )
        XCTAssertEqual(catalogCount, 1, "The ordinary failed-send restoration runs exactly once")
        XCTAssertTrue(harness.appState.errorMessage?.contains("Failed to send") == true)
    }

    func testStaleIdleWithUnavailableProbeFallsThroughToOrdinarySend() async {
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    throw HermesError.invalidResponse
                },
                steer: { _, _, _ in steerCount += 1 }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.handleScenePhase(.background)

        let submitted = await harness.appState.submitComposer(text: "Direct send")

        XCTAssertTrue(submitted, "An unreadable probe must not block the user")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            submitCount, 1,
            "The submission falls through to the ordinary new-turn send"
        )
        XCTAssertEqual(steerCount, 0)
        XCTAssertEqual(harness.appState.turnState, .running)
    }

    /// #1401: a send's stale-idle probe runs with the field already empty
    /// and nothing in the transcript yet. The composer says it's sending
    /// until the message shows, and only in the chat it was sent from.
    func testComposerSaysSendingWhileTheStaleIdleProbeRuns() async {
        let probeGate = LifecycleSuspension()
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    await probeGate.suspend()
                    return []
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.handleScenePhase(.background)
        XCTAssertFalse(harness.appState.composerSendIsChecking)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Still there?")
        }
        await probeGate.waitUntilSuspended()
        XCTAssertTrue(harness.appState.composerSendIsChecking, "The emptied field says the message is on its way")
        XCTAssertEqual(submitCount, 0)

        probeGate.resume()
        let submitted = await submission.value

        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.messages.last?.content, "Still there?")
        XCTAssertFalse(harness.appState.composerSendIsChecking, "The message shows: Sending… goes")
    }

    /// #1401: the user leaves the chat while its send is still checking.
    /// The other chat isn't sending, the send stops, and its words go back
    /// through AppState, which outlasts the composer that sent them.
    func testLeavingAChatMidSendSendsNothingAndHandsTheWordsBack() async {
        let probeGate = LifecycleSuspension()
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    await probeGate.suspend()
                    return []
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a"), session("stored-b")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.handleScenePhase(.background)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Still there?")
        }
        await probeGate.waitUntilSuspended()
        harness.appState.activeSessionId = "stored-b"
        XCTAssertFalse(harness.appState.composerSendIsChecking, "Only the chat it was sent from says Sending…")

        probeGate.resume()
        let submitted = await submission.value
        XCTAssertFalse(submitted)
        XCTAssertEqual(submitCount, 0)

        let key = ComposerDraftKey(dashboard: harness.appState.activeDashboardID, profile: harness.appState.activeProfile, sessionID: "stored-a")
        let words = ComposerDraft(text: "Still there?", attachments: [])
        // From another dashboard: the words go back, and this one's
        // composer says nothing about them.
        let otherDashboard = UUID()
        harness.appState.returnFailedComposerSubmission(
            words, key: key, dashboardID: otherDashboard, title: "Trip plans", stoppedQuietly: true
        )
        let request = harness.appState.composerRestoreRequests.last
        XCTAssertEqual(request?.key, key)
        XCTAssertEqual(request?.dashboardID, otherDashboard)
        XCTAssertEqual(request?.draft.text, "Still there?")
        XCTAssertEqual(request?.focuses, false)
        XCTAssertNil(harness.appState.composerNotice)

        guard let dashboardID = harness.appState.activeDashboardID else { return }
        harness.appState.returnFailedComposerSubmission(
            words, key: key, dashboardID: dashboardID, title: "Trip plans", stoppedQuietly: true
        )
        XCTAssertEqual(
            harness.appState.composerNotice,
            AppLocalization.string("Your message to “\("Trip plans")” wasn't sent. It's back in that chat's draft.", table: .chat),
            "Nothing else said the send stopped"
        )
    }

    /// #1401: a send whose reply was lost after its chat was left may have
    /// reached Hermes, so it isn't announced as unsent; one Hermes refused
    /// outright is.
    func testLeftChatSendWithLostReplyIsNotCalledUnsent() async {
        for (lostReply, expectedQuiet) in [(true, false), (false, true)] {
            let submitGate = LifecycleSuspension()
            let harness = makeHarness(
                lifecycleOperations: ChatResumeLifecycleOperations(
                    sendPrompt: { _, _, _ in
                        await submitGate.suspend()
                        if lostReply { throw URLError(.networkConnectionLost) }
                        throw RpcError(code: 4001, message: "refused")
                    },
                    probeActiveSessions: { _ in [] }
                )
            )
            installDisconnectedClient(into: harness)
            harness.appState.sessions = [session("stored-a"), session("stored-b")]
            harness.appState.activeSessionId = "stored-a"
            let context = harness.appState.composerSubmissionContext()

            let submission = Task { @MainActor in
                await harness.appState.submitComposer(text: "Still there?", context: context)
            }
            await submitGate.waitUntilSuspended()
            harness.appState.activeSessionId = "stored-b"
            submitGate.resume()
            let submitted = await submission.value

            XCTAssertFalse(submitted)
            XCTAssertEqual(
                harness.appState.composerSubmissionStoppedQuietly(context), expectedQuiet,
                lostReply ? "A lost reply may mean Hermes has it" : "A refusal is a send that didn't go"
            )
            XCTAssertTrue(harness.appState.composerSubmissionStoppedQuietly(context), "Asked once per failed send")
        }
    }

    func testQueuedPromptOutcomeAdoptsAuthoritativeRunningState() async {
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    // Hermes was busy: the prompt joined the busy policy.
                    return .queued
                },
                probeActiveSessions: { _ in [] }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let submitted = await harness.appState.submitComposer(text: "Queued send")

        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "A busy-policy outcome proves the session was running server-side"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
    }

    // MARK: - Round 2: ambiguous acceptance proven by the durable transcript

    /// The headline fast-settle regression: the prompt was ACCEPTED, the turn
    /// completed, and by the time recovery probed, the registry had already
    /// gone absent. The durable transcript must prove acceptance instead of
    /// the submission being restored as unsent.
    func testAmbiguousAcceptedTurnCompletedBeforeProbeIsProvenByTranscript() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // The pre-submit hydration: two durable rows held.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: the accepted turn landed and settled.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Ambiguous send", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Completed result", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The turn completed and the runtime was reaped before
                    // recovery looked: current liveness is absent.
                    return []
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance through the real hydration path.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submitted = await harness.appState.submitComposer(text: "Ambiguous send")

        XCTAssertTrue(submitted, "Transcript-proven acceptance must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded tail read decides the outcome")
        XCTAssertEqual(
            catalogCount, 0,
            "No failed-send restoration may run for a transcript-proven acceptance"
        )
        XCTAssertEqual(resumeCount, resumesBeforeSubmit)
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The submitted turn stays; the transcript converges on the next bounded refresh"
        )
        XCTAssertEqual(harness.appState.turnState, .idle, "The turn settled before recovery looked")
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// A staged file's reference leads the prompt, and Hermes persists the
    /// row expanded (reference, typed text, its attached-context footer).
    /// The check must project what was SENT, reference included: typed
    /// text that itself holds a footer heading only loses it on the
    /// persisted side when a reference sits above.
    func testAmbiguousSendWithAStagedFileIsProvenByTranscript() async {
        let active = session("stored-a")
        let typed = "Compare these\n\n--- Attached Context ---\nmy own notes"
        let reference = "@file:/root/.hermes/attachments/notes.txt"
        var submitted: [String] = []
        var transcriptReads = 0
        var catalogCount = 0
        var operations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in
                catalogCount += 1
                return [active]
            },
            openSession: { _, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in
                transcriptReads += 1
                if transcriptReads == 1 {
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                }
                let persisted = "\(reference)\n\n\(typed)\n\n--- Attached Context ---\n\n"
                    + "📎 notes.txt is available on disk at /root/.hermes/attachments/notes.txt"
                return .payload([
                    "messages": [
                        ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                        ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                        ["id": "102", "role": "user", "content": persisted, "timestamp": "3"],
                        ["id": "103", "role": "assistant", "content": "Compared", "timestamp": "4"]
                    ],
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                ])
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, _, text in
                submitted.append(text)
                throw HermesError.timeout("prompt.submit")
            },
            probeActiveSessions: { _ in [] }
        )
        operations.uploadAttachment = { _, _, _ in reference }
        let harness = makeHarness(lifecycleOperations: operations)
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let notes = Attachment(
            id: UUID().uuidString,
            name: "notes.txt",
            uri: "file:///tmp/notes.txt",
            mimeType: "text/plain",
            kind: .document
        )

        let sent = await harness.appState.submitComposer(text: typed, attachments: [notes])

        XCTAssertTrue(sent, "The expanded persisted row proves the send landed")
        XCTAssertEqual(submitted, ["\(reference)\n\n\(typed)"], "An accepted prompt must never be re-submitted")
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(catalogCount, 0, "No failed-send restoration may run")
        XCTAssertEqual(harness.appState.messages.last?.content, typed)
        box.client.disconnect()
    }

    /// The genuine not-accepted case keeps its coverage: registry idle AND
    /// the durable transcript holds nothing beyond the submit-time baseline.
    func testAmbiguousPromptAbsentFromDurableTranscriptRestoresOnce() async {
        let active = session("stored-a")
        var submitCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(id: "100", role: .user, content: "Earlier question", timestamp: "1"),
                            ChatMessage(id: "101", role: .assistant, content: "Earlier answer", timestamp: "2")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance through the real hydration path: the
        // pre-submit conversation durably holds rows 100 and 101.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submitted = await harness.appState.submitComposer(text: "Never delivered")

        XCTAssertFalse(submitted)
        XCTAssertEqual(submitCount, 1, "No blind retry may follow the ambiguous failure")
        XCTAssertEqual(
            transcriptReads, 3,
            "Hydration, ambiguous verification, and the restore's compact resume each read once"
        )
        XCTAssertEqual(catalogCount, 1, "The unsent restoration runs exactly once")
        XCTAssertEqual(resumeCount, resumesBeforeSubmit + 1)
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101"],
            "The optimistic row is restored away exactly once by the authoritative transcript"
        )
        XCTAssertTrue(harness.appState.errorMessage?.contains("Failed to send") == true)
        box.client.disconnect()
    }

    /// A duplicate-text trap: the transcript advanced with rows that do not
    /// carry the submitted text, while an OLDER identical user row exists.
    /// Ordering (baseline ids) must decide, not content matching.
    func testAmbiguousPromptWithDuplicateOlderTextIsProvenAbsentByOrdering() async {
        let active = session("stored-a")
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // Pre-submit hydration: the older identical "go on".
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "go on", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier reply", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: the tail advanced with a DIFFERENT newer ask.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "go on", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier reply", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Different newer ask", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Newer reply", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in throw HermesError.timeout("prompt.submit") },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance for the older identical "go on" row.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        let submitted = await harness.appState.submitComposer(text: "go on")

        XCTAssertFalse(submitted, "The transcript advanced without this prompt: it was not accepted")
        XCTAssertEqual(transcriptReads, 3)
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103"],
            "Restoration converges on the authoritative tail even though only its older rows " +
            "predate the submission — the newer rows prove this prompt never landed"
        )
        box.client.disconnect()
    }

    /// No usable durable source (bridge unavailable): acceptance can be
    /// neither proven nor disproven — conservative restore, never a resend.
    func testAmbiguousPromptWithUnreadableTranscriptRestoresConservatively() async {
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [self.session("stored-a")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in .unavailable },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let submitted = await harness.appState.submitComposer(text: "Unverifiable send")

        XCTAssertFalse(submitted)
        XCTAssertEqual(submitCount, 1, "Unresolved acceptance must never become an automatic resend")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(catalogCount, 1, "Exactly one conservative restoration")
    }

    // MARK: - Round 2: submission-owned stale-state correction

    /// A probe started for session A must not mutate anything after the user
    /// switched to session B: B's stale marker survives and B runs its own
    /// authoritative correction before its send.
    func testStaleIdleProbeSupersededBySessionHandoffDoesNotMutateNewSession() async {
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        var probeCalls = 0
        var submitCount = 0
        var steerTargets: [String] = []
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCalls += 1
                    if probeCalls == 1 {
                        await probeGate.suspend()
                        return [LiveSessionStatus(
                            runtimeSessionId: "runtime-a",
                            storedSessionId: "stored-a",
                            status: "working"
                        )]
                    }
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-b",
                        storedSessionId: "stored-b",
                        status: "working"
                    )]
                },
                steer: { _, sessionID, _ in steerTargets.append(sessionID) }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id
        harness.appState.handleScenePhase(.background)

        let submissionA = Task { @MainActor in
            await harness.appState.submitComposer(text: "A follow-up")
        }
        await probeGate.waitUntilSuspended()

        // The user switches to session B while A's probe is suspended.
        harness.appState.activeSessionId = sessionB.id
        probeGate.resume()
        let submittedA = await submissionA.value

        XCTAssertFalse(submittedA, "A superseded submission must abort, not fall through")
        XCTAssertEqual(submitCount, 0, "A's aborted submission must not send")
        XCTAssertEqual(steerTargets, [], "A's result must not steer")
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "A's running result must not be attributed to B"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "B's stale marker must survive A's completed probe"
        )

        // B still performs its own authoritative probe before routing.
        let submittedB = await harness.appState.submitComposer(text: "B follow-up")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(probeCalls, 2)
        XCTAssertEqual(steerTargets, ["stored-b"], "B routes through the configured busy action")
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
    }

    /// A mention typed while the bot is busy routes through steer; the
    /// steered text carries the same @mention identification note a new
    /// turn would.
    func testBusySteerCarriesTheMentionAnnotation() async {
        let sessionA = session("stored-a")
        let researcher = BotProfile(
            name: "researcher",
            botTitle: nil,
            displayName: "",
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: false,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: nil,
            lastActive: nil,
            lastPreview: nil
        )
        var steeredTexts: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in .accepted },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                },
                steer: { _, _, text in steeredTexts.append(text) },
                botRoster: { _ in
                    BotRosterSnapshot(bots: [researcher], supportsBotProtocol: true)
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.isConnected = true
        await harness.appState.refreshBotRoster()
        harness.appState.isConnected = false
        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["researcher"])

        harness.appState.sessions = [sessionA]
        harness.appState.activeSessionId = sessionA.id
        harness.appState.handleScenePhase(.background)

        let text = "@researcher check the numbers"
        let submitted = await harness.appState.submitComposer(text: text)

        XCTAssertTrue(submitted)
        let expected = BotMentions.middlewareAnnotation(
            text: text,
            roster: [researcher],
            activeProfileName: "default"
        )
        XCTAssertNotNil(expected)
        XCTAssertEqual(steeredTexts, [expected ?? ""])
    }

    /// A quoted reply (#385) that names a bot is not a mention: only the
    /// user's own words below the quote are scanned, and a mention there
    /// annotates the whole sent text.
    func testQuotedReplyBotNamesAreNotTakenAsMentions() async {
        let sessionA = session("stored-a")
        let researcher = BotProfile(
            name: "researcher",
            botTitle: nil,
            displayName: "",
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: false,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: nil,
            lastActive: nil,
            lastPreview: nil
        )
        var steeredTexts: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in .accepted },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                },
                steer: { _, _, text in steeredTexts.append(text) },
                botRoster: { _ in
                    BotRosterSnapshot(bots: [researcher], supportsBotProtocol: true)
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.isConnected = true
        await harness.appState.refreshBotRoster()
        harness.appState.isConnected = false
        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["researcher"])

        harness.appState.sessions = [sessionA]
        harness.appState.activeSessionId = sessionA.id
        harness.appState.handleScenePhase(.background)

        let quotedOnly = ReplyQuoteEnvelope.outboundText(
            quoting: "Ask @researcher for the numbers",
            message: "Sounds good"
        )
        let submittedQuote = await harness.appState.submitComposer(text: quotedOnly)
        XCTAssertTrue(submittedQuote)
        XCTAssertEqual(steeredTexts, [quotedOnly], "a bot named only in the quote is not a mention")

        let mentioned = ReplyQuoteEnvelope.outboundText(
            quoting: "Earlier answer",
            message: "@researcher check this"
        )
        let submittedMention = await harness.appState.submitComposer(text: mentioned)
        XCTAssertTrue(submittedMention)
        // The bot named in the user's own words is annotated onto the whole
        // text, quote included.
        let expected = BotMentions.annotated(text: mentioned, mentions: [researcher])
        XCTAssertNotEqual(expected, mentioned)
        XCTAssertEqual(steeredTexts.last, expected)
        XCTAssertEqual(ReplyQuoteEnvelope.parse(expected)?.quote, "Earlier answer")

        // A selection quoted as `>` lines is someone else's words too.
        let selectionQuote = ChatQuote.inserting(
            ChatQuote.blockquote("Ask @researcher for the numbers"),
            into: ""
        ) + "What did they mean?"
        let submittedSelection = await harness.appState.submitComposer(text: selectionQuote)
        XCTAssertTrue(submittedSelection)
        XCTAssertEqual(steeredTexts.last, selectionQuote, "a bot named only in a quoted selection is not a mention")
    }

    /// A prompt outcome returned after the user switched sessions must not
    /// adopt running state or clear staleness for the new session.
    func testPromptOutcomeHandoffDoesNotMutateNewSessionState() async {
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        var submitCount = 0
        let sendGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    if submitCount == 1 {
                        await sendGate.suspend()
                    }
                    // Hermes was busy: a typed busy outcome for session A.
                    return .queued
                },
                probeActiveSessions: { _ in [] }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id

        let submissionA = Task { @MainActor in
            await harness.appState.submitComposer(text: "A message")
        }
        await sendGate.waitUntilSuspended()

        // Switch to B, let B go stale, and establish B's authoritative idle
        // edge while A's RPC is still suspended.
        harness.appState.activeSessionId = sessionB.id
        harness.appState.handleScenePhase(.inactive)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: sessionB.id, busy: false))

        sendGate.resume()
        let submittedA = await submissionA.value

        XCTAssertTrue(submittedA, "A's remotely accepted send stays a success")
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "A's busy outcome must not be misattributed to session B"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "B's stale marker must not be cleared by A's outcome"
        )
    }

    /// A starting runtime is not committed busy: the stale-idle correction
    /// falls through to the ordinary send, whose typed outcome reconciles any
    /// genuine busy race.
    func testStaleIdleWithStartingRuntimeSendsOrdinaryTurn() async {
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                },
                steer: { _, _, _ in steerCount += 1 }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.handleScenePhase(.background)

        let submitted = await harness.appState.submitComposer(text: "Go")

        XCTAssertTrue(submitted)
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(steerCount, 0, "Starting alone must not route through busy steer")
        XCTAssertEqual(submitCount, 1, "The submission falls through to the ordinary new-turn send")
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
    }

    // MARK: - Round 2: foreground probe/event ordering

    /// A turn-ending event that arrives while the foreground probe is in
    /// flight is NEWER than the registry snapshot and must win: the settled
    /// state is idle, not a falsely-resurrected running turn.
    func testForegroundBufferedTurnEndWinsOverStaleRunningSnapshot() async {
        let active = session("stored-a")
        var resumeCount = 0
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    await probeGate.suspend()
                    // The snapshot was taken before the turn ended.
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        let sceneTask = harness.appState.handleScenePhase(.active)
        await probeGate.waitUntilSuspended()

        // The turn ENDS while the probe is still in flight: the newest edge.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        probeGate.resume()
        await sceneTask?.value

        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "The newest authoritative event must win over the older registry snapshot"
        )
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "The race must not manufacture a resume"
        )
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling
        )
        box.client.disconnect()
    }

    // MARK: - Round 3: durable-anchor evidence model

    /// Case A: the pre-submit conversation holds an optimistic local row
    /// ("continue"), and the persisted tail contains an identical user row
    /// (501) that may be that SAME send re-homed under a database id. The
    /// verifier must not prove acceptance merely because "501" is not
    /// "local-123": with a durable anchor present but local-only rows
    /// outstanding, the outcome is indeterminate → conservative restore.
    func testAmbiguousMatchingRowAfterAnchorWithLocalPredecessorIsIndeterminate() async {
        let active = session("stored-a")
        var submitCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // Pre-submit hydration: two durable rows held.
                        return .payload([
                            "messages": [
                                ["id": "98", "role": "user", "content": "prior", "timestamp": "0"],
                                ["id": "99", "role": "assistant", "content": "ack", "timestamp": "1"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: an identical user row exists after the anchor,
                    // but the conversation also held an optimistic local row.
                    return .payload([
                        "messages": [
                            ["id": "98", "role": "user", "content": "prior", "timestamp": "0"],
                            ["id": "99", "role": "assistant", "content": "ack", "timestamp": "1"],
                            ["id": "501", "role": "user", "content": "continue", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance for rows 98/99 through real hydration.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        // Turn 1 was sent optimistically and never re-hydrated: its persisted
        // twin's id is unknown to this conversation.
        harness.appState.messages.append(
            ChatMessage(id: "local-123", role: .user, content: "continue", timestamp: "2")
        )

        let submitted = await harness.appState.submitComposer(text: "continue")

        XCTAssertFalse(
            submitted,
            "An identical persisted row after the anchor cannot be attributed to this submission"
        )
        XCTAssertEqual(submitCount, 1, "No automatic resend")
        XCTAssertEqual(transcriptReads, 3)
        XCTAssertEqual(catalogCount, 1, "The conservative restoration runs exactly once")
        XCTAssertEqual(
            harness.appState.messages.filter { $0.role == .user && $0.content == "continue" }.count,
            1,
            "The optimistic duplicate is restored away; exactly one user row remains"
        )
        box.client.disconnect()
    }

    /// Case B: the first identical turn is durably anchored (hydrated rows
    /// 501/502) and the tail advances past that anchor with a NEW identical
    /// user row (503) plus its response — acceptance is provable.
    func testAmbiguousNewIdenticalRowBeyondDurableAnchorIsAcceptedSettled() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // Pre-submit hydration: the first identical turn is
                        // durably anchored (rows 501/502).
                        return .payload([
                            "messages": [
                                ["id": "501", "role": "user", "content": "continue", "timestamp": "1"],
                                ["id": "502", "role": "assistant", "content": "done", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: the tail advanced past the anchor with a NEW
                    // identical user row (503) plus its response.
                    return .payload([
                        "messages": [
                            ["id": "501", "role": "user", "content": "continue", "timestamp": "1"],
                            ["id": "502", "role": "assistant", "content": "done", "timestamp": "2"],
                            ["id": "503", "role": "user", "content": "continue", "timestamp": "3"],
                            ["id": "504", "role": "assistant", "content": "done again", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The turn already completed and the runtime was reaped.
                    return []
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Durably anchor the FIRST identical turn (rows 501/502) via real
        // hydration; the verifier may then treat 503 as new.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["501", "502"])

        let submitted = await harness.appState.submitComposer(text: "continue")

        XCTAssertTrue(submitted, "Durable ordering proves the second identical turn landed")
        XCTAssertEqual(submitCount, 1, "No second prompt.submit")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(catalogCount, 0, "No composer restoration for a proven acceptance")
        XCTAssertEqual(
            harness.appState.messages.last?.content, "continue",
            "The optimistic row converges with the persisted transcript"
        )
        XCTAssertEqual(harness.appState.turnState, .idle, "The turn settled before recovery looked")
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// Case C: with NO durable pre-submit anchor at all, a matching persisted
    /// row cannot be dated — indeterminate, never present.
    func testAmbiguousMatchingRowWithoutDurableAnchorIsIndeterminate() async {
        var submitCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [self.session("stored-a")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "501", "role": "user", "content": "continue", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = [
            ChatMessage(id: "local-123", role: .user, content: "continue", timestamp: "2")
        ]

        let submitted = await harness.appState.submitComposer(text: "continue")

        XCTAssertFalse(submitted, "Without a durable anchor the outcome must not claim acceptance")
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(catalogCount, 1, "Conservative restoration exactly once")
    }

    // MARK: - Round 3: post-recovery presentation ownership

    /// A failed-send error produced by session A's ambiguous recovery must
    /// not paint the error (or any turn state) onto session B after the user
    /// switched mid-recovery.
    func testAmbiguousRecoveryErrorDoesNotLeakIntoHandedOffSession() async {
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [sessionA]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    await probeGate.suspend()
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id
        // Establish durable provenance through the real hydration path.
        let opened = await harness.appState.openSession(sessionA.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        let submissionA = Task { @MainActor in
            await harness.appState.submitComposer(text: "A doomed send")
        }
        await probeGate.waitUntilSuspended()

        // The user switches to session B while A's recovery is suspended.
        harness.appState.activeSessionId = sessionB.id
        harness.appState.handleScenePhase(.inactive)
        harness.appState.errorMessage = "B-sentinel"

        probeGate.resume()
        let submittedA = await submissionA.value

        XCTAssertFalse(submittedA)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            harness.appState.errorMessage, "B-sentinel",
            "A's stale send failure must not overwrite B's error surface"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "B's stale marker must survive A's recovery"
        )
        XCTAssertEqual(catalogCount, 0, "A's restoration is skipped under lost ownership")
        box.client.disconnect()
    }

    /// Round 4: the accepted turn generated so much activity that BOTH the
    /// pre-submit durable anchor and the submitted row fell out of the newest
    /// bounded page. Ordering evidence is gone — content absence from a
    /// window cannot prove non-acceptance, so the outcome is indeterminate
    /// (conservative restore, no resend, no false rejection claim).
    func testAmbiguousPromptBeyondBoundedTailIsIndeterminate() async {
        let active = session("stored-a")
        var submitCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // Pre-submit hydration: one durable anchor row held.
                        return .payload([
                            "messages": [
                                ["id": "500", "role": "assistant", "content": "anchor row", "timestamp": "1"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                        ])
                    }
                    // Recovery: the newest page holds neither the anchor nor
                    // the submitted user row — the accepted turn's activity
                    // pushed both out of the window.
                    return .payload([
                        "messages": [
                            ["id": "601", "role": "assistant", "content": "much later output", "timestamp": "9"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["500"])

        let submitted = await harness.appState.submitComposer(text: "continue")

        XCTAssertFalse(
            submitted,
            "Without ordering evidence the submission must be treated as unresolved"
        )
        XCTAssertEqual(submitCount, 1, "No automatic resend of the ambiguous prompt")
        XCTAssertEqual(transcriptReads, 3)
        XCTAssertEqual(catalogCount, 1, "Exactly one conservative restoration")
        XCTAssertFalse(
            harness.appState.messages.contains { $0.role == .user && $0.content == "continue" },
            "The unresolved submission is restored rather than kept as sent"
        )
        box.client.disconnect()
    }

    /// Synthetic visible ids (optimistic sends, live streaming completions,
    /// positional fallbacks, reasoning/tool projections) carry no persisted
    /// provenance and must never become overlap anchors — even when the tail
    /// contains a matching user row that could be the older logical twin.
    func testSyntheticVisibleIDsNeverBecomeDurableAnchors() async {
        for syntheticID in [
            "local-123",
            "assistant-1700000000",
            "3",
            "reasoning-1700000001",
            "tool-start-1700000002"
        ] {
            let harness = makeHarness(
                lifecycleOperations: ChatResumeLifecycleOperations(
                    loadCatalog: { _, _ in [self.session("stored-a")] },
                    openSession: { _, sessionID, _ in
                        SessionResumeResult(
                            sessionId: sessionID,
                            messages: [],
                            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                        )
                    },
                    persistedTranscript: { _, _, _ in
                        .payload([
                            "messages": [
                                ["id": "501", "role": "user", "content": "continue", "timestamp": "5"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                        ])
                    },
                    refreshContext: { _, _ in },
                    sendPrompt: { _, _, _ in throw HermesError.timeout("prompt.submit") },
                    probeActiveSessions: { _ in
                        [LiveSessionStatus(
                            runtimeSessionId: "runtime-a",
                            storedSessionId: "stored-a",
                            status: "idle"
                        )]
                    }
                )
            )
            installDisconnectedClient(into: harness)
            harness.appState.sessions = [session("stored-a")]
            harness.appState.activeSessionId = "stored-a"
            // The visible conversation holds ONLY a synthetic id: no positive
            // persisted provenance exists.
            harness.appState.messages = [
                ChatMessage(id: syntheticID, role: .user, content: "continue", timestamp: "1")
            ]

            let submitted = await harness.appState.submitComposer(text: "continue")

            XCTAssertFalse(
                submitted,
                "Synthetic id \(syntheticID) must not prove acceptance"
            )
            XCTAssertEqual(
                harness.appState.turnState, .idle,
                "Synthetic id \(syntheticID) must not adopt a running state"
            )
            XCTAssertEqual(
                harness.appState.messages.last?.id, "501",
                "Synthetic id \(syntheticID): the durable tail restored exactly once"
            )
        }
    }

    // MARK: - Round 8: locally-owned optimistic tails, freshness split, single structural resume

    /// The NORMAL workflow: a real `submitComposer` turn starts with an
    /// optimistic `local-*` user row that has NO durable id. Background +
    /// foreground with the runtime still working on that same locally
    /// submitted turn must stay observational — zero `session.resume`, zero
    /// transcript replacement, the optimistic row and the live reasoning
    /// segment survive, and later deltas extend the same turn.
    func testForegroundNormalLocallySubmittedRunningTurnStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    // Every read returns only the durable pre-turn history:
                    // the in-flight turn has persisted nothing.
                    return .payload(seedPayload)
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        // The real submit path: optimistic user row, accepted prompt, live
        // reasoning projection.
        let submitted = await harness.appState.submitComposer(text: "Follow-up question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.messages.count, 3)
        XCTAssertEqual(harness.appState.messages.last?.role, .user)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The visible user row must be the optimistic local row"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 2,
            "One bounded freshness read; the durable frontier is unchanged"
        )
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "The normal locally-submitted running turn must NOT pay a session.resume"
        )
        XCTAssertEqual(harness.appState.messages, messagesBefore, "No transcript replacement")
        XCTAssertEqual(
            harness.appState.liveReasoningSegment, segmentBefore,
            "The live reasoning projection survives the foreground cycle"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future deltas extend the SAME turn — no reset, no replacement.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.id, segmentBefore?.id,
            "Later deltas must extend the same live reasoning segment"
        )
        // The sidebar toggle synchronously flushes the coalesced live
        // projection publish (the established deterministic-test pattern).
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.content, "Thinking. More.",
            "The delta merged into the SAME segment's buffer"
        )
        box.client.disconnect()
    }

    /// A locally-submitted Turn A whose persisted evidence advanced past the
    /// pre-turn frontier while suspended (A completed, another surface
    /// started Turn B) must NOT keep the optimistic tail as same-turn
    /// continuation. The tail shows TWO new canonical user-turn boundaries
    /// after the pre-submit anchor (Turn A's twin and Turn B's prompt): the
    /// second boundary proves a later turn exists and forces the
    /// authoritative attach, resetting Turn A's live projection in favor of
    /// Turn B's.
    func testForegroundLocallyOwnedOptimisticTailYieldsToPersistedTurnB() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Turn B partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Turn A's rows AND Turn B's first row are persisted:
                    // advancement beyond the locally-owned pre-turn frontier.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Turn A answer", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "Turn B question", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposer(text: "Turn A question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Turn A thinking."))
        XCTAssertNotNil(harness.appState.liveReasoningSegment)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "Persisted advancement behind an optimistic tail forces the authoritative attach"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103", "104"],
            "Turn A completion and Turn B prefix are visible after the attach"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "The stale Turn A reasoning segment must not survive the attach"
        )
        XCTAssertEqual(
            harness.appState.streamingText, "Turn B partial answer",
            "Turn B's live projection is authoritative"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// A transient foreground freshness failure leaves
    /// `transcriptFreshnessIsStale` set. The next NEW-TURN submit runs
    /// exactly one bounded tail-only retry; when it proves advancement, the
    /// missing rows merge BEFORE the optimistic user row appends, and the
    /// send proceeds with zero resume.
    func testPreSendFreshnessRetryMergesMissingRowsBeforeNewPrompt() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // The foreground freshness read fails transiently.
                        return .failed(DashboardTicketBridgeError.http(
                            status: 503,
                            detail: "temporarily unavailable"
                        ))
                    }
                    // The pre-send retry proves the remote completed turn.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "No foreground retry, no legacy fallback")
        XCTAssertEqual(resumeCount, resumesBefore, "No resume on the transient path")
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)

        let submitted = await harness.appState.submitComposer(text: "Follow-up")
        XCTAssertTrue(submitted)

        XCTAssertEqual(submitCount, 1, "prompt.submit called exactly once")
        XCTAssertEqual(transcriptReads, 3, "Exactly one bounded pre-send retry")
        XCTAssertEqual(
            resumeCount, resumesBefore,
            "The merge needs no resume — the persisted source supplied the rows"
        )
        XCTAssertEqual(
            harness.appState.messages.count, 5,
            "Missing remote rows reconcile, then the optimistic user appends"
        )
        XCTAssertEqual(
            Array(harness.appState.messages.map(\.id).prefix(4)), ["100", "101", "102", "103"],
            "The remote rows land before the new prompt"
        )
        XCTAssertEqual(harness.appState.messages.last?.role, .user)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The new prompt appends last, after the reconciled rows"
        )
        XCTAssertFalse(
            harness.appState.transcriptFreshnessIsStale,
            "A proven advancement merge clears transcript freshness"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// A SECOND transient freshness failure at the pre-send gate must not
    /// loop, must not fall back to full history, and must not silently
    /// append a new-turn prompt into an unresolved ordering: the send is
    /// blocked with a lightweight retryable message.
    func testPreSendFreshnessRetryTransientFailureBlocksNewTurn() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)

        let submitted = await harness.appState.submitComposer(text: "Follow-up")
        XCTAssertFalse(submitted, "The blocked send must not report success")

        XCTAssertEqual(submitCount, 0, "No prompt.submit into an unresolved ordering")
        XCTAssertEqual(transcriptReads, 3, "Foreground read + one retry; no loop, no legacy fallback")
        XCTAssertEqual(resumeCount, resumesBefore, "A transient failure never escalates to a resume")
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101"],
            "The new-turn prompt must not append out of order"
        )
        XCTAssertTrue(
            harness.appState.transcriptFreshnessIsStale,
            "Freshness stays unresolved after the second transient failure"
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    // MARK: - Round 9: realistic persisted shape, busy-edge race

    /// The REALISTIC locally-submitted turn: Hermes persists the user row at
    /// turn start, so the foreground bounded tail already contains the
    /// durable twin (102) of Conduit's optimistic local row. Exactly ONE new
    /// canonical user-turn boundary after the pre-submit anchor is the
    /// expected Turn A twin — it must NOT force a resume: zero
    /// `session.resume`, transcript untouched (the twin is never merged
    /// behind the optimistic bubble), live reasoning projection intact.
    func testForegroundLocalTurnAWithPersistedUserTwinStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload(seedPayload)
                    }
                    // The freshness read: Hermes' crash-resilience path has
                    // already persisted the durable twin of our optimistic
                    // user row.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Follow-up question", "timestamp": "3"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        let submitted = await harness.appState.submitComposer(text: "Follow-up question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.messages.count, 3)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The visible user row must still be the optimistic local row"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "The durable user twin of our own turn must NOT force a session.resume"
        )
        XCTAssertEqual(
            harness.appState.messages, messagesBefore,
            "The persisted twin is never merged behind the optimistic row"
        )
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future deltas extend the SAME turn.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentBefore?.id)
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.liveReasoningSegment?.content, "Thinking. More.")
        box.client.disconnect()
    }

    /// Turn A's crash-resilience persistence can outrun the live stream:
    /// besides the durable user twin, assistant and tool rows of the SAME
    /// turn may already be persisted while the runtime is still working.
    /// Non-user rows do not prove another turn: exactly one new canonical
    /// user boundary stays same-turn continuation — zero resume, same live
    /// projection, same optimistic local row.
    func testForegroundLocalTurnAWithPersistedTurnARowsStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Turn A's user twin PLUS two Turn A rows (assistant
                    // output and a tool row): still only ONE new user-turn
                    // boundary after the pre-submit anchor.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Follow-up question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Working answer", "timestamp": "4"],
                            ["id": "104", "role": "tool", "content": "tool output", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposer(text: "Follow-up question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "Turn A's own persisted output/tool rows must NOT force a session.resume"
        )
        XCTAssertEqual(harness.appState.messages, messagesBefore)
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)
        box.client.disconnect()
    }

    /// A busy edge that races the pre-send freshness read must win: when the
    /// gate's bounded read returns and the SAME conversation has turned
    /// running, the text routes through the configured busy submission —
    /// never an ordinary new-turn `prompt.submit`, and no optimistic
    /// new-turn row is appended into the running turn.
    func testPreSendFreshnessRetryYieldsToBusyEdge() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        var steerCount = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // The foreground freshness read fails transiently,
                        // arming the pre-send gate.
                        return .failed(DashboardTicketBridgeError.http(
                            status: 503,
                            detail: "temporarily unavailable"
                        ))
                    }
                    // Hold ONLY the pre-send retry; the busy edge lands
                    // while it is suspended.
                    if transcriptReads == 3 {
                        await parkedRead.suspend()
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                },
                steer: { _, _, _ in
                    steerCount += 1
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)
        XCTAssertEqual(harness.appState.turnState, .idle)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Follow-up")
        }
        await parkedRead.waitUntilSuspended()
        // The race: a live busy edge arrives while the pre-send freshness
        // read is suspended.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        parkedRead.resume()

        let submitted = await submission.value
        XCTAssertTrue(submitted, "The steered busy submission reports success")

        XCTAssertEqual(submitCount, 0, "No ordinary prompt.submit into a running turn")
        XCTAssertEqual(steerCount, 1, "The text routed through the configured busy action")
        XCTAssertEqual(transcriptReads, 3, "No retry loop behind the routed submission")
        XCTAssertEqual(
            Array(harness.appState.messages.map(\.id).prefix(2)), ["100", "101"],
            "No optimistic new-turn row is appended into the running turn"
        )
        XCTAssertEqual(
            harness.appState.messages.dropFirst(2).map(\.isSteer), [true],
            "Only the steer confirmation (issue #337) follows the transcript"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertTrue(
            harness.appState.transcriptFreshnessIsStale,
            "The busy path does not claim transcript freshness it never checked"
        )
        box.client.disconnect()
    }

    // MARK: - Round 9 review hardening

    /// The twin is what makes the one-boundary shape provable. When the
    /// first persisted row after the pre-submit anchor is NOT a user prompt
    /// (the twin is missing while Turn A output rows persisted), the page
    /// cannot prove same-turn continuity — the classifier must take the
    /// authoritative attach, not observational adoption.
    func testForegroundLocalTurnAWithMissingUserTwinTakesAttach() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Recovered partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Turn A output rows persisted WITHOUT the user twin:
                    // the first row after the anchor is not a user prompt.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "103", "role": "assistant", "content": "Orphaned output", "timestamp": "3"],
                            ["id": "104", "role": "assistant", "content": "More orphaned output", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposer(text: "Follow-up question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Turn A thinking."))
        XCTAssertNotNil(harness.appState.liveReasoningSegment)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "A non-user first row after the anchor cannot prove same-turn continuity"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "103", "104"],
            "The authoritative attach owns the unprovable tail"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "The optimistic live projection must not survive the attach"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// A brand-new conversation's first locally-submitted turn: the initial
    /// hydration POSITIVELY proved the persisted transcript empty, which is
    /// valid ordering evidence (distinct from unknown). The persisted twin
    /// of the optimistic first-turn row — exactly ONE new canonical
    /// user-turn boundary after a positively-empty baseline, with the
    /// runtime still working — stays same-turn observational: zero
    /// `session.resume`, zero transcript replacement, optimistic row and
    /// live reasoning projection intact.
    func testForegroundFirstTurnFromPositivelyEmptyBaselineStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // A positively empty conversation: no durable rows.
                        return .payload([
                            "messages": [],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 0]
                        ])
                    }
                    // The twin of our optimistic first-turn user row.
                    return .payload([
                        "messages": [
                            ["id": "102", "role": "user", "content": "First question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.messages.isEmpty)

        let submitted = await harness.appState.submitComposer(text: "First question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.messages.count, 1)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The visible user row is the optimistic local row"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "A positively-empty baseline makes the first turn's twin provable — zero session.resume"
        )
        XCTAssertEqual(
            harness.appState.messages, messagesBefore,
            "The persisted twin is never merged behind the optimistic row"
        )
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future deltas extend the SAME turn.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentBefore?.id)
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.liveReasoningSegment?.content, "Thinking. More.")
        box.client.disconnect()
    }

    /// Consecutive locally-owned turns: the Turn A foreground's unchanged
    /// verdict advances the persisted ordering frontier through Turn A's
    /// persisted rows WITHOUT touching the visible transcript, so Turn B's
    /// marker anchors past them — Turn B's foreground must not miscount
    /// Turn A's rows as foreign user-turn boundaries. Both foregrounds stay
    /// observational: zero `session.resume`.
    func testConsecutiveLocallyOwnedTurnsAdvancePersistedOrderingFrontier() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Turn A's durable twin + output while A runs.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    if transcriptReads == 3 {
                        // Mandatory settled-tail check before Turn B. The
                        // live-time observation already contained A's final
                        // persisted row, so nothing follows frontier 103.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // Turn B's twin: only ONE new user boundary after the
                    // advanced ordering frontier (103).
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "B", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        // --- Turn A ---
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        let segmentA = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentA)
        let messagesAfterA = harness.appState.messages

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(
            resumeCount, 1,
            "Turn A's foreground with its durable twin stays observational"
        )
        XCTAssertEqual(harness.appState.messages, messagesAfterA)
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentA)
        XCTAssertEqual(harness.appState.turnState, .running)

        // Settle Turn A locally through the normal stream completion path.
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // --- Turn B ---
        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(transcriptReads, 3, "One bounded settled-tail check before Turn B")
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "B thinking."))
        let segmentB = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentB)
        let messagesAfterB = harness.appState.messages

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(transcriptReads, 4, "Settled-tail check plus one bounded read per background return")
        XCTAssertEqual(
            resumeCount, 1,
            "Turn A's persisted rows must not be miscounted as foreign boundaries — Turn B stays observational"
        )
        XCTAssertEqual(harness.appState.messages, messagesAfterB, "No transcript replacement")
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentB)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future Turn B deltas extend the SAME segment.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentB?.id)
        box.client.disconnect()
    }

    /// Frontier advancement never weakens cross-surface protection: the
    /// locally-owned marker's baseline is FROZEN at submit time, so after
    /// Turn A's foreground advances the frontier through 103, a SECOND
    /// background return where A completed and a remote Turn B started
    /// still sees TWO boundaries against the frozen baseline and takes the
    /// authoritative attach.
    func testForegroundRemoteTurnBAfterFrontierAdvanceStillAttaches() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Turn B partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Turn A's twin + output while A runs.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // A completed while away; a remote Turn B started: TWO
                    // boundaries after the frozen baseline (101).
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "Turn B question", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // Turn A: foreground advances the ordering frontier through 103.
        let submitted = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Turn A thinking."))
        XCTAssertNotNil(harness.appState.liveReasoningSegment)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(resumeCount, 1, "Turn A's own foreground stays observational")
        XCTAssertEqual(transcriptReads, 2)

        // Second background: A completes unobserved, remote Turn B starts.
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(transcriptReads, 4, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, 2,
            "A second user boundary after the FROZEN baseline forces the authoritative attach"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103", "104"],
            "Turn A completion and the remote Turn B prefix are visible"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "The stale Turn A projection must not survive the attach"
        )
        XCTAssertEqual(
            harness.appState.streamingText, "Turn B partial answer",
            "The remote Turn B projection is authoritative"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// Local Turn A observed (frontier advanced), local Turn B submitted,
    /// then B completes while backgrounded and a remote Turn C starts: TWO
    /// boundaries after B's frozen baseline force the attach — advancing the
    /// ordering frontier does not erase the second-boundary protection.
    func testForegroundRemoteTurnCAfterLocalTurnBStillAttaches() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Turn C partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Turn A's twin + output while A runs.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    if transcriptReads == 3 {
                        // Mandatory settled-tail check before Turn B. The
                        // earlier live observation already held A's final row.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // B completed while away; remote Turn C started: TWO
                    // boundaries after B's frozen baseline (103).
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "B", "timestamp": "5"],
                            ["id": "105", "role": "assistant", "content": "Answer B", "timestamp": "6"],
                            ["id": "106", "role": "user", "content": "Turn C question", "timestamp": "7"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 7]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // Turn A: foreground advances the ordering frontier through 103.
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(resumeCount, 1)

        // Settle A locally, then submit Turn B.
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(transcriptReads, 3, "One bounded settled-tail check before Turn B")
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "B thinking."))
        XCTAssertNotNil(harness.appState.liveReasoningSegment)

        // B completes while backgrounded; a remote Turn C starts.
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(transcriptReads, 5, "Settled-tail check + freshness read + attach reconcile read")
        XCTAssertEqual(
            resumeCount, 2,
            "Two boundaries after B's frozen baseline force the authoritative attach"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103", "104", "105", "106"],
            "Turn B completion and the remote Turn C prefix are visible"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "The stale Turn B projection must not survive the attach"
        )
        XCTAssertEqual(
            harness.appState.streamingText, "Turn C partial answer",
            "The remote Turn C projection is authoritative"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// The twin can lag the read: a locally-owned first turn whose user row
    /// has NOT persisted yet (the page is still positively empty) with the
    /// runtime working stays observational — nothing new is persisted, so
    /// there is nothing to attach to.
    func testForegroundLocallyOwnedTurnTwinNotYetPersistedStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let emptyPage: [String: Any] = [
            "messages": [],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 0]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload(emptyPage)
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.messages.isEmpty)

        let submitted = await harness.appState.submitComposer(text: "First question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "An empty persisted tail behind a running locally-owned turn is not evidence of anything foreign"
        )
        XCTAssertEqual(harness.appState.messages, messagesBefore)
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)
        box.client.disconnect()
    }

    /// THE foreground-only lifecycle: Turn A is submitted, runs, and
    /// settles entirely while Conduit stays foregrounded — no bounded
    /// history read ever observes its durable rows. The settle records one
    /// unit of local ordering debt, and Turn B's submit reconciles it with
    /// exactly one bounded tail read BEFORE freezing B's ordering baseline.
    /// B's foreground then sees only B's own boundary and stays
    /// observational.
    func testConsecutiveLocallyOwnedTurnsWithoutIntermediateFreshnessReadStayObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // The pre-send debt catch-up: Turn A's durable rows.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // Turn B's twin: exactly ONE boundary after 103.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "B", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        // --- Turn A: runs and settles entirely in the foreground ---
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertEqual(transcriptReads, 1, "No history read observed Turn A")

        // --- Turn B: the debt catch-up read fires before B freezes its
        // baseline, then B submits normally ---
        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2, "prompt.submit exactly once for Turn B")
        XCTAssertEqual(
            transcriptReads, 2,
            "Exactly one bounded debt catch-up read before Turn B"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "B thinking."))
        let segmentB = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentB)
        let messagesAfterB = harness.appState.messages

        // --- Foreground during Turn B ---
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3)
        XCTAssertEqual(
            resumeCount, 1,
            "Turn A's persisted rows were anchored by the debt read — Turn B stays observational"
        )
        XCTAssertEqual(harness.appState.messages, messagesAfterB, "No transcript replacement")
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentB)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future Turn B deltas extend the SAME segment.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentB?.id)
        box.client.disconnect()
    }

    /// Local ordering debt that is EXCEEDED by persisted history proves
    /// foreign activity: the authoritative reconcile runs before the local
    /// send, the remote turn becomes visible, and only then does the new
    /// local prompt append after it.
    func testLocalOrderingDebtExceededByRemoteTurnForcesReconcile() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // The debt read (and the recovery reconcile's own read)
                    // see MORE boundaries than the one outstanding
                    // locally-owned settled turn: remote B.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "Remote B", "timestamp": "5"],
                            ["id": "105", "role": "assistant", "content": "Remote B answer", "timestamp": "6"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 6]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // Turn A: foreground-only lifecycle, settles, leaves debt = 1.
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // The next local submit: the debt read proves foreign activity.
        let submittedC = await harness.appState.submitComposer(text: "Local C")
        XCTAssertTrue(submittedC)

        XCTAssertEqual(submitCount, 2, "Turn A + one reconciled local send — no duplicates")
        XCTAssertEqual(transcriptReads, 3, "Debt read + the recovery reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, 2,
            "Seed hydration + the authoritative recovery resume"
        )
        XCTAssertEqual(
            harness.appState.messages.count, 7,
            "The remote turn is visible and the local prompt appends after it"
        )
        XCTAssertEqual(harness.appState.messages.last?.role, .user)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The reconciled local prompt appends last"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// A settled-tail check may absorb only the already-observed local turn's
    /// assistant/tool suffix. A canonical user boundary after the live-time
    /// frontier proves another turn occurred and must be adopted before the
    /// next local prompt is appended.
    func testObservedRunningTurnWithRemoteActivityReconcilesBeforeNextTurn() async {
        let active = session("stored-a")
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let remoteTail: [[String: Any]] = [
            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
            ["id": "103", "role": "assistant", "content": "Partial A", "timestamp": "4"],
            ["id": "104", "role": "tool", "content": "Final tool A", "timestamp": "5"],
            ["id": "105", "role": "user", "content": "Remote B", "timestamp": "6"],
            ["id": "106", "role": "assistant", "content": "Remote B answer", "timestamp": "7"]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": Array(remoteTail.prefix(2)),
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        return .payload([
                            "messages": Array(remoteTail.prefix(4)),
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    return .payload([
                        "messages": remoteTail,
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 7]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(transcriptReads, 2)

        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))

        let submittedC = await harness.appState.submitComposer(text: "Local C")
        XCTAssertTrue(submittedC)

        XCTAssertEqual(submitCount, 2, "Turn A plus exactly one reconciled local send")
        XCTAssertEqual(transcriptReads, 4, "Settled-tail read plus authoritative reconcile read")
        XCTAssertEqual(resumeCount, 2, "The remote user boundary forces authoritative recovery")
        XCTAssertEqual(
            harness.appState.messages.dropLast().map(\.id),
            ["100", "101", "102", "103", "105", "106"],
            "The remote user turn is visible; persisted tool rows remain presentation-filtered"
        )
        XCTAssertTrue(harness.appState.messages.last?.id.hasPrefix("local-") == true)
        box.client.disconnect()
    }

    /// Hermes `prompt.submit` busy outcomes have distinct persistence
    /// contracts. A redirect mutates the current live turn, so it owes ZERO
    /// new canonical user boundaries — but the mutated turn can keep
    /// persisting assistant/tool rows after the current ordering frontier.
    /// The zero-user-boundary final-tail obligation is satisfied by exactly
    /// that non-user-only suffix: one bounded read advances the frontier and
    /// the next ordinary local send proceeds without an authoritative resume.
    func testRedirectedBusySubmissionPersistsTrailingRowsBeforeNextSend() async {
        await assertBusyPromptOutcomeOrdering(
            outcome: .redirected,
            persistedRowsOnDebtRead: [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                ["id": "102", "role": "assistant", "content": "Redirected output", "timestamp": "3"],
                ["id": "103", "role": "tool", "name": "search", "content": "", "timestamp": "4"],
                ["id": "104", "role": "assistant", "content": "Redirected conclusion", "timestamp": "5"]
            ],
            expectedTranscriptReads: 2,
            expectedResumeCount: 1
        )
    }

    /// If a canonical user boundary appears after a redirect, a later or new
    /// turn exists. The zero-user-boundary obligation is then EXCEEDED, and
    /// the next ordinary local send must reconcile authoritatively — the
    /// remote turn becomes visible before the local prompt is sent, exactly
    /// once, with no duplicate delivery.
    func testRedirectedBusySubmissionRemoteTurnReconcilesBeforeNextSend() async {
        await assertBusyPromptOutcomeOrdering(
            outcome: .redirected,
            persistedRowsOnDebtRead: [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                ["id": "102", "role": "assistant", "content": "Redirected output", "timestamp": "3"],
                ["id": "103", "role": "user", "content": "Remote B", "timestamp": "4"],
                ["id": "104", "role": "assistant", "content": "Remote B answer", "timestamp": "5"]
            ],
            expectedTranscriptReads: 3,
            expectedResumeCount: 2
        )
    }

    /// Steer injects into the current run at a role-safe boundary and does not
    /// persist an independent user turn.
    func testSteeredBusySubmissionCreatesNoNewTurnOrderingDebt() async {
        await assertBusyPromptOutcomeOrdering(
            outcome: .steered,
            persistedRowsOnDebtRead: nil,
            expectedTranscriptReads: 2,
            expectedResumeCount: 1
        )
    }

    /// A non-deduplicated queue drains as a full turn. Because the typed
    /// outcome cannot prove an exact boundary count, observing that user row
    /// forces authoritative adoption before another local turn is appended.
    func testQueuedBusySubmissionCanonicalTurnReconcilesBeforeNextSend() async {
        await assertBusyPromptOutcomeOrdering(
            outcome: .queued,
            persistedRowsOnDebtRead: [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                ["id": "102", "role": "user", "content": "Queued follow-up", "timestamp": "3"],
                ["id": "103", "role": "assistant", "content": "Queued answer", "timestamp": "4"]
            ],
            expectedTranscriptReads: 3,
            expectedResumeCount: 2
        )
    }

    /// Hermes reports `.queued` even when `_enqueue_prompt` drops a text-only
    /// duplicate of the in-flight prompt. The outcome therefore cannot create
    /// an exact one-boundary debt; a bounded read with no new user row clears
    /// the observation obligation without an authoritative resume.
    func testQueuedBusySubmissionDroppedAsDuplicateCreatesNoImpossibleDebt() async {
        await assertBusyPromptOutcomeOrdering(
            outcome: .queued,
            persistedRowsOnDebtRead: nil,
            expectedTranscriptReads: 2,
            expectedResumeCount: 1
        )
    }

    /// A steer normally stays inside the live turn, but Hermes promotes a
    /// late `pending_steer` to the queued next turn. If that canonical user
    /// boundary appears, the zero-boundary observation obligation forces an
    /// authoritative reconcile before the next local prompt.
    func testSteeredBusySubmissionPromotedToTurnReconcilesBeforeNextSend() async {
        await assertBusyPromptOutcomeOrdering(
            outcome: .steered,
            persistedRowsOnDebtRead: [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                ["id": "102", "role": "user", "content": "Late steer", "timestamp": "3"],
                ["id": "103", "role": "assistant", "content": "Late steer answer", "timestamp": "4"]
            ],
            expectedTranscriptReads: 3,
            expectedResumeCount: 2
        )
    }

    private func assertBusyPromptOutcomeOrdering(
        outcome: PromptSubmissionOutcome,
        persistedRowsOnDebtRead: [[String: Any]]?,
        expectedTranscriptReads: Int,
        expectedResumeCount: Int
    ) async {
        let active = session("stored-a")
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let seedRows: [[String: Any]] = [
            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    let rows = persistedRowsOnDebtRead ?? seedRows
                    return .payload([
                        "messages": transcriptReads == 1 ? seedRows : rows,
                        "pagination": [
                            "limit": 120,
                            "offset": 0,
                            "order": "latest",
                            "returned": transcriptReads == 1 ? seedRows.count : rows.count
                        ]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return submitCount == 1 ? outcome : .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in [] }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submittedBusy = await harness.appState.submitComposer(text: "Busy-race follow-up")
        XCTAssertTrue(submittedBusy)
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        let submittedNext = await harness.appState.submitComposer(text: "Ordinary next turn")
        XCTAssertTrue(submittedNext)
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(transcriptReads, expectedTranscriptReads)
        XCTAssertEqual(resumeCount, expectedResumeCount)
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// A running probe and persisted read remain older than stream events
    /// buffered behind the foreground boundary. Even when a newer busy edge
    /// confirms the same turn is live, the read certifies only its user
    /// boundary; its later settle still causes one bounded tail catch-up.
    func testRunningForegroundObservationWithBufferedBusyEdgeStillLeavesTailDebt() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        await parkedRead.suspend()
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Partial A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    if transcriptReads == 3 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Partial A", "timestamp": "4"],
                                ["id": "104", "role": "tool", "content": "Final tool A", "timestamp": "5"],
                                ["id": "105", "role": "assistant", "content": "Final A", "timestamp": "6"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 6]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Partial A", "timestamp": "4"],
                            ["id": "104", "role": "tool", "content": "Final tool A", "timestamp": "5"],
                            ["id": "105", "role": "assistant", "content": "Final A", "timestamp": "6"],
                            ["id": "106", "role": "user", "content": "B", "timestamp": "7"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 7]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        harness.appState.handleScenePhase(.background)
        let activationA = Task { @MainActor in await runSceneActivation(harness) }
        await parkedRead.waitUntilSuspended()
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        parkedRead.resume()
        await activationA.value
        await flushMainActor()

        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(harness.appState.turnState, .running)

        harness.appState.handleStreamEvent(.toolStart(
            sessionId: active.id,
            toolName: "read_file",
            toolInput: nil
        ))
        harness.appState.handleStreamEvent(.toolComplete(
            sessionId: active.id,
            toolName: "read_file",
            toolOutput: "Final tool A"
        ))
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Final A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))

        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(transcriptReads, 3, "Buffered busy edge must preserve one settled-tail read")
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(resumeCount, 1)

        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "B thinking."))
        let segmentB = harness.appState.liveReasoningSegment
        let messagesDuringB = harness.appState.messages
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(resumeCount, 1, "Turn B foreground remains observational")
        XCTAssertEqual(harness.appState.messages, messagesDuringB)
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentB)
        box.client.disconnect()
    }

    /// Observing Turn A's user boundary while A is still running does not
    /// certify A's final persisted tail. The next new-turn submit performs one
    /// bounded settled-tail read, advances through assistant/tool-only rows,
    /// and freezes Turn B's baseline after them so B's foreground remains
    /// observational.
    func testObservedRunningTurnReconcilesFinalPersistedTailBeforeNextTurn() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Turn A's foreground freshness read while it is still
                        // running: its user boundary and only the output that
                        // had persisted so far.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    if transcriptReads == 3 {
                        // Turn A continued after the live-time observation.
                        // This pre-send settled-tail read contains no new user
                        // boundary after 103, only A's final durable tail.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Partial answer A", "timestamp": "4"],
                                ["id": "104", "role": "tool", "content": "Tool output A", "timestamp": "5"],
                                ["id": "105", "role": "assistant", "content": "Final answer A", "timestamp": "6"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 6]
                        ])
                    }
                    // Turn B's twin: exactly one canonical user boundary after
                    // the settled-tail catch-up frontier at 105.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Partial answer A", "timestamp": "4"],
                            ["id": "104", "role": "tool", "content": "Tool output A", "timestamp": "5"],
                            ["id": "105", "role": "assistant", "content": "Final answer A", "timestamp": "6"],
                            ["id": "106", "role": "user", "content": "B", "timestamp": "7"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 7]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // Turn A: background + foreground observes its boundary and partial
        // persisted output through 103 while the turn is still live.
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        let segmentA = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentA)

        // A continues after that read and persists more tool/output rows.
        harness.appState.handleStreamEvent(
            .toolStart(sessionId: active.id, toolName: "read_file", toolInput: nil)
        )
        harness.appState.handleStreamEvent(
            .toolComplete(sessionId: active.id, toolName: "read_file", toolOutput: "Tool output A")
        )

        // Settle A locally. No history read has yet observed its final tail.
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // Turn B performs exactly one settled-tail catch-up before freezing
        // its ordering baseline, without replacing the visible transcript.
        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(
            transcriptReads, 3,
            "A live-time boundary observation still requires one final-tail read"
        )
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(harness.appState.turnState, .running)

        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "B thinking."))
        let segmentB = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentB)
        let messagesDuringB = harness.appState.messages
        let optimisticB = messagesDuringB.last
        XCTAssertEqual(optimisticB?.role, .user)
        XCTAssertTrue(optimisticB?.id.hasPrefix("local-") == true)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(transcriptReads, 4)
        XCTAssertEqual(
            resumeCount, 1,
            "B's foreground must not resume after A's final tail was re-anchored"
        )
        XCTAssertEqual(harness.appState.messages, messagesDuringB)
        XCTAssertEqual(harness.appState.messages.last, optimisticB)
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentB)

        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentB?.id)
        box.client.disconnect()
    }

    /// The gate's second non-proceed arm: a recovery boundary
    /// (.reconnecting here) racing the pre-send freshness read proves
    /// neither liveness nor ordering — the send is blocked, not blind-sent
    /// and not routed as a busy action.
    func testPreSendFreshnessRetryBlockedByRecoveryBoundary() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let parkedRead = LifecycleSuspension()
        let parkedMint = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in
                    await parkedMint.suspend()
                    return "ticket"
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        return .failed(DashboardTicketBridgeError.http(
                            status: 503,
                            detail: "temporarily unavailable"
                        ))
                    }
                    if transcriptReads == 3 {
                        await parkedRead.suspend()
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Follow-up")
        }
        await parkedRead.waitUntilSuspended()
        // The race: a reconnect boundary starts while the pre-send freshness
        // read is suspended and parks mid-mint in .reconnecting.
        let reconnect = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await parkedMint.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        parkedRead.resume()

        let submitted = await submission.value
        XCTAssertFalse(submitted, "The blocked send must not report success")

        XCTAssertEqual(submitCount, 0, "No ordinary prompt.submit past a recovery boundary")
        XCTAssertEqual(transcriptReads, 3, "No retry loop behind the blocked send")
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101"],
            "No optimistic new-turn row is appended past a recovery boundary"
        )
        XCTAssertEqual(
            harness.appState.errorMessage, "Unable to refresh this conversation. Try again."
        )
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        box.client.disconnect()
    }

    /// The busy-edge rule also covers the sibling stale-idle probe: a busy
    /// edge landing while THAT probe is suspended must route through the
    /// configured busy action instead of falling through to an ordinary
    /// new-turn prompt.submit into the now-running turn.
    func testStaleIdleProbeBusyEdgeRaceRoutesThroughBusyAction() async {
        let active = session("stored-a")
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        let parkedProbe = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    await parkedProbe.suspend()
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                },
                steer: { _, _, _ in
                    steerCount += 1
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // The lifecycle boundary marks the local idle state stale.
        harness.appState.handleScenePhase(.background)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Follow-up")
        }
        await parkedProbe.waitUntilSuspended()
        // The race: the live busy edge lands while the stale-idle probe is
        // suspended.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        parkedProbe.resume()

        let submitted = await submission.value
        XCTAssertTrue(submitted)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(submitCount, 0, "No ordinary prompt.submit into the running turn")
        XCTAssertEqual(steerCount, 1, "The text routed through the configured busy action")
        XCTAssertEqual(
            harness.appState.messages.map(\.isSteer), [true],
            "No optimistic new-turn row is appended into the running turn; only the steer confirmation (issue #337)"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
    }

    // MARK: - Round 13: `starting` never settles; lifecycle revisions order recovery stamps

    /// The classification CONTRACT for ambiguous-submission recovery, pinned
    /// as a pure matrix. `working`/`waiting` are authoritative committed-busy
    /// state: they classify `.acceptedRunning` before the durable verifier is
    /// consulted, regardless of transcript evidence — and regardless of which
    /// client performed the probe, since ownership is not a classifier input
    /// (regression C: a replacement/reconnected client's `working` row is
    /// acceptedRunning, never acceptedSettled). `starting` NEVER classifies
    /// `.acceptedSettled` or `.notAccepted`.
    func testAmbiguousClassificationContractSplitRegistryStatuses() {
        // committedBusy: a running registry row is never settled — the
        // durable verdict is irrelevant (the verifier is not even consulted).
        XCTAssertEqual(
            AppState.classifyAmbiguousSubmission(
                registryLiveness: .committedBusy,
                transcript: .present
            ),
            .acceptedRunning
        )
        XCTAssertEqual(
            AppState.classifyAmbiguousSubmission(
                registryLiveness: .committedBusy,
                transcript: .absent
            ),
            .acceptedRunning,
            "A working/waiting row classifies acceptedRunning even when the durable tail cannot prove the row: the registry alone settles acceptance"
        )
        XCTAssertEqual(
            AppState.classifyAmbiguousSubmission(
                registryLiveness: .committedBusy,
                transcript: .indeterminate
            ),
            .acceptedRunning
        )

        // starting: runtime present, liveness inconclusive.
        XCTAssertEqual(
            AppState.classifyAmbiguousSubmission(
                registryLiveness: .starting,
                transcript: .present
            ),
            .acceptedUnsettled,
            "A durable submitted row under a starting runtime proves acceptance, never settlement"
        )
        XCTAssertEqual(
            AppState.classifyAmbiguousSubmission(
                registryLiveness: .starting,
                transcript: .absent
            ),
            .unresolved,
            "starting masks a committed turn that may not have reached the durable verification point: absent must stay unresolved, never notAccepted and never a resend"
        )
        XCTAssertEqual(
            AppState.classifyAmbiguousSubmission(
                registryLiveness: .starting,
                transcript: .indeterminate
            ),
            .unresolved
        )

        // idle/absent: the durable transcript decides settled vs not-accepted.
        for liveness in [AppState.AmbiguousRegistryLiveness.idle, .absent] {
            XCTAssertEqual(
                AppState.classifyAmbiguousSubmission(
                    registryLiveness: liveness,
                    transcript: .present
                ),
                .acceptedSettled
            )
            XCTAssertEqual(
                AppState.classifyAmbiguousSubmission(
                    registryLiveness: liveness,
                    transcript: .absent
                ),
                .notAccepted
            )
            XCTAssertEqual(
                AppState.classifyAmbiguousSubmission(
                    registryLiveness: liveness,
                    transcript: .indeterminate
                ),
                .unresolved
            )
        }
    }

    /// Regression A: an ambiguous prompt whose registry row reports
    /// `starting` while the durable verifier proves the submitted user row.
    /// The submission is ACCEPTED (never resent, optimistic row kept, no
    /// failed-send restoration), but the turn is NOT settled: no idle stamp,
    /// the turn stays running-like so the composer cannot ordinary-send a
    /// fresh turn into the committed/building turn, and the next
    /// authoritative registry/stream edges take over and settle it normally.
    func testAmbiguousStartingRegistryWithDurableRowIsAcceptedUnsettled() async {
        let active = session("stored-a")
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // The pre-submit hydration: two durable rows held.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: the submitted user row persisted; the turn is
                    // still building (no assistant output has landed).
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Ambiguous send", "timestamp": "3"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                },
                steer: { _, _, _ in
                    steerCount += 1
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance through the real hydration path.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submitted = await harness.appState.submitComposer(text: "Ambiguous send")

        // Accepted: never a failed send, never a resend, optimistic row kept.
        XCTAssertTrue(
            submitted,
            "Durable acceptance under a starting runtime must not surface as a failed send"
        )
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded tail read decides the outcome")
        XCTAssertEqual(
            catalogCount, 0,
            "No failed-send restoration may run for a durably accepted submission"
        )
        XCTAssertEqual(resumeCount, resumesBeforeSubmit)
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The optimistic user row remains accepted"
        )

        // NOT settled: the turn stays running-like, so a follow-up routes
        // through the busy action instead of a fresh ordinary prompt.submit.
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "A starting runtime must never stamp idle: settlement is unproven"
        )
        let busyRouted = await harness.appState.submitComposer(text: "Follow-up")
        XCTAssertTrue(busyRouted)
        XCTAssertEqual(steerCount, 1, "The follow-up must route through the configured busy action")
        XCTAssertEqual(
            submitCount, 1,
            "No fresh ordinary turn may enter the committed/building turn"
        )

        // The next authoritative edges take over and settle normally.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running, "A busy edge takes over cleanly")
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "The turn settles normally once the authoritative edge arrives"
        )
        box.client.disconnect()
    }

    /// Regression A, staleness half: the same `starting` + durable-present
    /// recovery raced against a real staleness boundary. A scene dip while
    /// the durable verifier is suspended marks the turn state stale; the
    /// acceptedUnsettled resolution must keep the turn running-like WITHOUT
    /// clearing that staleness as though settlement were proven (the
    /// uncertainty survives until an authoritative edge resolves it).
    func testAcceptedUnsettledPreservesStalenessFromNewerBoundary() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery's bounded verification: parked until the test
                    // has opened a staleness boundary against it.
                    await parkedRead.suspend()
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Ambiguous send", "timestamp": "3"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Ambiguous send")
        }
        await parkedRead.waitUntilSuspended()
        // The lifecycle boundary marks the state stale while the recovery's
        // verifier is suspended.
        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.appState.turnStateIsStale)
        parkedRead.resume()

        let submitted = await submission.value

        // Accepted — and NOT settled: no idle stamp, and the boundary's
        // staleness must survive untouched (an acceptedRunning- or
        // acceptedSettled-shaped stamp would clear it).
        XCTAssertTrue(submitted, "Durable acceptance under a starting runtime must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(catalogCount, 0, "No failed-send restoration may run")
        XCTAssertEqual(harness.appState.turnState, .running, "The turn stays running-like")
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "The uncertainty must not be cleared as though settlement were proven"
        )
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The optimistic user row remains accepted"
        )

        // The next authoritative edges resolve the uncertainty normally.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle, "The authoritative settle edge resolves the turn")
        box.client.disconnect()
    }

    /// Regression B: ambiguous prompt, registry `starting`, and the durable
    /// verifier cannot yet prove the submitted row. `starting` is explicitly
    /// inconclusive — the committed turn may not have reached the durable
    /// verification point — so the outcome is the conservative unresolved
    /// path (restore the unsent state exactly once), never acceptedSettled
    /// and never notAccepted solely because `starting` was present.
    func testAmbiguousStartingRegistryWithoutDurableRowStaysUnresolved() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(id: "100", role: .user, content: "Earlier question", timestamp: "1"),
                            ChatMessage(id: "101", role: .assistant, content: "Earlier answer", timestamp: "2")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    // Every read, including recovery's, sees only the
                    // pre-submit tail: the submitted row is not provable.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submitted = await harness.appState.submitComposer(text: "Never delivered")

        XCTAssertFalse(submitted, "Unprovable acceptance under a starting runtime restores conservatively")
        XCTAssertEqual(submitCount, 1, "No blind retry may follow the ambiguous failure")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 3,
            "Hydration, ambiguous verification, and the restore's compact resume each read once"
        )
        XCTAssertEqual(catalogCount, 1, "The unsent restoration runs exactly once")
        XCTAssertEqual(resumeCount, resumesBeforeSubmit + 1)
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101"],
            "The optimistic row is restored away exactly once"
        )
        XCTAssertTrue(
            harness.appState.errorMessage?.contains("Failed to send") == true
        )
        box.client.disconnect()
    }

    /// Regression C (integration): the probe observes `working` while the
    /// active client is REPLACED mid-recovery. The classification must remain
    /// acceptedRunning — a running registry row is never settled — while the
    /// ownership/epoch guards suppress stale local mutation after the
    /// handoff. The submission stays accepted either way.
    func testAmbiguousWorkingRowAfterClientReplacementIsAcceptedRunning() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        // Assigned after harness creation; the seam below only fires during
        // the submission, long after setup has finished.
        var appStateForProbe: AppState?
        var replacementClient: HermesClient?
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The probe itself runs on the CAPTURED client; the
                    // active client is replaced while that probe await is
                    // suspended (a concurrent reconnect elsewhere), so the
                    // classification observes probeClient != self.client.
                    let replacement = HermesClient(
                        connection: HermesConnection(
                            baseUrl: "https://two.example",
                            ticket: "replacement"
                        ),
                        profile: "default"
                    )
                    appStateForProbe?.client = replacement
                    replacementClient = replacement
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        appStateForProbe = harness.appState
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "earlier", role: .assistant, content: "Earlier", timestamp: "0")
        ]

        let submitted = await harness.appState.submitComposer(text: "Ambiguous send")

        XCTAssertTrue(submitted, "A working registry row accepts the submission regardless of client replacement")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        // Ownership (the replaced client) suppresses every local lifecycle
        // stamp after the handoff, so no settled state may leak through the
        // real caller path either: the turn frame the optimistic pre-send
        // stamp left must survive untouched. The classification itself
        // (acceptedRunning for a working row, independent of client identity
        // and durable evidence) is pinned by the contract matrix test.
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertNil(harness.appState.errorMessage, "No failed-send error may surface for an accepted submission")
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The optimistic user row remains accepted"
        )
        replacementClient?.disconnect()
        box.client.disconnect()
    }

    /// Regression D: an `idle` registry snapshot drives the recovery toward
    /// acceptedSettled, but a NEWER sessionBusy(true) lands while the durable
    /// verifier is suspended. The newer running state must survive: the older
    /// recovery result keeps the acceptance (no resend) but must NOT stamp
    /// idle and must NOT clear staleness. Value equality cannot prove this —
    /// the pre-send stamp already left turnState == .running, so a guard
    /// comparing turnState values would pass here and wrongly stamp idle.
    func testNewerBusyEdgeBeatsAcceptedSettledRecoveryStamp() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery's bounded verification: parked until the test
                    // has raced newer lifecycle edges against it.
                    await parkedRead.suspend()
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Ambiguous send", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Completed result", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The registry had already gone absent when recovery
                    // looked: without newer evidence this classifies
                    // acceptedSettled.
                    return []
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Ambiguous send")
        }
        await parkedRead.waitUntilSuspended()
        // Newer live evidence arrives while the older recovery awaits: the
        // session is running again, and the lifecycle boundary marks the
        // state stale.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.appState.turnStateIsStale)
        parkedRead.resume()

        let submitted = await submission.value

        XCTAssertTrue(submitted, "The submission stays accepted: no resend, no failed-send restoration")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(catalogCount, 0, "No failed-send restoration may run")
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The optimistic user row remains accepted"
        )
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The newer busy edge survives: the older recovery must NOT stamp idle"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "The staleness written by the newer boundary must not be cleared by the older recovery result"
        )
        box.client.disconnect()
    }

    /// Regression E (the converse of D): the recovery probe observes
    /// `working` (acceptedRunning), but a NEWER sessionBusy(false) settles
    /// the turn while the probe is suspended. The newer idle settlement must
    /// survive: the older recovery must not force running again and must not
    /// clear the boundary's staleness. A running row also never needs the
    /// durable verifier, so no transcript read may follow.
    func testNewerSettleEdgeBeatsAcceptedRunningRecoveryStamp() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        let parkedProbe = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(id: "100", role: .user, content: "Earlier question", timestamp: "1")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    if submitCount == 1 {
                        throw HermesError.timeout("prompt.submit")
                    }
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    if probeCount == 1 {
                        // The probe itself is parked: the registry says the
                        // turn was working when ASKED, but newer edges land
                        // first.
                        await parkedProbe.suspend()
                        return [LiveSessionStatus(
                            runtimeSessionId: "runtime-a",
                            storedSessionId: "stored-a",
                            status: "working"
                        )]
                    }
                    // Later probes (the stale-idle correction) see the
                    // settled, absent runtime.
                    return []
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100"])
        let resumesBeforeSubmit = resumeCount

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Ambiguous send")
        }
        await parkedProbe.waitUntilSuspended()
        // The turn settled while the probe was suspended, and the settlement
        // boundary marks the state stale.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)
        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.appState.turnStateIsStale)
        parkedProbe.resume()

        let submitted = await submission.value

        XCTAssertTrue(submitted, "The registry proved the submission was accepted: no resend")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 1,
            "A running registry row never consults the durable verifier"
        )
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The optimistic user row remains accepted"
        )
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "The newer settle edge survives: the older recovery must NOT force running again"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "The staleness written by the newer boundary must not be cleared by the older recovery result"
        )
        XCTAssertEqual(resumeCount, resumesBeforeSubmit)

        // Regression B, ownership half: the settle edge ENDED live ownership,
        // so the acceptedRunning recovery must not resurrect the locally-owned
        // marker. A later turn cycle settles with no marker, records no
        // ordering debt, and the next ordinary send therefore performs NO
        // bounded read and no resume.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        let submittedNext = await harness.appState.submitComposer(text: "Ordinary next turn")
        XCTAssertTrue(submittedNext)
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(probeCount, 2, "The stale-idle correction probes once before the ordinary send")
        XCTAssertEqual(
            transcriptReads, 1,
            "No resurrected ownership: the later settle recorded no debt, so the next send needs no bounded read"
        )
        XCTAssertEqual(resumeCount, resumesBeforeSubmit, "Stale settled ownership never forces an authoritative resume")
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// PRIMARY regression: an ambiguous submission whose recovery races a
    /// newer busy edge must retain locally-owned turn continuity. The newer
    /// edge owns the lifecycle STATE (no stale running stamp), but
    /// acceptedRunning positively proves the submission was accepted and is
    /// the active turn — so the locally-owned marker must still be installed.
    /// Without it, the next foreground cannot prove same-turn continuity,
    /// degrades to inconclusive, and a session.resume destroys the PR #121
    /// live reasoning projection.
    func testAmbiguousAcceptedRunningAfterNewerBusyEdgeRetainsLocalTurnContinuity() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        var catalogCount = 0
        let parkedProbe = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // The foreground freshness read: the submitted turn's
                    // durable twin persisted while Conduit was suspended.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    if probeCount == 1 {
                        // The recovery's registry probe is parked: a newer
                        // busy edge lands while it is suspended.
                        await parkedProbe.suspend()
                    }
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "A")
        }
        await parkedProbe.waitUntilSuspended()
        // Newer live evidence arrives while the recovery awaits. The
        // lifecycle revision advances; the turn stays running.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        parkedProbe.resume()

        let submitted = await submission.value

        // Accepted once, lifecycle state untouched by the older recovery.
        XCTAssertTrue(submitted, "The accepted turn must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 1,
            "A running registry row never consults the durable verifier"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertEqual(
            harness.appState.messages.count, 3,
            "The optimistic user row remains accepted"
        )
        XCTAssertEqual(harness.appState.messages.last?.content, "A")

        // The live reasoning projection starts on the running turn.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)

        // A background/foreground cycle must stay observational: the
        // retained locally-owned marker proves same-turn continuity against
        // the persisted twin, so NO session.resume may run and the live
        // reasoning segment must survive untouched.
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(resumeCount, resumesBeforeSubmit, "Zero session.resume: retained ownership proves same-turn continuity")
        XCTAssertEqual(catalogCount, 0, "A healthy foreground must not reload the catalog")
        XCTAssertEqual(probeCount, 2, "The foreground probes the registry once")
        XCTAssertEqual(transcriptReads, 2, "The foreground freshness check reads the bounded tail once")
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.id, segmentBefore?.id,
            "The live reasoning segment must survive the foreground"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertEqual(harness.appState.messages.count, 3, "Foregrounding must not replace the transcript")
        XCTAssertEqual(harness.appState.messages.last?.content, "A")

        // Later reasoning deltas extend the SAME segment (no reset, no
        // duplicate settled thinking row).
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " Step two."))
        await flushMainActor()
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.id, segmentBefore?.id,
            "The same live segment must extend across the foreground"
        )
        XCTAssertEqual(harness.appState.messages.count, 3)
        box.client.disconnect()
    }

    /// Regression C: an acceptedRunning recovery that raced a newer busy edge
    /// retains the locally-owned marker, so when the turn later settles it
    /// flows into the SAME ordering-debt lifecycle as an ordinary accepted
    /// turn: the settle records a missing-boundary debt (one canonical user
    /// turn), and the next local send clears it with exactly one bounded
    /// read — no authoritative resume.
    func testAmbiguousAcceptedRunningRetainedOwnershipLaterSettlesIntoOrderingDebt() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        let parkedProbe = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // The pre-send debt read: turn A's persisted user twin
                    // (plus its output tail) satisfies the missing-boundary
                    // debt.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    if submitCount == 1 {
                        throw HermesError.timeout("prompt.submit")
                    }
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    if probeCount == 1 {
                        await parkedProbe.suspend()
                    }
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "A")
        }
        await parkedProbe.waitUntilSuspended()
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        parkedProbe.resume()

        let submittedA = await submission.value
        XCTAssertTrue(submittedA)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(transcriptReads, 1)

        // The turn settles. The retained locally-owned marker turns this
        // settle into the standard missing-boundary debt.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // The next ordinary send clears the debt with ONE bounded read
        // (exactly one new canonical user boundary observed) and proceeds —
        // no authoritative resume.
        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2, "Exactly one new local prompt after the debt read")
        XCTAssertEqual(
            transcriptReads, 2,
            "One bounded read satisfies the settle debt before the baseline freezes"
        )
        XCTAssertEqual(resumeCount, resumesBeforeSubmit, "A satisfied debt needs no authoritative resume")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertEqual(harness.appState.messages.count, 4, "Both optimistic rows remain: A and B")
        XCTAssertEqual(harness.appState.messages.last?.content, "B")
        box.client.disconnect()
    }

    /// Symmetric provenance coverage for `.acceptedUnsettled`: a `starting`
    /// registry row with the durable row present proves acceptance but not
    /// settlement. When a newer busy edge races the durable verification, the
    /// same split applies — the edge owns the lifecycle state, the accepted
    /// marker stays live — and a later background/foreground cycle stays
    /// observational with the live reasoning projection intact.
    func testAmbiguousAcceptedUnsettledAfterNewerBusyEdgeRetainsLocalTurnContinuity() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Recovery's bounded verification: parked until the
                        // newer busy edge has raced it; then the submitted
                        // user row. Later reads (the foreground freshness
                        // check) must pass through ungated.
                        await parkedRead.suspend()
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The recovery probe observes `starting` (the submit →
                    // agent-ready window); by the foreground the build has
                    // completed and the registry reports committed-busy.
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: probeCount == 1 ? "starting" : "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "A")
        }
        await parkedRead.waitUntilSuspended()
        // A newer busy edge lands while the durable verification awaits.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        parkedRead.resume()

        let submitted = await submission.value

        // Accepted-unsettled: never a failed send, no verifier re-read, and
        // the newer edge's running state survives untouched.
        XCTAssertTrue(submitted, "Durable acceptance must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded tail read decides the outcome")
        XCTAssertEqual(harness.appState.turnState, .running, "The newer busy edge owns the lifecycle state")
        XCTAssertEqual(harness.appState.messages.count, 3, "The optimistic user row remains accepted")

        // The retained ownership marker must carry the turn through a
        // background/foreground cycle observationally.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(resumeCount, resumesBeforeSubmit, "Zero session.resume: retained ownership proves same-turn continuity")
        XCTAssertEqual(probeCount, 2, "The foreground probes the registry once")
        XCTAssertEqual(transcriptReads, 3, "The foreground freshness check reads the bounded tail once")
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.id, segmentBefore?.id,
            "The live reasoning segment must survive the foreground"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertEqual(harness.appState.messages.count, 3)
        box.client.disconnect()
    }

    /// A steer whose RPC completes after the user switched conversations must
    /// stay SUCCESSFUL (an accepted Hermes steer is never a local failure) but
    /// must not mutate the current conversation's global lifecycle evidence.
    /// Otherwise a late Session-A running claim contaminates Session B and
    /// lets B's older ambiguous recovery resurrect accepted-turn ownership
    /// over B's newer settled edge.
    func testLateSteerFromPreviousConversationCannotOverwriteCurrentLifecycleEvidence() async {
        let conversationA = session("stored-a")
        let conversationB = session("stored-b")
        var steerCount = 0
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        let steerGate = LifecycleSuspension()
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [conversationA, conversationB] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    // Stubbed so the transcriptReads assertions below are
                    // live: any accidental verifier or debt read fails them.
                    transcriptReads += 1
                    return .payload([
                        "messages": [],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 0]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    if submitCount == 1 {
                        throw HermesError.timeout("prompt.submit")
                    }
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    if probeCount == 1 {
                        // B's ambiguous-recovery probe is parked.
                        await probeGate.suspend()
                    }
                    // The stale registry snapshot still reports B committed-busy.
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-b",
                        storedSessionId: "stored-b",
                        status: "working"
                    )]
                },
                steer: { _, _, _ in
                    steerCount += 1
                    if steerCount == 1 {
                        // A's steer RPC is parked; B's whole recovery races it.
                        await steerGate.suspend()
                    }
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [conversationA, conversationB]
        harness.appState.activeSessionId = conversationA.id
        // A is running; the user steers into it.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: conversationA.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)

        let steerSubmission = Task { @MainActor in
            await harness.appState.submitComposer(text: "A correction")
        }
        await steerGate.waitUntilSuspended()

        // The user switches to conversation B. A settle edge normalizes the
        // shared turn state so B's text routes as an ordinary new turn.
        harness.appState.activeSessionId = conversationB.id
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: conversationB.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // B's acknowledgement is ambiguous; its recovery probe parks.
        let bSubmission = Task { @MainActor in
            await harness.appState.submitComposer(text: "B prompt")
        }
        await probeGate.waitUntilSuspended()

        // Newer authoritative evidence settles B while its recovery awaits.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: conversationB.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // The parked Session-A steer completes successfully AFTER B's newer
        // settle. It must still report success — without advancing B's
        // lifecycle evidence to running.
        steerGate.resume()
        let steerSubmitted = await steerSubmission.value
        XCTAssertTrue(
            steerSubmitted,
            "A successful steer stays successful across a conversation handoff"
        )

        // B's stale probe returns working. The newer settlement must win.
        probeGate.resume()
        let bSubmitted = await bSubmission.value

        XCTAssertTrue(bSubmitted, "The accepted turn must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(steerCount, 1)
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(resumeCount, 0)
        XCTAssertEqual(
            transcriptReads, 0,
            "A running registry row never consults the durable verifier"
        )
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "The newer settlement survives: no stale running stamp"
        )
        XCTAssertEqual(
            harness.appState.messages.last?.content, "B prompt",
            "The optimistic user row remains accepted"
        )
        XCTAssertNil(harness.appState.errorMessage)

        // No hidden provenance leaked: a further settle with no resurrected
        // marker records no ordering debt, so the next ordinary send needs no
        // bounded read and no resume.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: conversationB.id, busy: false))
        let nextSubmitted = await harness.appState.submitComposer(text: "B next")
        XCTAssertTrue(nextSubmitted)
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(
            transcriptReads, 0,
            "No resurrected ownership: the later settle recorded no debt, so this send needs no bounded read"
        )
        XCTAssertEqual(
            resumeCount, 0,
            "No authoritative resume may follow the stale-evidence race"
        )
        XCTAssertEqual(harness.appState.messages.count, 2, "Both optimistic B rows remain")
        box.client.disconnect()
    }

    /// Same-conversation alias rotation keeps the steer's lifecycle evidence:
    /// a steer that begins for the stored session id and completes after the
    /// runtime identity rotates (still the SAME conversation) must count as
    /// authoritative running evidence. Observable through the recovery guard:
    /// the evidence advance suppresses the acceptedRunning recovery's stale
    /// clearing, so the boundary-written staleness survives.
    func testSteerAfterSameConversationAliasRotationStillAdvancesLifecycleEvidence() async {
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        var steerCount = 0
        var submitCount = 0
        var probeCount = 0
        let steerGate = LifecycleSuspension()
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    if probeCount == 1 {
                        // The ambiguous recovery's probe is parked.
                        await probeGate.suspend()
                    }
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                },
                steer: { _, _, _ in
                    steerCount += 1
                    if steerCount == 1 {
                        await steerGate.suspend()
                    }
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        let steerSubmission = Task { @MainActor in
            await harness.appState.submitComposer(text: "A correction")
        }
        await steerGate.waitUntilSuspended()

        // A settle edge, then the runtime identity rotates within the SAME
        // conversation.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        harness.appState.activeSessionId = "runtime-a"

        // An ambiguous send on the (aliased) conversation parks its recovery
        // probe — the capture predates the parked steer's completion.
        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Ambiguous send")
        }
        await probeGate.waitUntilSuspended()
        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.appState.turnStateIsStale)

        // The steer completes for the SAME conversation: its running evidence
        // must advance.
        steerGate.resume()
        let steerSubmitted = await steerSubmission.value
        XCTAssertTrue(steerSubmitted)

        probeGate.resume()
        let submitted = await submission.value

        XCTAssertTrue(submitted, "The accepted turn must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(steerCount, 1)
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The turn stays running-like for the accepted submission (from the pre-send optimistic stamp, not the suppressed recovery)"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "The aliased steer advanced the evidence, so the recovery must not clear the boundary's staleness"
        )
        box.client.disconnect()
    }

    // MARK: - Foreground recovery purpose

    /// When no visible conversation identity exists on foreground, transport
    /// recovery falls back to .automaticReturn and selects the saved session.
    func testForegroundHealthCheckFailureWithoutVisibleSessionRestoresSavedSession() async throws {
        let savedOlder = session("stored-b")
        let healthGate = LifecycleSuspension()
        var mintCount = 0
        var openedSessionIDs: [String] = []
        var recoveryPurposeDuringReconnect: ChatResumeSyncPurpose? = nil
        var captureRecoveryPurpose: (() -> Void)? = nil
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in [savedOlder] },
                mintTicket: { _ in
                    mintCount += 1
                    captureRecoveryPurpose?()
                    return "reconnect-ticket"
                },
                openSession: { _, sessionID, _ in
                    openedSessionIDs.append(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in
                    await healthGate.suspend()
                    throw URLError(.networkConnectionLost)
                },
                probeActiveSessions: { _ in [] },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        captureRecoveryPurpose = {
            recoveryPurposeDuringReconnect = harness.recoverySequence.currentPurpose
        }
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [savedOlder]
        harness.appState.activeSessionId = nil
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: savedOlder.id), for: "default")

        harness.appState.handleScenePhase(.background)
        let activation = harness.appState.handleScenePhase(.active)
        await healthGate.waitUntilSuspended()

        healthGate.resume()
        if let activation {
            await activation.value
        }

        XCTAssertEqual(
            mintCount, 1,
            "The foreground attempt must reconnect exactly once"
        )
        XCTAssertEqual(
            recoveryPurposeDuringReconnect, .automaticReturn,
            "Foreground transport recovery without a visible session must proceed with .automaticReturn"
        )
        XCTAssertEqual(
            openedSessionIDs, [savedOlder.id],
            "Transport recovery without a visible session must resume the saved session"
        )
        XCTAssertEqual(harness.appState.activeSessionId, savedOlder.id)
        XCTAssertEqual(
            harness.recoverySequence.currentPurpose, .preserveCurrent,
            "Recovery sequence must settle back to baseline"
        )
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertFalse(harness.appState.isConnecting)
        XCTAssertEqual(harness.appState.turnState, .idle)
        box.client.disconnect()
    }

    /// A transport failure is not navigation authority. Even before the
    /// composer is edited, reconnecting must repair the visible conversation
    /// rather than applying the saved-session fallback to an older chat.
    func testForegroundHealthCheckFailurePreservesVisibleSession() async throws {
        try await assertForegroundHealthCheckFailureFallback()
    }

    private func assertForegroundHealthCheckFailureFallback(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let visible = session("stored-a")
        let savedOlder = session("stored-b")
        let healthGate = LifecycleSuspension()
        var mintCount = 0
        var probeReads = 0
        var openedSessionIDs: [String] = []
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in [savedOlder, visible] },
                mintTicket: { _ in
                    mintCount += 1
                    return "reconnect-ticket"
                },
                openSession: { _, sessionID, _ in
                    openedSessionIDs.append(sessionID)
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in
                    await healthGate.suspend()
                    throw URLError(.networkConnectionLost)
                },
                // The probe goes out beside the ping (issue 1727): the busy
                // row it reads from the socket that then fails must be
                // thrown away. Reads after the reconnect see nothing running.
                probeActiveSessions: { _ in
                    probeReads += 1
                    guard probeReads == 1 else { return [] }
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [savedOlder, visible]
        harness.appState.activeSessionId = visible.id
        // Seed through the real hydration path, then repoint the resume
        // store at the older session — the one `.automaticReturn` would
        // restore over the conversation the user is editing.
        let seeded = await harness.appState.openSession(visible.id)
        XCTAssertTrue(seeded, file: file, line: line)
        openedSessionIDs.removeAll()
        probeReads = 0
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: savedOlder.id), for: "default")

        harness.appState.handleScenePhase(.background)
        let activation = harness.appState.handleScenePhase(.active)
        await healthGate.waitUntilSuspended()

        healthGate.resume()
        if let activation {
            await activation.value
        }

        XCTAssertEqual(
            mintCount, 1,
            "The foreground attempt must reconnect exactly once",
            file: file, line: line
        )
        XCTAssertEqual(
            openedSessionIDs, [visible.id],
            "Transport recovery must resume the visible session, never the saved older one",
            file: file, line: line
        )
        XCTAssertEqual(harness.appState.activeSessionId, visible.id, file: file, line: line)
        XCTAssertEqual(
            harness.recoverySequence.currentPurpose, .preserveCurrent,
            "Foreground transport recovery must proceed with .preserveCurrent",
            file: file, line: line
        )
        XCTAssertTrue(harness.appState.isConnected, file: file, line: line)
        XCTAssertFalse(harness.appState.isConnecting, file: file, line: line)
        XCTAssertEqual(harness.appState.turnState, .idle, file: file, line: line)
        box.client.disconnect()
    }

    // MARK: - Harness

    private func makeHarness(
        lifecycleOperations: ChatResumeLifecycleOperations = .live,
        configureDefaults: (UserDefaults) -> Void = { _ in },
        reconnectScheduler: ChatResumeReconnectScheduler? = nil,
        reconnectExecutor: ChatResumeReconnectExecutor? = nil
    ) -> (
        appState: AppState,
        coordinator: ChatResumeCoordinator,
        store: ChatResumeStore,
        recoverySequence: ChatResumeRecoverySequence
    ) {
        let defaults = makeScratchDefaults("AppStateForegroundLifecycleTests")
        configureDefaults(defaults)
        let store = ChatResumeStore(defaults: defaults)
        let coordinator = ChatResumeCoordinator(store: store)
        let recoverySequence = ChatResumeRecoverySequence()
        // A fresh presentation cache per test: the shared singleton would let
        // one test's optimistic rows leak into another test's resume merge.
        let presentationCache = SessionPresentationCache(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: recoverySequence,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            reconnectScheduler: reconnectScheduler,
            reconnectExecutor: reconnectExecutor,
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: presentationCache
        )
        // The registry checks' pace, not this Mac's Low Power Mode or network.
        appState.deviceConditions = { DeviceConditions() }
        return (appState, coordinator, store, recoverySequence)
    }

    /// A real HermesClient whose handshake completed over a fake transport, so
    /// `isConnected` is true without any network traffic. All RPCs in these
    /// tests ride the lifecycle-operation seams.
    @discardableResult
    private func installConnectedClient(
        into harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence
        )
    ) async -> ConnectedClientBox {
        let transport = LifecycleFakeTransport()
        let socket = LifecycleFakeSocket()
        transport.nextSocket = { socket }
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        let client = HermesClient(
            connection: connection,
            profile: "default",
            transportFactory: { transport }
        )
        harness.appState.connection = connection
        harness.appState.client = client
        let connectTask = Task { try await client.connect() }
        transport.open(socket)
        addTeardownBlock { client.disconnect() }
        let box = ConnectedClientBox(
            client: client,
            socket: socket,
            transport: transport,
            connectTask: connectTask
        )
        connectedClientBox = box
        // Deterministic handshake: the caller must observe `isConnected` as
        // soon as this returns, or the ambiguous-submission path would treat
        // the transport as dead and take the reconnect route.
        try? await awaitCompletion(of: connectTask, "the fake handshake")
        return box
    }

    private func installDisconnectedClient(
        into harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence
        )
    ) {
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
    }

    /// Awaits the scene-activation task (the handshake already settled in
    /// `installConnectedClient`).
    private func runSceneActivation(
        _ harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence
        )
    ) async {
        if let task = harness.appState.handleScenePhase(.active) {
            await task.value
        }
    }

    private var connectedClientBox: ConnectedClientBox?

    private func flushMainActor() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func session(
        _ id: String,
        alternateIDs: [String] = []
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternateIDs,
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
}

/// Holds the fake-transport client for a test so the handshake can be awaited
/// and the socket disconnected at teardown.
@MainActor
private final class ConnectedClientBox {
    let client: HermesClient
    let socket: LifecycleFakeSocket
    let transport: LifecycleFakeTransport
    let connectTask: Task<Void, Error>

    init(
        client: HermesClient,
        socket: LifecycleFakeSocket,
        transport: LifecycleFakeTransport,
        connectTask: Task<Void, Error>
    ) {
        self.client = client
        self.socket = socket
        self.transport = transport
        self.connectTask = connectTask
    }
}

private struct LifecycleSyncTimedOut: Error {
    let phase: String
}

/// Suspend/resume gate for driving an in-flight RPC to a chosen point and
/// releasing it after the test has raced a handoff against it.
@MainActor
private final class LifecycleSuspension {
    private var suspension: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspension = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard suspension == nil else { return }
        await withCheckedContinuation { continuation in
            observer = continuation
        }
    }

    func resume() {
        suspension?.resume()
        suspension = nil
    }
}

/// Bounded wait for a spawned task to finish: a wedged phase fails the test
/// naming it instead of suspending forever.
@MainActor
private func awaitCompletion(
    of task: Task<Void, Error>,
    _ phase: String,
    timeout: TimeInterval = 10
) async throws {
    let finished = LifecycleGate()
    let watcher = Task<Void, Never>.detached(priority: .userInitiated) {
        _ = try? await task.value
        finished.signal()
    }
    defer { watcher.cancel() }
    try await finished.wait(phase, timeout: timeout)
}

/// Single-use bounded gate (mirrors the HermesClientTests helper).
private final class LifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal() {
        lock.lock()
        signalled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: false)
    }

    func wait(
        _ phase: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let timedOut = await withCheckedContinuation { continuation in
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            self.continuation = continuation
            lock.unlock()
            Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.fireDeadline()
            }
        }
        if timedOut {
            XCTFail("Timed out after \(timeout)s waiting for \(phase)", file: file, line: line)
            throw LifecycleSyncTimedOut(phase: phase)
        }
    }

    private func fireDeadline() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let signalled = self.signalled
        lock.unlock()
        if !signalled {
            continuation?.resume(returning: true)
        }
    }
}

private final class LifecycleFakeSocket: HermesWebSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var cancelled = false
    var cancelErrorsReceive = true
    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        cancelled = true
        if cancelErrorsReceive {
            receiveContinuation?.resume(throwing: URLError(.networkConnectionLost))
            receiveContinuation = nil
        }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        completionHandler(nil)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }
}

private final class LifecycleFakeTransport: HermesWebSocketTransport {
    var nextSocket: (() -> LifecycleFakeSocket)?
    private var openCallbacks: [ObjectIdentifier: () -> Void] = [:]
    private var earlyOpenRequests = Set<ObjectIdentifier>()

    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket {
        let socket = nextSocket?() ?? LifecycleFakeSocket()
        openCallbacks[ObjectIdentifier(socket)] = { onOpen(socket) }
        if earlyOpenRequests.remove(ObjectIdentifier(socket)) != nil,
           let callback = openCallbacks.removeValue(forKey: ObjectIdentifier(socket)) {
            callback()
        }
        return socket
    }

    func invalidate() {}

    /// Fire the handshake-open callback; buffered so it works whether the
    /// socket has been made yet or not.
    func open(_ socket: LifecycleFakeSocket) {
        let key = ObjectIdentifier(socket)
        if let callback = openCallbacks.removeValue(forKey: key) {
            callback()
        } else {
            earlyOpenRequests.insert(key)
        }
    }
}

// MARK: - Quick app switches (notifier #296)

extension AppStateForegroundLifecycleTests {
    private func installFakeGrace(
        into appState: AppState,
        ended: @escaping (UIBackgroundTaskIdentifier) -> Void = { _ in }
    ) {
        appState.backgroundConnectionGrace = BackgroundConnectionGrace(
            window: 25,
            beginTask: { _ in UIBackgroundTaskIdentifier(rawValue: 7) },
            endTask: ended,
            sleep: { _ in
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
        )
    }

    func testLeavingWithAnOpenSocketHoldsItUntilTheAppIsBack() async {
        var ended: [UIBackgroundTaskIdentifier] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            refreshContext: { _, _ in },
            verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [] }
        ))
        installFakeGrace(into: harness.appState) { ended.append($0) }
        _ = await installConnectedClient(into: harness)

        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.appState.backgroundConnectionGrace.isHolding)
        XCTAssertFalse(harness.appState.isReturningQuietly)

        // Read before the foreground refresh runs: the quiet window is
        // only a few seconds long.
        let activation = harness.appState.handleScenePhase(.active)
        XCTAssertFalse(harness.appState.backgroundConnectionGrace.isHolding)
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
        // Back from the background: a reconnect starting now stays quiet
        // for a moment.
        XCTAssertTrue(harness.appState.isReturningQuietly)
        harness.appState.isConnecting = true
        XCTAssertTrue(harness.appState.hidesBriefReconnect)
        harness.appState.isConnecting = false
        // The refresh itself isn't under test: an overlay dip stops it.
        harness.appState.handleScenePhase(.inactive)
        await activation?.value
    }

    func testAnOverlayDipIsNotAQuietReturn() async {
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            refreshContext: { _, _ in },
            verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [] }
        ))
        installFakeGrace(into: harness.appState)
        _ = await installConnectedClient(into: harness)

        harness.appState.handleScenePhase(.inactive)
        XCTAssertFalse(harness.appState.backgroundConnectionGrace.isHolding)
        let activation = harness.appState.handleScenePhase(.active)
        XCTAssertFalse(harness.appState.isReturningQuietly)
        harness.appState.isConnecting = true
        XCTAssertFalse(harness.appState.hidesBriefReconnect)
        harness.appState.isConnecting = false
        harness.appState.handleScenePhase(.inactive)
        await activation?.value
    }

    func testLeavingWithoutAnOpenSocketHoldsNothing() {
        let harness = makeHarness()
        installFakeGrace(into: harness.appState)
        installDisconnectedClient(into: harness)

        harness.appState.handleScenePhase(.background)
        XCTAssertFalse(harness.appState.backgroundConnectionGrace.isHolding)
    }

    func testTheSocketDroppingOffScreenEndsTheHold() async {
        var ended: [UIBackgroundTaskIdentifier] = []
        let harness = makeHarness()
        installFakeGrace(into: harness.appState) { ended.append($0) }
        _ = await installConnectedClient(into: harness)
        harness.appState.isConnected = true

        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.appState.backgroundConnectionGrace.isHolding)
        harness.appState.isConnected = false
        XCTAssertFalse(harness.appState.backgroundConnectionGrace.isHolding)
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }
}

// MARK: - A reaped runtime (Hermes' ws_orphan_reap_grace_s)

/// Hermes parks a chat whose socket dropped and, after
/// `dashboard.ws_orphan_reap_grace_s` (20 s by default), clears its runtime.
/// From then on the old runtime id gets 4001 "session not found" on chat
/// calls, a 404 on the history read and 4007 on a resume; only the stored id
/// resumes (checked on a real dashboard, Hermes main 2026-11-19). The app
/// resumes the stored chat itself and carries on.
extension AppStateForegroundLifecycleTests {
    private final class ReapedHost {
        var reaped = false
        var refusesEverySend = false
        var storedGone = false
        var resumes: [String] = []
        var sends: [String] = []
        var reads: [String] = []
    }

    private func reapedHostOperations(_ host: ReapedHost) -> ChatResumeLifecycleOperations {
        let page: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        return ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.session("stored-a")] },
            openSession: { _, id, _ in
                host.resumes.append(id)
                if host.reaped, id == "runtime-a" || host.storedGone {
                    throw RpcError(code: 4007, message: "session not found")
                }
                return SessionResumeResult(
                    sessionId: host.reaped ? "runtime-b" : "runtime-a",
                    storedSessionId: "stored-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { id, _, _ in
                host.reads.append(id)
                if host.reaped, id == "runtime-a" {
                    return .failed(DashboardTicketBridgeError.http(status: 404, detail: "Session not found"))
                }
                return .payload(page)
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, id, _ in
                host.sends.append(id)
                if host.refusesEverySend || (host.reaped && id == "runtime-a") {
                    throw RpcError(code: 4001, message: "session not found")
                }
                return .accepted
            },
            verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in
                host.reaped ? [] : [LiveSessionStatus(
                    runtimeSessionId: "runtime-a",
                    storedSessionId: "stored-a",
                    status: "idle"
                )]
            }
        )
    }

    func testASendIntoAReapedRuntimeResumesTheStoredChatAndSends() async {
        let host = ReapedHost()
        let harness = makeHarness(lifecycleOperations: reapedHostOperations(host))
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")

        host.reaped = true
        let submitted = await harness.appState.submitComposer(text: "Follow-up")

        XCTAssertTrue(submitted)
        XCTAssertEqual(host.sends.last, "runtime-b", "the message goes to the resumed runtime")
        XCTAssertEqual(host.sends.filter { $0 == "runtime-b" }.count, 1, "sent once")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-b")
        XCTAssertNil(harness.appState.errorMessage)
        XCTAssertNil(harness.appState.chatSyncErrorMessage)
        XCTAssertTrue(
            harness.appState.openChatSync.sentHereSinceBaseline,
            "the open chat knows the next count change is this send's"
        )
        box.client.disconnect()
    }

    func testABackgroundReturnAfterTheReapResumesTheStoredChat() async {
        let host = ReapedHost()
        let harness = makeHarness(lifecycleOperations: reapedHostOperations(host))
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        harness.appState.handleScenePhase(.background)
        host.reaped = true
        await runSceneActivation(harness)

        XCTAssertEqual(harness.appState.activeSessionId, "runtime-b")
        XCTAssertFalse(host.resumes.dropFirst().contains("runtime-a"), "never resumed by the cleared runtime id: \(host.resumes)")
        XCTAssertNil(harness.appState.chatSyncErrorMessage)
        let submitted = await harness.appState.submitComposer(text: "Follow-up")
        XCTAssertTrue(submitted)
        XCTAssertEqual(host.sends, ["runtime-b"])
        XCTAssertNil(harness.appState.errorMessage)
        box.client.disconnect()
    }

    func testThePreSendCheckAfterTheReapResumesTheStoredChat() async {
        let host = ReapedHost()
        let harness = makeHarness(lifecycleOperations: reapedHostOperations(host))
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        // A freshness read failed for now while away: the next send reads
        // the chat first.
        harness.appState.transcriptFreshnessIsStale = true
        host.reaped = true
        let submitted = await harness.appState.submitComposer(text: "Follow-up")

        XCTAssertTrue(submitted, "error: \(harness.appState.errorMessage ?? "-")")
        XCTAssertEqual(host.sends, ["runtime-b"])
        XCTAssertNotEqual(harness.appState.errorMessage, "Unable to refresh this conversation. Try again.")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-b")
        box.client.disconnect()
    }

    func testASecondRefusalAfterTheResumeShowsTheFailedSend() async {
        let host = ReapedHost()
        let harness = makeHarness(lifecycleOperations: reapedHostOperations(host))
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        host.reaped = true
        host.refusesEverySend = true
        let submitted = await harness.appState.submitComposer(text: "Follow-up")

        XCTAssertFalse(submitted)
        XCTAssertEqual(host.sends, ["runtime-a", "runtime-b"], "one resume and one more try, no loop")
        XCTAssertEqual(harness.appState.errorMessage, "Failed to send: session not found")
        box.client.disconnect()
    }

    func testAResumeThatFailsAfterTheReapShowsTheFailedSend() async {
        let host = ReapedHost()
        let harness = makeHarness(lifecycleOperations: reapedHostOperations(host))
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        host.reaped = true
        host.storedGone = true
        let submitted = await harness.appState.submitComposer(text: "Follow-up")

        XCTAssertFalse(submitted)
        XCTAssertEqual(host.sends, ["runtime-a"], "nothing to send to once the resume fails")
        XCTAssertEqual(
            harness.appState.sendFailureShown, "Failed to send: session not found",
            "the message doesn't just vanish"
        )
        box.client.disconnect()
    }
}

@MainActor
extension AppStateForegroundLifecycleTests {
    func testForegroundRotatedTailDoesNotAdmitCallBeforeRetainedRows() async throws {
        let active = session("stored-a")
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        var reads = 0
        var resumes = 0
        var offsets: [Int] = []
        func rows(_ ids: [Int]) -> [[String: Any]] {
            ids.map { id in ["id": String(id), "role": id.isMultiple(of: 2) ? "assistant" : "user",
                "content": "Rotated foreground row \(id)",
                "timestamp": iso.string(from: epoch.addingTimeInterval(Double(id * 60)))] }
        }
        let initialRows = rows(Array(121...240))
        let rotatedRows = rows(Array(120...237) + [241, 242])
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in
                resumes += 1
                return SessionResumeResult(sessionId: id, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                reads += 1
                let page = reads == 1 ? initialRows : rotatedRows
                return .payload(["session_id": "stored-a", "messages": page,
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": page.count]])
            },
            loadEarlierTranscriptPage: { id, profile, offset in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                offsets.append(offset)
                return .payload(["session_id": "stored-a", "messages": rows(Array(1...120)),
                    "pagination": ["limit": 120, "offset": offset, "order": "latest", "returned": 120]])
            },
            refreshContext: { _, _ in }, verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [LiveSessionStatus(runtimeSessionId: "stored-a", storedSessionId: "stored-a", status: "idle")] }
        ))
        let box = await installConnectedClient(into: harness)
        defer { box.client.disconnect() }
        let state = harness.appState
        state.sessions = [active]
        state.activeSessionId = active.id
        let opened = await state.openSession(active.id)
        XCTAssertTrue(opened)
        let ordinary = state.messages
        XCTAssertEqual(ordinary.map(\.id), (121...240).map(String.init))
        let callTime = epoch.addingTimeInterval(120.5 * 60)
        state.adoptHostChatCalls([VoiceHostChatCall(callID: "unadopted-row-120", chatID: "stored-a",
            startedAt: callTime, endedAt: callTime)], profile: "default")
        let links = state.voiceCallChatLinks
        XCTAssertFalse(state.messages.contains { $0.id == "voice-call-unadopted-row-120" })

        state.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(reads, 2)
        XCTAssertEqual(resumes, 1, "ROTATED_REAL_ADVANCEMENT: anchor 237 must append, not manufacture a resume or direct advancement input")
        XCTAssertTrue(offsets.isEmpty)
        XCTAssertEqual(Array(state.messages.filter { $0.role != .system }.prefix(120)), ordinary,
            "Append-only foreground retains rows 121...240 with exact metadata and order")
        XCTAssertEqual(state.messages.filter { $0.role != .system }.map(\.id), (121...242).map(String.init))
        XCTAssertFalse(state.messages.contains { $0.id == "120" }, "Raw page row120 was not adopted")
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120, "Raw page remains the paging source of truth")
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.oldestLoadedTimestamp, epoch.addingTimeInterval(121 * 60),
            "ROTATED_DISPLAYED_COVERAGE: an unadopted older raw row cannot extend displayed coverage")
        XCTAssertFalse(state.messages.contains { $0.id == "voice-call-unadopted-row-120" },
            "ROTATED_CALL_ADMISSION: call120.5 must remain deferred before the first displayed row121")
        XCTAssertEqual(state.voiceCallChatLinks, links)
        XCTAssertEqual(state.shownChat.durablePersistedRowIDs,
            Set((Array(120...237) + [241, 242]).map(String.init)), "Do not redefine accepted-page provenance")

        let prepended = await state.loadEarlierMessages()
        XCTAssertTrue(prepended)
        XCTAssertEqual(offsets, [120])
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.messages.filter { $0.role != .system }.map(\.id), (1...242).map(String.init))
        let marker = try XCTUnwrap(state.messages.firstIndex { $0.id == "voice-call-unadopted-row-120" })
        XCTAssertEqual(state.messages[marker - 1].id, "120")
        XCTAssertEqual(state.messages[marker + 1].id, "121")
        XCTAssertEqual(state.voiceCallChatLinks, links, "Backfill reveals the marker without rewriting saved links")
    }
}

// An authoritative empty persisted read must retire the hidden-only page and admit its saved calls.
@MainActor
extension AppStateForegroundLifecycleTests {
    func testReview6035656478PositiveEmptyForegroundCompletesHiddenWindow() async throws {
        try await assertPositiveEmptyReadCompletesHiddenWindow(retryBeforeSend: false)
    }

    func testReview6035656478PositiveEmptyPreSendCompletesHiddenWindow() async throws {
        try await assertPositiveEmptyReadCompletesHiddenWindow(retryBeforeSend: true)
    }

    private func assertPositiveEmptyReadCompletesHiddenWindow(retryBeforeSend: Bool) async throws {
        let active = session("stored-a")
        let epoch = Date(timeIntervalSince1970: 1_788_256_800)
        let iso = ISO8601DateFormatter()
        let hidden: [[String: Any]] = (121...240).map { id in
            ["id": String(id), "role": "user", "content": "Hidden durable row \(id)",
             "display_kind": "hidden", "timestamp": iso.string(from: epoch.addingTimeInterval(Double(id * 60)))]
        }
        XCTAssertTrue(MessageNormalizer.normalizeMessages(hidden.map(AnyCodable.from)).isEmpty)
        var reads = 0
        var resumes = 0
        var probes = 0
        var sends = 0
        var rowsAtSend: [String] = []
        var rowsForSend: () -> [String] = { [] }
        var defaults: UserDefaults?
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID, compact in
                resumes += 1
                XCTAssertTrue(compact)
                return SessionResumeResult(sessionId: sessionID, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { id, profile, query in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                XCTAssertEqual(query, PersistedTranscriptPagination.tailQuery(offset: 0))
                reads += 1
                if retryBeforeSend && reads == 2 {
                    return .failed(DashboardTicketBridgeError.http(status: 503, detail: "temporary fixture failure"))
                }
                let rows: [[String: Any]] = reads == 1 ? hidden : []
                return .payload(["session_id": "stored-a", "messages": rows,
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": rows.count]])
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, _, _ in
                sends += 1
                rowsAtSend = rowsForSend()
                return .accepted
            },
            verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in
                probes += 1
                return [LiveSessionStatus(runtimeSessionId: "stored-a", storedSessionId: "stored-a", status: "idle")]
            }
        ), configureDefaults: { defaults = $0 })
        let box = await installConnectedClient(into: harness)
        defer { box.client.disconnect() }
        let state = harness.appState
        state.sessions = [active]
        state.activeSessionId = active.id
        state.adoptHostChatCalls([VoiceHostChatCall(callID: "review-c-saved", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(30), endedAt: epoch.addingTimeInterval(30))], profile: "default")
        let opened = await state.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(resumes, 1)
        XCTAssertTrue(state.messages.isEmpty, "C_INITIAL_HIDDEN_CALL_DEFERRED")
        XCTAssertEqual(state.shownChat.durablePersistedRowIDs, Set((121...240).map(String.init)))
        XCTAssertTrue(try XCTUnwrap(state.persistedTranscriptWindow).hasAcceptedHiddenOnlyPage)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        let links = state.voiceCallChatLinks
        XCTAssertEqual(links.links.count, 1)
        let ordinaryBefore = state.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }
        var model = TranscriptModel()
        var input = TranscriptModel.Input()
        input.loadsEarlier = state.canLoadEarlierMessagesForActiveConversation
        input.hasSavedCopy = state.offlineChatPresentation != nil
        input.chatIsOpening = state.liveChatIsOnItsWay
        _ = model.update(input, targets: [], disclosure: ChatRowDisclosure())
        XCTAssertTrue(model.rows.contains { if case .loadEarlier = $0.kind { return true }; return false })
        XCTAssertTrue(model.rows.contains { if case .empty = $0.kind { return true }; return false },
            "Zero normalized targets draw the welcome in addition to Load earlier")
        XCTAssertFalse(model.drawsOnlyLoadEarlier, "REAL_CAPTURE_AUTOLOAD_GUARD_IS_FALSE")
        try await captureReviewPositiveEmptyHistory(state, label: retryBeforeSend ? "pre-send-before" : "foreground-before")
        XCTAssertEqual(reads, 1, "Mounting the real ChatView must not read earlier history or consume the injected 503")
        state.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(probes, 1)
        if retryBeforeSend {
            XCTAssertTrue(state.transcriptFreshnessIsStale, "Real transient foreground failure arms pre-send retry")
            rowsForSend = { [weak state] in state?.messages.map(\.id) ?? [] }
            let submitted = await state.submitComposer(text: "New prompt after empty history")
            XCTAssertTrue(submitted)
            XCTAssertEqual(sends, 1)
            XCTAssertEqual(reads, 3, "Exactly one real pre-send retry")
            XCTAssertTrue(rowsAtSend.contains("voice-call-review-c-saved"), "Call admitted before new prompt submission")
        } else {
            XCTAssertEqual(reads, 2, "C_EXACTLY_ONE_REAL_ZERO_RAW_FOREGROUND_READ")
        }
        XCTAssertEqual(resumes, 1, "C_CLASSIFIED_UNCHANGED_MUST_NOT_RESUME")
        XCTAssertTrue(state.shownChat.persistedOrderingFrontier.isPositivelyEmpty, "C_REACHED_POSITIVELY_EMPTY_UNCHANGED_BRANCH")
        XCTAssertFalse(state.transcriptFreshnessIsStale)
        if !retryBeforeSend { XCTAssertEqual(state.turnState, .idle) }
        if !retryBeforeSend { XCTAssertEqual(state.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }, ordinaryBefore) }
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, true, "C_POSITIVE_EMPTY_MUST_COMPLETE_WINDOW")
        XCTAssertEqual(state.messages.filter { $0.id == "voice-call-review-c-saved" }.count, 1, "C_POSITIVE_EMPTY_MUST_ADMIT_SAVED_CALL")
        XCTAssertEqual(state.voiceCallChatLinks, links)
        XCTAssertEqual(VoiceCallChatLinks.load(from: try XCTUnwrap(defaults)), links)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 0, "Authoritative zero-row coverage replaces raw120")
        XCTAssertEqual(state.persistedTranscriptWindow?.canLoadEarlier, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.hasAcceptedHiddenOnlyPage, false)
        XCTAssertTrue(state.shownChat.durablePersistedRowIDs.isEmpty, "Obsolete hidden rows are not the accepted durable frontier")
        try await captureReviewPositiveEmptyHistory(state, label: retryBeforeSend ? "pre-send-after" : "foreground-after")
        let receipt: [String: Any] = ["tailReads": reads, "resumes": resumes, "probes": probes,
            "positiveEmptyOrdering": state.shownChat.persistedOrderingFrontier.isPositivelyEmpty,
            "rawOffset": state.persistedTranscriptWindow?.nextOffset ?? -1,
            "reachedBeginning": state.persistedTranscriptWindow?.reachedBeginning ?? false,
            "acceptedHiddenOnly": state.persistedTranscriptWindow?.hasAcceptedHiddenOnlyPage ?? false,
            "rowIDs": state.messages.map(\.id), "linksUnchanged": state.voiceCallChatLinks == links]
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: documents.appendingPathComponent(retryBeforeSend ? "review6035656478-c-pre-send.json" : "review6035656478-c.json"), options: .atomic)
    }

    private func captureReviewPositiveEmptyHistory(_ state: AppState, label: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: DormancyHarnessEnvironment.applying(
            ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize).environmentObject(state)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<15 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        var didDraw = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            didDraw = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw)
        let name = "review6035656478-\(label)-native-ChatView"
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try XCTUnwrap(image.pngData()).write(to: documents.appendingPathComponent(name + ".png"), options: .atomic)
    }
}


@MainActor
extension AppStateForegroundLifecycleTests {
    private func review604ModelSwitchPages() throws -> ([String: Any], [String: Any], [String: Any]) {
        func payload(_ json: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let before = try payload(#"""
{"pagination":{"limit":120,"offset":0,"order":"latest","returned":3},"profile":"default","session_id":"20261124_160454_d1612f","messages":[
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Kept older row X","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":1,"message_uid":"eddb75f0f16b40bba612939f67bfbe7f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.3644767,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"[System: The active model for this chat has changed to fixture-model-before via provider fixture-provider. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]","display_kind":"model_switch","display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":2,"message_uid":"a4ed9014aa214426bbe43c49efd23914","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.370923,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Kept anchor B","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":3,"message_uid":"8393e2f9918c4389a52b898a80a3b1d7","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.3754544,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null}
]}
"""#)
        let tail = try payload(#"""
{"pagination":{"limit":120,"offset":0,"order":"latest","returned":120},"profile":"default","session_id":"20261124_160454_d1612f","messages":[
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Kept anchor B","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":3,"message_uid":"8393e2f9918c4389a52b898a80a3b1d7","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.3754544,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 0","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":4,"message_uid":"7cbf0ca1c27640afa14d5e25fcdffaeb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.389395,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 1","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":5,"message_uid":"2e11cf6c0c9a4bce8c108fef37c8c74f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.3946598,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 2","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":6,"message_uid":"321fd1fd7c1c4eb9be62721b115525ac","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.3993979,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 3","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":7,"message_uid":"2bac54cea11448abb6b560b21fd3c1cc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4042659,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 4","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":8,"message_uid":"e4d39514b8bf4b31b33a36f1f82ad998","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4092014,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 5","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":9,"message_uid":"3ece6275478a4a16b1086738625639a3","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4140465,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 6","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":10,"message_uid":"0c2aa3fb45ce405a982ca9843f830083","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4186313,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 7","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":11,"message_uid":"4e49c3d414c74020999f5987fb6781da","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4235575,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 8","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":12,"message_uid":"02d7766e195544818f1831ed92de6e5d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4292452,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 9","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":13,"message_uid":"9b81adf212684b09971306e65fdbbf49","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4342523,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 10","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":14,"message_uid":"0edbbb53645c48a4aa75aa5c492aa496","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4387698,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 11","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":15,"message_uid":"7f796721de23425ebbb38003f745a72d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4434094,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 12","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":16,"message_uid":"849b367cc77b46efb52d86b686487a87","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4481313,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 13","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":17,"message_uid":"b5dc28bb44fe43f199ae24e0a29d3905","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4532688,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 14","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":18,"message_uid":"469af9362e2b40a4a69d897f36ef12bb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4582617,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 15","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":19,"message_uid":"dbdf132f33834021a58c738cc0d3fb92","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4632044,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 16","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":20,"message_uid":"a4094f6cf72a49ee8ae12d8c264f4215","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.468264,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 17","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":21,"message_uid":"5d491bbbe41a4c63aee0a4efcce4cb2d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4728267,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 18","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":22,"message_uid":"d50a380521094ac290fb3b0241e0bc1e","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4776788,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 19","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":23,"message_uid":"dea5662f815849d68fc89982b1990c03","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4829907,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 20","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":24,"message_uid":"55b5fbc3ae014772aa0c2d41881e6a42","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.488534,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 21","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":25,"message_uid":"6231d35a142540269c51cebd754a9b26","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4936821,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 22","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":26,"message_uid":"14b7a7c0f5dc44ba82db1e460b8ecadc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4987886,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 23","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":27,"message_uid":"9e7510e7ef2d4657946c298d033922e6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.503766,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 24","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":28,"message_uid":"1f3d103544f74178921f760ac2ebe2ab","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5088573,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 25","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":29,"message_uid":"acdf9fe6a2294cbb92b28d387225db0f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5136847,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 26","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":30,"message_uid":"659d6bb24d40492a8dcc7c26518192f0","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5183203,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 27","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":31,"message_uid":"e2ccfc3024af4c4c94cca8be3a918e1b","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5228987,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 28","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":32,"message_uid":"b1293f12fa3a4511899c1878b89649e3","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5276902,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 29","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":33,"message_uid":"fcfb925a26b7440aa434588e18b5e4aa","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5330377,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 30","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":34,"message_uid":"0d31ad9dd1df45f0b2b009d149f7c383","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5375495,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 31","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":35,"message_uid":"8e2599445cbd4de7bf86b460f8eba8c4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5423346,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 32","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":36,"message_uid":"ee24cdaa9d3a4795bf2a79f875583277","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.547805,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 33","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":37,"message_uid":"836ba9b90716466ca8ff0931b459ec02","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5546653,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 34","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":38,"message_uid":"71590ae41eca4c3f82277333ffbf02fc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5610118,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 35","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":39,"message_uid":"6879315ce05c4dd69c0ffd2f9d7b49a6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5666487,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 36","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":40,"message_uid":"3b732ee5aa4f4ebaa9fc0714574e0c89","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.571568,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 37","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":41,"message_uid":"5ee50619641a474fad58be68df986f77","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5771942,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 38","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":42,"message_uid":"682683e9b5eb4bd78e01fab25d69ce5d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5824256,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 39","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":43,"message_uid":"6b334b28199e41a0b5ffd6d1f967fe67","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.587891,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 40","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":44,"message_uid":"5d427ab5402c4b1983ed37eed3a7d267","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5926945,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 41","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":45,"message_uid":"7ae8f427b07942858c4443fb6e379587","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5978725,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 42","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":46,"message_uid":"a01b133738054600af1add81c0eada58","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.603003,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 43","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":47,"message_uid":"6d9d7ad1b2f346d992331386d3c56f82","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6081958,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 44","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":48,"message_uid":"88aaaeb4e27b4678aecd7064c05a95ec","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6162002,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 45","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":49,"message_uid":"66dcbf121626460d800f5cd269518162","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6249554,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 46","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":50,"message_uid":"325ee4a4f80b46b49ecb9de6e5e38567","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.63145,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 47","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":51,"message_uid":"ada369f3949e4365b4a4a0fa39f8e52c","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6359718,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 48","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":52,"message_uid":"ce8539907a624af89faf6ba68dbbba23","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.641093,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 49","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":53,"message_uid":"0be6ef88ac664b2c8fe3d3c84f6e874e","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.645745,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 50","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":54,"message_uid":"52bb35171bce4c339f0c8c0d4fd483ec","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6501138,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 51","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":55,"message_uid":"6b73ffeeb1284c3cb33493348b69ef43","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6548843,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 52","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":56,"message_uid":"0ddb04f5fe8b493ca899ae7e194e82f8","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6594527,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 53","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":57,"message_uid":"2569d648b1024c7ea8e8c7bdd73acdc5","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6643925,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 54","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":58,"message_uid":"1d656d64a5614a089ebfc8ae9513f08c","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6692057,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 55","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":59,"message_uid":"c465b9c70a454f2e98bf7d28499a8c64","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6741116,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 56","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":60,"message_uid":"7765110ce71c4ee3905f89c8e826ad61","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.67878,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 57","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":61,"message_uid":"cd667e0088064407a6942f5784ad23cc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6844132,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 58","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":62,"message_uid":"e5b88de4dd214bdcb6acb7dcbc39e382","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6896343,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 59","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":63,"message_uid":"54025449274641d6a9e3a1d5712a3bba","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6945107,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 60","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":64,"message_uid":"15747e1276814372aadd875851753344","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.699017,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 61","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":65,"message_uid":"a1f122172c77446db53cf8bf0b4480c0","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7038884,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 62","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":66,"message_uid":"979ab821befc4948841543ac73cb5f3c","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7090228,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 63","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":67,"message_uid":"04b19e29f719490fa10f1c2dfa2890d4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7145617,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 64","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":68,"message_uid":"7edca7c6bfe54b2aa94f562a7dc95fcb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.719436,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 65","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":69,"message_uid":"7e09573164504d2b85f999ff689041a7","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7243106,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 66","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":70,"message_uid":"c18aa67d32a84b84887ff5b5b64e99eb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.729184,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 67","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":71,"message_uid":"1a94d91d11a34dddb9bdeba0de2871e9","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7341862,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 68","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":72,"message_uid":"881699c131f14288bc973456496316ef","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7387624,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 69","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":73,"message_uid":"c4d588ba948f46469dd8c64f9724aac2","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7437942,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 70","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":74,"message_uid":"17f1d8ac479449e990e62afe4f7da418","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7488315,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 71","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":75,"message_uid":"a1065eee498d40f08965fb38e43ee9eb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7539809,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 72","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":76,"message_uid":"06cdb2dfbee24666a69bc4c6a45527bb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7591343,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 73","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":77,"message_uid":"491945d1a04a4c4c877de4d2f86c99bc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7637794,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 74","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":78,"message_uid":"f22afbefd4b7420c8862b705a7024e0b","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7689397,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 75","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":79,"message_uid":"56bcecbad2e2468a877515ad36a80cca","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.773911,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 76","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":80,"message_uid":"65f9dea9f1fd435fb154169fcb8a095a","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7789576,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 77","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":81,"message_uid":"73b28fb5d5d34849a1081f71cc35fc8f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7838955,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 78","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":82,"message_uid":"3177eeddb67d4bc593b32db65b3ea353","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7886453,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 79","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":83,"message_uid":"78bd804a3806461c8ce7f71fd9649d23","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7934017,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 80","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":84,"message_uid":"1a6fcf44b22747669c0b26e7aa18d9bf","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.797215,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 81","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":85,"message_uid":"fe440a664cc245de9a415681d8609197","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8017492,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 82","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":86,"message_uid":"04b9355ce8874294a758494cdc3d5a1f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8069208,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 83","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":87,"message_uid":"a73535db13774f1da3b992986e12f51a","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8114414,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 84","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":88,"message_uid":"5a44c7d9cd00401595297b9b0e90172a","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.816228,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 85","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":89,"message_uid":"a59cf4c3baa24e64916c798453684c6e","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.820692,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 86","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":90,"message_uid":"1ca7b433fa014a9c851c945bf4a48e92","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.825615,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 87","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":91,"message_uid":"c3204576297741e3aa38e62d02e4a3d4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8302658,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 88","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":92,"message_uid":"1cf6b030da4b4c9ab7b793f064b37463","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8352056,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 89","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":93,"message_uid":"02edd5508734415d823bf11caea04b62","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8403912,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 90","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":94,"message_uid":"4e4e00982c244d6b84e77311c242f0da","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8455868,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 91","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":95,"message_uid":"2bb5e428f2bf44a29f470ee2c395f75f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8506372,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 92","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":96,"message_uid":"4bfbc205e3b74df19a61cfdeb31f02cc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.857302,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 93","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":97,"message_uid":"ce0c1c7b00754cc4a5ffc9a0b80907fe","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8641963,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 94","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":98,"message_uid":"ded053b845444694a99327660b7039fe","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8694215,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 95","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":99,"message_uid":"c39d2a50eb014230b90617228c7d94df","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8783526,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 96","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":100,"message_uid":"4dc2f340c5eb459f99f677f4800eb6fc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8853126,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 97","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":101,"message_uid":"de942e2427944992bfffd5d7ae5e27a6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8900836,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 98","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":102,"message_uid":"6ded230fc4c043a3b99c9a228ee5ce29","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8953807,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 99","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":103,"message_uid":"34afe803ec8d4219ac29d8461624eaad","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9003665,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 100","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":104,"message_uid":"d568026a188c4114903d0e3352799851","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.905119,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 101","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":105,"message_uid":"226dff410cf54feea47a44c90953085f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9100332,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 102","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":106,"message_uid":"ac7b38a2e1b84c389b61bc4fa9eae492","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9163015,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 103","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":107,"message_uid":"1111294229924eaaad501319626f810d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9213681,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 104","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":108,"message_uid":"d35378f10c8d4ce2b174802cb2855fa4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9260263,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 105","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":109,"message_uid":"db11b2cb10f74986ac07d4b5956afbc6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9311886,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 106","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":110,"message_uid":"d2a8307d3bb84b0e95723f4202487622","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9369447,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 107","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":111,"message_uid":"7304be8fb365464ba365046d293177db","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9420018,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 108","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":112,"message_uid":"1ca35d6d4e9249f3aa29aa058c89be30","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9468267,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 109","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":113,"message_uid":"c8b5cbb2d7b94bde9380e7f6b177b57a","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.951779,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 110","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":114,"message_uid":"32019f2d708c4808b74439d159f1f2da","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9563284,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 111","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":115,"message_uid":"7b57d5fdb9e9473181528240559e9dd0","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9609833,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 112","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":116,"message_uid":"578cde59679942aa9a9c471f15c60182","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9657187,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 113","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":117,"message_uid":"19f498d548ad42f88330f9a173afba75","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9704676,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 114","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":118,"message_uid":"940fb72e0957444f9347c408c3fd3780","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9752998,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 115","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":119,"message_uid":"6a2df364875e4fe3b23dcb8b23dc82b6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.980527,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 116","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":120,"message_uid":"c7f3e3d902e349dfb60bf5393c3b44c4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9847736,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 117","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":121,"message_uid":"a89213cc6f7648848e247ac385d1f305","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9894543,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"[System: The active model for this chat has changed to fixture-model-after via provider fixture-provider. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]","display_kind":"model_switch","display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":122,"message_uid":"c44b35ca200546d8a37f26e83dba00c6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9988883,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null}
]}
"""#)
        let earlier = try payload(#"""
{"pagination":{"limit":120,"offset":120,"order":"latest","returned":1},"profile":"default","session_id":"20261124_160454_d1612f","messages":[
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Kept older row X","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":1,"message_uid":"eddb75f0f16b40bba612939f67bfbe7f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.3644767,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null}
]}
"""#)
        return (before, tail, earlier)
    }
}

@MainActor
extension AppStateForegroundLifecycleTests {
    func testReview6043623895ForegroundReconcilesWithdrawnModelNotice() async throws {
        try await assertReview604ModelSwitchRefresh(retryBeforeSend: false)
    }

    func testReview6043623895PreSendReconcilesWithdrawnModelNotice() async throws {
        try await assertReview604ModelSwitchRefresh(retryBeforeSend: true)
    }

    func testReview6043623895ForegroundReconcilesShortOverlapModelNotice() async throws {
        try await assertReview604ModelSwitchRefresh(retryBeforeSend: false, shortTail: true)
    }

    func testReview6043623895PreSendReconcilesShortOverlapModelNotice() async throws {
        try await assertReview604ModelSwitchRefresh(retryBeforeSend: true, shortTail: true)
    }

    /// Generated no-growth equivalent of the pinned real writer/route receipt:
    /// server.py1152-1194 deactivates old model_switch rows then appends one,
    /// independently of intervening ordinary growth or the tail page size.
    private func review604ShortOverlapModelSwitchPages() throws -> ([String: Any], [String: Any], [String: Any]) {
        let (before, capturedTail, earlier) = try review604ModelSwitchPages()
        let initial = try XCTUnwrap(before["messages"] as? [[String: Any]])
        var replacement = try XCTUnwrap((capturedTail["messages"] as? [[String: Any]])?.last)
        replacement["id"] = 4
        var shortTail = before
        shortTail["messages"] = [initial[0], initial[2], replacement]
        shortTail["pagination"] = ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
        return (before, shortTail, earlier)
    }

    private func assertReview604ModelSwitchRefresh(retryBeforeSend: Bool, shortTail: Bool = false) async throws {
        let pages: ([String: Any], [String: Any], [String: Any])
        if shortTail { pages = try review604ShortOverlapModelSwitchPages() }
        else { pages = try review604ModelSwitchPages() }
        let (before, tail, earlier) = pages
        let stored = try XCTUnwrap(before["session_id"] as? String)
        let active = session(stored)
        let initialRows = MessageNormalizer.normalizeMessages(try XCTUnwrap(before["messages"] as? [Any]).map(AnyCodable.from))
        let tailRows = MessageNormalizer.normalizeMessages(try XCTUnwrap(tail["messages"] as? [Any]).map(AnyCodable.from))
        let earlierRows = MessageNormalizer.normalizeMessages(try XCTUnwrap(earlier["messages"] as? [Any]).map(AnyCodable.from))
        if shortTail {
            XCTAssertEqual(initialRows.map(\.id), ["1.0", "2.0", "3.0"])
            XCTAssertEqual(tailRows.map(\.id), ["1.0", "3.0", "4.0"])
            XCTAssertEqual(tailRows.last?.displayKind, HermesDisplayKind.modelSwitch.rawValue)
        }
        var reads = 0
        var resumes = 0
        var sends = 0
        var rowsAtSend: [String] = []
        var rowsForSend: () -> [String] = { [] }
        var offsets: [Int] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [active] },
            openSession: { _, id, _ in
                resumes += 1
                return SessionResumeResult(sessionId: id, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { id, profile, query in
                XCTAssertEqual(id, stored); XCTAssertEqual(profile, "default")
                XCTAssertEqual(query, PersistedTranscriptPagination.tailQuery(offset: 0))
                reads += 1
                if reads == 1 { return .payload(before) }
                if retryBeforeSend && reads == 2 {
                    return .failed(DashboardTicketBridgeError.http(status: 503, detail: "fixture transient"))
                }
                return .payload(tail)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                offsets.append(offset)
                return .payload(earlier)
            },
            refreshContext: { _, _ in },
            sendPrompt: { _, _, _ in sends += 1; rowsAtSend = rowsForSend(); return .accepted },
            verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [LiveSessionStatus(runtimeSessionId: stored, storedSessionId: stored, status: "idle")] }
        ))
        let box = await installConnectedClient(into: harness)
        defer { box.client.disconnect() }
        let state = harness.appState
        state.sessions = [active]; state.activeSessionId = stored
        let opened = await state.openSession(stored)
        XCTAssertTrue(opened)
        XCTAssertEqual(state.messages, initialRows)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, true)
        let links = state.voiceCallChatLinks
        state.handleScenePhase(.background)
        await runSceneActivation(harness)
        if retryBeforeSend {
            XCTAssertTrue(state.transcriptFreshnessIsStale)
            rowsForSend = { [weak state] in state?.messages.map(\.id) ?? [] }
            let submitted = await state.submitComposer(text: "Prompt after remote model change")
            XCTAssertTrue(submitted)
            XCTAssertEqual(sends, 1)
            XCTAssertFalse(rowsAtSend.contains("2.0"), "PRESEND_REPLACEMENT_MUST_DROP_WITHDRAWN_NOTICE_BEFORE_SEND")
            XCTAssertEqual(Array(rowsAtSend.prefix(tailRows.count)), tailRows.map(\.id))
        } else {
            XCTAssertFalse(state.messages.contains { $0.id == "2.0" }, "FOREGROUND_MUST_NOT_APPEND_WITHDRAWN_NOTICE")
            XCTAssertEqual(state.messages, tailRows, "NEW_NOTICE_REQUIRES_AUTHORITATIVE_TAIL")
            if shortTail {
                XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, true)
                XCTAssertEqual(state.persistedTranscriptWindow?.canLoadEarlier, false)
                XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 3)
                XCTAssertTrue(offsets.isEmpty)
            } else {
                try await captureReviewPositiveEmptyHistory(state, label: "review604-model-switch-after")
                let loaded = await state.loadEarlierMessages()
                XCTAssertTrue(loaded)
                XCTAssertEqual(state.messages, earlierRows + tailRows)
                XCTAssertEqual(offsets, [120])
            }
        }
        XCTAssertEqual(resumes, 2, "Replacement alone uses bounded authoritative reconcile; ordinary growth controls still forbid resume")
        XCTAssertEqual(reads, retryBeforeSend ? 4 : 3)
        XCTAssertEqual(state.voiceCallChatLinks, links)
        XCTAssertFalse(state.transcriptFreshnessIsStale)
    }
}

@MainActor
extension AppStateForegroundLifecycleTests {
    func testReview6043623895BackfillCoverageExcludesOptimisticAndUnadoptedRows() async throws {
        let epoch = Date()
        let iso = ISO8601DateFormatter()
        let persistedStart = epoch.addingTimeInterval(10_000)
        let olderStart = epoch.addingTimeInterval(9_000)
        func rows(_ ids: ClosedRange<Int>, start: Date) -> [[String: Any]] {
            ids.map { id in ["id": "durable-\(id)", "role": "assistant", "content": "Persisted row \(id)",
                "timestamp": iso.string(from: start.addingTimeInterval(Double(id - ids.lowerBound)))] }
        }
        let initial = rows(121...240, start: persistedStart)
        var older = rows(1...119, start: olderStart)
        older.append(["id": "accepted-but-hidden", "role": "user", "content": "Hidden scaffolding", "display_kind": "hidden",
            "timestamp": iso.string(from: epoch.addingTimeInterval(2_000))])
        var offsets: [Int] = []
        var sends = 0
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in SessionResumeResult(sessionId: id, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])) },
            persistedTranscript: { _, _, _ in .payload(["session_id": "stored-a", "messages": initial,
                "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 120]]) },
            loadEarlierTranscriptPage: { _, _, offset in
                offsets.append(offset)
                return .payload(["session_id": "stored-a", "messages": older,
                    "pagination": ["limit": 120, "offset": offset, "order": "latest", "returned": 120]])
            },
            sendPrompt: { _, _, _ in sends += 1; return .accepted }
        ))
        let box = await installConnectedClient(into: harness)
        defer { box.client.disconnect() }
        let state = harness.appState
        state.sessions = [session("stored-a")]; state.activeSessionId = "stored-a"
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        let durable = state.shownChat.durablePersistedRowIDs
        let submitted = await state.submitComposer(text: "Real optimistic row on an earlier local clock")
        XCTAssertTrue(submitted); XCTAssertEqual(sends, 1)
        let optimistic = try XCTUnwrap(state.messages.last)
        XCTAssertEqual(optimistic.role, .user)
        XCTAssertFalse(durable.contains(optimistic.id), "Accepted-page IDs are provenance, not displayed-row guesses")
        XCTAssertLessThan(try XCTUnwrap(MessageTimestampFormatter.date(from: optimistic.timestamp)), olderStart)
        state.adoptHostChatCalls([VoiceHostChatCall(callID: "review604-too-old", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(7_500), endedAt: epoch.addingTimeInterval(7_500))], profile: "default")
        let links = state.voiceCallChatLinks
        XCTAssertFalse(state.messages.contains { $0.id == "voice-call-review604-too-old" })
        let loaded = await state.loadEarlierMessages()
        XCTAssertTrue(loaded)
        XCTAssertEqual(offsets, [120])
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.oldestLoadedTimestamp,
            MessageTimestampFormatter.date(from: iso.string(from: olderStart)), "BACKFILL_PERSISTED_BOUND_MUST_EXCLUDE_LOCAL_AND_HIDDEN_ROWS")
        XCTAssertFalse(state.messages.contains { $0.id == "voice-call-review604-too-old" }, "OPTIMISTIC_TIMESTAMP_MUST_NOT_ADMIT_OLD_CALL")
        XCTAssertEqual(state.messages.last, optimistic)
        XCTAssertEqual(state.messages.filter { $0.id.hasPrefix("durable-") }.map(\.id), (1...240).filter { $0 != 120 }.map { "durable-\($0)" })
        XCTAssertFalse(state.messages.contains { $0.id == "accepted-but-hidden" })
        XCTAssertEqual(state.shownChat.durablePersistedRowIDs, durable, "Backfill must not redefine the latest-page verifier frontier")
        XCTAssertEqual(state.voiceCallChatLinks, links)
    }
}

@MainActor
extension AppStateForegroundLifecycleTests {
    func testReview6043623895OldEarlierRequestCannotReleaseReplacementFlight() async throws {
        let firstGate = LifecycleSuspension()
        let secondGate = LifecycleSuspension()
        defer { firstGate.resume(); secondGate.resume() }
        let firstEntered = LifecycleGate()
        let secondEntered = LifecycleGate()
        var reads = 0
        var offsets: [Int] = []
        func rows(_ range: ClosedRange<Int>) -> [[String: Any]] {
            range.map { ["id": "durable-\($0)", "role": "assistant", "content": "Row \($0)"] }
        }
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in SessionResumeResult(sessionId: id, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])) },
            persistedTranscript: { _, _, _ in
                reads += 1
                let page = rows(reads == 1 ? 121...240 : 123...242)
                return .payload(["session_id": "stored-a", "messages": page,
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 120]])
            },
            loadEarlierTranscriptPage: { _, _, offset in
                offsets.append(offset)
                let ordinal = offsets.count
                if ordinal == 1 { firstEntered.signal(); await firstGate.suspend() }
                if ordinal == 2 { secondEntered.signal(); await secondGate.suspend() }
                return .payload(["session_id": "stored-a", "messages": rows(1...120),
                    "pagination": ["limit": 120, "offset": offset, "order": "latest", "returned": 120]])
            },
            refreshContext: { _, _ in }, verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [LiveSessionStatus(runtimeSessionId: "stored-a", storedSessionId: "stored-a", status: "idle")] }
        ))
        let box = await installConnectedClient(into: harness)
        defer { box.client.disconnect() }
        let state = harness.appState
        state.sessions = [session("stored-a")]; state.activeSessionId = "stored-a"
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        let first = Task { await state.loadEarlierMessages() }
        try await firstEntered.wait("first earlier request entered", timeout: 10)
        XCTAssertEqual(state.persistedTranscriptWindow?.isLoadingEarlier, true)
        state.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(reads, 2, "Real foreground advancement installs the replacement, not a hand-built window")
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(state.persistedTranscriptWindow?.isLoadingEarlier, false)
        let held = state.messages
        let second = Task { await state.loadEarlierMessages() }
        try await secondEntered.wait("replacement earlier request entered", timeout: 10)
        let replacement = try XCTUnwrap(state.persistedTranscriptWindow)
        firstGate.resume()
        let oldLanded = await first.value
        XCTAssertFalse(oldLanded, "STALE_REQUEST_MUST_NOT_ADOPT_INTO_REPLACEMENT_FLIGHT")
        XCTAssertEqual(state.persistedTranscriptWindow, replacement, "STALE_REQUEST_MUST_NOT_RELEASE_OR_ADVANCE_NEW_FLIGHT")
        XCTAssertEqual(state.messages, held)
        let duplicate = await state.loadEarlierMessages()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(offsets, [120, 120], "Single-flight must reject a third fetch while the replacement request owns it")
        secondGate.resume()
        let newLanded = await second.value
        XCTAssertTrue(newLanded, "Replacement response still owns and adopts its page")
        XCTAssertEqual(state.persistedTranscriptWindow?.isLoadingEarlier, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertEqual(state.messages.map(\.id), (1...242).map { "durable-\($0)" })
    }
}

@MainActor
extension AppStateForegroundLifecycleTests {
    func testReview6043623895ActiveTrimKeepsRetainedDurableSkewNotLocalClock() async throws {
        try await assertReview604TrimCoverage(whenLeaving: false, rotateTail: false)
        try await assertReview604TrimCoverage(whenLeaving: false, rotateTail: true)
    }

    func testReview6043623895LeavingTrimKeepsRetainedDurableSkewNotLocalClock() async throws {
        try await assertReview604TrimCoverage(whenLeaving: true, rotateTail: false)
        try await assertReview604TrimCoverage(whenLeaving: true, rotateTail: true)
    }

    private func assertReview604TrimCoverage(whenLeaving: Bool, rotateTail: Bool) async throws {
        let epoch = Date().addingTimeInterval(10_000)
        let iso = ISO8601DateFormatter()
        var reads = 0
        func rows(_ range: ClosedRange<Int>) -> [[String: Any]] {
            range.map { id in ["id": "persisted-\(id)", "role": "assistant", "content": "Row \(id)",
                "timestamp": iso.string(from: epoch.addingTimeInterval(Double((id == 2001 ? 600 : id) * 60)))] }
        }
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in SessionResumeResult(sessionId: id, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])) },
            persistedTranscript: { _, _, _ in
                reads += 1
                return .payload(["session_id": "stored-a", "messages": rows(reads == 1 ? 1881...2000 : reads == 2 ? 1883...2002 : 2002...2121),
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 120]])
            },
            loadEarlierTranscriptPage: { _, _, offset in
                .payload(["session_id": "stored-a", "messages": rows((1881 - offset)...(2000 - offset)),
                    "pagination": ["limit": 120, "offset": offset, "order": "latest", "returned": 120]])
            },
            refreshContext: { _, _ in }, sendPrompt: { _, _, _ in .accepted }, verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [LiveSessionStatus(runtimeSessionId: "stored-a", storedSessionId: "stored-a", status: "idle")] }
        ))
        let box = await installConnectedClient(into: harness)
        defer { box.client.disconnect() }
        let state = harness.appState
        state.sessions = [session("stored-a")]; state.activeSessionId = "stored-a"
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        for _ in 0..<9 { let loaded = await state.loadEarlierMessages(); XCTAssertTrue(loaded) }
        XCTAssertEqual(state.messages.count, 1_200)
        state.chatReaderIsUpInOlderRows = true
        state.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(reads, 2)
        let skew = try XCTUnwrap(state.messages.first { $0.id == "persisted-2001" })
        let skewTime = try XCTUnwrap(MessageTimestampFormatter.date(from: skew.timestamp))
        XCTAssertEqual(state.persistedTranscriptWindow?.oldestLoadedTimestamp, skewTime)
        XCTAssertEqual(state.shownChat.durablePersistedRowIDs, Set((1883...2002).map { "persisted-\($0)" }))
        if rotateTail {
            state.handleScenePhase(.background)
            await runSceneActivation(harness)
            XCTAssertEqual(reads, 3, "Second normal idle foreground must use append-only advancement")
            XCTAssertEqual(state.shownChat.durablePersistedRowIDs, Set((2002...2121).map { "persisted-\($0)" }))
            XCTAssertFalse(state.shownChat.durablePersistedRowIDs.contains(skew.id), "Latest-page verifier IDs must rotate, never union")
            XCTAssertTrue(state.messages.contains { $0.id == skew.id }, "Skewed durable row remains held after provenance rotation")
            XCTAssertEqual(state.persistedTranscriptWindow?.oldestLoadedTimestamp, skewTime)
        }
        let sent = await state.submitComposer(text: "Local optimistic row on an earlier clock")
        XCTAssertTrue(sent)
        let local = try XCTUnwrap(state.messages.last)
        XCTAssertFalse(state.shownChat.durablePersistedRowIDs.contains(local.id))
        XCTAssertLessThan(try XCTUnwrap(MessageTimestampFormatter.date(from: local.timestamp)), skewTime)
        state.handleStreamEvent(.sessionBusy(sessionId: "stored-a", busy: false))
        XCTAssertEqual(state.turnState, .idle, "Real settlement makes both trim callers lifecycle-eligible")
        // A local decoration is not accepted persisted provenance either.
        state.messages.append(ChatMessage(id: "review-summary-trim-local", role: .system, content: "Local decoration",
            timestamp: iso.string(from: epoch)))
        state.adoptHostChatCalls([VoiceHostChatCall(callID: "trim-first", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(650 * 60), endedAt: epoch.addingTimeInterval(650 * 60))], profile: "default")
        let rawOrder = state.messages.filter { $0.id.hasPrefix("persisted-") }.map(\.id)
        state.chatReaderIsUpInOlderRows = false
        let window: PersistedTranscriptWindowState
        let retained: [ChatMessage]
        if whenLeaving {
            state.keepLeftBackfilledTranscript()
            let kept = try XCTUnwrap(state.leftBackfilledTranscripts.last)
            window = kept.window; retained = kept.messages
        } else {
            state.trimLoadedHistoryIfLong()
            window = try XCTUnwrap(state.persistedTranscriptWindow); retained = state.messages
        }
        XCTAssertLessThan(retained.count, 1_200)
        XCTAssertEqual(window.oldestLoadedTimestamp, skewTime, "TRIM_MUST_KEEP_RETAINED_DURABLE_SKEW_WITHOUT_ADOPTING_LOCAL_CLOCK")
        XCTAssertTrue(retained.contains { $0.id == skew.id })
        XCTAssertEqual(retained.first?.id, rotateTail ? "persisted-1041" : "persisted-921", "Each lifecycle cut retains its known page-start suffix")
        if rotateTail { XCTAssertFalse(state.shownChat.durablePersistedRowIDs.contains(skew.id)) }
        XCTAssertTrue(retained.contains { $0.id == local.id }, "A real optimistic row survives but cannot widen persisted coverage")
        let retainedIDs = retained.filter { $0.id.hasPrefix("persisted-") }.map(\.id)
        XCTAssertEqual(retainedIDs, Array(rawOrder.suffix(retainedIDs.count)), "Trim never sorts or rewrites ordinary rows")
        XCTAssertEqual(window.reachedBeginning, false)
        XCTAssertTrue(window.canLoadEarlier)
        if !whenLeaving {
            let links = state.voiceCallChatLinks
            state.adoptHostChatCalls([VoiceHostChatCall(callID: "trim-second", chatID: "stored-a",
                startedAt: epoch.addingTimeInterval(651 * 60), endedAt: epoch.addingTimeInterval(651 * 60))], profile: "default")
            XCTAssertTrue(state.messages.contains { $0.id == "voice-call-trim-second" }, "Retained skewed history must still admit an in-window saved call after remerge")
            XCTAssertTrue(state.voiceCallChatLinks.links.count > links.links.count)
        }
    }
}
