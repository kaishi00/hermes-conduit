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

    // MARK: - Create options

    func testCreateParamsCloneTheMainProfileAndShareKeysByDefault() {
        let params = BotCreateRequest.params(slug: "scout", description: "Deals", soul: "# Scout", draft: BotEditorDraft())
        XCTAssertEqual(params["name"] as? String, "scout")
        XCTAssertEqual(params["clone_from"] as? String, "default", "Desktop copies the main profile's settings")
        XCTAssertEqual(params["share_auth"] as? Bool, true)
        XCTAssertEqual(params["no_skills"] as? Bool, false)
        XCTAssertNil(params["model"], "no pick inherits the main profile's model")
        XCTAssertNil(params["provider"])
    }

    func testCreateParamsCarryAFreshStartAndAModelPin() {
        var draft = BotEditorDraft()
        draft.cloneFrom = ""
        draft.shareAuth = false
        draft.noSkills = true
        draft.provider = "openrouter"
        draft.model = " anthropic/claude-sonnet "
        let params = BotCreateRequest.params(slug: "scout", description: "", soul: "", draft: draft)
        XCTAssertNil(params["clone_from"], "omitted = a fresh profile with the bundled skills")
        XCTAssertEqual(params["share_auth"] as? Bool, false)
        XCTAssertEqual(params["no_skills"] as? Bool, true)
        XCTAssertEqual(params["provider"] as? String, "openrouter")
        XCTAssertEqual(params["model"] as? String, "anthropic/claude-sonnet")

        draft.provider = ""
        let half = BotCreateRequest.params(slug: "scout", description: "", soul: "", draft: draft)
        XCTAssertNil(half["model"], "the gateway pins only a provider and a model together")
    }

    func testCreateReportsAModelPinOnlyTheGatewayRefused() {
        let pinned: [String: Any] = ["name": "scout", "provider": "openrouter", "model": "anthropic/claude-sonnet"]
        XCTAssertFalse(BotCreateRequest.modelPinned(pinned, result: .object(["ok": .bool(true), "model_set": .bool(false)])))
        XCTAssertTrue(BotCreateRequest.modelPinned(pinned, result: .object(["ok": .bool(true), "model_set": .bool(true)])))
        XCTAssertTrue(BotCreateRequest.modelPinned(pinned, result: .object(["ok": .bool(true)])), "an older gateway omits the key")
        XCTAssertTrue(
            BotCreateRequest.modelPinned(["name": "scout"], result: .object(["model_set": .bool(false)])),
            "no pick asked for, so nothing failed"
        )
    }

    func testRuntimeCheckNeedsModelOnlyOnAnExplicitRefusal() {
        XCTAssertTrue(BotRuntimeCheck.needsModel(.object(["ok": .bool(false), "error": .string("No usable credentials")])))
        XCTAssertFalse(BotRuntimeCheck.needsModel(.object(["ok": .bool(true)])))
        XCTAssertFalse(BotRuntimeCheck.needsModel(nil), "an older gateway without the check goes ahead")
        XCTAssertFalse(BotRuntimeCheck.needsModel(.object([:])))
    }

    func testModelConfirmationReadsTheGatewaysGuardMessage() {
        XCTAssertEqual(
            BotModelConfirmation.message(in: .object([
                "ok": .bool(true),
                "applied": .object([:]),
                "confirm_required": .bool(true),
                "confirm_message": .string("This model costs $15 per million tokens.")
            ])),
            "This model costs $15 per million tokens."
        )
        XCTAssertEqual(
            BotModelConfirmation.message(in: .object([
                "confirm_required": .bool(true),
                "warning": .string("This model may train on your data.")
            ])),
            "This model may train on your data.",
            "older gateways name the text `warning`"
        )
        XCTAssertNotNil(BotModelConfirmation.message(in: .object(["confirm_required": .bool(true)])))
        XCTAssertNil(BotModelConfirmation.message(in: .object(["ok": .bool(true), "applied": .object(["model": .bool(true)])])))
    }

    // MARK: - Skills, tools and MCP

    func testCapabilitiesDecodeTheDescribeLists() {
        let caps = BotCapabilities(describe: [
            "skills": .array([
                .object(["name": .string("web-search"), "enabled": .bool(true)]),
                .object(["name": .string("arxiv"), "enabled": .bool(false)])
            ]),
            "toolsets": .array([
                .object(["name": .string("terminal"), "label": .string("Terminal"), "description": .string("Shell"),
                         "tool_count": .number(3), "enabled": .bool(true)])
            ]),
            "mcp_servers": .array([.object(["name": .string("github"), "transport": .string("http")])])
        ])
        XCTAssertEqual(caps.skills.map(\.name), ["arxiv", "web-search"], "skills list alphabetically")
        XCTAssertEqual(caps.toolsets.first?.label, "Terminal")
        XCTAssertEqual(caps.toolsets.first?.toolCount, 3)
        XCTAssertEqual(caps.mcpServers.first?.enabled, true, "an MCP entry without the flag is on")
    }

    func testCapabilityParamsWriteOnlyChangedSections() {
        let original = BotCapabilities(
            skills: [BotCapability(name: "a", enabled: true), BotCapability(name: "b", enabled: true)],
            toolsets: [BotCapability(name: "web", enabled: true), BotCapability(name: "terminal", enabled: true)],
            mcpServers: [BotCapability(name: "github", enabled: false)]
        )
        XCTAssertTrue(BotCapabilities.configureParams(original: original, edited: original).isEmpty)

        var edited = original
        edited.skills[1].enabled = false
        let skillsOnly = BotCapabilities.configureParams(original: original, edited: edited)
        XCTAssertEqual(skillsOnly["disabled_skills"] as? [String], ["b"])
        XCTAssertNil(skillsOnly["enabled_toolsets"])
        XCTAssertNil(skillsOnly["enabled_mcp_servers"])
        XCTAssertEqual(BotCapabilities.appliedSections(for: skillsOnly), ["skills"])

        edited.toolsets[1].enabled = false
        edited.mcpServers[0].enabled = true
        let all = BotCapabilities.configureParams(original: original, edited: edited)
        XCTAssertEqual(all["enabled_toolsets"] as? [String], ["web"])
        XCTAssertEqual(all["enabled_mcp_servers"] as? [String], ["github"])
        XCTAssertEqual(BotCapabilities.appliedSections(for: all), ["skills", "toolsets", "mcp_servers"])

        var pinned = original
        pinned.toolsets[1].enabled = false
        var everyToolBack = pinned
        everyToolBack.toolsets[1].enabled = true
        XCTAssertEqual(
            BotCapabilities.configureParams(original: pinned, edited: everyToolBack)["enabled_toolsets"] as? [String],
            [],
            "every tool on clears the pin"
        )
    }

    func testTheLastToolOnCannotBeTurnedOff() {
        var capabilities = BotCapabilities(
            skills: [],
            toolsets: [BotCapability(name: "web", enabled: true), BotCapability(name: "terminal", enabled: true)],
            mcpServers: []
        )
        XCTAssertTrue(capabilities.canTurnOffToolset(at: 0))
        capabilities.toolsets[1].enabled = false
        XCTAssertFalse(capabilities.canTurnOffToolset(at: 0), "no tools on would save as Hermes' defaults")
        XCTAssertTrue(capabilities.canTurnOffToolset(at: 1), "an off tool can always be turned back on")
    }

    func testEveryMCPServerOffSendsAnEmptyList() {
        let original = BotCapabilities(mcpServers: [BotCapability(name: "github", enabled: true)])
        var edited = original
        edited.mcpServers[0].enabled = false
        XCTAssertEqual(
            BotCapabilities.configureParams(original: original, edited: edited)["enabled_mcp_servers"] as? [String],
            [],
            "the gateway turns off every server not listed"
        )
    }

    // MARK: - Generated pictures

    func testPictureGenerationProbeNeedsAnExplicitYes() {
        XCTAssertTrue(PictureGeneration.isAvailable(probe: .object(["available": .bool(true)])))
        XCTAssertFalse(PictureGeneration.isAvailable(probe: .object(["available": .bool(false)])))
        XCTAssertFalse(PictureGeneration.isAvailable(probe: nil), "an older gateway without image.generate")
        XCTAssertEqual(PictureGeneration.params(prompt: "x")["aspect_ratio"] as? String, "square")
    }

    func testPictureGenerationPromptsFollowDesktop() {
        XCTAssertEqual(
            PictureGeneration.botPrompt(name: "Scout", description: "Finds deals"),
            "Cute minimal robot avatar for an AI agent named \"Scout — Finds deals\". "
                + "Friendly simple mascot face, bold flat vector style, solid color background, centered, no text."
        )
        XCTAssertTrue(PictureGeneration.botPrompt(name: " ", description: "").contains("named \"agent\""))
        XCTAssertNil(PictureGeneration.customPrompt("  ", forGroup: false), "an empty description uses the default prompt")
        XCTAssertEqual(
            PictureGeneration.customPrompt("A fox", forGroup: false),
            "A fox. Avatar for an AI agent: centered, bold flat vector style, solid color background, no text."
        )
        XCTAssertTrue(PictureGeneration.groupPrompt(name: "Trip", members: ["Atlas", "Scout"]).contains("named \"Trip\" (Atlas, Scout)"))
    }

    func testPictureGenerationOutcomePrefersTheInlineImage() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let dataURL = "data:image/png;base64," + png.base64EncodedString()
        XCTAssertEqual(
            PictureGeneration.outcome(of: .object([
                "success": .bool(true), "image_data": .string(dataURL), "image": .string("https://cdn.example/a.png")
            ])),
            .image(png)
        )
        XCTAssertEqual(
            PictureGeneration.outcome(of: .object(["success": .bool(true), "image": .string("https://cdn.example/a.png")])),
            .remote(try XCTUnwrap(URL(string: "https://cdn.example/a.png")))
        )
        XCTAssertEqual(
            PictureGeneration.outcome(of: .object(["success": .bool(true), "image": .string("/home/me/.hermes/cache/a.png")])),
            .failed(nil),
            "a path on the Hermes machine can't be read from the phone"
        )
        XCTAssertEqual(
            PictureGeneration.outcome(of: .object(["success": .bool(false), "error": .string("No image backend")])),
            .failed("No image backend")
        )
        XCTAssertNil(PictureGeneration.imageData(fromDataURL: "data:text/plain;base64,aGk="))
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
