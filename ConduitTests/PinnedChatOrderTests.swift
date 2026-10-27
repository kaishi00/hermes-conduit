//
//  PinnedChatOrderTests.swift
//  Conduit
//
//  The Pinned section's own order (issue 1354). An extension of the nesting
//  suite, so the planner gains no class.
//

import XCTest
@testable import Conduit

extension SessionNestingModelTests {
    private struct PinRow: Equatable {
        var id: String
        var profile = "default"
        var lineageRoot: String?

        var pinID: String { lineageRoot ?? id }
        var ids: Set<String> { [id, pinID] }
    }

    private func pinArranged(_ rows: [PinRow], _ orders: [String: [String]]) -> [String] {
        PinnedChatOrder.arrange(rows, profile: \.profile, ids: \.ids, order: { orders[$0] ?? [] }).map(\.id)
    }

    private func pinOrders(
        _ rows: [PinRow],
        moving source: IndexSet,
        to destination: Int,
        saved: [String: [String]] = [:]
    ) -> [String: [String]] {
        PinnedChatOrder.orders(
            moving: rows,
            fromOffsets: source,
            toOffset: destination,
            profile: \.profile,
            pinID: \.pinID,
            ids: \.ids,
            order: { saved[$0] ?? [] }
        )
    }

    func testPinnedOrderUnsetKeepsRecentActivity() {
        let rows = [PinRow(id: "a"), PinRow(id: "b"), PinRow(id: "c")]
        XCTAssertEqual(pinArranged(rows, [:]), ["a", "b", "c"])
    }

    func testPinnedOrderPutsNewPinsOnTop() {
        let rows = [PinRow(id: "new"), PinRow(id: "a"), PinRow(id: "b"), PinRow(id: "c")]
        XCTAssertEqual(pinArranged(rows, ["default": ["c", "a", "b"]]), ["new", "c", "a", "b"])
    }

    func testPinnedOrderFollowsTheLineageRootAcrossCompaction() {
        let rows = [PinRow(id: "a"), PinRow(id: "rotated", lineageRoot: "root")]
        XCTAssertEqual(pinArranged(rows, ["default": ["root", "a"]]), ["rotated", "a"])
    }

    func testPinnedOrderKeepsWhereEachProfileSitsInAll() {
        let rows = [
            PinRow(id: "w1", profile: "work"),
            PinRow(id: "h1", profile: "home"),
            PinRow(id: "w2", profile: "work"),
            PinRow(id: "h2", profile: "home"),
        ]
        let shown = pinArranged(rows, ["work": ["w2", "w1"], "home": ["h2", "h1"]])
        XCTAssertEqual(shown, ["w2", "h2", "w1", "h1"], "each profile's rows hold the places they held")
    }

    func testPinnedOrderFirstDragSavesTheWholeSection() {
        let rows = [PinRow(id: "a"), PinRow(id: "b"), PinRow(id: "c")]
        XCTAssertEqual(pinOrders(rows, moving: [2], to: 0), ["default": ["c", "a", "b"]])
    }

    func testPinnedOrderDragKeepsPinsNotShown() {
        let rows = [PinRow(id: "a"), PinRow(id: "b")]
        let saved = ["default": ["hidden", "a", "b"]]
        XCTAssertEqual(pinOrders(rows, moving: [0], to: 2, saved: saved), ["default": ["b", "a", "hidden"]])
    }

    func testPinnedOrderDragInAllChangesOnlyTheMovedProfile() {
        let rows = [
            PinRow(id: "w1", profile: "work"),
            PinRow(id: "h1", profile: "home"),
            PinRow(id: "w2", profile: "work"),
        ]
        XCTAssertEqual(pinOrders(rows, moving: [2], to: 0), ["work": ["w2", "w1"]])
    }

    func testPinnedOrderMovesSkipNestRowsAndStayAboveRecentChats() {
        // pinned a, its "3 jobs" line, an open job, pinned b, then a recent chat.
        let movable = [true, false, false, true, false]
        let up = PinnedChatOrder.movableOffsets(fromOffsets: [3], toOffset: 1, movable: movable)
        XCTAssertEqual(up?.source, IndexSet([1]))
        XCTAssertEqual(up?.destination, 1, "dropped under a's row, a's nest follows it")
        let down = PinnedChatOrder.movableOffsets(fromOffsets: [0], toOffset: 5, movable: movable)
        XCTAssertEqual(down?.destination, 2, "below the recent chat lands at the end of Pinned")
        XCTAssertNil(PinnedChatOrder.movableOffsets(fromOffsets: [1], toOffset: 0, movable: movable))
    }

    func testPinnedOrderDropsUnpinnedChatsAndSaves() throws {
        let suite = "PinnedChatOrderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var order = PinnedChatOrder()
        order.set(["a", "b", "a", "c"], profile: "default")
        XCTAssertEqual(order.ids(profile: "default"), ["a", "b", "c"])
        order.drop(["b"], profile: "default")
        order.set(["x"], profile: "work")
        order.save(to: defaults)
        XCTAssertEqual(PinnedChatOrder(defaults: defaults), order)
        order.forget(profile: "work")
        order.drop(["a", "c"], profile: "default")
        XCTAssertTrue(order.idsByProfile.isEmpty)
        order.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: PinnedChatOrder.storageKey))
    }
}
