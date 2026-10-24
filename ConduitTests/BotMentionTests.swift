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

    /// Quoted lines (#385) are someone else's words: only a bot the user
    /// names in their own lines is a mention, and the note covers just that
    /// bot while the whole text, quote included, is sent.
    func testMiddlewareIgnoresBotsNamedOnlyInQuotedLines() {
        let researcher = bot("researcher")
        let roster = [researcher, bot("writer")]
        XCTAssertNil(BotMentions.middlewareAnnotation(
            text: "> Ask @writer for a draft\r\n\r\nSounds good",
            roster: roster,
            activeProfileName: "default"
        ))
        let text = "> Ask @writer for a draft\n\n@researcher check this first"
        XCTAssertEqual(
            BotMentions.middlewareAnnotation(text: text, roster: roster, activeProfileName: "default"),
            BotMentions.annotated(text: text, mentions: [researcher])
        )
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
        XCTAssertEqual(
            BotMentions.foreverChatRerouteText(for: "/clear", isCanonicalBotChat: true),
            "/compact",
            "/clear starts a new chat too, so a bot's forever chat compacts instead"
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

    // MARK: - Teammate messages

    func testATeammateDeliveryIsReadFromItsSignature() {
        XCTAssertEqual(
            BotTeammateMessages.inbound("Message from 🤖 Atlas (@atlas): Found three flights.\nThe cheapest is Tuesday."),
            BotTeammateMessages.Inbound(sender: "Atlas", handle: "atlas", body: "Found three flights.\nThe cheapest is Tuesday.")
        )
        XCTAssertEqual(BotTeammateMessages.inbound("Message from 🤖 Atlas: hi")?.handle, "Atlas")
        XCTAssertEqual(BotTeammateMessages.inbound("Message from 🤖 Atlas (@Atlas): hi")?.body, "hi", "a capitalised handle still signs")
        XCTAssertEqual(BotTeammateMessages.inbound("Message from Scout (@scout@laptop): yo")?.handle, "scout")
        XCTAssertEqual(
            BotTeammateMessages.inbound("[Message from agent 'scout'] hello"),
            BotTeammateMessages.Inbound(sender: "scout", handle: "scout", body: "hello")
        )
    }

    func testAnUnsignedMessageFromStaysTheUsersText() {
        XCTAssertNil(BotTeammateMessages.inbound("Message from Mom: call me back"), "no bot signature")
        XCTAssertNil(BotTeammateMessages.inbound("Can you pass a message from 🤖 Atlas: on?"))
        XCTAssertNil(BotTeammateMessages.inbound("hello"))
    }

    func testDeliveriesNameTheirTeammate() {
        XCTAssertEqual(
            BotTeammateMessages.deliveryTarget(toolName: "message_agent", input: #"{"target":"@Scout@laptop","message":"hi"}"#),
            "scout"
        )
        XCTAssertEqual(
            BotTeammateMessages.deliveryTarget(
                toolName: "terminal",
                input: #"{"command":"hermes -p scout chat --in ~ -c \"Bot Chat\" -Q -q \"Message from 🤖 atlas (@atlas): hi\""}"#
            ),
            "scout"
        )
        XCTAssertEqual(
            BotTeammateMessages.deliveryTarget(toolName: "terminal", input: #"hermes --profile=scout chat -q 'Message from Atlas: hi'"#),
            "scout"
        )
        XCTAssertEqual(
            BotTeammateMessages.deliveryTarget(toolName: "terminal", input: #"hermes -p 'scout' chat -q "Message from Atlas: hi""#),
            "scout"
        )
        XCTAssertNil(BotTeammateMessages.deliveryTarget(toolName: "terminal", input: #"{"command":"ls -la"}"#))
        XCTAssertNil(BotTeammateMessages.deliveryTarget(toolName: "message_agent", input: #"{"message":"hi"}"#))
        XCTAssertNil(BotTeammateMessages.deliveryTarget(toolName: "web_search", input: #"{"target":"scout"}"#))
    }

    func testATeammateIsNamedFromTheRoster() {
        let roster = [bot("scout", title: "Trip Scout"), bot("atlas")]
        XCTAssertEqual(BotTeammateMessages.bot(named: "@Scout", in: roster)?.name, "scout")
        XCTAssertEqual(BotTeammateMessages.bot(named: "trip-scout", in: roster)?.name, "scout")
        XCTAssertEqual(BotTeammateMessages.bot(named: "Trip Scout", in: roster)?.name, "scout", "a signature without a handle names the title")
        XCTAssertEqual(BotTeammateMessages.displayName(for: "scout", in: roster), "Trip Scout")
        XCTAssertEqual(BotTeammateMessages.displayName(for: "nova", in: roster), "nova", "a bot not in the roster keeps its key")
    }

    func testAMenuMentionIsSpacedOffTheDraft() {
        let scout = MentionAutocomplete.Candidate(tag: "scout", title: "Scout")
        XCTAssertEqual(MentionAutocomplete.inserting("", with: scout), "@scout ")
        XCTAssertEqual(MentionAutocomplete.inserting("ask", with: scout), "ask @scout ")
        XCTAssertEqual(MentionAutocomplete.inserting("ask ", with: scout), "ask @scout ")
        XCTAssertEqual(MentionAutocomplete.inserting("ask @sc", with: scout), "ask @scout ", "a typed @query is completed")
    }
}
