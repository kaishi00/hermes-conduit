import XCTest

@testable import Conduit

/// Bot @mention resolution and annotation — the ported upstream composer
/// middleware contract (`plugin.tsx` `mention-middleware` /
/// `data.ts` `resolveRosterMentions`, pinned upstream SHA fdec926e).
final class BotMentionTests: XCTestCase {
    private func bot(
        _ name: String,
        title: String? = nil,
        displayName: String = "",
        previousNames: [String] = []
    ) -> BotProfile {
        var profile = BotProfile(
            name: name,
            botTitle: title,
            displayName: displayName,
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: false,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: nil,
            lastActive: nil,
            lastPreview: nil
        )
        profile.previousNames = previousNames
        return profile
    }

    private func names(_ text: String, roster: [BotProfile], active: String? = "default") -> [String] {
        BotMentions.resolve(text: text, roster: roster, activeProfileName: active)
            .map(\.name)
    }

    // MARK: - Resolution

    func testExactProfileHandleResolves() {
        let roster = [bot("researcher"), bot("writer")]
        XCTAssertEqual(names("@researcher have a look", roster: roster), ["researcher"])
    }

    func testFriendlySlugAndCollapsedFormsResolve() {
        let roster = [bot("Researcher", title: "Research Buddy")]
        XCTAssertEqual(names("@research-buddy please", roster: roster), ["Researcher"])
        XCTAssertEqual(names("@researchbuddy please", roster: roster), ["Researcher"])
    }

    func testProfileDisplayNameIsTaggable() {
        let roster = [bot("atlas", displayName: "Atlas Prime")]
        XCTAssertEqual(names("@atlas-prime go", roster: roster), ["atlas"])
    }

    func testPrimaryProfileAnswersToHermes() {
        let roster = [bot("default"), bot("researcher")]
        // Upstream excludes the FOCUSED conversation's profile from mention
        // resolution — in a default-profile chat the primary bot IS the
        // listener, so @hermes annotates only when focused elsewhere.
        XCTAssertEqual(names("@hermes do the thing", roster: roster, active: "researcher"), ["default"])
        XCTAssertEqual(names("@hermes do the thing", roster: roster, active: nil), ["default"])
        XCTAssertEqual(names("@hermes do the thing", roster: roster, active: "default"), [])
    }

    func testUnknownTokenStaysUnresolved() {
        let roster = [bot("researcher")]
        XCTAssertEqual(names("@nobody here", roster: roster), [])
    }

    func testEmailAddressNeverResolves() {
        let roster = [bot("example", title: "Example")]
        // The @ in user@example.com follows a letter — the leading-boundary
        // guard keeps e-mail addresses ordinary text.
        XCTAssertEqual(names("contact user@example.com today", roster: roster), [])
    }

    func testMentionInsideCodeFenceIsContent() {
        let roster = [bot("researcher")]
        XCTAssertEqual(names("```\n@researcher\n```", roster: roster), [])
        XCTAssertEqual(names("ping `@researcher` done", roster: roster), [])
    }

    func testAmbiguousFriendlyFormResolvesForNeitherBot() {
        // Two bots whose titles reduce to the same slug: the ambiguous form
        // fails closed (no annotation, no guess), while each bot's unique
        // profile handle still resolves.
        let roster = [bot("alpha", title: "Reviewer"), bot("beta", title: "Reviewer")]
        XCTAssertEqual(names("@reviewer check this", roster: roster), [])
        XCTAssertEqual(names("@alpha check this", roster: roster), ["alpha"])
        XCTAssertEqual(names("@beta check this", roster: roster), ["beta"])
    }

    func testMultipleMentionsResolveInTagOrder() {
        let roster = [bot("researcher"), bot("writer")]
        XCTAssertEqual(
            names("@writer then @researcher review", roster: roster),
            ["writer", "researcher"]
        )
    }

    func testDuplicateTagYieldsOneMention() {
        let roster = [bot("researcher")]
        XCTAssertEqual(
            names("@researcher and @researcher again", roster: roster),
            ["researcher"]
        )
    }

    func testActiveConversationBotIsNeverAMentionTarget() {
        let roster = [bot("researcher")]
        // Inside researcher's own Bot Chat, @researcher is the listener.
        XCTAssertEqual(names("@researcher yourself", roster: roster, active: "researcher"), [])
        XCTAssertEqual(names("@researcher yourself", roster: roster, active: "default"), ["researcher"])
    }

    func testPreviousNameResolvesWhenLiveNameDoesNotClaimIt() {
        let roster = [
            bot("researcher", previousNames: ["scout"]),
            bot("writer"),
        ]
        XCTAssertEqual(names("@scout where were you", roster: roster), ["researcher"])
    }

    func testLiveNameOutranksAnotherBotsRenameHistory() {
        // beta was once named "shared"; alpha OWNS the live name now.
        let roster = [
            bot("alpha"),
            bot("beta", previousNames: ["alpha"]),
        ]
        XCTAssertEqual(names("@alpha hello", roster: roster), ["alpha"])
    }

