import XCTest
@testable import Conduit

@MainActor
final class BotModeTests: XCTestCase {
    // MARK: - profiles.list decoding

    func testRosterDecoderExtractsBotFieldsFromProfilesListPayload() throws {
        let payload: [String: AnyCodable] = [
            "profiles": .array([
                .object([
                    "name": .string("atlas"),
                    "display_name": .string("Atlas"),
                    "description": .string("Research agent"),
                    "model": .string("hermes-4"),
                    "provider": .string("nous"),
                    "is_default": .bool(false),
                    "has_avatar": .bool(true),
                    "ui_meta": .object([
                        "hermes-bots": .object([
                            "title": .string("Scout"),
                            "pinned": .bool(true),
                            "hidden": .bool(false),
                            "color": .string("teal")
                        ])
                    ]),
                    "canonical_session": .object([
                        "id": .string("stored-1"),
                        "resolved_id": .string("runtime-1"),
                        "last_active": .number(1_700_000_000),
                        "preview": .string("Working on it")
                    ]),
                    "last_session": .object([
                        "last_active": .number(1_700_000_500),
                        "preview": .string("Newest human chat")
                    ])
                ])
            ]),
            "bot_mode_protocol": .bool(true)
        ]

        let snapshot = try XCTUnwrap(BotRosterDecoder.decode(.object(payload)))

        XCTAssertTrue(snapshot.supportsBotProtocol)
        XCTAssertEqual(snapshot.bots.count, 1)
        let bot = try XCTUnwrap(snapshot.bots.first)
        XCTAssertEqual(bot.name, "atlas")
        XCTAssertEqual(bot.displayLabel, "Scout", "the customized bot title outranks the profile display name")
        XCTAssertEqual(bot.profileDescription, "Research agent")
        XCTAssertEqual(bot.model, "hermes-4")
        XCTAssertTrue(bot.hasAvatar)
        XCTAssertTrue(bot.isPinned)
        XCTAssertEqual(bot.canonicalSession?.id, "stored-1")
        XCTAssertEqual(bot.canonicalSession?.resolvedID, "runtime-1")
        XCTAssertEqual(bot.canonicalSession?.preview, "Working on it")
        XCTAssertEqual(bot.lastActive, 1_700_000_500)
    }

    func testRosterDecodeFallsBackToDisplayNameAndToleratesMissingCanonical() throws {
        let payload: [String: AnyCodable] = [
            "profiles": .array([
                .object([
                    "name": .string("default"),
                    "display_name": .string("Default Profile")
                ])
            ])
        ]

        let snapshot = try XCTUnwrap(BotRosterDecoder.decode(.object(payload)))

        XCTAssertFalse(snapshot.supportsBotProtocol, "an older gateway omits the protocol flag")
        let bot = try XCTUnwrap(snapshot.bots.first)
        XCTAssertEqual(bot.displayLabel, "Default Profile")
        XCTAssertNil(bot.canonicalSession)
    }

    func testRosterDecodeRejectsNonProfilesEnvelope() {
        XCTAssertNil(BotRosterDecoder.decode(.object(["error": .string("nope")])))
    }

    func testDisplayOrderPinsFirstThenSortsByActivityThenName() {
        let pinned = makeBot(name: "pinned", pinned: true, canonicalLastActive: 10)
        let fresh = makeBot(name: "fresh", canonicalLastActive: 500)
        let older = makeBot(name: "older", canonicalLastActive: 100)
        let plainA = makeBot(name: "aaa", lastActive: 5)
        let plainB = makeBot(name: "bbb", lastActive: 5)

        let ordered = BotProfile.displayOrder([plainB, plainA, older, fresh, pinned])

        XCTAssertEqual(ordered.map(\.name), ["pinned", "fresh", "older", "aaa", "bbb"])
    }

    // MARK: - canonical-chat lookup rows

    func testLookupRowMatchesCanonicalTitleThroughRootTitlePrecedence() {
        XCTAssertTrue(BotChatLookupRow(id: "s1", title: "Bot Chat").isCanonicalTitle())
        XCTAssertTrue(
            BotChatLookupRow(id: "s1", title: "Drifted", rootTitle: "Bot Chat").isCanonicalTitle(),
            "the durable lineage-root title wins over the listing title"
        )
        XCTAssertFalse(BotChatLookupRow(id: "s1", title: "Project planning").isCanonicalTitle())
        XCTAssertFalse(
            BotChatLookupRow(id: "s1", rootTitle: "Project planning").isCanonicalTitle(),
            "a plain-title match must not override a different root title"
        )
    }

