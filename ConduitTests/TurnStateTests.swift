import XCTest
@testable import Conduit

final class TurnStateTests: XCTestCase {
    func testGatewayRunningMapsToAuthoritativeComposerStates() {
        XCTAssertEqual(TurnState.fromGatewayRunning(true), .running)
        XCTAssertEqual(TurnState.fromGatewayRunning(false), .idle)
        XCTAssertEqual(TurnState.fromGatewayRunning(nil), .unsupportedGateway)
    }

    /// Hermes reattaches a live empty chat (no stored row yet) without
    /// `running`: it is idle, not an old gateway (App Store review
    /// 2026-11-02; Eric, 2026-11-04, a New Chat left and come back to).
    func testALazyResumeWithoutRunningIsIdle() {
        let lazy: [String: AnyCodable] = [
            "session_id": .string("rt-1"),
            "info": .object(["lazy": .bool(true), "model": .string("glm")])
        ]
        let liveness = HermesClient.resumeLiveness(lazy)
        XCTAssertEqual(liveness["running"], .bool(false))
        XCTAssertEqual(liveness["status"], .string("idle"))
        XCTAssertEqual(TurnState.fromGatewayRunning(SessionRuntimeSnapshot(object: HermesClient.resumeSnapshotFields(lazy)).running), .idle)
        XCTAssertEqual(SessionRuntimeSnapshot(object: HermesClient.resumeSnapshotFields(lazy)).model, "glm", "info's other fields stay")
        // A JSON null says nothing either way.
        let nulls: [String: AnyCodable] = ["running": .null, "status": .null, "info": .object(["lazy": .bool(true)])]
        XCTAssertEqual(SessionRuntimeSnapshot(object: HermesClient.resumeSnapshotFields(nulls)).running, false)
        let nullOverBusy: [String: AnyCodable] = ["status": .null, "info": .object(["lazy": .bool(true), "status": .string("working")])]
        XCTAssertNil(SessionRuntimeSnapshot(object: HermesClient.resumeSnapshotFields(nullOverBusy)).running)
    }

    func testAResumeThatSaysItRunsKeepsItsWordAndAnOldOneStillCantSay() {
        let running: [String: AnyCodable] = [
            "running": .bool(true), "status": .string("streaming"),
            "info": .object(["lazy": .bool(true)])
        ]
        XCTAssertEqual(HermesClient.resumeLiveness(running)["running"], .bool(true))
        XCTAssertEqual(HermesClient.resumeLiveness(running)["status"], .string("streaming"))
        let old: [String: AnyCodable] = ["session_id": .string("rt-1"), "info": .object(["model": .string("glm")])]
        XCTAssertNil(HermesClient.resumeLiveness(old)["running"], "a gateway that never says stays unsupported")
        // A lazy resume that says otherwise in `info` or by a busy status
        // isn't overruled.
        let saysInInfo: [String: AnyCodable] = ["info": .object(["lazy": .bool(true), "running": .bool(true)])]
        XCTAssertNil(HermesClient.resumeLiveness(saysInInfo)["running"])
        XCTAssertEqual(SessionRuntimeSnapshot(object: HermesClient.resumeSnapshotFields(saysInInfo)).running, true)
        let busy: [String: AnyCodable] = ["status": .string("streaming"), "info": .object(["lazy": .bool(true)])]
        XCTAssertNil(HermesClient.resumeLiveness(busy)["running"])
    }

    func testOnlyResolvedStatesEnableComposerActions() {
        XCTAssertTrue(TurnState.idle.acceptsComposerActions)
        XCTAssertTrue(TurnState.running.acceptsComposerActions)
        XCTAssertFalse(TurnState.synchronizing.acceptsComposerActions)
        XCTAssertFalse(TurnState.reconnecting.acceptsComposerActions)
        XCTAssertFalse(TurnState.unsupportedGateway.acceptsComposerActions)
    }

    func testComposerActionMappingCoversIdleRecoveryAndBusyModes() {
        XCTAssertEqual(TurnState.idle.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .send)
        XCTAssertEqual(TurnState.synchronizing.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .unavailable)
        XCTAssertEqual(TurnState.reconnecting.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .unavailable)
        XCTAssertEqual(TurnState.running.composerAction(hasText: false, hasAttachments: false, busyInputMode: .steer), .stop)
        XCTAssertEqual(TurnState.running.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .steer)
        XCTAssertEqual(TurnState.running.composerAction(hasText: true, hasAttachments: false, busyInputMode: .interrupt), .interrupt)
        XCTAssertEqual(TurnState.running.composerAction(hasText: true, hasAttachments: false, busyInputMode: .queue), .queue)
        XCTAssertEqual(TurnState.running.composerAction(hasText: false, hasAttachments: false, busyInputMode: .queue), .stop)
        XCTAssertEqual(TurnState.unsupportedGateway.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .unavailable)
    }

