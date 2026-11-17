import XCTest
@testable import Conduit

/// Starter faces (StarterFaces). An extension rather than its own class:
/// the hosted CI planner balances shards per class.
extension BotModeTests {
    private func starterRoster(_ rows: [[String: AnyCodable]]) throws -> [BotProfile] {
        try XCTUnwrap(BotRosterDecoder.decode(.object(["profiles": .array(rows.map(AnyCodable.object))]))).bots
    }

    private func starterRow(_ name: String, created: Double? = nil, face: Int? = nil, isDefault: Bool = false) -> [String: AnyCodable] {
        var meta: [String: AnyCodable] = [:]
        if let created { meta["created"] = .number(created) }
        if let face { meta["face"] = .number(Double(face)) }
        return [
            "name": .string(name),
            "is_default": .bool(isDefault),
            "ui_meta": .object(["hermes-bots": .object(meta)])
        ]
    }

    /// The main bot gets the first face, the rest the next free ones in the
    /// order they were made, whatever order the roster lists them in.
    func testStarterFacesGoToTheMainBotFirstThenByWhenEachWasMade() throws {
        let bots = try starterRoster([
            starterRow("scout", created: 3_000),
            starterRow("atlas", created: 2_000),
            starterRow("default", isDefault: true),
            starterRow("undated")
        ])
        let faces = Dictionary(uniqueKeysWithValues: bots.map { ($0.name, $0.starterFace) })
        XCTAssertEqual(faces["default"], 0)
        XCTAssertEqual(faces["atlas"], 1)
        XCTAssertEqual(faces["scout"], 2)
        XCTAssertEqual(faces["undated"], 3, "a bot with no date comes after the dated ones")
    }

    /// A face held in ui_meta is kept, even when another bot holds it too,
    /// and the others skip it.
    func testAStoredStarterFaceIsKeptAndSkippedByTheOthers() throws {
        let bots = try starterRoster([
            starterRow("default", isDefault: true),
            starterRow("atlas", created: 1, face: 0),
            starterRow("scout", created: 2, face: 0),
            starterRow("juno", created: 3)
        ])
        let faces = Dictionary(uniqueKeysWithValues: bots.map { ($0.name, $0.starterFace) })
        XCTAssertEqual(faces["atlas"], 0)
        XCTAssertEqual(faces["scout"], 0, "a picked face is kept even if another bot has it")
        XCTAssertEqual(faces["default"], 1)
        XCTAssertEqual(faces["juno"], 2)
        XCTAssertEqual(StarterFaces.nextFree(after: bots), 3)
    }

    /// A bot's color is the one Hermes keeps, else its face's; past the
    /// twelve, faces keep coming.
    func testABotWithoutAColorTakesItsStarterFacesColor() throws {
        var bots = try starterRoster([starterRow("default", isDefault: true)])
        XCTAssertEqual(bots[0].shownColor, StarterFaces.set[0].hex)
        bots = try starterRoster([[
            "name": .string("atlas"),
            "ui_meta": .object(["hermes-bots": .object(["color": .string("hsl(30 68% 58%)")])])
        ]])
        XCTAssertEqual(bots[0].shownColor, "hsl(30 68% 58%)")
        XCTAssertEqual(StarterFaces.set.count, 12)
        XCTAssertEqual(Set(StarterFaces.set.map(\.hex)).count, 12, "no two starter faces share a color")
        XCTAssertNotEqual(StarterFaces.face(12), StarterFaces.face(13))
    }

    /// The kept copy carries each bot's face, so a kept row wears the same
    /// one before Hermes answers.
    func testTheKeptRosterCarriesEachBotsStarterFace() throws {
        let bots = try starterRoster([starterRow("default", isDefault: true), starterRow("atlas", created: 1)])
        let data = try JSONEncoder().encode(KeptBotRoster(bots: bots, desktopGroups: []))
        let kept = try JSONDecoder().decode(KeptBotRoster.self, from: data)
        XCTAssertEqual(kept.bots.map(\.starterFace), [0, 1])
        XCTAssertEqual(StarterFaces.assign(kept.bots).map(\.starterFace), [0, 1])
    }

    /// ProfileAvatarView's look: the dashboard on screen's or another
    /// combined dashboard's, by exact name, else by the one name that
    /// differs only in case. Two such names, or a dashboard not read here,
    /// give none.
    func testTheFaceDirectoryLooksUpEachDashboardsBotsByName() throws {
        let directory = BotFaceDirectory()
        let here = try starterRoster([starterRow("default", isDefault: true), starterRow("Atlas", created: 1)])
        directory.update(here)
        XCTAssertEqual(directory.look(for: "default")?.face, StarterFaces.face(0))
        XCTAssertEqual(directory.look(for: "atlas")?.face, StarterFaces.face(1), "one case variant folds")

        let twins = try starterRoster([starterRow("atlas", created: 1), starterRow("Atlas", created: 2)])
        directory.update(twins)
        XCTAssertEqual(directory.look(for: "Atlas")?.face, StarterFaces.face(1), "an exact name wins")
        XCTAssertNil(directory.look(for: "ATLAS"), "two case variants give none")

        let far = UUID()
        let there = try starterRoster([starterRow("default", face: 5, isDefault: true)])
        directory.updateOthers([far: there])
        XCTAssertEqual(directory.look(for: "default", on: far)?.face, StarterFaces.face(5))
        XCTAssertEqual(directory.look(for: "default", on: far)?.color, StarterFaces.face(5).hex)
        XCTAssertNil(directory.look(for: "default", on: UUID()), "a dashboard not read here has none")

        directory.updateOthers([:])
        XCTAssertNil(directory.look(for: "default", on: far), "a dashboard that left the group is dropped")
    }
}
