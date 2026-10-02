import XCTest
import UIKit
@testable import Conduit

/// Bot management (create / edit / delete / avatars). An extension rather
/// than its own class: the hosted CI planner balances shards per class.
extension BotModeTests {
    // MARK: - Profile id

    func testSlugMatchesDesktopForAsciiAccentedAndCJKNames() {
        XCTAssertEqual(BotProfileSlug.slug(from: "Ada Lovelace"), "ada-lovelace")
        XCTAssertEqual(BotProfileSlug.slug(from: "  --Hi!! there__ "), "hi-there__")
        XCTAssertEqual(BotProfileSlug.slug(from: "Résumé"), "resume")
        XCTAssertEqual(BotProfileSlug.slug(from: "小助手"), "u5c0f-u52a9-u624b")
        XCTAssertEqual(BotProfileSlug.slug(from: "!!!"), "")
    }

    func testSlugCutsLongNamesAtATokenBoundary() {
        let name = String(repeating: "abcdefghi ", count: 10)
        let slug = BotProfileSlug.slug(from: name)
        XCTAssertLessThanOrEqual(slug.count, BotProfileSlug.maxLength)
        XCTAssertFalse(slug.hasSuffix("-"))
        XCTAssertTrue(slug.hasSuffix("abcdefghi"), "the cut lands on a dash, never mid-token")
        XCTAssertTrue(BotProfileSlug.isValid(slug))
    }

    func testSlugValidityFollowsTheBackendIdRule() {
        XCTAssertTrue(BotProfileSlug.isValid("atlas"))
        XCTAssertTrue(BotProfileSlug.isValid("9lives_bot-2"))
        XCTAssertFalse(BotProfileSlug.isValid(""))
        XCTAssertFalse(BotProfileSlug.isValid("_atlas"))
        XCTAssertFalse(BotProfileSlug.isValid("-atlas"))
        XCTAssertFalse(BotProfileSlug.isValid("Atlas"))
        XCTAssertFalse(BotProfileSlug.isValid(String(repeating: "a", count: 65)))
    }

    func testTitleIsKeptOnlyWhenTheNameDiffersFromItsId() {
        XCTAssertEqual(BotProfileSlug.title(forName: "atlas"), "")
        XCTAssertEqual(BotProfileSlug.title(forName: " Ada Lovelace "), "Ada Lovelace")
    }

    // MARK: - Colors

