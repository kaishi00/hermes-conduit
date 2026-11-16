import XCTest
@testable import Conduit

/// The Artifacts screens' list (Artifacts.swift), read from the host's
/// notifier plugin. An extension, so no new class to plan.
@MainActor
extension GatewayRestartTests {
    private func artifactRow(_ fields: [String: Any]) -> [String: Any] {
        var row: [String: Any] = [
            "kind": "image", "source": "delivered", "name": "map.png", "path": "/root/out/map.png",
            "exists": true, "size": 2048, "session_id": "s1", "session_title": "Weekend trip",
            "message_id": 12, "timestamp": 1_760_000_000.0,
        ]
        row.merge(fields) { _, new in new }
        return row
    }

    /// The list as it opens (every kind, unsearched, its first page) is
    /// kept as Hermes gave it, per store, so it opens on it next time
    /// (#1533); a chat's own as one chat's of many. A filtered, searched or
    /// later page isn't, nor an answer the list can't read.
    func testArtifactsKeepTheListAsItOpens() async throws {
        var saved: [String: [String: Any]] = [:]
        let answers = KeptAnswers(
            kept: { saved[$0] },
            keep: { route, _, read in
                let answer = try await read()
                saved[route] = answer
                return answer
            }
        )
        var answer: [String: Any] = ["ok": true, "items": [artifactRow([:])], "next_before": 5]
        var asked: [String] = []
        let client = ArtifactsClient { path in
            asked.append(path)
            return answer
        }
        let profile = ArtifactSource(profile: "work", sessionIDs: [])
        let chat = ArtifactSource(profile: "work", sessionIDs: ["s1"])

        _ = try await client.page(profile, showMissing: false, keptIn: answers)
        _ = try await client.page(chat, keptIn: answers)
        _ = try await client.page(profile, filter: .images, showMissing: false, keptIn: answers)
        _ = try await client.page(profile, query: "map", showMissing: false, keptIn: answers)
        _ = try await client.page(profile, showMissing: false, before: 5, keptIn: answers)

        let profileRoute = try XCTUnwrap(ArtifactsClient.keptRoute(profile, filter: .all, query: " ", showMissing: false))
        XCTAssertEqual(profileRoute, asked[0], "the page as it was asked for")
        XCTAssertEqual(Set(saved.keys), [profileRoute, OfflineChatCacheStore.lastOpenedRoutePrefix + asked[1]])
        XCTAssertNil(ArtifactsClient.keptRoute(profile, filter: .images, query: "", showMissing: false))
        XCTAssertNil(ArtifactsClient.keptRoute(profile, filter: .all, query: "map", showMissing: false))
        let kept = try XCTUnwrap(ArtifactsClient.keptPage(profile, filter: .all, query: "", showMissing: false, in: answers))
        XCTAssertEqual(kept.items.map(\.name), ["map.png"])
        XCTAssertEqual(kept.nextBefore, 5)
        XCTAssertNil(ArtifactsClient.keptPage(profile, filter: .all, query: "", showMissing: true, in: answers),
                     "showing missing files is another list")

        answer = ["ok": false]
        do {
            _ = try await client.page(profile, showMissing: false, keptIn: answers)
            XCTFail("a malformed answer is refused")
        } catch {}
        XCTAssertEqual(ArtifactsClient.keptPage(profile, filter: .all, query: "", showMissing: false, in: answers), kept,
                       "and not kept over the last one")
    }

    func testArtifactsAskForOneChatByEachOfItsIDs() async throws {
        var asked: [String] = []
        let client = ArtifactsClient { path in
            asked.append(path)
            return ["ok": true, "items": [], "next_before": NSNull()]
        }
        _ = try await client.page(profile: "work", sessionIDs: ["tip", "root"], filter: .images,
                                  query: " road trip ", before: 40)
        XCTAssertEqual(
            asked,
            ["/api/plugins/conduit_push/artifacts?limit=60&session_id=root&session_id=tip&kind=images"
                + "&q=road%20trip&before=40&profile=work"]
        )
        _ = try await client.page(profile: "default")
        XCTAssertEqual(asked.last, "/api/plugins/conduit_push/artifacts?limit=60")
    }

