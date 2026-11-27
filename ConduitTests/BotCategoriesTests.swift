//
//  BotCategoriesTests.swift
//  ConduitTests
//
//  Bot categories (BotCategories): read from and written to the same
//  ui_meta fields as Hermes Desktop's sections, grouped by name, Other
//  last, in the synced order.
//

import XCTest
@testable import Conduit

@MainActor
final class BotCategoriesTests: XCTestCase {
    private func bot(_ name: String, category: BotCategoryTag? = nil) -> BotProfile {
        var bot = BotProfile(
            name: name, botTitle: nil, displayName: name, profileDescription: "", model: nil, provider: nil,
            hasAvatar: false, isPinned: false, isHiddenByMeta: false, appearanceColor: nil,
            canonicalSession: nil, lastActive: nil, lastPreview: nil
        )
        bot.category = category
        return bot
    }

    /// A bot's category is Hermes Desktop's section: both fields, or none
    /// (an old Desktop's id with no name has nothing to show).
    func testTheCategoryIsReadFromHermesDesktopsSectionFields() throws {
        let payload: [String: AnyCodable] = [
            "profiles": .array([
                .object(["name": .string("butler"), "ui_meta": .object(["hermes-bots": .object([
                    "sectionId": .string("sec-1"), "sectionName": .string("  Home "), "color": .string("#fff"),
                ])])]),
                .object(["name": .string("coder"), "ui_meta": .object(["hermes-bots": .object([
                    "sectionId": .string("sec-2"),
                ])])]),
                .object(["name": .string("ledger")]),
            ]),
        ]
        let bots = try XCTUnwrap(BotRosterDecoder.decode(.object(payload))).bots
        XCTAssertEqual(bots.first { $0.name == "butler" }?.category, BotCategoryTag(id: "sec-1", name: "Home"))
        XCTAssertNil(bots.first { $0.name == "coder" }?.category)
        XCTAssertNil(bots.first { $0.name == "ledger" }?.category)
        // The kept copy keeps it, so the headings draw before Hermes answers.
        let butler = try XCTUnwrap(bots.first { $0.name == "butler" })
        let kept = try JSONDecoder().decode(BotProfile.self, from: JSONEncoder().encode(butler))
        XCTAssertEqual(kept.category, butler.category)
    }

    /// Filing writes both fields; taking a bot out deletes them; every
    /// other field another client keeps rides along.
    func testThePatchWritesBothFieldsAndKeepsTheRest() {
        let existing: [String: AnyCodable] = ["color": .string("#fff"), "sectionId": .string("old")]
        let filed = BotMetaPatch.merged(existing: existing, patch: BotCategories.patch(BotCategoryTag(id: "sec-9", name: "Business")))
        XCTAssertEqual(filed["sectionId"] as? String, "sec-9")
        XCTAssertEqual(filed["sectionName"] as? String, "Business")
        XCTAssertEqual(filed["color"] as? String, "#fff")
        let removed = BotMetaPatch.merged(existing: existing, patch: BotCategories.patch(nil))
        XCTAssertNil(removed["sectionId"])
        XCTAssertNil(removed["sectionName"])
        XCTAssertEqual(removed["color"] as? String, "#fff")
    }

    /// A name a host already files bots under keeps that host's id, in any
    /// case, so Hermes Desktop there draws one section; a new one gets
    /// Desktop's shape of id.
    func testFilingReusesTheHostsIDForTheSameName() {
        let bots = [bot("a", category: BotCategoryTag(id: "sec-home", name: "Home")), bot("b")]
        XCTAssertEqual(BotCategories.tag(named: "home", among: bots), BotCategoryTag(id: "sec-home", name: "home"))
        let fresh = BotCategories.tag(named: "Business", among: bots)
        XCTAssertEqual(fresh.name, "Business")
        XCTAssertTrue(fresh.id.hasPrefix("sec-"))
        XCTAssertNotEqual(fresh.id, "sec-home")
    }

    /// Headings group by name in any case (one category across dashboards
    /// whose ids differ), follow the order, then first appearance, with
    /// Other last; no category at all is no headings.
    func testSectionsGroupByNameInTheOrderWithOtherLast() throws {
        let items = [
            bot("coder"),
            bot("ledger", category: BotCategoryTag(id: "x1", name: "Business")),
            bot("butler", category: BotCategoryTag(id: "h1", name: "Home")),
            bot("scout", category: BotCategoryTag(id: "x2", name: "business")),
        ]
        let unordered = try XCTUnwrap(BotCategories.sections(items, order: BotOrder()) { $0.category?.name })
        XCTAssertEqual(unordered.map(\.name), ["Business", "Home", nil])
        XCTAssertEqual(unordered[0].items.map(\.name), ["ledger", "scout"])
        XCTAssertEqual(unordered[2].items.map(\.name), ["coder"])
        let ordered = try XCTUnwrap(BotCategories.sections(items, order: BotOrder(names: ["home"])) { $0.category?.name })
        XCTAssertEqual(ordered.map(\.name), ["Home", "Business", nil])
        XCTAssertNil(BotCategories.sections([bot("a"), bot("b")], order: BotOrder()) { $0.category?.name })
        XCTAssertNotEqual(ordered[2].id, BotCategories.key("Other"), "a category named Other isn't Other")
    }

    /// Move Earlier and Move Later step a heading past its neighbour; a
    /// rename keeps its place.
    func testMovingAndRenamingKeepTheOrder() {
        let shown = ["Home", "Business", "Clients"]
        XCTAssertEqual(BotCategories.moving(BotOrder(), "Clients", by: -1, shown: shown).names, ["Home", "Clients", "Business"])
        XCTAssertEqual(BotCategories.moving(BotOrder(), "Home", by: 1, shown: shown).names, ["Business", "Home", "Clients"])
        XCTAssertEqual(BotCategories.moving(BotOrder(), "Home", by: -1, shown: shown), BotOrder(), "nothing before the first")
        XCTAssertEqual(BotCategories.renaming(BotOrder(names: shown), "business", to: "Work").names, ["Home", "Work", "Clients"])
    }

    /// The order is kept per dashboard and synced as `bots.categories`.
    func testTheOrderIsSavedAndSynced() throws {
        let suite = "BotCategoriesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let slot = appState.botCategoryOrderSlot
        XCTAssertEqual(slot.key, "bots.categories")
        XCTAssertNil(slot.read())
        appState.moveBotCategory("Business", by: -1, shown: ["Home", "Business"])
        XCTAssertEqual(slot.read() as? [String], ["Business", "Home"])
        let key = BotCategories.storageKey(scope: appState.dashboardListsScope)
        XCTAssertEqual(defaults.stringArray(forKey: key), ["Business", "Home"])
        XCTAssertTrue(AppState.dashboardScopedSyncKeys.contains("bots.categories"))
        slot.write(nil)
        XCTAssertTrue(appState.botCategoryOrder.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: key))
    }
}
