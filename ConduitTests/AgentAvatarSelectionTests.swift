import XCTest
import UIKit
@testable import Conduit

final class AgentAvatarSelectionTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "AvatarSelectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testChoicesPersistIndependentlyForEachProfile() throws {
        try withDefaults { defaults in
            let research = AgentAvatarSelection(character: .init(shape: .bean, color: .blue, accessory: .hat))
            let ops = AgentAvatarSelection(character: nil, usesPhoto: true, photoRevision: UUID())
            try AgentAvatarSelectionStore.save(research, for: "research", defaults: defaults)
            try AgentAvatarSelectionStore.save(ops, for: "ops", defaults: defaults)
            XCTAssertEqual(AgentAvatarSelectionStore.load(for: "research", defaults: defaults), research)
            XCTAssertEqual(AgentAvatarSelectionStore.load(for: "ops", defaults: defaults), ops)
            XCTAssertNil(AgentAvatarSelectionStore.load(for: "new", defaults: defaults))
        }
    }

    func testResetUsesGeneratedCharacterWithoutDeletingOtherProfiles() throws {
        try withDefaults { defaults in
            try AgentAvatarSelectionStore.save(.init(character: nil, usesPhoto: true), for: "research", defaults: defaults)
            let other = AgentAvatarSelection(character: nil, usesPhoto: true)
            try AgentAvatarSelectionStore.save(other, for: "ops", defaults: defaults)
            let reset = AgentAvatarSelection(character: nil, usesPhoto: false)
            try AgentAvatarSelectionStore.save(reset, for: "research", defaults: defaults)
            let restored = try XCTUnwrap(AgentAvatarSelectionStore.load(for: "research", defaults: defaults))
            XCTAssertNil(restored.character)
            XCTAssertFalse(restored.usesPhoto)
            XCTAssertEqual(AgentAvatarSelectionStore.load(for: "ops", defaults: defaults), other)
        }
    }

    func testUnsupportedEntryDoesNotEraseKnownProfiles() throws {
        try withDefaults { defaults in
            let good = AgentAvatarSelection(character: .init(shape: .petal, color: .rose, accessory: .none))
            let entries = ["future": Data("{\"character\":\"future-format\"}".utf8), "good": try JSONEncoder().encode(good)]
            defaults.set(try JSONEncoder().encode(entries), forKey: AgentAvatarSelectionStore.key)
            XCTAssertEqual(AgentAvatarSelectionStore.load(for: "good", defaults: defaults), good)
            XCTAssertNil(AgentAvatarSelectionStore.load(for: "future", defaults: defaults))
            try AgentAvatarSelectionStore.save(.init(character: nil), for: "new", defaults: defaults)
            let saved = try JSONDecoder().decode([String: Data].self, from: XCTUnwrap(defaults.data(forKey: AgentAvatarSelectionStore.key)))
            XCTAssertEqual(saved["future"], entries["future"])
        }
    }

    func testEditingADraftDoesNotChangeSavedSelection() throws {
        try withDefaults { defaults in
            let original = AgentAvatarSelection(character: .generated(for: "research"))
            try AgentAvatarSelectionStore.save(original, for: "research", defaults: defaults)
            var draft = original
            draft.character?.color = .orange
            draft.usesPhoto = true
            XCTAssertEqual(AgentAvatarSelectionStore.load(for: "research", defaults: defaults), original)
        }
    }
    @MainActor
    func testReplacingPhotoAtSameURLRefreshesDecodedImage() throws {
        let profile = "avatar-test-\(UUID())"
        let app = AppState(loadSavedConnection: false)
        defer {
            if let url = app.profileAvatarURL(for: profile) { AgentAvatarImageCache.shared.invalidate(url: url) }
            app.removeProfileAvatar(for: profile)
        }
        func photo(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            }
            return try XCTUnwrap(image.pngData())
        }
        try app.saveProfileAvatar(photo(.red), for: profile)
        let url = try XCTUnwrap(app.profileAvatarURL(for: profile))
        let before = try XCTUnwrap(AgentAvatarImageCache.shared.image(at: url)?.pngData())
        try app.saveProfileAvatar(photo(.blue), for: profile)
        XCTAssertEqual(app.profileAvatarURL(for: profile), url)
        let after = try XCTUnwrap(AgentAvatarImageCache.shared.image(at: url)?.pngData())
        XCTAssertNotEqual(before, after)
    }

}
