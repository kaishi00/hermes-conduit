import XCTest
@testable import Conduit

/// Pins shared with Hermes (#555). An extension of an existing class so the
/// CI planner gets no new class to place.
extension ChatReadStateTests {
    private static let pinHost = "https://hermes.example"
    private static let pinT0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pinRow(_ id: String, pinned: Bool?, lineageRoot: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            isPinned: pinned,
            lineageRootId: lineageRoot
        )
    }

    private func pinSync(adopted: Bool = false) -> SessionPinSync {
        var sync = SessionPinSync(adopted: adopted ? ["\(Self.pinHost)\u{1F}default"] : [])
        sync.setHost(Self.pinHost)
        return sync
    }

    func testPinsHostWithoutTheFlagKeepsPhonePins() {
        var sync = pinSync()
        let outcome = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: nil), pinRow("b", pinned: nil)], profile: "default")
        XCTAssertEqual(outcome, SessionPinSync.Reconciliation(pins: ["a"], uploads: []))
        XCTAssertFalse(sync.supportsPins(profile: "default", host: Self.pinHost))
        XCTAssertFalse(sync.isAdopted(profile: "default"))
    }

    func testPinsFirstSyncUploadsPhonePinsAndTakesHostPins() {
        var sync = pinSync()
        let listed = [pinRow("a", pinned: false), pinRow("b", pinned: true), pinRow("c", pinned: false)]
        let outcome = sync.reconcile(pins: ["a", "gone-from-listing"], listed: listed, profile: "default", now: Self.pinT0)
        XCTAssertEqual(outcome.pins, ["a", "gone-from-listing", "b"], "Host pins join after the phone's, in order")
        XCTAssertEqual(outcome.uploads, [
            SessionPinSync.Upload(pinID: "a", hostID: "a"),
            SessionPinSync.Upload(pinID: "gone-from-listing", hostID: "gone-from-listing"),
        ], "Pins on unlisted chats go up too")
        XCTAssertTrue(sync.supportsPins(profile: "default", host: Self.pinHost))
        XCTAssertFalse(sync.isAdopted(profile: "default"), "Not adopted until the uploads land")
    }

    func testPinsAdoptedOnceUploadsLand() {
        var sync = pinSync()
        _ = sync.reconcile(pins: ["a", "old"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        sync.recordWrite(pinID: "a", profile: "default", pinned: true, at: Self.pinT0)
        sync.recordWrite(pinID: "old", profile: "default", pinned: true, at: Self.pinT0)
        sync.uploadSucceeded(pinID: "a", profile: "default")
        sync.uploadSucceeded(pinID: "old", profile: "default")

        // A listing fetched before the upload landed still says unpinned.
        let stale = sync.reconcile(pins: ["a", "old"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(stale, SessionPinSync.Reconciliation(pins: ["a", "old"], uploads: []))
        XCTAssertFalse(sync.isAdopted(profile: "default"))

        let later = Self.pinT0.addingTimeInterval(SessionPinSync.pendingWriteLifetime + 1)
        let confirmed = sync.reconcile(pins: ["a", "old"], listed: [pinRow("a", pinned: true)], profile: "default", now: later)
        XCTAssertEqual(confirmed, SessionPinSync.Reconciliation(pins: ["a", "old"], uploads: []))
        XCTAssertTrue(sync.isAdopted(profile: "default"))
    }

    func testPinsUploadTheHostDidntKeepGoesAgain() {
        var sync = pinSync()
        _ = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        sync.recordWrite(pinID: "a", profile: "default", pinned: true, at: Self.pinT0)
        sync.uploadSucceeded(pinID: "a", profile: "default")
        let later = Self.pinT0.addingTimeInterval(SessionPinSync.pendingWriteLifetime + 1)
        let outcome = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: false)], profile: "default", now: later)
        XCTAssertEqual(outcome.uploads, [SessionPinSync.Upload(pinID: "a", hostID: "a")])
        XCTAssertFalse(sync.isAdopted(profile: "default"), "Never adopted while the host disagrees")
    }

    func testPinsAdoptedHostDecides() {
        var sync = pinSync(adopted: true)
        let outcome = sync.reconcile(
            pins: ["a", "unlisted"],
            listed: [pinRow("a", pinned: false), pinRow("b", pinned: true)],
            profile: "default"
        )
        XCTAssertEqual(outcome.pins, ["unlisted", "b"], "Unpinned on Desktop leaves; an unlisted pin stays")
        XCTAssertEqual(outcome.uploads, [])
    }

    func testPinsOwnWriteOutranksAStaleListing() {
        var sync = pinSync(adopted: true)
        sync.recordWrite(pinID: "a", profile: "default", pinned: true, at: Self.pinT0)
        let stale = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(stale.pins, ["a"])

        let confirmed = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: true)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(confirmed.pins, ["a"])
        XCTAssertTrue(sync.pendingWrites.isEmpty, "A listing that shows the write retires it")

        let unpinnedElsewhere = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(unpinnedElsewhere.pins, [])
    }

    func testPinsFailedWriteOnlyDiscardsTheLatest() {
        var sync = pinSync()
        let first = sync.recordWrite(pinID: "a", profile: "default", pinned: true)
        let second = sync.recordWrite(pinID: "a", profile: "default", pinned: false)
        XCTAssertFalse(sync.discardWrite(pinID: "a", profile: "default", generation: first))
        XCTAssertTrue(sync.discardWrite(pinID: "a", profile: "default", generation: second))
        XCTAssertTrue(sync.pendingWrites.isEmpty)
    }

    func testPinsFollowTheLineageRoot() {
        var sync = pinSync(adopted: true)
        let tip = pinRow("tip", pinned: true, lineageRoot: "root")
        let outcome = sync.reconcile(pins: [], listed: [tip], profile: "default")
        XCTAssertEqual(outcome.pins, ["root"])
        let unpinned = sync.reconcile(pins: ["tip"], listed: [pinRow("tip", pinned: false, lineageRoot: "root")], profile: "default")
        XCTAssertEqual(unpinned.pins, [], "A pin stored under the tip's own id clears too")
    }

    func testPinsUploadWritesTheListedRowsOwnID() {
        var sync = pinSync()
        let outcome = sync.reconcile(
            pins: ["root"],
            listed: [pinRow("tip", pinned: false, lineageRoot: "root")],
            profile: "default"
        )
        XCTAssertEqual(outcome.uploads, [SessionPinSync.Upload(pinID: "root", hostID: "tip")])
    }

    func testPinsForgetADeletedProfile() {
        var sync = pinSync(adopted: true)
        _ = sync.reconcile(pins: [], listed: [pinRow("a", pinned: true)], profile: "default")
        sync.recordWrite(pinID: "a", profile: "default", pinned: false)
        sync.forget(profile: "default")
        XCTAssertFalse(sync.isAdopted(profile: "default"))
        XCTAssertFalse(sync.supportsPins(profile: "default", host: Self.pinHost))
        XCTAssertTrue(sync.pendingWrites.isEmpty)
    }

    func testPinsAnotherHostStartsOver() {
        var sync = pinSync(adopted: true)
        _ = sync.reconcile(pins: [], listed: [pinRow("a", pinned: true)], profile: "default")
        sync.recordWrite(pinID: "a", profile: "default", pinned: false)
        sync.setHost("https://other.example")
        XCTAssertFalse(sync.supportsPins(profile: "default", host: "https://other.example"))
        XCTAssertFalse(sync.isAdopted(profile: "default"))
        XCTAssertTrue(sync.pendingWrites.isEmpty)
    }

    func testDashboardRowsCarryHermesPinnedFlag() {
        let rows: [[String: Any]] = [
            ["id": "a", "title": "A", "message_count": 3, "pinned": true, "profile": "default"],
            ["id": "b", "title": "B", "message_count": 3, "pinned": false, "profile": "default"],
            ["id": "c", "title": "C", "message_count": 3, "profile": "default"],
        ]
        let sessions = MessageNormalizer.normalizeSessions(
            AnyCodable.from(["sessions": rows] as [String: Any]),
            profile: nil
        )
        XCTAssertEqual(sessions.first { $0.id == "a" }?.isPinned, true)
        XCTAssertEqual(sessions.first { $0.id == "b" }?.isPinned, false)
        XCTAssertNil(sessions.first { $0.id == "c" }?.isPinned)
    }
}
