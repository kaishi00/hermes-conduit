import XCTest
@testable import Conduit

/// Standalone calls and Classic voice chats archived when their call ends (#1124): Hermes
/// Desktop leaves them out, Conduit keeps listing them with its calls. An
/// extension of an existing class so the CI planner gets no new class to place.
extension ChatReadStateTests {
    private func archivedCallRows(_ rows: [[String: Any]]) -> [SessionSummary] {
        MessageNormalizer.normalizeSessions(
            AnyCodable.from(["sessions": rows] as [String: Any]),
            profile: nil
        )
    }

    func testArchivedCallRowsCarryHermesAutoArchiveStampAndEndReason() {
        let sessions = archivedCallRows([
            ["id": "call", "title": "Call", "message_count": 2, "archived": true, "auto_archived": 1,
             "end_reason": "conduit_voice", "profile": "default"],
            ["id": "chat", "title": "Chat", "message_count": 2, "archived": true, "auto_archived": 0,
             "profile": "default"],
            ["id": "old", "title": "Old host", "message_count": 2, "archived": true, "profile": "default"],
        ])
        let call = sessions.first { $0.id == "call" }
        XCTAssertEqual(call?.isAutoArchived, true)
        XCTAssertEqual(call?.endReason, "conduit_voice")
        XCTAssertEqual(sessions.first { $0.id == "chat" }?.isAutoArchived, false)
        XCTAssertNil(sessions.first { $0.id == "chat" }?.endReason)
        XCTAssertNil(sessions.first { $0.id == "old" }?.isAutoArchived, "a host without the stamp")
    }

    func testOnlyACallThePluginArchivedStaysListed() {
        let sessions = archivedCallRows([
            // Archived by the plugin when the call ended.
            ["id": "call", "title": "Call", "message_count": 2, "archived": true, "auto_archived": 1,
             "end_reason": "conduit_voice", "profile": "default"],
            // Archived by the user: the stamp is cleared.
            ["id": "kept-away", "title": "Call", "message_count": 2, "archived": true, "auto_archived": 0,
             "end_reason": "conduit_voice", "profile": "default"],
            // A chat Hermes' idle sweep archived.
            ["id": "stale", "title": "Chat", "message_count": 2, "archived": true, "auto_archived": 1,
             "end_reason": "agent_close", "profile": "default"],
            // Typed into since: Hermes reopened and un-archived it.
            ["id": "continued", "title": "Call", "message_count": 4, "archived": false, "auto_archived": 0,
             "profile": "default"],
        ])
        XCTAssertEqual(sessions.filter { AppState.isArchivedVoiceChat($0, tags: [:]) }.map(\.id), ["call"])
    }

    func testAClassicVoiceChatOrVoiceJobThePluginArchivedStaysListedByItsTag() {
        let sessions = archivedCallRows([
            ["id": "classic", "title": "Voice chat", "message_count": 4, "archived": true, "auto_archived": 1,
             "profile": "default"],
            ["id": "job", "title": "Job", "message_count": 4, "archived": true, "auto_archived": 1,
             "profile": "default"],
            ["id": "kept-away", "title": "Voice chat", "message_count": 4, "archived": true, "auto_archived": 0,
             "profile": "default"],
        ])
        let tags: [String: VoiceSessionTag] = [
            "classic": VoiceSessionTag(kind: .classic),
            "job": VoiceSessionTag(kind: .job),
            "kept-away": VoiceSessionTag(kind: .classic),
        ]
        // A voice job's chat is archived once Hermes answered it.
        XCTAssertEqual(sessions.filter { AppState.isArchivedVoiceChat($0, tags: tags) }.map(\.id), ["classic", "job"])
        XCTAssertFalse(AppState.isArchivedVoiceChat(sessions[1], tags: [:]), "untagged, it's Hermes' own sweep")
    }

    func testArchivedCallsMergeIntoTheListByRecency() {
        func row(_ id: String, at: TimeInterval) -> SessionSummary {
            SessionSummary(id: id, alternateIds: [], title: id, model: "Hermes", updatedLabel: "",
                           lastActivityAt: at, profile: "default", source: .chat, isActive: false, isArchived: false)
        }
        let merged = V2FilterSelection.mergedByRecency(
            [row("chat-3", at: 30), row("chat-1", at: 10)],
            [row("call-2", at: 20), row("call-0", at: 0)]
        )
        XCTAssertEqual(merged.map(\.id), ["chat-3", "call-2", "chat-1", "call-0"])
    }

    func testContentSearchKeepsAnArchivedCallConduitStillLists() {
        let call = SessionSummary(id: "call", alternateIds: [], title: "Call", model: "Hermes", updatedLabel: "",
                                  profile: "default", source: .chat, isActive: false, isArchived: false)
        let rows = SessionContentSearch.rows(
            hits: SessionContentSearch.hits(from: ["results": [
                ["session_id": "call", "snippet": "the >>>garden<<< plan", "archived": true],
                ["session_id": "gone", "snippet": "the >>>garden<<< plan", "archived": true],
            ]], query: "garden") ?? [],
            listed: [],
            known: [call]
        )
        XCTAssertEqual(rows.map(\.openID), ["call"])
    }
}