    func testColorParsesDesktopSwatchesAndHex() throws {
        let red = try XCTUnwrap(BotAvatarColor.rgb(from: "hsl(0 68% 58%)"))
        XCTAssertEqual(red.red, 0.8656, accuracy: 0.001)
        XCTAssertEqual(red.green, 0.2944, accuracy: 0.001)
        XCTAssertEqual(red.blue, 0.2944, accuracy: 0.001)

        let commas = try XCTUnwrap(BotAvatarColor.rgb(from: "hsl(0deg, 68%, 58%)"))
        XCTAssertEqual(commas, red)

        let violet = try XCTUnwrap(BotAvatarColor.rgb(from: "#8b5cf6"))
        XCTAssertEqual(violet.red, 139.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(violet.blue, 246.0 / 255, accuracy: 0.0001)

        XCTAssertNil(BotAvatarColor.rgb(from: "teal"), "named colors are the view's concern")
        XCTAssertEqual(BotAvatarColor.swatches.count, 12)
        XCTAssertEqual(BotAvatarColor.swatches.first, "hsl(0 68% 58%)")
    }

    func testFallbackHueMatchesDesktopsProfileColor() {
        // JS: h = (h * 31 + charCode) >>> 0 over "atlas" = 93144203; 93144203 % 360 = 323.
        let atlas = BotAvatarColor.fallbackRGB(for: "atlas")
        let expected = BotAvatarColor.hslToRGB(hue: 323, saturation: 0.68, lightness: 0.58)
        XCTAssertEqual(atlas, expected)
        XCTAssertEqual(atlas.red, 0.8656, accuracy: 0.001)
        XCTAssertEqual(atlas.blue, 0.6466, accuracy: 0.001)

        XCTAssertEqual(BotAvatarColor.fallbackRGB(for: "default"), BotAvatarColor.rgb(from: "#8b5cf6"))
    }

    // MARK: - ui_meta

    func testMetaPatchKeepsOtherClientsFieldsAndDropsDataURLs() {
        let existing: [String: AnyCodable] = [
            "title": .string("Scout"),
            "shape": .string("blob:abc:round"),
            "sectionId": .string("s1"),
            "groups": .array([.string("ops")]),
            "image": .string("data:image/png;base64,AAAA"),
            "chat": .string("legacy")
        ]
        var patch: [String: Any?] = ["color": "hsl(30 68% 58%)", "pinned": true]
        patch.updateValue(nil, forKey: "title")

        let merged = BotMetaPatch.merged(existing: existing, patch: patch)

        XCTAssertNil(merged["title"], "a nil patch value deletes the field")
        XCTAssertEqual(merged["color"] as? String, "hsl(30 68% 58%)")
        XCTAssertEqual(merged["pinned"] as? Bool, true)
        XCTAssertEqual(merged["shape"] as? String, "blob:abc:round")
        XCTAssertEqual(merged["sectionId"] as? String, "s1")
        XCTAssertEqual(merged["groups"] as? [String], ["ops"])
        XCTAssertNil(merged["image"], "pictures travel through the asset store, never ui_meta")
        XCTAssertNil(merged["chat"])
    }

    func testMetaWriteOutcomeReadsTheAppliedContract() {
        XCTAssertEqual(
            BotMetaWriteOutcome(configureResult: .object(["applied": .object(["ui_meta": .bool(true)])])),
            .persisted
        )
        XCTAssertEqual(
            BotMetaWriteOutcome(configureResult: .object(["applied": .object([
                "ui_meta": .bool(false),
                "ui_meta_conflicts": .object(["hermes-bots": .object(["expected": .number(1), "actual": .number(2)])])
            ])])),
            .conflict
        )
        XCTAssertEqual(
            BotMetaWriteOutcome(configureResult: .object(["applied": .object(["ui_meta": .bool(false)])])),
            .failed
        )
        XCTAssertEqual(BotMetaWriteOutcome(configureResult: .object(["ok": .bool(true)])), .unsupported)
        XCTAssertEqual(
            BotConfigureSections.failed(
                in: .object(["applied": .object(["soul": .bool(false), "description": .bool(true)])]),
                among: ["description", "soul"]
            ),
            ["soul"]
        )
    }

    func testRosterDecoderKeepsRawMetaRevisionAndDefaultFlag() throws {
        let payload: AnyCodable = .object([
            "profiles": .array([
                .object([
                    "name": .string("default"),
                    "is_default": .bool(true),
                    "ui_meta_revisions": .object([:])
                ]),
                .object([
                    "name": .string("atlas"),
                    "ui_meta_revisions": .object(["hermes-bots": .number(4)]),
                    "ui_meta": .object(["hermes-bots": .object([
                        "title": .string("Scout"),
                        "sectionId": .string("s1")
                    ])])
                ]),
                .object(["name": .string("legacy")])
            ])
        ])

        let bots = try XCTUnwrap(BotRosterDecoder.decode(payload)).bots

        XCTAssertTrue(bots[0].isDefault)
        XCTAssertFalse(bots[0].isDeletable)
        XCTAssertEqual(bots[0].botMetaRevision, 0, "an empty revisions object means CAS at revision 0")
        XCTAssertEqual(bots[1].botMetaRevision, 4)
        XCTAssertEqual(bots[1].botMeta["sectionId"], .string("s1"))
        XCTAssertTrue(bots[1].isDeletable)
        XCTAssertNil(bots[2].botMetaRevision, "no revisions object: a gateway without ui_meta CAS")
    }

    // MARK: - SOUL

    func testComposedSoulIsIdentityOnlyWhenTheBackendInjectsTheProtocol() {
        let soul = BotSoul.compose(
            name: "ada-lovelace",
            title: "Ada Lovelace",
            description: "Math tutor",
            customSoul: "",
            serverInjectsProtocol: true,
            roster: []
        )
        XCTAssertTrue(soul.hasPrefix("# Ada Lovelace"))
        XCTAssertTrue(soul.contains("**Mission:** Math tutor"))
        XCTAssertTrue(soul.contains("(profile `ada-lovelace`)"))
        XCTAssertFalse(soul.contains(BotSoul.protocolHeading))
    }

    func testComposedSoulAppendsTheProtocolForOlderBackends() {
        let teammate = BotProfile(
            name: "atlas", botTitle: nil, displayName: "", profileDescription: "Research",
            model: nil, provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false,
            appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil
        )
        let hidden = BotProfile(
            name: "ops-internal", botTitle: nil, displayName: "", profileDescription: "",
            model: nil, provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: true,
            appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil
        )
        let custom = BotSoul.compose(
            name: "nova", title: "", description: "", customSoul: "You are Nova.",
            serverInjectsProtocol: false, roster: [teammate, hidden]
        )
        XCTAssertFalse(custom.contains("ops-internal"), "meta-hidden bots are not listed as teammates")
        XCTAssertTrue(custom.hasPrefix("You are Nova."))
        XCTAssertTrue(custom.contains(BotSoul.protocolHeading))
        XCTAssertTrue(custom.contains("- `atlas` — Research"))
        XCTAssertTrue(custom.contains("Message from 🤖 nova (@nova)"))

        let alreadyHasIt = "Me.\n\n" + BotSoul.protocolHeading + "\n..."
        XCTAssertEqual(
            BotSoul.compose(name: "nova", title: "", description: "", customSoul: alreadyHasIt,
                            serverInjectsProtocol: false, roster: []),
            alreadyHasIt
        )
    }

    // MARK: - Avatar images

    func testGetAssetResultDecodesTheDataURL() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let found: AnyCodable = .object([
            "found": .bool(true),
            "mime": .string("image/png"),
            "data": .string(BotAvatarImage.dataURL(png: png))
        ])
        XCTAssertEqual(BotAvatarImage.imageData(fromGetAssetResult: found), png)
        XCTAssertNil(BotAvatarImage.imageData(fromGetAssetResult: .object(["found": .bool(false)])))
    }

    func testNormalizedAvatarIsASquare256PNG() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 120))
        let wide = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 120))
        }

        let png = try XCTUnwrap(BotAvatarImage.normalizedPNG(from: wide))
        let decoded = try XCTUnwrap(UIImage(data: png))

        XCTAssertEqual(decoded.size.width * decoded.scale, 256)
        XCTAssertEqual(decoded.size.height * decoded.scale, 256)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
