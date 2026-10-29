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

    private func pinArranged(_ rows: [PinRow], _ orders: [String: [String]], mixed: [String] = []) -> [String] {
        PinnedChatOrder.arrange(rows, profile: \.profile, ids: \.ids, order: { orders[$0] ?? [] }, mixed: mixed).map(\.id)
    }

    private func pinKeys(_ rows: [PinRow]) -> [String] {
        rows.map { PinnedChatOrder.key(profile: $0.profile, id: $0.pinID) }
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

    func testPinnedOrderDragInAllStaysWhereItWasDropped() {
        // Issue 1486: home's only pin dragged above work's snapped back.
        let rows = [
            PinRow(id: "w1", profile: "work"),
            PinRow(id: "w2", profile: "work"),
            PinRow(id: "h1", profile: "home"),
        ]
        let orders = pinOrders(rows, moving: [2], to: 0)
        let mixed = PinnedChatOrder.mixedOrder(
            moving: rows, fromOffsets: [2], toOffset: 0,
            profile: \.profile, pinID: \.pinID, ids: \.ids, mixed: ["home\u{1F}gone"]
        )
        XCTAssertEqual(mixed, pinKeys([rows[2], rows[0], rows[1]]) + ["home\u{1F}gone"])
        XCTAssertEqual(pinArranged(rows, orders, mixed: mixed), ["h1", "w1", "w2"])
    }

    func testPinnedOrderMixedKeepsEachProfilesOwnOrder() {
        let rows = [
            PinRow(id: "w1", profile: "work"),
            PinRow(id: "h1", profile: "home"),
            PinRow(id: "w2", profile: "work"),
        ]
        let mixed = pinKeys([rows[1], rows[0], rows[2]])
        XCTAssertEqual(pinArranged(rows, [:], mixed: mixed), ["h1", "w1", "w2"])
        // Reordered since in work alone: home keeps the top, work's chats swap.
        XCTAssertEqual(pinArranged(rows, ["work": ["w2", "w1"]], mixed: mixed), ["h1", "w2", "w1"])
        // A chat pinned since goes on top.
        let pinned = [PinRow(id: "h2", profile: "home")] + rows
        XCTAssertEqual(pinArranged(pinned, [:], mixed: mixed), ["h2", "h1", "w1", "w2"])
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
        order.setMixed([
            PinnedChatOrder.key(profile: "work", id: "x"),
            PinnedChatOrder.key(profile: "default", id: "a"),
            PinnedChatOrder.key(profile: "default", id: "b"),
        ])
        order.save(to: defaults)
        XCTAssertEqual(PinnedChatOrder(defaults: defaults), order)
        order.drop(["b"], profile: "default")
        XCTAssertEqual(order.mixed.count, 2, "an unpinned chat leaves All's order too")
        order.forget(profile: "work")
        order.drop(["a", "c"], profile: "default")
        XCTAssertTrue(order.isEmpty)
        order.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: PinnedChatOrder.storageKey))
        XCTAssertNil(defaults.object(forKey: PinnedChatOrder.mixedStorageKey))
    }
}