    func testArtifactsHideMissingFilesUnlessAsked() async throws {
        var asked: [String] = []
        let rows = [
            artifactRow([:]),
            artifactRow(["exists": false, "path": "/root/gone.pdf", "kind": "document", "name": "gone.pdf"]),
            artifactRow(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                         "name": "Curate", "exists": false]),
        ]
        // An older plugin lists missing files whatever it was asked.
        let client = ArtifactsClient { path in
            asked.append(path)
            return ["ok": true, "items": rows, "next_before": 5]
        }
        let hidden = try await client.page(profile: "default", showMissing: false)
        XCTAssertEqual(asked.last, "/api/plugins/conduit_push/artifacts?limit=60&missing=hide")
        XCTAssertEqual(hidden.items.map(\.name), ["map.png", "Curate"], "a link has no file to miss")
        XCTAssertEqual(hidden.nextBefore, 5, "a page the filter emptied still pages on")
        XCTAssertTrue(hidden.items[1].exists, "a link is never shown as missing")
        let emptied = try ArtifactsClient.parse(["ok": true, "items": [rows[1]], "next_before": 3], showMissing: false)
        XCTAssertTrue(emptied.items.isEmpty)
        XCTAssertEqual(emptied.nextBefore, 3, "a page the filter emptied still pages on")
        let shown = try await client.page(profile: "default", showMissing: true)
        XCTAssertEqual(asked.last, "/api/plugins/conduit_push/artifacts?limit=60")
        XCTAssertEqual(shown.items.map(\.name), ["map.png", "gone.pdf", "Curate"])

