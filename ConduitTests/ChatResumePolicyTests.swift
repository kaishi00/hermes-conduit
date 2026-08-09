import XCTest
@testable import Conduit

final class ChatResumePolicyTests: XCTestCase {
    private func session(
        _ id: String,
        alternates: [String] = [],
        source: SessionSource = .chat
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternates,
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: source,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    func testContinueReturnsSavedConversationWhenAnotherConversationIsNewer() {
        let newestB = session("stored-b", alternates: ["runtime-b"])
        let savedA = session("stored-a", alternates: ["runtime-a"])

        let selected = ChatResumeSessionResolver.target(
            in: [newestB, savedA],
            behavior: .continueWhereLeftOff,
            purpose: .automaticReturn,
            savedSessionID: "runtime-a",
            currentSessionID: "runtime-a"
        )

        XCTAssertEqual(selected?.id, "stored-a")
    }

    func testLatestReturnDeliberatelyIgnoresSavedConversation() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-b"), session("stored-a")],
            behavior: .latestActivity,
            purpose: .automaticReturn,
            savedSessionID: "stored-a",
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(selected?.id, "stored-b")
    }

    func testRecoverySyncPreservesCurrentConversationRegardlessOfPreference() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-b"), session("stored-a")],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: "stored-a",
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(selected?.id, "stored-a")
    }

    func testUnavailableSavedConversationFallsBackToNewestOrdinaryChat() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("cron", source: .cron), session("stored-b")],
            behavior: .continueWhereLeftOff,
            purpose: .automaticReturn,
            savedSessionID: "deleted-a",
            currentSessionID: "deleted-a"
        )

        XCTAssertEqual(selected?.id, "stored-b")
    }

    func testLatestReturnsNilWhenNoOrdinaryChatExists() {
        XCTAssertNil(ChatResumeSessionResolver.target(
            in: [session("cron", source: .cron)],
            behavior: .latestActivity,
            purpose: .automaticReturn,
            savedSessionID: "cron",
            currentSessionID: "cron"
        ))
    }

    func testRecoveryMatchesAlternateCurrentID() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-a", alternates: ["runtime-a"])],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: nil,
            currentSessionID: "runtime-a"
        )
        XCTAssertEqual(selected?.id, "stored-a")
    }

    func testContinueCanRestoreSavedCronConversation() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-b"), session("cron-a", source: .cron)],
            behavior: .continueWhereLeftOff,
            purpose: .automaticReturn,
            savedSessionID: "cron-a",
            currentSessionID: "cron-a"
        )
        XCTAssertEqual(selected?.id, "cron-a")
    }
}
