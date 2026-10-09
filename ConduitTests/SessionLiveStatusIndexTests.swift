import XCTest
@testable import Conduit

// Kept in ChatReadStateTests' class so the CI planner sees no new class.
extension ChatReadStateTests {
    private func listed(_ id: String, stored: String? = nil, alternates: [String] = []) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: stored,
            alternateIds: alternates,
            title: id,
            model: "Hermes",
            updatedLabel: "",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false
        )
    }

    func testLiveIndexMapsWorkingAndWaitingRows() {
        let index = SessionLiveStatusIndex(rows: [
            LiveSessionStatus(runtimeSessionId: "rt-1", storedSessionId: "s-1", status: "working"),
            LiveSessionStatus(runtimeSessionId: "rt-2", storedSessionId: "s-2", status: "waiting"),
            LiveSessionStatus(runtimeSessionId: "rt-3", storedSessionId: "s-3", status: "idle"),
            LiveSessionStatus(runtimeSessionId: "rt-4", storedSessionId: "s-4", status: "starting"),
        ])
        XCTAssertEqual(index.status(for: listed("s-1")), .working)
        XCTAssertEqual(index.status(for: listed("s-2")), .needsInput)
        XCTAssertNil(index.status(for: listed("s-3")))
        XCTAssertNil(index.status(for: listed("s-4")))
    }

    func testLiveIndexMatchesRuntimeAndAlternateIDs() {
        let index = SessionLiveStatusIndex(rows: [
            LiveSessionStatus(runtimeSessionId: "rt-1", storedSessionId: "s-1", status: "working"),
        ])
        XCTAssertEqual(index.status(for: listed("rt-1")), .working)
        XCTAssertEqual(index.status(for: listed("x", alternates: ["s-1"])), .working)
        XCTAssertEqual(index.status(for: listed("x", stored: "s-1")), .working)
        XCTAssertNil(index.status(for: listed("other")))
    }

    func testNeedsInputOutranksWorkingForOneConversation() {
        let index = SessionLiveStatusIndex(rows: [
            LiveSessionStatus(runtimeSessionId: "rt-a", storedSessionId: "s-1", status: "waiting"),
            LiveSessionStatus(runtimeSessionId: "rt-b", storedSessionId: "s-1", status: "working"),
        ])
        XCTAssertEqual(index.status(for: listed("s-1")), .needsInput)
        XCTAssertEqual(index.status(for: listed("rt-b", alternates: ["s-1"])), .needsInput)
    }

    func testLiveIndexMatchesTheLineageRoot() {
        let index = SessionLiveStatusIndex(rows: [
            LiveSessionStatus(runtimeSessionId: "rt-1", storedSessionId: "root", status: "waiting"),
        ])
        var continued = listed("continuation")
        continued.lineageRootId = "root"
        XCTAssertEqual(index.status(for: continued), .needsInput)
    }
}