    func testLookupRowResumeTargetPrefersResolvedTip() {
        XCTAssertEqual(BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1").resumeTargetID, "runtime-1")
        XCTAssertEqual(BotChatLookupRow(id: "stored-1").resumeTargetID, "stored-1")
        XCTAssertEqual(BotChatLookupRow(id: "stored-1", resolvedID: "  ").resumeTargetID, "stored-1")
    }

    // MARK: - fail-closed resolution

    func testResolverOpensExistingCanonicalChatWithLineageTip() throws {
        let rows = [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]

        let resolution = BotChatResolver.resolve(rows: rows, rosterCanonicalID: "stored-1")

        XCTAssertEqual(
            try resolution.get(),
            .openExisting(registryID: "stored-1", resumeID: "runtime-1")
        )
    }

    func testResolverCreatesOnlyOnConfirmedAbsence() throws {
        let resolution = BotChatResolver.resolve(rows: [], rosterCanonicalID: nil)

        XCTAssertEqual(try resolution.get(), .create)
    }

    func testResolverFailsClosedWhenEmptyLookupContradictsRosterCanonical() {
        // The roster positively confirms this profile HAD a canonical chat;
        // an empty lookup answer is unconfirmed absence (a mid-restart
        // profile backend can answer successfully and empty). Minting here
        // is the forever-chat fork.
        let resolution = BotChatResolver.resolve(rows: [], rosterCanonicalID: "stored-1")

        XCTAssertEqual(resolution, .failure(.unconfirmedAbsence))
    }

    func testResolverFailsClosedWhenLookupFindsOnlyForeignTitles() {
        let rows = [BotChatLookupRow(id: "stored-9", title: "Bot Chatty")]

        let resolution = BotChatResolver.resolve(rows: rows, rosterCanonicalID: "stored-1")

        XCTAssertEqual(resolution, .failure(.unconfirmedAbsence))
    }

    // MARK: - adopt-before-mint classification

    func testTitleCollisionClassifierMatchesGatewayRejection() {
        XCTAssertTrue(BotChatTitleCollision.isError(RpcError(code: 4022, message: "Title 'Bot Chat' is already in use by session x")))
        XCTAssertTrue(BotChatTitleCollision.isError(RpcError(code: 5000, message: "Title 'Bot Chat' is already in use by session x")))
        XCTAssertFalse(BotChatTitleCollision.isError(RpcError(code: 5000, message: "database is locked")))
        XCTAssertFalse(BotChatTitleCollision.isError(RpcError(code: -32601, message: "unknown method")))
    }

    // MARK: - gateway missing-method classification

    func testMissingMethodClassifierCoversProfilesListGap() {
        XCTAssertTrue(HermesClient.isMissingRPCMethod(RpcError(code: -32601, message: "unknown method")))
        XCTAssertTrue(HermesClient.isMissingRPCMethod(RpcError(code: nil, message: "method not found")))
        XCTAssertFalse(HermesClient.isMissingRPCMethod(RpcError(code: 4001, message: "session not found")))
        XCTAssertFalse(HermesClient.isMissingRPCMethod(RpcError(code: 5000, message: "state.db is locked")))
    }

    // MARK: - sessions-list hygiene

    func testHygieneHidesCanonicalRegistryAndTipRows() {
        let bot = makeBot(name: "atlas", canonicalID: "stored-1", resolvedID: "runtime-1")
        let registryRow = makeSessionSummary(id: "stored-1", title: "Bot Chat")
        let tipRow = makeSessionSummary(id: "runtime-1", title: "Bot Chat", storedID: "stored-1")
        let titledStaleRow = makeSessionSummary(id: "stray-1", title: "Bot Chat", profile: "atlas")

        XCTAssertTrue(BotChatHygiene.isCanonicalBotChatRow(registryRow, roster: [bot]))
        XCTAssertTrue(BotChatHygiene.isCanonicalBotChatRow(tipRow, roster: [bot]))
        XCTAssertTrue(BotChatHygiene.isCanonicalBotChatRow(titledStaleRow, roster: [bot]))
    }

    func testHygieneNeverHidesOrdinarySessions() {
        let bot = makeBot(name: "atlas", canonicalID: "stored-1", resolvedID: "runtime-1")
        // A user conversation that merely shares the canonical title on the
        // dashboard profile stays visible: hidden + exact title is the
        // canonical discriminator, the title alone is not.
        let dashboardTitled = makeSessionSummary(id: "user-1", title: "Bot Chat", profile: "default")
        // An ordinary bot-profile session with a different title is a real
        // conversation and stays visible.
        let botProfileSession = makeSessionSummary(id: "bot-work-1", title: "Project planning", profile: "atlas")
        // A session matching nothing is untouched.
        let unrelated = makeSessionSummary(id: "user-2", title: "Groceries")

        XCTAssertFalse(BotChatHygiene.isCanonicalBotChatRow(dashboardTitled, roster: [bot]))
        XCTAssertFalse(BotChatHygiene.isCanonicalBotChatRow(botProfileSession, roster: [bot]))
        XCTAssertFalse(BotChatHygiene.isCanonicalBotChatRow(unrelated, roster: [bot]))
    }

    func testActiveProfileSessionsProjectionDropsCanonicalButKeepsCatalog() async {
        let bot = makeBot(name: "atlas", canonicalID: "stored-1")
        let canonicalRow = makeSessionSummary(id: "stored-1", title: "Bot Chat")
        let ordinaryRow = makeSessionSummary(id: "ordinary", title: "Design review")

        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            botRoster: { _ in
                BotRosterSnapshot(bots: [bot], supportsBotProtocol: true)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [canonicalRow, ordinaryRow]

        // Seeding the roster through the probe path must project the
        // canonical row out of the Sessions list...
        await harness.appState.refreshBotRoster()

        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["atlas"])
        XCTAssertEqual(harness.appState.botModePhase, .available)
        XCTAssertEqual(harness.appState.activeProfileSessions.map(\.id), ["ordinary"])
        // ...while the identity machinery's catalog still sees the row:
        // the filter is presentation hygiene, never discovery.
        XCTAssertEqual(harness.appState.sessions.map(\.id), ["stored-1", "ordinary"])
    }

    // MARK: - open flow: fail-closed and identity semantics

    func testLookupFailureDoesNotCreateAndSurfacesRetryError() async {
        var createCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            findBotChat: { _, _ in
                throw RpcError(code: 5000, message: "state.db is locked")
            },
            createBotChat: { _, _ in
                createCalls += 1
                return ("runtime-x", nil)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        let opened = await harness.appState.openBotChat(for: bot)

        XCTAssertFalse(opened)
        XCTAssertEqual(createCalls, 0, "a failed registry lookup must never mint a chat")
        XCTAssertNil(harness.appState.activeSessionId)
        XCTAssertNotNil(harness.appState.errorMessage)
        XCTAssertEqual(harness.appState.botModePhase, .idle, "an ordinary lookup failure is not a gateway gap")
    }

    func testMissingMethodLookupMarksGatewayUnsupportedWithoutCreating() async {
        var createCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            findBotChat: { _, _ in
                throw RpcError(code: -32601, message: "unknown method")
            },
            createBotChat: { _, _ in
                createCalls += 1
                return ("runtime-x", nil)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        let opened = await harness.appState.openBotChat(for: bot)

        XCTAssertFalse(opened)
        XCTAssertEqual(createCalls, 0)
        XCTAssertEqual(harness.appState.botModePhase, .gatewayUnsupported)
    }

    func testUnconfirmedAbsenceRefusesToCreate() async throws {
        var createCalls = 0
        let rosterBot = makeBot(name: "atlas", canonicalID: "stored-1")
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            botRoster: { _ in
                BotRosterSnapshot(bots: [rosterBot], supportsBotProtocol: true)
            },
            findBotChat: { _, _ in [] },
            createBotChat: { _, _ in
                createCalls += 1
                return ("runtime-x", nil)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        let bot = try XCTUnwrap(harness.appState.botRoster.first)

        let opened = await harness.appState.openBotChat(for: bot)

        XCTAssertFalse(opened)
        XCTAssertEqual(createCalls, 0, "empty lookup while the roster confirms a canonical chat must not mint")
        XCTAssertNotNil(harness.appState.errorMessage)
    }

    func testExistingCanonicalOpensResolvedTipThroughOrdinaryResume() async {
        var created = 0
        var resumedIDs: [String] = []
        var resumeProfiles: [String?] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, profile in
                resumedIDs.append(id)
                resumeProfiles.append(profile)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            },
            createBotChat: { _, _ in
                created += 1
                return ("runtime-x", nil)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(created, 0)
        XCTAssertEqual(resumedIDs, ["runtime-1"], "the open addresses the compression-lineage tip")
        XCTAssertEqual(resumeProfiles, ["atlas"], "the resume rides the BOT profile, never the dashboard scope")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(harness.appState.activeSessionTitle, "atlas", "the bot's display label titles the chat")
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testMissingCanonicalCreatesHiddenTitledChatThenOpensRuntime() async {
        var order: [String] = []
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, profile in
                order.append("open:\(profile ?? "nil")")
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-new",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                order.append("lookup")
                return []
            },
            createBotChat: { _, profile in
                order.append("create:\(profile)")
                return ("runtime-new", "stored-new")
            },
            titleBotChat: { _, sessionID, title, profile in
                order.append("title:\(sessionID):\(title):\(profile)")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(
            order.first, "lookup",
            "the registry lookup always precedes creation"
        )
        XCTAssertTrue(order.contains("create:atlas"))
        XCTAssertTrue(
            order.contains("title:runtime-new:\(BotMode.canonicalChatTitle):atlas"),
            "the eager title names the bot profile it addresses"
        )
        XCTAssertTrue(
            (order.firstIndex { $0.hasPrefix("open:") } ?? order.endIndex) > (order.firstIndex { $0.hasPrefix("title:") } ?? 0),
            "the open only happens after the canonical title landed"
        )
        XCTAssertEqual(order.last, "open:atlas", "the open resumes under the BOT's profile scope")
        XCTAssertEqual(resumedIDs, ["runtime-new"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-new")
    }

    func testCreationTitleCollisionAdoptsWinnerInsteadOfForking() async {
        var createCalls = 0
        var lookups = 0
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-winner",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                lookups += 1
                // First consultation: confirmed absence. Second (post-collision
                // adoption re-lookup): another writer holds the canonical row.
                return lookups == 1
                    ? []
                    : [BotChatLookupRow(id: "stored-winner", resolvedID: "runtime-winner", title: "Bot Chat")]
            },
            createBotChat: { _, _ in
                createCalls += 1
                return ("runtime-stray", nil)
            },
            titleBotChat: { _, _, _, _ in
                throw RpcError(code: 4022, message: "Title 'Bot Chat' is already in use by session stored-winner")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(createCalls, 1, "the stray lazy session is created once and then abandoned")
        XCTAssertEqual(lookups, 2, "the collision re-consults the registry")
        XCTAssertEqual(resumedIDs, ["runtime-winner"], "the winner's lineage tip is opened, never our stray")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-winner")
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testTitleFailureOtherThanCollisionFailsClosedWithoutOpening() async {
        var openCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, _, _ in
                openCalls += 1
                return SessionResumeResult(
                    sessionId: "runtime-stray",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in [] },
            createBotChat: { _, _ in ("runtime-stray", nil) },
            titleBotChat: { _, _, _, _ in
                throw RpcError(code: 5000, message: "state.db is locked")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertFalse(opened)
        XCTAssertEqual(openCalls, 0, "an untitled lazy row must never be opened: the registry has no entry yet")
        XCTAssertNotNil(harness.appState.errorMessage)
    }

    /// A bot open records the conversation the user is now viewing — with its
    /// KIND. The reference is what a relaunch restores from, so recording it as
    /// an ordinary conversation of the dashboard profile (the pre-type
    /// behavior) would reopen a bot's forever chat from the Sessions surface;
    /// recording nothing would lose the conversation the user was in. The
    /// workspace's ORDINARY selection is protected by the reference's kind, not
    /// by refusing to remember it.
    func testBotOpenRecordsTypedReferenceWithoutClaimingTheOrdinarySurface() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        _ = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        let stored = harness.store.lastSession(for: "default")
        XCTAssertEqual(stored?.kind, SessionReference.Kind.bot, "the Bot Chat is remembered as a Bot Chat")
        XCTAssertEqual(stored?.scopeProfile, "atlas")
        XCTAssertNil(
            harness.appState.sessions.first(where: { $0.id == "stored-1" }),
            "the Sessions surface still carries no bot row"
        )
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "the bot chat never writes the workspace's ordinary title cache: \(persisted ?? [:])"
        )
    }

    func testConcurrentBotOpensShareOneFlight() async {
        var lookupCalls = 0
        var resumeCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in
                resumeCalls += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                lookupCalls += 1
                return [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        async let first: Bool = harness.appState.openBotChat(for: bot)
        async let second: Bool = harness.appState.openBotChat(for: bot)
        let (firstResult, secondResult) = await (first, second)

        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(lookupCalls, 1, "double-tapping a row must not consult the registry twice")
        XCTAssertEqual(resumeCalls, 1)
    }

    func testRosterRefreshDropsStaleResponseAfterServerIdentityChange() async {
        // The seam captures the state by box so the response can race the
        // outgoing server's teardown: by the time it lands,
        // prepareChatResumeForConnection has already bumped the epoch.
        var capturedState: AppState?
        let staleBot = makeBot(name: "stale-bot")
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(
                    "https://one.example",
                    forKey: "conduit.chatResumeServerIdentity.v1"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                botRoster: { _ in
                    _ = capturedState?.prepareChatResumeForConnection(
                        to: "https://elsewhere.example",
                        dashboardID: UUID()
                    )
                    return BotRosterSnapshot(bots: [staleBot], supportsBotProtocol: true)
                }
            )
        )
        capturedState = harness.appState
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await harness.appState.refreshBotRoster()

        XCTAssertEqual(
            harness.appState.botRoster.map(\.name), [],
            "a roster answer captured under an older epoch must never describe the new server"
        )
        XCTAssertEqual(harness.appState.botModePhase, .idle)
    }

    func testResolverPinsRosterCanonicalAmongLegacyForks() throws {
        let rows = [
            BotChatLookupRow(id: "stray-1", title: "Bot Chat"),
            BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")
        ]

        let resolution = BotChatResolver.resolve(rows: rows, rosterCanonicalID: "stored-1")

        XCTAssertEqual(
            try resolution.get(),
            .openExisting(registryID: "stored-1", resumeID: "runtime-1"),
            "the roster's server-resolved registry breaks ties among legacy forks"
        )
    }

    func testResolverFallsBackToFirstCanonicalWhenRosterPinMisses() throws {
        let rows = [
            BotChatLookupRow(id: "a-1", title: "Bot Chat"),
            BotChatLookupRow(id: "b-1", title: "Bot Chat")
        ]

        let resolution = BotChatResolver.resolve(rows: rows, rosterCanonicalID: "not-present")

        XCTAssertEqual(
            try resolution.get(),
            .openExisting(registryID: "a-1", resumeID: "a-1"),
            "a pin that matches none of the forks falls back to the listing order"
        )
    }

    // MARK: - PR #170 review triage regressions

    func testLookupDecoderRejectsAnyMalformedRowInsteadOfDiscarding() {
        // A conforming gateway always emits non-empty ids, but the decoder
        // is the identity registry: one malformed row makes the WHOLE
        // lookup unreliable, and an unreliable lookup must read as failure —
        // never as confirmed absence (which is what authorizes minting).
        let payload: [String: AnyCodable] = [
            "sessions": .array([
                .object([
                    "id": .string("stored-1"),
                    "title": .string("Bot Chat")
                ]),
                // Structurally malformed: no id at all.
                .object([
                    "title": .string("Bot Chat")
                ])
            ])
        ]

        XCTAssertNil(
            BotChatLookupDecoder.decode(.object(payload)),
            "a malformed row must fail the whole lookup, never shrink it"
        )
    }

    func testLookupDecoderRejectsNonDictionaryRow() {
        let payload: [String: AnyCodable] = [
            "sessions": .array([
                .string("not-a-row")
            ])
        ]

        XCTAssertNil(BotChatLookupDecoder.decode(.object(payload)))
    }

    func testSupersededRosterRefreshDoesNotClearNewerRefreshClaim() async {
        // Boxes the two seam invocations can poll from the test body.
        final class Gate: @unchecked Sendable {
            var open = false
            var calls = 0
        }
        let releaseFirst = Gate()
        // Bounded wait on the seam's call count: a fixed sleep races a slow
        // runner, and a first refresh that starts only AFTER the server
        // switch belongs to the new identity (the second then joins it).
        func waitForRosterCall(_ count: Int) async {
            for _ in 0..<500 where releaseFirst.calls < count {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(releaseFirst.calls, count, "roster call \(count) never started")
        }
        let rosterBot = makeBot(name: "atlas")
        let staleBot = makeBot(name: "stale-bot")
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(
                    "https://one.example",
                    forKey: "conduit.chatResumeServerIdentity.v1"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                botRoster: { _ in
                    releaseFirst.calls += 1
                    if releaseFirst.calls == 1 {
                        while !releaseFirst.open {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                        return BotRosterSnapshot(bots: [staleBot], supportsBotProtocol: true)
                    }
                    // The newer refresh holds the claim long enough for the
                    // superseded one to finish and (wrongly) release it.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return BotRosterSnapshot(bots: [rosterBot], supportsBotProtocol: true)
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let first = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.refreshBotRoster()
        }
        await waitForRosterCall(1)
        // Server switch: bumps the epoch and resets the single-flight flag.
        _ = harness.appState.prepareChatResumeForConnection(
            to: "https://elsewhere.example",
            dashboardID: UUID()
        )
        let second = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.refreshBotRoster()
        }
        await waitForRosterCall(2)
        XCTAssertTrue(
            harness.appState.isRefreshingBotRoster,
            "the newer refresh owns the single-flight claim"
        )

        releaseFirst.open = true
        await first.value
        XCTAssertTrue(
            harness.appState.isRefreshingBotRoster,
            "the superseded refresh completing must NOT clear the newer refresh's claim"
        )
        await second.value
        XCTAssertFalse(harness.appState.isRefreshingBotRoster)
        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["atlas"])
    }

    func testSupersededSameSessionBotOpenStaysSilent() async {
        // While the bot open is mid-resume, a newer ordinary open of the
        // SAME session id takes over the viewport. The superseded bot open
        // completes afterwards and must stay silent: supersession is
        // navigation state, not an error.
        final class Gate: @unchecked Sendable {
            var open = false
        }
        let releaseBotResume = Gate()
        var resumeCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, _ in
                resumeCalls += 1
                if resumeCalls == 1 {
                    while !releaseBotResume.open {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        let botOpen = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.openBotChat(for: bot)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        // A newer navigation re-opens the SAME session id through the
        // ordinary path; it takes over the viewport transition.
        _ = await harness.appState.openSession("runtime-1")
        releaseBotResume.open = true

        let opened = (await botOpen.value) ?? false

        XCTAssertEqual(resumeCalls, 2)
        XCTAssertFalse(
            opened,
            "the superseded open did not complete — the newer navigation owns the viewport"
        )
        XCTAssertNil(
            harness.appState.errorMessage,
            "a superseded bot open is navigation state, never an error"
        )
    }

    // MARK: - review-hardening regressions

    func testStrayCatalogRowDoesNotBlockCanonicalOpen() async {
        // A visible stray row for the canonical chat (older server data) sits
        // in the raw catalog under the BOT's profile. The ordinary workspace
        // guard protects dashboard opens; a bot open carries its own profile
        // and must proceed through the ordinary machinery anyway.
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, profile in
                resumedIDs.append(id)
                _ = profile
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [
            makeSessionSummary(id: "runtime-1", title: "Bot Chat", storedID: "stored-1", profile: "atlas")
        ]

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened, "a stray cross-profile catalog row must not block the canonical open")
        XCTAssertEqual(resumedIDs, ["runtime-1"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testCreateCollisionAdoptsWinnerInsteadOfForking() async {
        var createCalls = 0
        var lookups = 0
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-winner",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                lookups += 1
                return lookups == 1
                    ? []
                    : [BotChatLookupRow(id: "stored-winner", resolvedID: "runtime-winner", title: "Bot Chat")]
            },
            // Some gateways enforce the canonical name at create time.
            createBotChat: { _, _ in
                createCalls += 1
                throw RpcError(code: 4022, message: "Title 'Bot Chat' is already in use by session stored-winner")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(createCalls, 1)
        XCTAssertEqual(lookups, 2, "a create-time collision re-consults the registry")
        XCTAssertEqual(resumedIDs, ["runtime-winner"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-winner")
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testRefreshFailureWithEstablishedRosterSurfacesNotice() async {
        var calls = 0
        let rosterBot = makeBot(name: "atlas")
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            botRoster: { _ in
                calls += 1
                if calls == 1 {
                    return BotRosterSnapshot(bots: [rosterBot], supportsBotProtocol: true)
                }
                throw RpcError(code: 5000, message: "gateway restart in progress")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)

        await harness.appState.refreshBotRoster()

        guard case .failed(let message) = harness.appState.botModePhase else {
            return XCTFail("a failed refresh over an established roster must surface the notice phase")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(
            harness.appState.botRoster.map(\.name), ["atlas"],
            "the stale roster stays visible under the failure notice"
        )
    }

    func testServerSwitchCancelsInFlightBotOpen() async {
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(
                    "https://one.example",
                    forKey: "conduit.chatResumeServerIdentity.v1"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSessionWithProfile: { _, id, _, _ in
                    // The flight is mid-resume when the server switches.
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: "stored-1",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                findBotChat: { _, _ in
                    [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        async let opened: Bool = harness.appState.openBotChat(for: bot)
        try? await Task.sleep(nanoseconds: 60_000_000)
        _ = harness.appState.prepareChatResumeForConnection(
            to: "https://elsewhere.example",
            dashboardID: UUID()
        )
        let result = await opened

        XCTAssertFalse(result, "a server switch must abandon the in-flight bot open")
        XCTAssertNil(
            harness.appState.errorMessage,
            "an abandoned flight stays silent: the refusal text describes the outgoing server"
        )
        XCTAssertEqual(
            harness.appState.activeSessionId, nil,
            "the stale flight must not navigate the UI against the outgoing server"
        )
        XCTAssertTrue(harness.appState.botRoster.isEmpty)
        XCTAssertEqual(harness.appState.botModePhase, BotModePhase.idle)
    }

    func testBackfillWindowCarriesBotProfileScope() async {
        var hydrationProfiles: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, profile, _ in
                hydrationProfiles.append(profile)
                // A full tail-anchored page (echoed order=latest, limit ==
                // rawReturned) so the window stamp runs and the backfill
                // affordance arms.
                var rows: [[String: Any]] = []
                for index in 0..<PersistedTranscriptPagination.pageSize {
                    rows.append([
                        "id": "row-\(index)",
                        "role": "user",
                        "content": "row \(index)",
                        "timestamp": String(index)
                    ])
                }
                return .payload([
                    "session_id": sessionId,
                    "messages": rows,
                    "pagination": [
                        "limit": PersistedTranscriptPagination.pageSize,
                        "offset": 0,
                        "order": "latest",
                        "returned": PersistedTranscriptPagination.pageSize
                    ]
                ])
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(hydrationProfiles, ["atlas"], "the persisted-history hydration addresses the bot profile")
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.profile, "atlas",
            "the backfill window is stamped with the bot scope so older pages fetch from the bot's store"
        )
        XCTAssertTrue(
            harness.appState.canLoadEarlierMessagesForActiveConversation,
            "the ownership gate must accept the bot-scoped window while the chat is active"
        )
    }

    func testCreateStageGenericFailureFailsClosedWithoutOpening() async {
        var openCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, _, _, _ in
                openCalls += 1
                return SessionResumeResult(
                    sessionId: "runtime-stray",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in [] },
            createBotChat: { _, _ in
                throw RpcError(code: 5000, message: "profile backend unavailable")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertFalse(opened)
        XCTAssertEqual(openCalls, 0, "a failed create never opens the lazy runtime")
        XCTAssertNotNil(harness.appState.errorMessage)
        XCTAssertEqual(harness.appState.botModePhase, BotModePhase.idle)
    }

    // MARK: - bot title-cache regressions

    /// Opens a canonical Bot Chat as the ACTIVE session and then refreshes
    /// the catalog, whose raw row is titled exactly "Bot Chat". Neither the
    /// visible label nor the PERSISTED ordinary active-title cache may pick
    /// the wire title up (the cold-restore bug).
    func testCatalogRefreshNeverPersistsBotChatTitleForActiveBotConversation() async {
        let harness = makeBotHarness(
            sessionCatalogLoader: { _ in
                [self.makeSessionSummary(
                    id: "runtime-1",
                    title: BotMode.canonicalChatTitle,
                    storedID: "stored-1",
                    profile: "default"
                )]
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, id, _ in
                    SessionResumeResult(
                        sessionId: id,
                        storedSessionId: "stored-1",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                findBotChat: { _, _ in
                    [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        let opened = await harness.appState.openBotChat(for: bot)

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(harness.appState.activeSessionTitle, bot.displayLabel)

        await harness.appState.loadSessions()

        XCTAssertEqual(
            harness.appState.activeSessionTitle, bot.displayLabel,
            "the catalog's literal Bot Chat row must not displace the bot's display label"
        )
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "the wire title must never enter the persisted ordinary title cache: \(persisted ?? [:])"
        )
    }

    /// A .sessionTitle event addressed to the canonical Bot Chat may update
    /// catalog rows, but must never overwrite the active bot label or
    /// persist the literal wire title into the ordinary cache.
    func testSessionTitleEventNeverPersistsBotChatTitleForActiveBotConversation() async {
        let harness = makeBotHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, id, _ in
                    SessionResumeResult(
                        sessionId: id,
                        storedSessionId: "stored-1",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                findBotChat: { _, _ in
                    [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")
        let opened = await harness.appState.openBotChat(for: bot)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")

        harness.appState.handleStreamEvent(
            .sessionTitle(runtimeSessionId: "runtime-1", storedSessionId: "stored-1", title: BotMode.canonicalChatTitle)
        )

        XCTAssertEqual(
            harness.appState.activeSessionTitle, bot.displayLabel,
            "the event must not overwrite the bot's display label"
        )
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "the event title must never enter the persisted ordinary title cache: \(persisted ?? [:])"
        )
    }

    /// Ordinary (non-bot) sessions keep both title paths exactly as before.
    func testOrdinaryActiveSessionTitlesStillPersistThroughBothPaths() async {
        let harness = makeBotHarness(
            sessionCatalogLoader: { _ in
                [self.makeSessionSummary(id: "ordinary-1", title: "Fresh Catalog Title")]
            },
            lifecycleOperations: ChatResumeLifecycleOperations()
        )

        harness.appState.activeSessionId = "ordinary-1"
        await harness.appState.loadSessions()

        XCTAssertEqual(harness.appState.activeSessionTitle, "Fresh Catalog Title")
        var persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertEqual(persisted?["default"], "Fresh Catalog Title")

        harness.appState.handleStreamEvent(
            .sessionTitle(runtimeSessionId: "ordinary-1", storedSessionId: "stored-ordinary", title: "Event Title")
        )
        XCTAssertEqual(harness.appState.activeSessionTitle, "Event Title")
        persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertEqual(persisted?["default"], "Event Title")
    }

    /// The `.task(id:)` identity change cancels the VIEW task while its
    /// refresh is in flight. A replacement that only bails on the
    /// single-flight guard strands `.loading`: the cancelled holder releases
    /// the claim without committing a phase. The refresh now runs
    /// unstructured and late callers JOIN it, so the cancel can no longer
    /// kill the work and the roster still commits.
    func testRosterRefreshJoinKeepsPhaseAliveWhenCallerTaskIsCancelled() async {
        final class Gate: @unchecked Sendable {
            var open = false
        }
        let releaseFirst = Gate()
        var stubCalls = 0
        let rosterBot = makeBot(name: "atlas")
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            botRoster: { _ in
                stubCalls += 1
                if stubCalls == 1 {
                    // This await is the network boundary where a cancelled
                    // VIEW task used to kill the in-flight refresh.
                    try Task.checkCancellation()
                    while !releaseFirst.open {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    return BotRosterSnapshot(bots: [rosterBot], supportsBotProtocol: true)
                }
                return BotRosterSnapshot(bots: [], supportsBotProtocol: true)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let first = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.refreshBotRoster()
        }
        while !harness.appState.isRefreshingBotRoster {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let second = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.refreshBotRoster()
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        first.cancel()
        releaseFirst.open = true
        await second.value
        await first.value

        XCTAssertEqual(
            harness.appState.botModePhase, .available,
            "a cancelled view task must not strand the roster on .loading"
        )
        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["atlas"])
    }

    // MARK: - PR #170 triage: reserved-row resume boundary

    /// Cold launch has neither a roster nor a bot-chat registry entry, so the
    /// reserved exact title is the only signal that can keep a stale/legacy
    /// visible canonical row out of the ordinary automatic resume selection.
    /// The row must not become this workspace's active conversation (which is
    /// what seeds the cold-restore selection and persists the wire title),
    /// while the published catalog itself stays untouched.
    func testAutomaticResumeNeverSelectsReservedBotChatRow() async {
        let botChatRow = makeSessionSummary(
            id: "runtime-bot",
            title: BotMode.canonicalChatTitle,
            storedID: "stored-bot"
        )
        let ordinaryRow = makeSessionSummary(id: "ordinary-1", title: "Design review")
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [botChatRow, ordinaryRow] },
            openSession: { _, id, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        XCTAssertTrue(harness.appState.botRoster.isEmpty, "a cold launch carries no roster")

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            Set(resumedIDs),
            Set(["ordinary-1"]),
            "the reserved canonical row is never a resume candidate"
        )
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-1")
        XCTAssertEqual(
            harness.store.lastSessionID(for: "default"),
            "ordinary-1",
            "the cold-restore selection belongs to the ordinary conversation, not the bot chat"
        )
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertEqual(persisted?["default"], "Design review")
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "the reserved wire title must never enter the persisted ordinary title cache: \(persisted ?? [:])"
        )
        XCTAssertTrue(
            harness.appState.sessions.contains { $0.title == BotMode.canonicalChatTitle },
            "the filter is selection-only: the published catalog keeps the row"
        )
    }

    /// The reserved row is not a fallback either. When it is the only
    /// candidate, ordinary selection declines (the pre-existing "no eligible
    /// chat" behaviour) rather than adopting a bot's forever chat as this
    /// workspace's conversation. The resume seam is what makes the assertion
    /// meaningful: it proves the row was never even attempted, not that a
    /// failed resume happened to leave the state clean.
    func testAutomaticResumeDeclinesWhenOnlyCandidateIsReservedBotChat() async {
        let botChatRow = makeSessionSummary(
            id: "runtime-bot",
            title: BotMode.canonicalChatTitle,
            storedID: "stored-bot"
        )
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [botChatRow] },
            openSession: { _, id, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertTrue(resumedIDs.isEmpty, "the reserved row is never resumed: \(resumedIDs)")
        XCTAssertNil(harness.appState.activeSessionId, "the reserved row is never adopted")
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "declining must not persist the reserved title either: \(persisted ?? [:])"
        )
    }

    /// A canonical Bot Chat known to the registry can still be opened through
    /// the ORDINARY path (`requestOpenSession` and friends pass no
    /// conversation profile). Ownership must therefore come from registry
    /// identity, so the raw catalog row titled "Bot Chat" never reaches the
    /// persisted ordinary title cache — while ordinary opens are unchanged.
    func testOrdinaryOpenOfRegistryKnownBotChatNeverPersistsWireTitle() async {
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, profile in
                resumedProfiles.append(profile)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id == "runtime-1" ? "stored-1" : nil,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        // The roster's own open registers the canonical conversation.
        let openedAsBot = await harness.appState.openBotChat(for: bot)
        XCTAssertTrue(openedAsBot)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(harness.appState.activeSessionTitle, bot.displayLabel)
        XCTAssertEqual(resumedProfiles, ["atlas"])

        // A stale/legacy visible canonical row sits in the raw catalog.
        harness.appState.sessions = [
            makeSessionSummary(
                id: "runtime-1",
                title: BotMode.canonicalChatTitle,
                storedID: "stored-1"
            )
        ]

        let reopenedOrdinary = await harness.appState.openSession("runtime-1")
        XCTAssertTrue(reopenedOrdinary, "a registry-known bot chat still opens through the ordinary path")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(
            harness.store.lastSession(for: "default")?.kind,
            SessionReference.Kind.bot,
            "the conversation is remembered with its KIND, whatever path opened it"
        )
        XCTAssertEqual(
            harness.appState.activeSessionTitle,
            bot.displayLabel,
            "the reserved wire title never displaces the bot's display label"
        )
        let persistedAfterOrdinaryOpen = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persistedAfterOrdinaryOpen?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "ordinary opens of a bot conversation never persist the wire title: \(persistedAfterOrdinaryOpen ?? [:])"
        )

        // An ordinary conversation keeps persisting its title exactly as before.
        harness.appState.sessions = [
            makeSessionSummary(
                id: "runtime-1",
                title: BotMode.canonicalChatTitle,
                storedID: "stored-1"
            ),
            makeSessionSummary(id: "ordinary-1", title: "Design review")
        ]
        let openedOrdinary = await harness.appState.openSession("ordinary-1")
        XCTAssertTrue(openedOrdinary)
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-1")
        let persistedAfterOrdinarySession = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertEqual(persistedAfterOrdinarySession?["default"], "Design review")
    }

    /// A canonical Bot Chat's identity IS the exact title "Bot Chat", so it
    /// must never enter automatic title generation — a generated rename would
    /// break the exact-title lookup that resolves the profile's forever chat.
    /// Ordinary conversations keep the historical recovery scheduling.
    func testSecondaryTitleRecoveryNeverSchedulesForCanonicalBotChat() async {
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                // The recovery's own historical gate: it only runs for a
                // non-default workspace profile.
                defaults.set("analyst", forKey: "conduit.activeProfile")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSessionWithProfile: { _, id, _, profile in
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id == "runtime-1" ? "stored-1" : nil,
                        messages: [
                            ChatMessage(id: "user-1", role: .user, content: "Question", timestamp: "1"),
                            ChatMessage(id: "assistant-1", role: .assistant, content: "Answer", timestamp: "2")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                findBotChat: { _, _ in
                    [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "analyst"
        )
        XCTAssertEqual(harness.appState.activeProfile, "analyst")

        let openedAsBot = await harness.appState.openBotChat(for: makeBot(name: "atlas"))
        XCTAssertTrue(openedAsBot)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(resumedProfiles, ["atlas"])
        XCTAssertFalse(
            harness.appState.hasSecondaryTitleRecoveryScheduled(forSessionID: "runtime-1"),
            "a canonical Bot Chat never enters automatic title recovery"
        )

        // Positive control: the same entry point still schedules for an
        // ordinary conversation, so the assertion above cannot be vacuous.
        harness.appState.sessions = [
            makeSessionSummary(id: "ordinary-1", title: "Design review", profile: "analyst")
        ]
        let openedOrdinary = await harness.appState.openSession("ordinary-1")
        XCTAssertTrue(openedOrdinary)
        XCTAssertTrue(
            harness.appState.hasSecondaryTitleRecoveryScheduled(forSessionID: "ordinary-1"),
            "ordinary conversations keep the historical title-recovery scheduling"
        )
    }

    // MARK: - session kind across restoration

    /// A bot chat's open CAN legitimately rotate the runtime id (a documented
    /// `session.resume` behavior). Recording the conversation's KIND must
    /// therefore not depend on the resumed runtime id being the id the open
    /// requested: the stored reference must name a Bot Chat however the resume
    /// answered, so a relaunch restores it against the bot's profile instead of
    /// treating it as an ordinary conversation of the workspace that happened
    /// to be active.
    func testBotOpenRecordsTypedReferenceThroughRotatedRuntime() async {
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, _, _, profile in
                resumedProfiles.append(profile)
                return SessionResumeResult(
                    sessionId: "runtime-rotated",
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(resumedProfiles, ["atlas"], "the bot chat resumes its own profile")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-rotated")
        let stored = harness.store.lastSession(for: "default")
        XCTAssertEqual(
            stored?.kind,
            SessionReference.Kind.bot,
            "the rotated runtime is still the known Bot Chat"
        )
        XCTAssertEqual(stored?.scopeProfile, "atlas")
        XCTAssertEqual(
            stored?.resumeProfileScope,
            "atlas",
            "a restored Bot Chat addresses the BOT's store, never the workspace's"
        )
        XCTAssertEqual(
            harness.appState.botConversationProfileForTesting("runtime-rotated"),
            "atlas",
            "every identity of the adopted conversation resolves to its bot profile"
        )
    }

    /// The durable selection is state written by earlier builds: a bare session
    /// id with no kind. When positive bot evidence (the roster loaded at
    /// connect) attributes that id to a Bot Chat, restoring it as an ordinary
    /// conversation of the workspace — which is what the pre-type code did, and
    /// what reopens a bot session from a workspace with no Bots surface in
    /// sight — must not happen; the conversation restores AS a Bot Chat, scoped
    /// to the bot's profile and labelled with the bot's name.
    func testLegacyStoredSelectionNamingBotChatRestoresAsBotSession() async {
        var resumedIDs: [String] = []
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSessionID("stored-1", for: "default")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    [self.makeSessionSummary(id: "ordinary-new", title: "Design review")]
                },
                openSessionWithProfile: { _, id, _, profile in
                    resumedIDs.append(id)
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id == "stored-1" ? "runtime-1" : id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    BotRosterSnapshot(
                        bots: [self.makeBot(name: "atlas", canonicalID: "stored-1")],
                        supportsBotProtocol: false
                    )
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // The connect sequence's roster load, which is what supplies the
        // evidence that the stored id is a bot's canonical chat.
        await harness.appState.refreshBotRoster()
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["stored-1"], "the stored conversation is still preferred")
        XCTAssertEqual(
            resumedProfiles,
            ["atlas"],
            "and it resumes against the BOT's profile — the workspace profile cannot see it"
        )
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(
            harness.store.lastSession(for: "default")?.kind,
            SessionReference.Kind.bot,
            "the legacy id-only selection is upgraded to a typed reference"
        )
    }

    /// Both surfaces exist at once, and the BOT chat is the newer conversation.
    /// The workspace still restores its own newest conversation: a bot chat is
    /// not part of the Sessions surface, so "continue where I left off" must
    /// not open one. The reserved canonical title alone is enough here (the
    /// cold-launch case, with no roster loaded).
    func testAutomaticReturnPrefersNewestOrdinarySessionOverNewerBotChat() async {
        var resumedIDs: [String] = []
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in
                [
                    self.makeSessionSummary(
                        id: "runtime-bot",
                        title: BotMode.canonicalChatTitle,
                        storedID: "stored-bot",
                        lastActivityAt: 300
                    ),
                    self.makeSessionSummary(id: "ordinary-new", title: "Design review", lastActivityAt: 200)
                ]
            },
            openSessionWithProfile: { _, id, _, profile in
                resumedIDs.append(id)
                resumedProfiles.append(profile)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        XCTAssertTrue(harness.appState.botRoster.isEmpty, "a cold launch carries no roster")

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["ordinary-new"], "the newest BOT chat is never the workspace's conversation")
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-new")
        XCTAssertEqual(harness.store.lastSession(for: "default")?.kind, SessionReference.Kind.dashboard)
    }

    /// Same shape, opposite ordering: the ordinary conversation is older than
    /// the bot chat, and the bot chat's own title no longer reads "Bot Chat"
    /// (a compaction moved the conversation to a lineage tip). The roster's
    /// canonical registry is what excludes the row, so the workspace still
    /// restores its own newest conversation.
    func testOwnershipEvidenceExcludesUntitledBotChatFromOrdinarySelection() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in
                [
                    self.makeSessionSummary(id: "runtime-tip", title: "Weekly digest", lastActivityAt: 400),
                    self.makeSessionSummary(id: "ordinary-old", title: "Design review", lastActivityAt: 100)
                ]
            },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [self.makeBot(name: "atlas", canonicalID: "stored-1", resolvedID: "runtime-tip")],
                    supportsBotProtocol: false
                )
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedIDs,
            ["ordinary-old"],
            "a canonical chat's lineage tip is excluded by registry identity, not only by title"
        )
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-old")
    }

    /// Foregrounding while a normal conversation is on screen: the conversation
    /// stays, and nothing about Bot Mode leaks into the selection even though a
    /// newer bot chat sits in the same catalog.
    func testForegroundPreservesActiveNormalSession() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in
                [
                    self.makeSessionSummary(
                        id: "runtime-bot",
                        title: BotMode.canonicalChatTitle,
                        storedID: "stored-bot",
                        lastActivityAt: 900
                    ),
                    self.makeSessionSummary(id: "ordinary-visible", title: "Design review", lastActivityAt: 100)
                ]
            },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [makeSessionSummary(id: "ordinary-visible", title: "Design review")]
        harness.appState.activeSessionId = "ordinary-visible"

        await harness.appState.syncSession(
            purpose: .preserveCurrent,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["ordinary-visible"], "the visible conversation is repaired, not replaced")
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-visible")
        XCTAssertEqual(harness.store.lastSession(for: "default")?.kind, SessionReference.Kind.dashboard)
        XCTAssertNil(harness.appState.botConversationProfileForTesting("ordinary-visible"))
    }

    /// Foregrounding while a Bot Chat is on screen: the exact conversation
    /// survives, still as a Bot Chat — resumed against the bot's profile, still
    /// labelled with the bot's name, and still recorded as a `.bot` reference.
    func testForegroundPreservesActiveBotSessionAsBotSession() async {
        var resumedIDs: [String] = []
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSession(
                    .bot(botName: "atlas", label: "Scout", sessionID: "runtime-1"),
                    for: "default"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
                openSessionWithProfile: { _, id, _, profile in
                    resumedIDs.append(id)
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: "stored-1",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // A cold launch restored the Bot Chat's reference: identity, type, and
        // label all survive the relaunch.
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(harness.appState.activeSessionTitle, "Scout")
        XCTAssertEqual(harness.appState.botConversationProfileForTesting("runtime-1"), "atlas")

        await harness.appState.syncSession(
            purpose: .preserveCurrent,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["runtime-1"])
        XCTAssertEqual(resumedProfiles, ["atlas"], "the foreground refresh addresses the bot's profile")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(harness.appState.activeSessionTitle, "Scout")
        XCTAssertEqual(harness.store.lastSession(for: "default")?.kind, SessionReference.Kind.bot)
    }

    /// "Continue where I left off" prefers the stored conversation even when it
    /// is NOT the globally newest one — the stored selection is the user's last
    /// position, not a ranking.
    func testAutomaticReturnPrefersStoredSessionOverNewestCatalogRow() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSessionID("ordinary-stored", for: "default")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    [
                        self.makeSessionSummary(id: "ordinary-newest", title: "Newest", lastActivityAt: 900),
                        self.makeSessionSummary(id: "ordinary-stored", title: "Where I left off", lastActivityAt: 100)
                    ]
                },
                openSessionWithProfile: { _, id, _, _ in
                    resumedIDs.append(id)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["ordinary-stored"])
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-stored")
    }

    /// The stored conversation was deleted while the app was away: the 4007
    /// answer drops it and the replacement is chosen by the AUTHORITATIVE
    /// activity instant — not by list position, which merges cached rows behind
    /// live ones and can carry a stale row first.
    func testDeletedStoredSessionFallsBackToNewestByTimestampNotListOrder() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSessionID("ordinary-deleted", for: "default")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    // List order deliberately puts the older row first.
                    [
                        self.makeSessionSummary(id: "ordinary-older", title: "Older", lastActivityAt: 100),
                        self.makeSessionSummary(id: "ordinary-newer", title: "Newest", lastActivityAt: 500)
                    ]
                },
                openSessionWithProfile: { _, id, _, _ in
                    resumedIDs.append(id)
                    if id == "ordinary-deleted" {
                        throw RpcError(code: 4007, message: "session not found")
                    }
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedIDs,
            ["ordinary-deleted", "ordinary-newer"],
            "the deleted conversation is dropped once, then the newest conversation is chosen"
        )
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-newer")
        XCTAssertEqual(harness.store.lastSessionID(for: "default"), "ordinary-newer")
    }

    /// A workspace switch restores THAT workspace's conversation, with its own
    /// kind: a Bot Chat recorded under a workspace comes back as a Bot Chat
    /// scoped to its bot, and an ordinary conversation of another workspace
    /// never inherits a bot scope.
    func testWorkspaceRestorationKeepsEachContextsSessionKind() async {
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                let store = ChatResumeStore(defaults: defaults)
                store.setLastSession(
                    .bot(botName: "atlas", label: "Scout", sessionID: "stored-1"),
                    for: "default"
                )
                store.setLastSessionID("work-session", for: "work")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(refreshContext: { _, _ in })
        )

        // What `switchProfile` and cold launch both call.
        harness.appState.restoreActiveSessionState(for: "work")
        XCTAssertEqual(harness.appState.activeSessionId, "work-session")
        XCTAssertNil(
            harness.appState.botConversationProfileForTesting("work-session"),
            "an ordinary conversation never inherits a bot profile scope"
        )

        harness.appState.restoreActiveSessionState(for: "default")
        XCTAssertEqual(harness.appState.activeSessionId, "stored-1")
        XCTAssertEqual(
            harness.appState.botConversationProfileForTesting("stored-1"),
            "atlas",
            "the workspace's Bot Chat keeps its bot scope across a workspace switch"
        )
        XCTAssertEqual(harness.appState.activeSessionTitle, "Scout")
    }

    /// The `activeProfileSessions` projection (what the Sessions list renders
    /// and what a workspace considers its own) never carries a bot conversation
    /// — by reserved title or by registry identity — so a restored Bot Chat
    /// cannot reappear as an ordinary row after a workspace switch.
    func testSessionsSurfaceProjectionExcludesBotConversations() async {
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSession(
                    .bot(botName: "atlas", label: "Scout", sessionID: "stored-1"),
                    for: "default"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                refreshContext: { _, _ in },
                botRoster: { _ in
                    BotRosterSnapshot(
                        bots: [self.makeBot(name: "atlas", canonicalID: "stored-1", resolvedID: "runtime-tip")],
                        supportsBotProtocol: false
                    )
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()

        harness.appState.sessions = [
            makeSessionSummary(id: "runtime-tip", title: "Weekly digest"),
            makeSessionSummary(id: "ordinary-1", title: "Design review")
        ]

        XCTAssertEqual(
            harness.appState.activeProfileSessions.map(\.id),
            ["ordinary-1"],
            "the workspace surface keeps only its own conversations"
        )
    }

    /// The mirror of the newer-bot-chat case: with the ORDINARY conversation
    /// newest, both surfaces still keep to themselves — the workspace restores
    /// its own conversation and never reports a bot conversation as active.
    func testAutomaticReturnPicksTheNewestOrdinaryWhenItIsAlsoNewestOverall() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in
                [
                    self.makeSessionSummary(id: "ordinary-newest", title: "Newest", lastActivityAt: 900),
                    self.makeSessionSummary(
                        id: "runtime-bot",
                        title: BotMode.canonicalChatTitle,
                        storedID: "stored-bot",
                        lastActivityAt: 100
                    )
                ]
            },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["ordinary-newest"])
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-newest")
        XCTAssertNil(harness.appState.botConversationProfileForTesting("ordinary-newest"))
        XCTAssertEqual(harness.store.lastSession(for: "default")?.kind, SessionReference.Kind.dashboard)
    }

    /// A relaunch: a second AppState over the same defaults must restore the
    /// Bot Chat with its TYPE intact — the id, the bot's profile scope, and the
    /// bot's label — instead of an anonymous conversation of the dashboard
    /// profile.
    func testRelaunchRestoresPersistedBotSessionWithItsType() async {
        let suite = "BotModeTests.Relaunch.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let operations = ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-1",
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        )
        let bot = BotProfile(
            name: "atlas",
            botTitle: "Scout",
            displayName: "Atlas",
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

        // First launch: the user opens the bot's chat.
        let first = makeBotHarness(reusing: defaults, lifecycleOperations: operations)
        first.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let opened = await first.appState.openBotChat(for: bot)
        XCTAssertTrue(opened)
        XCTAssertEqual(first.store.lastSession(for: "default")?.kind, SessionReference.Kind.bot)

        // Relaunch: a new process reading the same defaults.
        var resumedProfiles: [String?] = []
        let relaunchedOperations = ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, profile in
                resumedProfiles.append(profile)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        )
        let second = makeBotHarness(reusing: defaults, lifecycleOperations: relaunchedOperations)
        second.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        // The DURABLE identity is what a relaunch addresses (the runtime id of
        // the previous process is gone), and it is still the bot's chat.
        XCTAssertEqual(second.appState.activeSessionId, "stored-1")
        XCTAssertEqual(second.appState.activeSessionTitle, "Scout")
        XCTAssertEqual(
            second.appState.botConversationProfileForTesting("stored-1"),
            "atlas",
            "the relaunch restored the conversation's BOT scope, not the dashboard profile's"
        )

        // And the restored conversation still resumes through the bot's profile.
        await second.appState.syncSession(
            purpose: .preserveCurrent,
            using: nil,
            automaticWorkToken: nil
        )
        XCTAssertEqual(resumedProfiles, ["atlas"])
    }

    // MARK: - review-gate hardening

    /// The resume scope must not depend on this PROCESS having opened the
    /// conversation: a restored Bot Chat's scope also comes from the roster's
    /// canonical registries and from the durable reference itself. With both
    /// the registry and the roster silent, the reference is the last
    /// authority — and without it the resume would address the dashboard
    /// profile store and lose the session.
    func testBotResumeScopeSurvivesRegistryAndRosterLoss() async {
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSession(
                    .bot(botName: "atlas", label: "Scout", sessionID: "stored-1"),
                    for: "default"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
                openSessionWithProfile: { _, id, _, profile in
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // The relaunch restored the reference (label and scope included), then
        // the process lost its in-memory registrations: the roster was never
        // loaded for this connection and the registry was cleared.
        XCTAssertEqual(harness.appState.activeSessionId, "stored-1")
        harness.appState.clearBotChatRegistryForTesting()

        await harness.appState.syncSession(
            purpose: .preserveCurrent,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedProfiles,
            ["atlas"],
            "the durable reference still names the bot profile its RPCs must ride"
        )
    }

    /// Bot evidence can live on an ALIAS of the stored id (a compaction tip, a
    /// runtime the rebind minted, a lineage root). Healing and the
    /// missing-saved-session gate are therefore evaluated across the
    /// conversation's whole identity set, not just the stored value.
    func testStoredSelectionHealsThroughAliasAndLineageRootEvidence() async {
        var resumedProfiles: [String?] = []
        let tipRow = SessionSummary(
            id: "runtime-tip",
            storedSessionId: "stored-1",
            alternateIds: [],
            title: "Weekly digest",
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: 500,
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: "canonical-root"
        )
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSessionID("stored-1", for: "default")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    [tipRow, self.makeSessionSummary(id: "ordinary-1", title: "Design review", lastActivityAt: 100)]
                },
                openSessionWithProfile: { _, id, _, profile in
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    // The canonical registry names ONLY the lineage root: the
                    // row reaches it through `lineageRootId` alone.
                    BotRosterSnapshot(
                        bots: [self.makeBot(name: "atlas", canonicalID: "canonical-root")],
                        supportsBotProtocol: false
                    )
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedProfiles,
            ["atlas"],
            "the alias/lineage evidence is what heals the stored selection"
        )
        XCTAssertEqual(
            harness.store.lastSession(for: "default")?.kind,
            SessionReference.Kind.bot
        )
    }

    /// A row linked to a bot only through its LINEAGE ROOT is still a bot
    /// conversation: it must not be adopted as the workspace's own, and it must
    /// not be visible on the Sessions surface.
    func testLineageRootLinkageExcludesRowFromSessionsSurfaceAndSelection() async {
        var resumedIDs: [String] = []
        let tipRow = SessionSummary(
            id: "runtime-tip",
            storedSessionId: nil,
            alternateIds: [],
            title: "Weekly digest",
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: 900,
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: "canonical-root"
        )
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in
                [tipRow, self.makeSessionSummary(id: "ordinary-1", title: "Design review", lastActivityAt: 100)]
            },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [self.makeBot(name: "atlas", canonicalID: "canonical-root")],
                    supportsBotProtocol: false
                )
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        harness.appState.sessions = [tipRow, makeSessionSummary(id: "ordinary-1", title: "Design review")]

        XCTAssertEqual(harness.appState.activeProfileSessions.map(\.id), ["ordinary-1"])

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedIDs,
            ["ordinary-1"],
            "the newest BOT lineage tip is never the workspace's conversation"
        )
    }

    /// The rule itself recognizes the lineage-root identity (the Sessions
    /// projection and the resume selection share this one definition).
    func testOwnershipRuleRecognizesLineageRootIdentity() {
        let tipRow = SessionSummary(
            id: "runtime-tip",
            alternateIds: [],
            title: "Weekly digest",
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: "canonical-root"
        )

        XCTAssertTrue(
            BotChatHygiene.isBotOwnedRow(tipRow, botOwnedSessionIDs: ["canonical-root"])
        )
        XCTAssertFalse(
            BotChatHygiene.isBotOwnedRow(tipRow, botOwnedSessionIDs: ["something-else"]),
            "unrelated evidence must not reserve an ordinary row"
        )
    }

    /// A locally-created conversation's activity is NOW: without a timestamp
    /// its row would rank behind every dated row in the "latest activity"
    /// fallback, abandoning a conversation whose first turn is still running.
    func testLocallyCreatedConversationOutranksOlderDatedRows() {
        let created = makeSessionSummary(
            id: "local-new",
            title: "New conversation",
            lastActivityAt: Date().timeIntervalSince1970
        )
        let olderDated = makeSessionSummary(id: "older", title: "Older", lastActivityAt: 100)

        XCTAssertEqual(
            ChatResumeSessionResolver.latestChat(in: [created, olderDated])?.id,
            "local-new"
        )
    }

    /// Equal instants keep the earliest catalog row — deterministic, and the
    /// behavior a `>=` refactor would silently flip.
    func testLatestChatKeepsEarliestRowOnEqualInstants() {
        let first = makeSessionSummary(id: "first", title: "First", lastActivityAt: 500)
        let second = makeSessionSummary(id: "second", title: "Second", lastActivityAt: 500)

        XCTAssertEqual(ChatResumeSessionResolver.latestChat(in: [first, second])?.id, "first")
        XCTAssertEqual(ChatResumeSessionResolver.latestChat(in: [second, first])?.id, "second")
    }

    // MARK: - connect ordering + push routing (review-gate hardening)

    /// Bot evidence must exist BEFORE the sync that decides which conversation
    /// the workspace was in: the reserved-title rule covers a cold launch, but
    /// the registry rule (and reference healing) needs the roster, so the
    /// roster load leads the connect sequence.
    func testConnectLoadsBotRosterBeforeTheResumeDecision() async {
        var events: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            connectClient: { _ in },
            loadCatalog: { _, _ in
                events.append("catalog")
                return [self.makeSessionSummary(id: "ordinary-1", title: "Design review")]
            },
            mintTicket: { _ in "refreshed-ticket" },
            openSessionWithProfile: { _, id, _, _ in
                events.append("resume:\(id)")
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {},
            loadBotRoster: {
                events.append("roster")
            }
        ))

        await harness.appState.connect(
            with: HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        )

        XCTAssertEqual(events.first, "roster", "the roster load leads the sequence: \(events)")
        XCTAssertLessThan(
            events.firstIndex(of: "roster") ?? .max,
            events.firstIndex(of: "catalog") ?? .max,
            "bot evidence is in hand before the resume decision: \(events)"
        )
    }

    /// A decision pushed from a Bot Chat names the BOT's profile. Adopting it
    /// as this dashboard's workspace would turn a bot conversation into the
    /// workspace's own context, so routing fails closed instead of switching.
    func testNotificationForBotProfileFailsClosedInsteadOfSwitchingWorkspace() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [self.makeBot(name: "atlas", canonicalID: "stored-1")],
                    supportsBotProtocol: false
                )
            }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.connection = connection
        // The roster the guard reads; the connect sequence loads the same one
        // before any resume decision runs.
        await harness.appState.refreshBotRoster()

        let routed = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(
                profile: "atlas",
                sessionId: "stored-1",
                type: "approval"
            )
        )

        XCTAssertFalse(routed, "a bot-profile decision is not routed as a workspace conversation")
        XCTAssertEqual(harness.appState.activeProfile, "default", "the workspace profile is untouched")
        XCTAssertTrue(resumedIDs.isEmpty)
        XCTAssertEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it."
        )
    }

    // MARK: - review round 3: scope case + ownership evidence

    /// A Hermes profile name is a wire identity, NOT a dictionary key: the
    /// gateway keys its per-profile store by the EXACT spelling, and the
    /// dashboard paths pass `activeProfile` verbatim. A mixed-case bot profile
    /// must therefore survive persistence and come back verbatim — a
    /// case-folded scope restores the conversation against a profile the
    /// gateway does not have.
    func testMixedCaseBotProfileScopeSurvivesRelaunchVerbatim() async {
        let suite = "BotModeTests.ScopeCase.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let operations = ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-1",
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        )
        let bot = makeBot(name: "Atlas", canonicalID: "stored-1")

        // First launch: the user opens the bot's chat.
        let first = makeBotHarness(reusing: defaults, lifecycleOperations: operations)
        first.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let openedOnFirstLaunch = await first.appState.openBotChat(for: bot)
        XCTAssertTrue(openedOnFirstLaunch)
        XCTAssertEqual(
            first.store.lastSession(for: "default")?.scopeProfile,
            "Atlas",
            "the persisted scope keeps the profile's canonical spelling"
        )

        // Relaunch: a fresh process over the same defaults.
        var resumedProfiles: [String?] = []
        let relaunched = makeBotHarness(
            reusing: defaults,
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
                openSessionWithProfile: { _, id, _, profile in
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            )
        )
        relaunched.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        relaunched.appState.clearBotChatRegistryForTesting()

        await relaunched.appState.syncSession(
            purpose: .preserveCurrent,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedProfiles,
            ["Atlas"],
            "the resume addresses the profile by its canonical name, never a case-folded one"
        )
        XCTAssertEqual(
            relaunched.store.lastSession(for: "default")?.resumeProfileScope,
            "Atlas"
        )
    }

    /// A Bot Chat opened in THIS process is bot evidence even when the roster
    /// never loaded: the runtime registry names the profile its RPCs ride.
    func testProfileOwnershipRecognizesRuntimeRegistryWithoutRoster() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-1",
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let openedTheBotChat = await harness.appState.openBotChat(for: makeBot(name: "Atlas"))
        XCTAssertTrue(openedTheBotChat)
        XCTAssertTrue(harness.appState.botRoster.isEmpty, "no roster was ever loaded")

        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("Atlas"),
            .botOwned,
            "the registry's exact-cased bot profile is recognized"
        )
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("atlas"),
            .botOwned,
            "and case-insensitively, so a differently-cased push cannot slip past"
        )
    }

    /// Without a usable roster, absence of bot evidence proves nothing: the
    /// verdict must be `unverifiable`, never a default "ordinary".
    func testProfileOwnershipIsUnverifiableWithoutUsableRosterEvidence() async {
        var rosterLoaded = false
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            refreshContext: { _, _ in },
            botRoster: { _ in
                rosterLoaded = true
                throw RpcError(code: 5000, message: "state.db is locked")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        XCTAssertTrue(rosterLoaded)
        XCTAssertTrue(harness.appState.botRoster.isEmpty)

        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("analyst"),
            .unverifiable,
            "a failed probe must not read as 'not a bot'"
        )

        // A successfully loaded roster IS usable evidence: absence now means
        // this profile is an ordinary workspace.
        let known = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(bots: [self.makeBot(name: "Atlas", canonicalID: "stored-1")], supportsBotProtocol: false)
            }
        ))
        known.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await known.appState.refreshBotRoster()