    /// #1146: while Hermes replies, attachments go as Queue in every busy
    /// mode; steer takes text alone.
    func testAttachmentsWhileRunningQueue() {
        for mode in BusyInputMode.allCases {
            XCTAssertEqual(TurnState.running.composerAction(hasText: true, hasAttachments: true, busyInputMode: mode), .queue)
            XCTAssertEqual(TurnState.running.composerAction(hasText: false, hasAttachments: true, busyInputMode: mode), .queue)
        }
        XCTAssertEqual(TurnState.idle.composerAction(hasText: false, hasAttachments: true, busyInputMode: .steer), .send)
        XCTAssertEqual(ComposerSendChoice.choices(for: .queue, hasAttachments: true, isSlashCommand: false), [])
    }

    /// Hermes treats an unset or unknown `display.busy_input_mode` as
    /// interrupt, so the app does too.
    func testBusyInputModeDefaultsToInterruptLikeHermes() {
        XCTAssertEqual(BusyInputMode.fromGatewayValue("interrupt"), .interrupt)
        XCTAssertEqual(BusyInputMode.fromGatewayValue("steer"), .steer)
        XCTAssertEqual(BusyInputMode.fromGatewayValue(" Steer "), .steer)
        XCTAssertEqual(BusyInputMode.fromGatewayValue("queue"), .queue)
        XCTAssertEqual(BusyInputMode.fromGatewayValue("QUEUE"), .queue)
        XCTAssertEqual(BusyInputMode.fromGatewayValue("something-new"), .interrupt)
        XCTAssertEqual(BusyInputMode.fromGatewayValue(""), .interrupt)
        XCTAssertEqual(BusyInputMode.fromGatewayValue(nil), .interrupt)
    }

    /// Touch and hold on the action button (#816, #817, #842, #962): the
    /// busy modes the tap doesn't use, then the side agents.
    func testSendChoicesOfferEveryOtherWayToSend() {
        XCTAssertEqual(
            ComposerSendChoice.choices(for: .steer, hasAttachments: false, isSlashCommand: false),
            [.queue, .interrupt, .background, .btw]
        )
        XCTAssertEqual(
            ComposerSendChoice.choices(for: .queue, hasAttachments: false, isSlashCommand: false),
            [.steer, .interrupt, .background, .btw]
        )
        XCTAssertEqual(
            ComposerSendChoice.choices(for: .interrupt, hasAttachments: false, isSlashCommand: false),
            [.steer, .queue, .background, .btw]
        )
        XCTAssertEqual(ComposerSendChoice.choices(for: .send, hasAttachments: false, isSlashCommand: false), [.background, .btw])
        XCTAssertEqual(ComposerSendChoice.choices(for: .send, hasAttachments: true, isSlashCommand: false), [])
        XCTAssertEqual(ComposerSendChoice.choices(for: .steer, hasAttachments: false, isSlashCommand: true), [])
        XCTAssertEqual(ComposerSendChoice.choices(for: .stop, hasAttachments: false, isSlashCommand: false), [])
        XCTAssertEqual(ComposerSendChoice.choices(for: .unavailable, hasAttachments: false, isSlashCommand: false), [])
        XCTAssertEqual(ComposerSendChoice.background.slashCommand, "background")
        XCTAssertEqual(ComposerSendChoice.btw.slashCommand, "btw")
        XCTAssertNil(ComposerSendChoice.queue.slashCommand)
    }

    func testActiveTurnRedirectOutcomesTreatQueuedAsDelivered() {
        XCTAssertEqual(SessionRedirectOutcome(gatewayStatus: "redirected"), .redirected)
        XCTAssertEqual(SessionRedirectOutcome(gatewayStatus: "queued"), .queued)
        XCTAssertEqual(SessionRedirectOutcome(gatewayStatus: "rejected"), .rejected)
        XCTAssertEqual(SessionRedirectOutcome(gatewayStatus: nil), .rejected)
    }

    func testSessionRuntimeSnapshotPreservesGatewayTurnAndRuntimeFields() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "running": .bool(true),
            "status": .string("streaming"),
            "model": .string("gpt-5.6"),
            "provider": .string("openai"),
            "context_percent": .number(42),
            "active_subagents": .number(3)
        ], inflight: .string("message-123"))

        XCTAssertEqual(snapshot.running, true)
        XCTAssertEqual(snapshot.status, "streaming")
        XCTAssertEqual(snapshot.model, "gpt-5.6")
        XCTAssertEqual(snapshot.provider, "openai")
        XCTAssertEqual(snapshot.contextPercent, 42)
        XCTAssertEqual(snapshot.activeAgents, 3)
        XCTAssertEqual(snapshot.inflight?.stringValue, "message-123")
    }
}