    func testListenersLiveNameNeverFallsThroughToRenameHistory() {
        // Inside alpha's Bot Chat, @alpha is the listener: beta's old name
        // must not turn it into a handoff to beta.
        let roster = [
            bot("alpha"),
            bot("beta", previousNames: ["alpha"]),
        ]
        XCTAssertEqual(names("@alpha hello", roster: roster, active: "alpha"), [])
    }

    func testSharedPreviousNameResolvesForNeitherBot() {
        let roster = [
            bot("researcher", previousNames: ["scout"]),
            bot("writer", previousNames: ["scout"]),
        ]
        XCTAssertEqual(names("@scout where were you", roster: roster), [])
    }

    func testConnectionQualifiedTagStaysPlainInSingleGatewayRoster() {
        let roster = [bot("researcher")]
        XCTAssertEqual(names("@researcher@remote go", roster: roster), [])
    }

    // MARK: - Annotation

    func testAnnotationAppendsUpstreamIdentificationNote() {
        let roster = [
            bot("default"),
            bot("researcher", title: "Research Buddy"),
        ]
        let annotated = BotMentions.annotated(
            text: "have a look @researcher",
            mentions: BotMentions.resolve(
                text: "have a look @researcher",
                roster: roster,
                activeProfileName: "default"
            )
        )
        XCTAssertTrue(annotated.hasPrefix("have a look @researcher"))
        XCTAssertTrue(annotated.contains(
            "@researcher = agent profile \"researcher\" (\"Research Buddy\")"
        ))
        XCTAssertTrue(annotated.contains(
            "[@mentions resolved from the Bot Mode roster — the user is referring to: "
        ))
        XCTAssertTrue(annotated.contains("never forward the user’s text verbatim"))
        XCTAssertTrue(annotated.hasSuffix(
            "If this session has no message_agent tool, agent messaging is unavailable here — say so.]"
        ))
    }

    func testPrimaryAnnotationUsesHermesHandle() {
        let annotated = BotMentions.annotated(
            text: "x",
            mentions: [bot("default")]
        )
        XCTAssertTrue(annotated.contains("@hermes = agent profile \"default\""))
    }

    func testMiddlewareLeavesTextUntouchedWithoutMentions() {
        let roster = [bot("researcher")]
        XCTAssertNil(BotMentions.middlewareAnnotation(
            text: "plain text, user@example.com, `/quoted`",
            roster: roster,
            activeProfileName: "default"
        ))
        // And without a roster (gateway without Bot Mode): untouched.
        XCTAssertNil(BotMentions.middlewareAnnotation(
            text: "@researcher hello",
            roster: [],
            activeProfileName: "default"
        ))
    }

    func testMiddlewareAnnotatesWhenRosterResolves() {
        let roster = [bot("researcher")]
        let result = BotMentions.middlewareAnnotation(
            text: "@researcher hello",
            roster: roster,
            activeProfileName: "default"
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.hasPrefix("@researcher hello"))
    }

    // MARK: - Forever-chat reroute

    func testNewAndResetRerouteToCompactOnlyInCanonicalChat() {
        XCTAssertEqual(
            BotMentions.foreverChatRerouteText(for: "/new", isCanonicalBotChat: true),
            "/compact"
        )
        XCTAssertEqual(
            BotMentions.foreverChatRerouteText(for: "/reset", isCanonicalBotChat: true),
            "/compact"
        )
        XCTAssertNil(BotMentions.foreverChatRerouteText(for: "/new", isCanonicalBotChat: false))
        // Padded forms reroute; anything else keeps slash-command freedom.
        XCTAssertEqual(
            BotMentions.foreverChatRerouteText(for: "  /new  ", isCanonicalBotChat: true),
            "/compact"
        )
        XCTAssertNil(BotMentions.foreverChatRerouteText(for: "/new extra", isCanonicalBotChat: true))
        XCTAssertNil(BotMentions.foreverChatRerouteText(for: "/compact", isCanonicalBotChat: true))
    }

    // MARK: - Tag helpers

    func testMentionTagPrefersFriendlyFormAndHandleFallsBack() {
        XCTAssertEqual(BotMentions.mentionTag(for: bot("a", title: "Research Buddy")), "research-buddy")
        XCTAssertEqual(BotMentions.mentionTag(for: bot("researcher")), "researcher")
        XCTAssertEqual(BotMentions.handle(for: bot("default")), "hermes")
        XCTAssertEqual(BotMentions.handle(for: bot("researcher")), "researcher")
    }

    func testMentionNameFormsRejectReservedTokensAndBadShapes() {
        XCTAssertEqual(BotMentions.mentionNameForms("All"), [])
        XCTAssertEqual(BotMentions.mentionNameForms("Everyone"), [])
        XCTAssertEqual(BotMentions.mentionNameForms("Hermes!"), [])
        XCTAssertEqual(BotMentions.mentionNameForms("   "), [])
        XCTAssertEqual(
            BotMentions.mentionNameForms("Research -- Buddy (v2)"),
            ["research----buddy-v2", "research--buddyv2"]
        )
        XCTAssertEqual(
            BotMentions.mentionNameForms("Research Buddy"),
            ["research-buddy", "researchbuddy"]
        )
    }
}