        let key = ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "", showMissing: false)
        let showing = ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "", showMissing: true)
        XCTAssertNotEqual(key, showing, "the toggle reads the list again")
        XCTAssertTrue(showing.showsRows(of: key))
        XCTAssertTrue(ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "").showMissing,
                      "a key without the setting lists everything, as the host does")
    }

    func testArtifactListsBelongToTheirDashboard() {
        let first = UUID()
        let second = UUID()
        let onFirst = ArtifactsListKey(dashboard: first, profile: "default", filter: .all, query: "")
        let onSecond = ArtifactsListKey(dashboard: second, profile: "default", filter: .all, query: "")
        let imagesOnFirst = ArtifactsListKey(dashboard: first, profile: "default", filter: .images, query: "")

        // Every server has a "default" profile: switching servers reads the list again...
        XCTAssertNotEqual(onFirst, onSecond)
        // ...and doesn't leave the other server's rows up while it does.
        XCTAssertFalse(onSecond.showsRows(of: onFirst))
        XCTAssertTrue(imagesOnFirst.showsRows(of: onFirst), "another filter keeps the rows up, dimmed")

        XCTAssertNotEqual(
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "default", path: "/root/out/map.png"),
            ArtifactsListKey.thumbnailCacheKey(dashboard: second, profile: "default", path: "/root/out/map.png")
        )
        XCTAssertNotEqual(
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "default", path: "/root/out/map.png"),
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "work", path: "/root/out/map.png")
        )
        XCTAssertEqual(
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "default", path: "/root/out/map.png"),
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "default", path: "/root/out/map.png")
        )
    }

    func testArtifactsParseFilesAndLinksAndSkipBrokenRows() throws {
        let page = try ArtifactsClient.parse([
            "ok": true,
            "items": [
                artifactRow([:]),
                artifactRow(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                              "host": "curate.example", "name": "Curate", "message_id": 11]),
                artifactRow(["kind": "link", "source": "link", "path": NSNull(), "url": "javascript:alert(1)"]),
                artifactRow(["kind": "sticker"]),
                artifactRow(["path": NSNull()]),
                artifactRow(["timestamp": NSNull(), "path": "/root/undated.png"]),
                artifactRow(["exists": false, "path": "/root/gone.pdf", "kind": "document", "name": "gone.pdf"]),
            ],
            "next_before": 9,
        ])
        XCTAssertEqual(page.nextBefore, 9)
        XCTAssertEqual(page.items.map(\.name), ["map.png", "Curate", "gone.pdf"])
        XCTAssertEqual(page.items[0].size, 2048)
        XCTAssertTrue(page.items[0].isVisual)
        XCTAssertEqual(page.items[1].url?.host(), "curate.example")
        XCTAssertNil(page.items[1].path)
        XCTAssertFalse(page.items[2].exists)
        XCTAssertThrowsError(try ArtifactsClient.parse(["ok": false]))
    }

    func testArtifactPagesMergeEachArtifactOnce() throws {
        let first = try ArtifactsClient.parse(["ok": true, "items": [artifactRow([:])]]).items
        let older = try ArtifactsClient.parse(["ok": true, "items": [
            artifactRow(["message_id": 3]),
            artifactRow(["path": "/root/older.png", "name": "older.png", "message_id": 2]),
        ]]).items
        let merged = ArtifactsClient.merged(first, with: older)
        XCTAssertEqual(merged.map(\.name), ["map.png", "older.png"])
        XCTAssertEqual(merged.first?.messageID, 12)
        let repeated = try ArtifactsClient.parse(["ok": true, "items": [artifactRow([:]), artifactRow(["message_id": 3])]])
        XCTAssertEqual(repeated.items.map(\.messageID), [12])
    }

    func testArtifactFiltersMatchTheHostsGroups() {
        XCTAssertTrue(ArtifactFilter.images.includes(.video))
        XCTAssertTrue(ArtifactFilter.files.includes(.audio))
        XCTAssertFalse(ArtifactFilter.files.includes(.page))
        XCTAssertNil(ArtifactFilter.all.hostKind)
        XCTAssertEqual(ArtifactFilter.links.hostKind, "links")
    }

    func testArtifactsGroupByDayNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let items = try ArtifactsClient.parse(["ok": true, "items": [
            artifactRow(["timestamp": 1_760_090_000.0, "path": "/a.png"]),
            artifactRow(["timestamp": 1_760_086_500.0, "path": "/b.png"]),
            artifactRow(["timestamp": 1_760_000_000.0, "path": "/c.png"]),
        ]]).items
        let days = ArtifactsClient.days(items, calendar: calendar)
        XCTAssertEqual(days.map { $0.items.map(\.id) }, [["/a.png", "/b.png"], ["/c.png"]])
    }

    func testShowInChatFindsTheMessageOrTheOneBeforeIt() {
        func row(_ id: String, _ rowId: Int?) -> ChatMessage {
            var message = ChatMessage(id: id, role: .assistant, content: "", timestamp: "")
            message.rowId = rowId
            return message
        }
        let messages = [row("u", 10), row("tool", nil), row("a", 14)]
        XCTAssertEqual(ArtifactReveal.rowID(for: 14, in: messages), "a")
        // A tool call split off message 12 shows the turn before it.
        XCTAssertEqual(ArtifactReveal.rowID(for: 12, in: messages), "u")
        XCTAssertNil(ArtifactReveal.rowID(for: 5, in: messages))
    }

    func testArtifactsPageMergesBotChatsNewestFirst() throws {
        func item(_ path: String, _ time: Double) -> ArtifactItem {
            ArtifactItem(artifactRow(["path": path, "timestamp": time]))!
        }
        let sources = [
            ArtifactSource(profile: "default", sessionIDs: []),
            ArtifactSource(profile: "atlas", sessionIDs: ["bot-chat"], label: "Atlas", isBotChat: true),
        ]
        var feed = ArtifactFeed(sources: sources, pages: [
            ArtifactPage(items: [item("/w1", 100), item("/w2", 80)], nextBefore: 7),
            ArtifactPage(items: [item("/b1", 90), item("/b2", 50), item("/w2", 40)], nextBefore: nil),
        ])
        // The workspace may still hold rows between 80 and 50, so the bot's
        // older rows wait for its next page.
        XCTAssertEqual(feed.items.map(\.id), ["/w1", "/b1", "/w2"])
        XCTAssertEqual(feed.items[1].otherProfile, "atlas")
        XCTAssertEqual(feed.items[1].otherProfileLabel, "Atlas")
        XCTAssertTrue(feed.items[1].isBotChat)
        XCTAssertNil(feed.items[0].otherProfile)
        XCTAssertEqual(feed.nextCursor, ArtifactFeed.Cursor(source: 0, before: 7))
        feed.append(ArtifactPage(items: [item("/w3", 60)], nextBefore: nil), at: ArtifactFeed.Cursor(source: 0, before: 7))
        XCTAssertNil(feed.nextCursor)
        XCTAssertEqual(feed.items.map(\.id), ["/w1", "/b1", "/w2", "/w3", "/b2"],
                       "a file both stores list shows once, at its newest mention")
        // A stale page doesn't land twice.
        let before = feed
        feed.append(ArtifactPage(items: [item("/w9", 10)], nextBefore: nil), at: ArtifactFeed.Cursor(source: 0, before: 7))
        XCTAssertEqual(feed, before)
    }

    func testArtifactsFeedReadsAnEmptyStoreBeforeShowingOlderRows() {
        let sources = [
            ArtifactSource(profile: "default", sessionIDs: []),
            ArtifactSource(profile: "atlas", sessionIDs: ["bot-chat"], label: "Atlas", isBotChat: true),
        ]
        let feed = ArtifactFeed(sources: sources, pages: [
            ArtifactPage(items: [], nextBefore: 30),
            ArtifactPage(items: [ArtifactItem(artifactRow(["path": "/b1"]))!], nextBefore: 9),
        ])
        XCTAssertTrue(feed.items.isEmpty, "a page the filter emptied may still hold newer rows")
        XCTAssertEqual(feed.nextCursor, ArtifactFeed.Cursor(source: 0, before: 30))
        // A store that couldn't be read adds nothing and pages no further.
        let partial = ArtifactFeed(sources: sources, pages: [
            ArtifactPage(items: [ArtifactItem(artifactRow(["path": "/w1"]))!], nextBefore: nil), nil,
        ])
        XCTAssertEqual(partial.items.map(\.id), ["/w1"])
        XCTAssertNil(partial.nextCursor)
    }

    func testArtifactsOneStoreKeepsTheHostsOrder() {
        let rows = ["/c", "/a", "/b"].map { ArtifactItem(artifactRow(["path": $0]))! }
        let feed = ArtifactFeed(sources: [ArtifactSource(profile: "default", sessionIDs: [])],
                                pages: [ArtifactPage(items: rows, nextBefore: 4)])
        XCTAssertEqual(feed.items.map(\.id), ["/c", "/a", "/b"])
        XCTAssertEqual(feed.nextCursor, ArtifactFeed.Cursor(source: 0, before: 4))
    }

    func testArtifactsNameABotChatInAProfileReadWhole() {
        let source = ArtifactSource(profile: "atlas", sessionIDs: [], label: "Atlas Work",
                                    botChatIDs: ["bot-chat"], botLabel: "Atlas")
        let rows = [
            ArtifactItem(artifactRow(["path": "/a", "session_id": "bot-chat"]))!,
            ArtifactItem(artifactRow(["path": "/b", "session_id": "other"]))!,
        ]
        let items = ArtifactFeed(sources: [source], pages: [ArtifactPage(items: rows, nextBefore: nil)]).items
        XCTAssertEqual(items.map(\.isBotChat), [true, false])
        XCTAssertEqual(items.map(\.otherProfileLabel), ["Atlas", "Atlas Work"])
        XCTAssertEqual(items.map(\.otherProfile), ["atlas", "atlas"])
        // The profile in use keeps its rows unlabelled, but its Bot Chat
        // still goes by the bot.
        let own = ArtifactSource(profile: "default", sessionIDs: [], botChatIDs: ["bot-chat"], botLabel: "Hermes")
        let ownItems = ArtifactFeed(sources: [own], pages: [ArtifactPage(items: rows, nextBefore: nil)]).items
        XCTAssertEqual(ownItems.map(\.isBotChat), [true, false])
        XCTAssertEqual(ownItems.map(\.otherProfileLabel), ["Hermes", nil])
        XCTAssertEqual(ownItems.map(\.otherProfile), [nil, nil])
    }

    /// The Artifacts list asks the plugin what it serves from its feed and
    /// from Saved as it opens (issue 2516): one status read answers both,
    /// and a read through another bridge isn't joined.
    func testTheListOpenSharesOnePluginStatusRead() async throws {
        let suite = "Artifacts.AppState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let held = HeldDashboardRequests(baseURL: "http://127.0.0.1:1")
        defer { held.releaseAll() }
        appState.dashboardTicketBridge = held.bridge
        let feed = Task { @MainActor in await appState.refreshNotifierPluginStatusOnce() }
        let saved = Task { @MainActor in await appState.refreshNotifierPluginStatusOnce() }
        try await held.waitForRequests(1)
        XCTAssertNotNil(appState.notifierPluginStatusSharedRefresh)

        let other = HeldDashboardRequests(baseURL: "http://127.0.0.1:1")
        defer { other.releaseAll() }
        appState.dashboardTicketBridge = other.bridge
        let otherRead = Task { @MainActor in await appState.refreshNotifierPluginStatusOnce() }
        try await other.waitForRequests(1)
        XCTAssertEqual(other.sent.first?.path, NotifierPluginStatus.path, "another bridge reads for itself")

        held.releaseAll()
        other.releaseAll()
        await feed.value
        await saved.value
        await otherRead.value
        // Counted once both have ended, so a second read either caller
        // sent, however late its cookie lookup let it go, is counted too.
        XCTAssertEqual(held.sent.filter { $0.path == NotifierPluginStatus.path }.count, 1, "one read for both")
        XCTAssertNil(appState.notifierPluginStatusSharedRefresh, "nothing left to join once the reads end")
    }

    /// A Bot Chat has no row in the chat list: its ⋯ menu still finds the
    /// chat's ids, so Artifacts isn't greyed out. An unlisted chat that isn't
    /// a bot's has none.
    func testABotChatsMenuFindsItsArtifactIDs() throws {
        let suite = "Artifacts.AppState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.activeSessionId = "unlisted"
        XCTAssertEqual(appState.activeChatArtifactSessionIDs, [])

        appState.activeSessionId = "bot-runtime"
        appState.noteBotChatSessionForTesting("bot-runtime", profile: "atlas")
        XCTAssertEqual(appState.activeChatArtifactSessionIDs, ["bot-runtime"])
        XCTAssertEqual(appState.artifactSources(for: .chat(appState.activeChatArtifactSessionIDs)).map(\.profile),
                       ["atlas"])
        // Its checklist ticks and card taps go to the bot's store, where its
        // turns hear them, not the profile in use's (issue 2520).
        XCTAssertEqual(appState.activeChatStoreProfile, "atlas")
        appState.activeSessionId = "unlisted"
        XCTAssertEqual(appState.activeChatStoreProfile, appState.activeProfile)
    }

    /// A workstream's chat has no row in the chat list either (it's left to
    /// its bot): open on its bot's profile it still goes by its ids, so its
    /// checklists tick, its cards' taps go and its Artifacts open (issue
    /// 2520). A resolved one known only by the plugin's list counts too;
    /// on another profile it has none, as its store isn't the one in use.
    func testAWorkstreamsChatFindsItsIDs() throws {
        let suite = "Artifacts.AppState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let response: [String: Any] = [
            "ok": true, "policy": "strict", "bot": "Furina",
            "work": [["ref": "W1", "kind": "workstream", "status": "running", "title": "Login bug",
                      "session_id": "20261101_w1", "actions": ["send", "stop"]]],
            "workstream_sessions": ["20261101_w1", "20261031_old"],
        ]
        appState.botWork.set(try XCTUnwrap(BotWorkSnapshot(response: response, profile: "furina")))
        appState.setActiveProfileForTesting("furina")
        appState.activeSessionId = "20261101_w1"
        XCTAssertEqual(appState.activeChatArtifactSessionIDs, ["20261101_w1"])
        XCTAssertEqual(appState.artifactSources(for: .chat(appState.activeChatArtifactSessionIDs)).map(\.profile),
                       ["furina"])
        XCTAssertEqual(appState.activeChatStoreProfile, "furina")
        appState.activeSessionId = "20261031_old"
        XCTAssertEqual(appState.activeChatArtifactSessionIDs, ["20261031_old"])
        appState.activeSessionId = "unlisted"
        XCTAssertEqual(appState.activeChatArtifactSessionIDs, [])

        appState.setActiveProfileForTesting("default")
        appState.activeSessionId = "20261101_w1"
        XCTAssertEqual(appState.activeChatArtifactSessionIDs, [])
    }

    /// A Bot Overview's Artifacts read the bot's whole profile: labelled
    /// as another profile's unless it's the one in use.
    func testABotOverviewReadsItsBotsWholeProfile() throws {
        let suite = "Artifacts.AppState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let other = appState.artifactSources(for: .bot("atlas"))
        XCTAssertEqual(other.map(\.profile), ["atlas"])
        XCTAssertEqual(other.map(\.sessionIDs), [[]])
        XCTAssertNotNil(other.first?.label)
        let own = appState.artifactSources(for: .bot(appState.activeProfile))
        XCTAssertEqual(own.map(\.profile), [appState.activeProfile])
        XCTAssertNil(own.first?.label)
    }

    // MARK: - Saved (issue 2467)

    /// A saved row carries its note, when it was saved and the copy the
    /// host keeps: a file whose original is gone opens that copy, one with
    /// neither can't open, and a link always opens.
    func testSavedArtifactsOpenTheirKeptCopyOnceTheOriginalIsGone() throws {
        let answer: [String: Any] = ["ok": true, "pins": [
            artifactRow(["exists": false, "kept_path": "/root/.hermes/conduit-saved-artifacts/ab/map.png",
                         "note": "trip map", "pinned_at": 1_760_000_500.0]),
            artifactRow(["path": "/root/out/gone.pdf", "kind": "document", "exists": false, "pinned_at": 1_760_000_400.0]),
            artifactRow(["kind": "link", "source": "link", "path": NSNull(), "url": "https://example.com/a",
                         "pinned_at": 1_760_000_300.0]),
        ]]
        let items = try ArtifactPinsClient.parse(answer)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].note, "trip map")
        XCTAssertEqual(items[0].openPath, "/root/.hermes/conduit-saved-artifacts/ab/map.png")
        XCTAssertTrue(items[0].canOpen)
        XCTAssertEqual(items[0].id, "/root/out/map.png", "one artifact, by its original path")
        XCTAssertEqual(items[0].savedAt, Date(timeIntervalSince1970: 1_760_000_500))
        XCTAssertNil(items[1].openPath)
        XCTAssertFalse(items[1].canOpen)
        XCTAssertTrue(items[2].canOpen)
        XCTAssertThrowsError(try ArtifactPinsClient.parse(["ok": true]))

        let live = try XCTUnwrap(ArtifactItem(artifactRow([:])))
        XCTAssertEqual(live.openPath, "/root/out/map.png", "the original while the host has it")
    }

    /// Saved lists what each store covers: a store read for some chats
    /// only theirs. The one saved last comes first, each artifact once (its
    /// newest pin, from the store that holds it), another profile's under
    /// its name, and the search reads notes too.
    func testSavedListsWhatTheListsStoresCover() throws {
        func saved(_ path: String, session: String, at: Double, note: String? = nil,
                   kind: String = "image") throws -> ArtifactItem {
            var row = artifactRow(["path": path, "session_id": session, "pinned_at": at, "kind": kind])
            if let note { row["note"] = note }
            return try XCTUnwrap(ArtifactItem(savedRow: row))
        }
        let work = [try saved("/a.png", session: "s1", at: 10), try saved("/b.png", session: "s2", at: 30, note: "wedding")]
        let atlas = [try saved("/c.png", session: "bot", at: 20), try saved("/d.png", session: "other", at: 40),
                     try saved("/a.png", session: "bot", at: 50, note: "lisbon")]
        let sources = [
            ArtifactSource(profile: "work", sessionIDs: []),
            ArtifactSource(profile: "atlas", sessionIDs: ["bot"], label: "Atlas", isBotChat: true),
        ]
        let items = ArtifactPinsClient.items(sources: sources, saved: [work, atlas])
        XCTAssertEqual(items.map(\.path), ["/a.png", "/b.png", "/c.png"])
        XCTAssertEqual(items.first { $0.path == "/c.png" }?.otherProfile, "atlas")
        let both = try XCTUnwrap(items.first { $0.path == "/a.png" })
        XCTAssertEqual(both.otherProfile, "atlas", "the newest pin, from the store that holds it")
        XCTAssertEqual(both.note, "lisbon")
        XCTAssertEqual(ArtifactPinsClient.items(sources: sources, saved: [work, atlas], query: "LISBON").map(\.path),
                       ["/a.png"], "the search reads the newest pin's note")
        XCTAssertEqual(ArtifactPinsClient.items(sources: sources, saved: [work, atlas], query: "WEDD").map(\.path),
                       ["/b.png"])
        XCTAssertEqual(ArtifactPinsClient.items(sources: sources, saved: [nil, atlas]).map(\.path), ["/a.png", "/c.png"],
                       "a store not read adds nothing: only Atlas's Bot Chat pins")
        let mixed = [try saved("/1.png", session: "s1", at: 5), try saved("/2.pdf", session: "s1", at: 4, kind: "document"),
                     try saved("/3.png", session: "s1", at: 3), try saved("/4.png", session: "s1", at: 2)]
        XCTAssertEqual(ArtifactPinsClient.runs(mixed).map { $0.items.map(\.path) },
                       [["/1.png"], ["/2.pdf"], ["/3.png", "/4.png"]], "drawn in the order saved")
        let chat = [ArtifactSource(profile: "work", sessionIDs: ["s1"])]
        XCTAssertEqual(ArtifactPinsClient.items(sources: chat, saved: [work]).map(\.path), ["/a.png"])
    }

    /// Saved opens on the set it read last time, offline too: a readable
    /// answer is kept per profile and read back, a malformed one isn't.
    func testSavedKeepsTheSetItReadLast() async throws {
        var store: [String: [String: Any]] = [:]
        let answers = KeptAnswers(
            kept: { store[$0] },
            keep: { route, _, read in
                let answer = try await read()
                store[route] = answer
                return answer
            }
        )
        var answer: [String: Any] = ["ok": true, "pins": [artifactRow(["note": "trip map", "pinned_at": 1_760_000_500.0])]]
        let client = ArtifactPinsClient { _, _, _ in answer }
        XCTAssertNil(ArtifactPinsClient.kept(profile: "work", in: answers))

        _ = try await client.list(profile: "work", keptIn: answers)
        XCTAssertEqual(ArtifactPinsClient.kept(profile: "work", in: answers)?.map(\.note), ["trip map"])
        XCTAssertNil(ArtifactPinsClient.kept(profile: "atlas", in: answers), "another profile's set is its own")

        answer = ["ok": true]
        do {
            _ = try await client.list(profile: "atlas", keptIn: answers)
            XCTFail("a malformed answer is refused")
        } catch {}
        XCTAssertNil(ArtifactPinsClient.kept(profile: "atlas", in: answers), "and never kept")
        XCTAssertEqual(ArtifactPinsClient.kept(profile: "work", in: answers)?.count, 1)
    }

    /// The host counts Unicode code points, not Swift Characters or UTF-8
    /// bytes: emoji sequences and combining marks use more than one point.
    func testSavedNotesFitTheHostsCodePointLimit() throws {
        let cases: [(String, Int, Int)] = [
            ("a", 201, 200),
            ("界", 201, 200),
            ("👍🏽", 101, 100),
            ("🇺🇸", 101, 100),
            ("👨‍👩‍👧‍👦", 29, 28),
            ("e\u{301}", 101, 100),
        ]
        for (character, count, kept) in cases {
            let note = String(repeating: character, count: count)
            let expected = String(repeating: character, count: kept)
            XCTAssertEqual(ArtifactPinsClient.limitedNote(note), expected)
            let cleaned = try XCTUnwrap(ArtifactPinsClient.cleanNote(note))
            XCTAssertEqual(cleaned, expected)
            XCTAssertLessThanOrEqual(cleaned.unicodeScalars.count, ArtifactPinsClient.maxNoteLength)
        }
    }

    func testSavedNoteClippingKeepsCharactersWholeAndEditorSpacesIntact() {
        let prefix = String(repeating: "a", count: 199)
        for character in ["👍🏽", "🇺🇸", "👨‍👩‍👧‍👦", "e\u{301}"] {
            XCTAssertEqual(ArtifactPinsClient.limitedNote(prefix + character), prefix,
                           "leave room unused rather than split a visible character")
        }
        let oversizedCharacter = "e" + String(repeating: "\u{301}", count: 200)
        XCTAssertEqual(ArtifactPinsClient.limitedNote(oversizedCharacter), "")
        XCTAssertNil(ArtifactPinsClient.cleanNote(oversizedCharacter))
        XCTAssertEqual(ArtifactPinsClient.limitedNote("  for   the site "), "  for   the site ")
        XCTAssertEqual(ArtifactPinsClient.cleanNote("  for   the\nsite "), "for the site")
        XCTAssertNil(ArtifactPinsClient.cleanNote(nil))
    }

    /// Both Save and Edit Note use this request: neither may send a note
    /// the host refuses just because it includes multi-code-point emoji.
    func testSavingClipsUnicodeNotesBeforeSendingThemToTheHost() async throws {
        let expected = String(repeating: "👍🏽", count: 100)
        var asked = false
        let client = ArtifactPinsClient { _, method, body in
            asked = true
            XCTAssertEqual(method, "POST")
            let note = try XCTUnwrap(body?["note"] as? String)
            XCTAssertEqual(note, expected)
            XCTAssertLessThanOrEqual(note.unicodeScalars.count, 200, "Python len accepts at most 200 code points")
            var row = try XCTUnwrap(body?["item"] as? [String: Any])
            row["pinned_at"] = 1_760_000_000.0
            row["note"] = note
            return ["ok": true, "pin": row]
        }
        let item = try XCTUnwrap(ArtifactItem(artifactRow([:])))
        let saved = try await client.save(item, note: String(repeating: "👍🏽", count: 101), profile: "atlas")
        XCTAssertTrue(asked)
        XCTAssertEqual(saved.note, expected)
    }

    /// Saving sends the row as the list gave it, in the store's profile,
    /// with the note on one line; unsaving names it by its path.
    func testSavingSendsTheRowAndUnsavingNamesIt() async throws {
        var asked: [(String, String, [String: Any]?)] = []
        let client = ArtifactPinsClient { path, method, body in
            asked.append((path, method, body))
            if method == "POST" {
                var row = (body?["item"] as? [String: Any]) ?? [:]
                row["pinned_at"] = 1_760_000_000.0
                row["note"] = body?["note"]
                return ["ok": true, "pin": row]
            }
            return ["ok": true, "removed": true]
        }
        let item = try XCTUnwrap(ArtifactItem(artifactRow(["path": "/root/out/a b.png"])))
        let saved = try await client.save(item, note: "  for   the\nsite ", profile: "atlas")
        XCTAssertEqual(saved.note, "for the site")
        XCTAssertEqual(asked[0].0, DashboardPath.withProfile(ArtifactPinsClient.path, profile: "atlas"))
        XCTAssertEqual(asked[0].1, "POST")
        let row = try XCTUnwrap(asked[0].2?["item"] as? [String: Any])
        XCTAssertEqual(row["path"] as? String, "/root/out/a b.png")
        XCTAssertEqual(row["session_id"] as? String, "s1")
        XCTAssertEqual(row["message_id"] as? Int, 12)
        XCTAssertNil(ArtifactPinsClient.cleanNote("   "))

        try await client.remove(item, profile: "default")
        XCTAssertEqual(asked[1].1, "DELETE")
        let encoded = try XCTUnwrap(DashboardPath.encodedQueryComponent("/root/out/a b.png"))
        XCTAssertEqual(asked[1].0, "\(ArtifactPinsClient.path)?id=\(encoded)")
    }
}
