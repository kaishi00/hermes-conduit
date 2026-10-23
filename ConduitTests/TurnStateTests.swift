import XCTest
@testable import Conduit

final class TurnStateTests: XCTestCase {
    func testGatewayRunningMapsToAuthoritativeComposerStates() {
        XCTAssertEqual(TurnState.fromGatewayRunning(true), .running)
        XCTAssertEqual(TurnState.fromGatewayRunning(false), .idle)
        XCTAssertEqual(TurnState.fromGatewayRunning(nil), .unsupportedGateway)
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