        XCTAssertEqual(known.appState.profileOwnershipVerdictForTesting("analyst"), .ordinary)
        XCTAssertEqual(known.appState.profileOwnershipVerdictForTesting("Atlas"), .botOwned)
    }

    /// The push path itself: a bot-owned target fails closed with the Bot Chat
    /// message; a target whose ownership cannot be established fails closed
    /// too (adopting it could hand a bot conversation the workspace's context);
    /// and a verifiably ordinary workspace still proceeds to switch.
    func testNotificationRoutingFailsClosedWithoutOwnershipEvidence() async {
        var resumedIDs: [String] = []
        let unresolved = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                throw RpcError(code: 5000, message: "state.db is locked")
            }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        unresolved.appState.client = HermesClient(connection: connection, profile: "default")
        unresolved.appState.connection = connection
        await unresolved.appState.refreshBotRoster()

        let refused = await unresolved.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "analyst", sessionId: "stored-1", type: "approval")
        )

        XCTAssertFalse(refused, "an unverifiable workspace is not adopted")
        XCTAssertEqual(unresolved.appState.activeProfile, "default")
        XCTAssertTrue(resumedIDs.isEmpty)
        XCTAssertEqual(
            unresolved.appState.errorMessage,
            "Could not verify that workspace for this notification. Reconnect and try again."
        )

        // Verifiably ordinary: the guard lets the switch attempt through, so
        // the failure (if any) is not the Bot Mode refusal.
        let ordinaryTarget = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(bots: [self.makeBot(name: "Atlas", canonicalID: "stored-atlas")], supportsBotProtocol: false)
            },
            findBotChat: { _, _ in [] }
        ))
        ordinaryTarget.appState.client = HermesClient(connection: connection, profile: "default")
        ordinaryTarget.appState.connection = connection
        await ordinaryTarget.appState.refreshBotRoster()

        XCTAssertEqual(
            ordinaryTarget.appState.profileOwnershipVerdictForTesting("analyst"),
            .ordinary
        )
        _ = await ordinaryTarget.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "analyst", sessionId: "stored-1", type: "approval")
        )
        XCTAssertNotEqual(
            ordinaryTarget.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it.",
            "an ordinary workspace is not refused as Bot Mode"
        )
        XCTAssertNotEqual(
            ordinaryTarget.appState.errorMessage,
            "Could not verify that workspace for this notification. Reconnect and try again.",
            "and it is not refused for missing evidence either"
        )
    }

    /// A gateway that cannot list profiles has no Bot Mode at all — the probe
    /// IS `profiles.list` — so no profile on it can be a bot's. Refusing every
    /// cross-profile route there would break working routing to protect against
    /// bots that cannot exist.
    func testProfileOwnershipTreatsUnsupportedGatewayAsOrdinary() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            refreshContext: { _, _ in },
            botRoster: { _ in
                throw RpcError(code: -32601, message: "unknown method: profiles.list")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()

        XCTAssertEqual(harness.appState.botModePhase, .gatewayUnsupported)
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("analyst"),
            .ordinary,
            "a gateway without Bot Mode cannot host bot profiles"
        )
    }

    /// The ownership evidence is cached for the render/event paths, so a
    /// registry mutation must be reflected immediately: a stale cache would
    /// read a just-opened Bot Chat's profile as an ordinary workspace and let
    /// the push guard fail open.
    func testOwnershipEvidenceCacheIsInvalidatedByRegistryMutation() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-1",
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // Prime the cache with no evidence at all…
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("Atlas"),
            .unverifiable
        )

        // …then open a bot chat, which registers the profile its RPCs ride.
        let opened = await harness.appState.openBotChat(for: makeBot(name: "Atlas"))
        XCTAssertTrue(opened)

        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("Atlas"),
            .botOwned,
            "the freshly registered scope is visible without a roster"
        )

        // And clearing the registry is reflected too.
        harness.appState.clearBotChatRegistryForTesting()
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("Atlas"),
            .unverifiable
        )
    }

    /// A roster retained across a FAILED refresh is stale in the one direction
    /// that matters: a bot registered since the last success is missing from it,
    /// so absence stops being evidence. The verdict must go back to
    /// `unverifiable` rather than reading that bot's profile as an ordinary
    /// workspace.
    func testStaleRosterAfterFailedRefreshIsNotAbsenceEvidence() async {
        var shouldFail = false
        let bot = makeBot(name: "Atlas", canonicalID: "stored-atlas")
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            refreshContext: { _, _ in },
            botRoster: { _ in
                if shouldFail {
                    throw RpcError(code: 5000, message: "state.db is locked")
                }
                return BotRosterSnapshot(bots: [bot], supportsBotProtocol: false)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("analyst"),
            .ordinary,
            "a verified roster makes absence meaningful"
        )

        // The next refresh fails; the roster stays on screen (stale).
        shouldFail = true
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["Atlas"], "the roster is retained")
        guard case .failed = harness.appState.botModePhase else {
            return XCTFail("expected a failed refresh phase, got \(harness.appState.botModePhase)")
        }

        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("analyst"),
            .unverifiable,
            "a bot added since the last successful refresh could be missing from the stale roster"
        )
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("Atlas"),
            .botOwned,
            "positive evidence from the retained roster still counts"
        )
    }

    /// A mixed-case bot profile whose canonical row is stamped with a
    /// differently-cased owner is still that bot's canonical chat: the row
    /// hygiene check compares like `ownsProfile` does, not case-sensitively.
    func testCanonicalRowOwnerMatchingIsCaseInsensitive() {
        let bot = makeBot(name: "Atlas", canonicalID: "stored-atlas")
        let row = makeSessionSummary(
            id: "runtime-row",
            title: BotMode.canonicalChatTitle,
            storedID: nil,
            profile: "atlas"
        )

        XCTAssertTrue(BotChatHygiene.isCanonicalBotChatRow(row, roster: [bot]))
        XCTAssertTrue(
            BotChatHygiene.ordinaryResumeCandidates([row], roster: [bot]).isEmpty,
            "and it is therefore never an ordinary resume candidate"
        )
    }

    /// A roster loaded at connect is not evidence about what the gateway knows
    /// NOW: a bot registered since then is missing from it, and its profile
    /// would read as an ordinary workspace. The routing decision therefore
    /// refreshes the roster itself, so the absence it reads is current.
    func testRoutingRefreshesRosterBeforeTrustingAbsence() async {
        var botRegistered = false
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: botRegistered ? [self.makeBot(name: "Atlas", canonicalID: "stored-atlas")] : [],
                    supportsBotProtocol: false
                )
            }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.connection = connection

        // Connect-time load: the gateway knows no bots yet.
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)
        XCTAssertTrue(harness.appState.botRoster.isEmpty)

        // The bot is registered on the gateway, with no client-side refresh.
        botRegistered = true

        let routed = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "Atlas", sessionId: "stored-atlas", type: "approval")
        )

        XCTAssertFalse(routed, "the profile became a bot's between the load and the decision")
        XCTAssertEqual(harness.appState.activeProfile, "default")
        XCTAssertTrue(resumedIDs.isEmpty)
        XCTAssertEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it."
        )
    }

    /// The decision-time refresh must not break the ordinary case: a target that
    /// is still absent from the refreshed roster is a workspace.
    func testRoutingStillProceedsForWorkspaceAbsentFromFreshRoster() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [self.makeBot(name: "Atlas", canonicalID: "stored-atlas")],
                    supportsBotProtocol: false
                )
            },
            findBotChat: { _, _ in [] }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.connection = connection

        _ = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "analyst", sessionId: "stored-1", type: "approval")
        )

        XCTAssertNotEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it.",
            "an ordinary workspace is never refused as Bot Mode"
        )
        XCTAssertNotEqual(
            harness.appState.errorMessage,
            "Could not verify that workspace for this notification. Reconnect and try again.",
            "and the fresh roster is usable evidence, not unverifiable"
        )
    }

    /// `profiles.list` lists EVERY Hermes profile, the default and the active
    /// workspace included, and the notifier stamps its profile on every push.
    /// A reply (or a background turn) in an ordinary conversation of the
    /// workspace on screen must still open: only the conversation being a
    /// bot's canonical chat makes a push a Bot Chat decision.
    func testPushForWorkspaceConversationOpensWhenItsProfileIsOnTheRoster() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSession: { _, id, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [
                        self.makeBot(name: "default", canonicalID: "default-bot-chat"),
                        self.makeBot(name: "Atlas", canonicalID: "stored-atlas")
                    ],
                    supportsBotProtocol: false
                )
            }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.connection = connection
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.activeProfile, "default")

        let routed = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "default", sessionId: "ordinary-1", type: "response")
        )

        XCTAssertTrue(routed, "a workspace conversation opens even though its profile is on the roster")
        XCTAssertNotEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it."
        )
        XCTAssertEqual(resumedIDs, ["ordinary-1"])
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-1")

        // The same profile's canonical Bot Chat is still refused.
        let refused = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "default", sessionId: "default-bot-chat", type: "approval")
        )
        XCTAssertFalse(refused)
        XCTAssertEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it."
        )
    }

    /// Crossing into another profile that is on the roster is still a workspace
    /// switch when the conversation is not that profile's Bot Chat.
    func testPushForOtherWorkspaceIsNotRefusedBecauseItsProfileIsOnTheRoster() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [self.makeBot(name: "Atlas", canonicalID: "stored-atlas")],
                    supportsBotProtocol: false
                )
            },
            findBotChat: { _, _ in [] }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.connection = connection
        await harness.appState.refreshBotRoster()

        _ = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "Atlas", sessionId: "atlas-workspace-1", type: "response")
        )

        XCTAssertNotEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it.",
            "an ordinary conversation of a rostered profile is not a Bot Chat"
        )
        XCTAssertNotEqual(
            harness.appState.errorMessage,
            "Could not verify that workspace for this notification. Reconnect and try again."
        )
    }

    /// A Bot Chat that compacted after the roster was read is known to the
    /// roster only by its old canonical id. The target profile's canonical
    /// lookup reports the lineage tip, so the push is refused BEFORE the
    /// dashboard adopts the bot's profile; a failed lookup fails closed.
    func testCrossProfilePushForCompactedBotChatIsRefusedBeforeTheSwitch() async {
        var lookupFails = false
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [self.makeBot(name: "Atlas", canonicalID: "stored-atlas")],
                    supportsBotProtocol: false
                )
            },
            findBotChat: { _, _ in
                if lookupFails { throw RpcError(code: 5000, message: "state.db is locked") }
                return [BotChatLookupRow(
                    id: "stored-atlas",
                    resolvedID: "atlas-tip",
                    title: BotMode.canonicalChatTitle
                )]
            }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.connection = connection
        await harness.appState.refreshBotRoster()

        let refused = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "Atlas", sessionId: "atlas-tip", type: "response")
        )
        XCTAssertFalse(refused)
        XCTAssertEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it."
        )
        XCTAssertEqual(harness.appState.activeProfile, "default", "the bot's profile was never adopted")

        lookupFails = true
        let unverified = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "Atlas", sessionId: "atlas-other", type: "response")
        )
        XCTAssertFalse(unverified)
        XCTAssertEqual(
            harness.appState.errorMessage,
            "Could not verify that workspace for this notification. Reconnect and try again."
        )
        XCTAssertEqual(harness.appState.activeProfile, "default")
    }

    /// A padded id must resolve in the registry wherever it is looked up: the
    /// keys are normalized on write, so the scope fast path and the identity
    /// guard have to normalize their queries too, or a Bot Chat reads as an
    /// ordinary conversation in one of them.
    func testPaddedSessionIDStillResolvesAsBotConversation() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-1",
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))
        XCTAssertTrue(opened)

        XCTAssertEqual(harness.appState.botConversationProfileForTesting("runtime-1"), "atlas")
        XCTAssertEqual(
            harness.appState.botConversationProfileForTesting("  runtime-1  "),
            "atlas",
            "the padded spelling resolves through the same normalization the keys use"
        )
        XCTAssertNil(harness.appState.botConversationProfileForTesting("   "))
    }

    /// Refusal folds case, so a name that differs only in casing may be an
    /// unrelated workspace: the user is told that instead of being told the
    /// decision belongs to a Bot Chat.
    func testCaseInsensitiveOnlyMatchReportsItsOwnReason() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [self.makeBot(name: "Atlas", canonicalID: "stored-atlas")],
                    supportsBotProtocol: false
                )
            }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.connection = connection

        // Exactly the bot's spelling: the Bot Chat message.
        _ = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "Atlas", sessionId: "stored-atlas", type: "approval")
        )
        XCTAssertEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it."
        )

        // A different spelling that only matches with case folded: its own reason.
        _ = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "atlas", sessionId: "stored-atlas", type: "approval")
        )
        XCTAssertEqual(
            harness.appState.errorMessage,
            "Could not tell this notification's workspace apart from a Bot Chat. Open Bots or the workspace list to continue."
        )
    }

    /// An UNTYPED (pre-v2) reference cannot authorise the catalog-absent escape
    /// hatch while bot evidence is unreadable: the id might name a bot chat a
    /// build without kinds wrote there, and resuming it as this workspace's
    /// conversation is the fail-open this PR closes. Our own typed writes keep
    /// the escape hatch.
    func testUntypedReferenceDeclinesTheCatalogAbsentEscapeHatchWithoutEvidence() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                // A v1 payload: a bare id, migrated as an untyped reference.
                defaults.set(try? JSONSerialization.data(withJSONObject: [
                    "version": 1,
                    "behavior": "continueWhereLeftOff",
                    "lastSessionIDsByProfile": ["default": "stored-ambiguous"],
                    "snapshots": []
                ]), forKey: ChatResumeStore.defaultStorageKey)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
                openSessionWithProfile: { _, id, _, _ in
                    resumedIDs.append(id)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    throw RpcError(code: 5000, message: "state.db is locked")
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        XCTAssertTrue(harness.store.lastSession(for: "default")?.isUnverified ?? false)

        // Bot evidence is unreadable (the probe failed), so the ambiguous id is
        // not resumed; the workspace falls back to its newest conversation.
        await harness.appState.refreshBotRoster()
        guard case .failed = harness.appState.botModePhase else {
            return XCTFail("expected a failed probe, got \(harness.appState.botModePhase)")
        }
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertFalse(
            resumedIDs.contains("stored-ambiguous"),
            "an untyped id is not authority while bot evidence is unavailable: \(resumedIDs)"
        )
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-1")
    }

    /// The same untyped reference IS resumed once bot evidence is readable and
    /// the id is not a bot's — the escape hatch exists for a conversation the
    /// catalog has not indexed yet.
    func testUntypedReferenceKeepsTheEscapeHatchWithUsableEvidence() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(try? JSONSerialization.data(withJSONObject: [
                    "version": 1,
                    "behavior": "continueWhereLeftOff",
                    "lastSessionIDsByProfile": ["default": "stored-just-created"],
                    "snapshots": []
                ]), forKey: ChatResumeStore.defaultStorageKey)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
                openSessionWithProfile: { _, id, _, _ in
                    resumedIDs.append(id)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    BotRosterSnapshot(
                        bots: [self.makeBot(name: "atlas", canonicalID: "stored-other")],
                        supportsBotProtocol: false
                    )
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["stored-just-created"])
        XCTAssertEqual(harness.appState.activeSessionId, "stored-just-created")
    }

    /// A typed (v2) reference is authoritative on its own: it carries the kind
    /// the app recorded, so an unreadable roster does not demote it.
    func testTypedReferenceKeepsTheEscapeHatchWithoutEvidence() async {
        var resumedIDs: [String] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                ChatResumeStore(defaults: defaults).setLastSessionID("stored-typed", for: "default")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
                openSessionWithProfile: { _, id, _, _ in
                    resumedIDs.append(id)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    throw RpcError(code: 5000, message: "state.db is locked")
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        XCTAssertFalse(harness.store.lastSession(for: "default")?.isUnverified ?? true)
        await harness.appState.refreshBotRoster()
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["stored-typed"])
    }

    /// `refreshBotRoster()` ALWAYS suspends (it creates or joins a task), so a
    /// routing attempt must re-prove it still owns the route after it returns.
    /// Without that check, a superseded attempt reads the verdict and writes its
    /// refusal over whatever the newer attempt is doing.
    func testSupersededRoutingAttemptStandsDownAfterTheRosterRefresh() async {
        var supersededDuringRefresh = false
        var appStateRef: AppState?
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                if !supersededDuringRefresh {
                    supersededDuringRefresh = true
                    // A newer tap (or any explicit navigation) takes the route
                    // while this attempt is suspended in its roster refresh.
                    _ = appStateRef?.requestOpenSession("ordinary-1")
                    // Let the newer navigation establish its transition.
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return BotRosterSnapshot(
                    bots: [self.makeBot(name: "Atlas", canonicalID: "stored-atlas")],
                    supportsBotProtocol: false
                )
            }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.connection = connection
        appStateRef = harness.appState

        let routed = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "Atlas", sessionId: "stored-atlas", type: "approval")
        )

        XCTAssertTrue(supersededDuringRefresh)
        XCTAssertFalse(routed)
        XCTAssertNotEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it.",
            "a superseded attempt must not publish its refusal over the newer navigation"
        )
        XCTAssertNotEqual(
            harness.appState.errorMessage,
            "Could not verify that workspace for this notification. Reconnect and try again."
        )
        XCTAssertEqual(harness.appState.activeProfile, "default")
    }

    /// An UNTYPED (v1) selection whose bot evidence is unreadable must not adopt
    /// a CATALOG row either: the row may be a bot chat this workspace cannot
    /// identify (a canonical chat whose title moved on wears no reserved title),
    /// so the selection falls through to the ordinary candidates instead.
    func testUntypedSelectionDoesNotAdoptACatalogRowWithoutEvidence() async {
        var resumedIDs: [String] = []
        // A lineage tip of a canonical chat: the stored value names its durable
        // row, and nothing in the title says "Bot Chat".
        let tipRow = SessionSummary(
            // The listing carries the canonical chat under the DURABLE id the
            // store persists, with the live runtime as an alias — so without the
            // authority gate the saved-id match resolves and adopts this row.
            id: "stored-of-the-tip",
            storedSessionId: nil,
            alternateIds: ["runtime-tip"],
            title: "Weekly digest",
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: 100,
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: "canonical-root"
        )
        let ordinaryRow = makeSessionSummary(id: "ordinary-1", title: "Design review", lastActivityAt: 900)
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(try? JSONSerialization.data(withJSONObject: [
                    "version": 1,
                    "behavior": "continueWhereLeftOff",
                    "lastSessionIDsByProfile": ["default": "stored-of-the-tip"],
                    "snapshots": []
                ]), forKey: ChatResumeStore.defaultStorageKey)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    [tipRow, ordinaryRow]
                },
                openSessionWithProfile: { _, id, _, _ in
                    resumedIDs.append(id)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    throw RpcError(code: 5000, message: "state.db is locked")
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // The untyped pointer names the tip's durable id, and the catalog lists
        // that row: without the authority gate the saved-id match would adopt it.
        harness.appState.sessions = [tipRow, ordinaryRow]
        await harness.appState.refreshBotRoster()
        guard case .failed = harness.appState.botModePhase else {
            return XCTFail("expected a failed probe, got \(harness.appState.botModePhase)")
        }
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedIDs,
            ["ordinary-1"],
            "an untyped id does not adopt a catalog row it cannot identify: \(resumedIDs)"
        )
    }

    /// The mirror: with usable evidence the same untyped pointer DOES select its
    /// catalog row (the row is not bot-owned, and the user asked to continue
    /// where they left off).
    func testUntypedSelectionAdoptsItsCatalogRowWithEvidence() async {
        var resumedIDs: [String] = []
        let storedRow = makeSessionSummary(id: "stored-plain", title: "Where I left off", lastActivityAt: 100)
        let ordinaryRow = makeSessionSummary(id: "ordinary-1", title: "Design review", lastActivityAt: 900)
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(try? JSONSerialization.data(withJSONObject: [
                    "version": 1,
                    "behavior": "continueWhereLeftOff",
                    "lastSessionIDsByProfile": ["default": "stored-plain"],
                    "snapshots": []
                ]), forKey: ChatResumeStore.defaultStorageKey)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [storedRow, ordinaryRow] },
                openSessionWithProfile: { _, id, _, _ in
                    resumedIDs.append(id)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    BotRosterSnapshot(
                        bots: [self.makeBot(name: "atlas", canonicalID: "stored-other")],
                        supportsBotProtocol: false
                    )
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(resumedIDs, ["stored-plain"])
        XCTAssertEqual(harness.appState.activeSessionId, "stored-plain")
    }

    /// A selection recorded while Bot Mode could not be probed is a GUESS: a bot
    /// chat can be sitting in the workspace store during that window, so the
    /// write is recorded UNVERIFIED rather than as a typed ordinary
    /// conversation. Otherwise the next launch would trust the guess for good,
    /// and the catalog-lags escape hatch would carry it forward.
    func testEvidenceBlindSelectionIsRecordedUnverified() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                throw RpcError(code: 5000, message: "state.db is locked")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        guard case .failed = harness.appState.botModePhase else {
            return XCTFail("expected a failed probe, got \(harness.appState.botModePhase)")
        }

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-1")
        XCTAssertEqual(
            harness.store.lastSession(for: "default")?.isUnverified,
            true,
            "an evidence-blind write is unverified, not a typed ordinary selection"
        )

        // With the roster verified, the same flow records a TYPED selection, so
        // the escape hatch keeps working in the normal case.
        let verified = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(bots: [], supportsBotProtocol: false)
            }
        ))
        verified.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await verified.appState.refreshBotRoster()
        XCTAssertEqual(verified.appState.botModePhase, .available)

        await verified.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(verified.appState.activeSessionId, "ordinary-1")
        XCTAssertEqual(
            verified.store.lastSession(for: "default")?.isUnverified,
            false,
            "a selection recorded with verified evidence stays typed"
        )
    }

    /// Roster evidence belongs to the CONNECTION that produced it: a populated
    /// roster carried across a reconnect is not a fresh answer, and both the
    /// resume-path authority gates and the routing verdict read absence from it.
    func testRosterEvidenceIsVerifiedPerConnection() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(
                    bots: [self.makeBot(name: "atlas", canonicalID: "stored-atlas")],
                    supportsBotProtocol: false
                )
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("analyst"),
            .ordinary,
            "a roster the server confirmed on this connection makes absence meaningful"
        )

        // A new connection must re-verify it: the roster stays on screen, but it
        // is no longer evidence about what the server knows now.
        harness.appState.unverifyBotRosterForCurrentConnectionForTesting()
        XCTAssertFalse(
            harness.appState.botRoster.isEmpty,
            "the roster is retained across the boundary…"
        )
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("analyst"),
            .unverifiable,
            "…but it is not absence evidence until the server confirms it again"
        )
    }

    /// A server-side profile name carrying incidental whitespace must behave
    /// identically everywhere it is consumed: the canonical-row hygiene check,
    /// the ownership verdict, and the profile the RPC actually addresses.
    func testPaddedBotProfileNameIsConsistentEverywhere() async {
        let padded = makeBot(name: "  Atlas  ", canonicalID: "stored-atlas")
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            botRoster: { _ in
                BotRosterSnapshot(bots: [padded], supportsBotProtocol: false)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)

        // Every consumer treats "Atlas" as that bot's profile.
        XCTAssertEqual(
            harness.appState.profileOwnershipVerdictForTesting("Atlas"),
            .botOwned,
            "the ownership verdict trims the roster name"
        )
        XCTAssertEqual(
            harness.appState.botProfileMatchForTesting("Atlas")?.isExact,
            true,
            "and reports an exact match rather than a case-only one"
        )

        // The canonical-row hygiene rule agrees (rule 2: reserved title stamped
        // with a roster bot's profile).
        let canonicalRow = makeSessionSummary(
            id: "runtime-row",
            title: BotMode.canonicalChatTitle,
            storedID: nil,
            profile: "Atlas"
        )
        XCTAssertTrue(BotChatHygiene.isCanonicalBotChatRow(canonicalRow, roster: [padded]))
        XCTAssertTrue(
            BotChatHygiene.ordinaryResumeCandidates([canonicalRow], roster: [padded]).isEmpty
        )
    }

    /// Absence evidence decides something only for an UNVERIFIED reference, and
    /// when it does, it must be evidence from NOW: the roster is verified per
    /// connection, so a bot registered mid-session would be missing from it and a
    /// legacy pointer would look resolved. The resume path re-verifies in exactly
    /// that case — and then heals the pointer instead of adopting it.
    func testUnverifiedReferenceReverifiesRosterBeforeTrustingAbsence() async {
        var botRegistered = false
        var resumedIDs: [String] = []
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(try? JSONSerialization.data(withJSONObject: [
                    "version": 1,
                    "behavior": "continueWhereLeftOff",
                    "lastSessionIDsByProfile": ["default": "stored-of-the-tip"],
                    "snapshots": []
                ]), forKey: ChatResumeStore.defaultStorageKey)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
                openSessionWithProfile: { _, id, _, profile in
                    resumedIDs.append(id)
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    BotRosterSnapshot(
                        bots: botRegistered
                            ? [self.makeBot(name: "Atlas", canonicalID: "stored-of-the-tip")]
                            : [],
                        supportsBotProtocol: false
                    )
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // Connect-time verification: the gateway knows no bots yet.
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)

        // The bot's canonical chat appears mid-session, under the id the legacy
        // pointer names.
        botRegistered = true
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedProfiles,
            ["Atlas"],
            "the re-verified roster identifies the pointer as a Bot Chat"
        )
        XCTAssertEqual(resumedIDs, ["stored-of-the-tip"])
        XCTAssertEqual(
            harness.store.lastSession(for: "default")?.kind,
            SessionReference.Kind.bot,
            "and the legacy pointer is healed rather than adopted as ordinary"
        )
    }

    /// A push carries the profile NAME. When that name is a bot's, it must not
    /// ride in under a workspace whose name differs only by case — least of all
    /// when the case-insensitive resolution lands on the ACTIVE workspace, which
    /// skips the cross-profile refusal entirely.
    func testPushNamingBotProfileIsRefusedEvenWhenItResolvesToTheActiveWorkspace() async {
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set("atlas", forKey: "conduit.activeProfile")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.makeSessionSummary(id: "ordinary-1", title: "Design review")] },
                openSessionWithProfile: { _, id, _, _ in
                    SessionResumeResult(
                        sessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    BotRosterSnapshot(
                        bots: [self.makeBot(name: "Atlas", canonicalID: "stored-atlas")],
                        supportsBotProtocol: false
                    )
                }
            )
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.client = HermesClient(connection: connection, profile: "atlas")
        harness.appState.connection = connection
        harness.appState.profiles = ["atlas"]
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.activeProfile, "atlas")

        let routed = await harness.appState.openNotificationTarget(
            ConduitNotificationTarget(profile: "Atlas", sessionId: "stored-atlas", type: "approval")
        )

        XCTAssertFalse(routed, "the bot's decision is not routed into the workspace it collides with")
        XCTAssertEqual(
            harness.appState.errorMessage,
            "This decision belongs to a Bot Chat. Open Bots to answer it."
        )
    }

    /// The catalog-PRESENT twin of the re-verification test, and the one that can
    /// tell stale evidence from fresh: the refreshed roster discovers the bot
    /// while the conversation's row is ALREADY in the catalog under a
    /// non-reserved title, so title hygiene cannot save it and the only thing
    /// standing between the workspace and the bot's conversation is that healing
    /// read the POST-refresh ownership. With a stale snapshot the row is adopted
    /// as an ordinary conversation of this workspace (workspace scope, no bot
    /// registration); with fresh evidence it heals to `.bot`, the Bot Mode open
    /// runs, and the resume addresses the bot's profile by its exact name.
    func testCatalogPresentBotChatHealsFromFreshlyVerifiedOwnership() async {
        var botRegistered = false
        var resumedIDs: [String] = []
        var resumedProfiles: [String?] = []
        // The canonical chat's row: listed under the durable id the stored
        // pointer names, with a title that says nothing about Bot Mode and a
        // lineage root for realism.
        let botRow = SessionSummary(
            id: "stored-of-the-tip",
            storedSessionId: nil,
            alternateIds: ["runtime-tip"],
            title: "Weekly digest",
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: 100,
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: "canonical-root"
        )
        // A NEWER ordinary conversation: if the stale snapshot were used, the
        // bot row would not be recognised as bot-owned and would win the
        // saved-id match instead of healing.
        let newerOrdinary = makeSessionSummary(
            id: "ordinary-newer",
            title: "Design review",
            lastActivityAt: 900
        )
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                // An UNVERIFIED (v1) selection naming the bot chat's row.
                defaults.set(try? JSONSerialization.data(withJSONObject: [
                    "version": 1,
                    "behavior": "continueWhereLeftOff",
                    "lastSessionIDsByProfile": ["default": "stored-of-the-tip"],
                    "snapshots": []
                ]), forKey: ChatResumeStore.defaultStorageKey)
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [botRow, newerOrdinary] },
                openSessionWithProfile: { _, id, _, profile in
                    resumedIDs.append(id)
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in
                    BotRosterSnapshot(
                        bots: botRegistered
                            ? [self.makeBot(name: "Atlas", canonicalID: "stored-of-the-tip")]
                            : [],
                        supportsBotProtocol: false
                    )
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        // Connect-time verification knows no bots; the catalog already carries
        // the canonical chat's row.
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)
        XCTAssertEqual(harness.appState.botRoster.map(\.name), [])
        XCTAssertTrue(harness.store.lastSession(for: "default")?.isUnverified ?? false)

        // The bot appears on the gateway mid-session, and only the sync's own
        // re-verification can see it.
        botRegistered = true
        harness.appState.activeSessionId = nil

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            resumedProfiles,
            ["Atlas"],
            "the resume addresses the BOT's profile by its exact name, which a stale snapshot cannot produce"
        )
        XCTAssertEqual(
            resumedIDs,
            ["stored-of-the-tip"],
            "the bot chat is resumed, not the newer ordinary conversation"
        )
        XCTAssertEqual(
            harness.store.lastSession(for: "default")?.kind,
            SessionReference.Kind.bot,
            "and the unverified selection is healed to `.bot`"
        )
        XCTAssertEqual(
            harness.appState.botConversationProfileForTesting("stored-of-the-tip"),
            "Atlas",
            "the bot scope is registered for later re-resumes"
        )
        XCTAssertEqual(
            harness.appState.activeSessionTitle,
            "Atlas",
            "and the bot's label is applied to the restored conversation"
        )
    }

    // MARK: - harness

    /// The UserDefaults suite of the most recent harness, so tests can pin
    /// PERSISTED state (e.g. the active-session title cache), not just the
    /// visible string.
    private var lastHarnessDefaults: UserDefaults?

    /// Builds an AppState over a private defaults suite. `reusing` supplies an
    /// EXISTING suite so a test can simulate a relaunch (a second process
    /// reading the same persisted state); the caller owns that suite's
    /// teardown in that case.
    private func makeBotHarness(
        configureDefaults: (UserDefaults) -> Void = { _ in },
        sessionCatalogLoader: ((Bool) async throws -> [SessionSummary])? = nil,
        reusing reusedDefaults: UserDefaults? = nil,
        lifecycleOperations: ChatResumeLifecycleOperations
    ) -> (appState: AppState, store: ChatResumeStore) {
        let defaults: UserDefaults
        if let reusedDefaults {
            defaults = reusedDefaults
        } else {
            let suite = "BotModeTests.\(UUID().uuidString)"
            guard let created = UserDefaults(suiteName: suite) else {
                fatalError("Failed to create test UserDefaults suite")
            }
            addTeardownBlock {
                created.removePersistentDomain(forName: suite)
            }
            defaults = created
        }
        lastHarnessDefaults = defaults
        configureDefaults(defaults)
        let store = ChatResumeStore(defaults: defaults)
        let coordinator = ChatResumeCoordinator(store: store)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionCatalogLoader: sessionCatalogLoader,
            chatResumeLifecycleOperations: lifecycleOperations
        )
        appState.isConnected = true
        return (appState, store)
    }

    // MARK: - fixtures

    private func makeBot(
        name: String,
        pinned: Bool = false,
        canonicalID: String? = nil,
        resolvedID: String? = nil,
        canonicalLastActive: Double? = nil,
        lastActive: Double? = nil,
        botTitle: String? = nil
    ) -> BotProfile {
        let resolvedCanonicalID = canonicalID
            ?? (canonicalLastActive != nil ? "stored-\(name)" : nil)
        return BotProfile(
            name: name,
            botTitle: botTitle,
            displayName: name,
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: pinned,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: resolvedCanonicalID.map { id in
                BotCanonicalSession(
                    id: id,
                    resolvedID: resolvedID,
                    lastActive: canonicalLastActive,
                    preview: nil
                )
            },
            lastActive: lastActive,
            lastPreview: nil
        )
    }

    private func makeSessionSummary(
        id: String,
        title: String,
        storedID: String? = nil,
        profile: String? = "default",
        lastActivityAt: TimeInterval? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: storedID,
            alternateIds: [],
            title: title,
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: lastActivityAt,
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}
