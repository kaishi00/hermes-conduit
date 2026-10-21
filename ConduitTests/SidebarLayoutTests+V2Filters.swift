//
//  SidebarLayoutTests+V2Filters.swift
//  Conduit
//
//  The V2 Chats filters combine: Unread with Chat lists unread chats, two
//  sources list either, Starred narrows the rest to starred chats (#757).
//  Covers what a selection lists, how it is saved, what the menu counts
//  beside each filter, and how stars are kept.
//

import XCTest
@testable import Conduit

extension SidebarLayoutTests {
    private func filterRow(
        _ id: String,
        source: SessionSource,
        at time: TimeInterval? = nil,
        archived: Bool = false
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: time,
            profile: "default",
            source: source,
            isActive: false,
            isArchived: archived,
            lineageRootId: nil
        )
    }

    /// Chats newest first, as the listing gives them.
    private var filterChats: [SessionSummary] {
        [
            filterRow("chat-new", source: .chat, at: 500),
            filterRow("voice", source: .voice, at: 400),
            filterRow("telegram", source: .telegram, at: 300),
            filterRow("chat-old", source: .chat, at: 100),
            filterRow("chat-archived", source: .chat, at: 50, archived: true)
        ]
    }

    /// Cron runs come in their own list.
    private var filterRuns: [SessionSummary] {
        [
            filterRow("run-new", source: .cron, at: 450),
            filterRow("run-old", source: .cron, at: 200),
            filterRow("run-archived", source: .cron, at: 10, archived: true)
        ]
    }

    private func filterIDs(
        _ selection: V2FilterSelection,
        unread: Set<String> = [],
        working: Set<String> = [],
        starred: Set<String> = []
    ) -> [String] {
        selection.rows(
            everything: filterChats.filter { !$0.isArchived },
            sessions: filterChats,
            cronSessions: filterRuns,
            category: \.source,
            hasStatus: { filter, session in
                switch filter {
                case .unread: return unread.contains(session.id)
                case .running: return working.contains(session.id)
                case .starred: return starred.contains(session.id)
                default: return false
                }
            }
        ).map(\.id)
    }

    func testV2FiltersUnreadAndChatListUnreadChats() {
        let selection = V2FilterSelection(filters: [.unread, .source(.chat)])
        XCTAssertEqual(filterIDs(selection, unread: ["chat-old", "voice", "telegram"]), ["chat-old"])
    }

    func testV2FiltersTwoSourcesListEither() {
        XCTAssertEqual(
            filterIDs(V2FilterSelection(filters: [.source(.chat), .source(.telegram)])),
            ["chat-new", "telegram", "chat-old"]
        )
    }

    func testV2FiltersScheduledWeavesRunsInByRecency() {
        XCTAssertEqual(filterIDs(V2FilterSelection(filters: [.scheduled])), ["run-new", "run-old"])
        XCTAssertEqual(
            filterIDs(V2FilterSelection(filters: [.source(.chat), .scheduled])),
            ["chat-new", "run-new", "run-old", "chat-old"]
        )
    }

    func testV2FiltersStatusesListRowsWithAnyOfThem() {
        XCTAssertEqual(
            filterIDs(V2FilterSelection(filters: [.unread, .running]), unread: ["telegram"], working: ["chat-new"]),
            ["chat-new", "telegram"]
        )
        // A status with no source chosen looks through everything.
        XCTAssertEqual(filterIDs(V2FilterSelection(filters: [.unread]), unread: ["voice"]), ["voice"])
    }

    func testV2FiltersVoiceIsASourceLikeTheOthers() {
        XCTAssertEqual(filterIDs(V2FilterSelection(filters: [.voice])), ["voice"])
        XCTAssertEqual(filterIDs(V2FilterSelection(filters: [.voice, .unread]), unread: ["chat-new"]), [])
    }

    func testV2StarredNarrowsWhateverElseIsChosen() {
        let starred: Set<String> = ["chat-old", "telegram", "chat-archived"]
        // Alone it looks through everything, archived chats left out.
        XCTAssertEqual(filterIDs(V2FilterSelection(filters: [.starred]), starred: starred), ["telegram", "chat-old"])
        // Starred and Unread: starred chats that are unread, not either.
        XCTAssertEqual(
            filterIDs(V2FilterSelection(filters: [.starred, .unread]), unread: ["chat-new", "chat-old"], starred: starred),
            ["chat-old"]
        )
        // Statuses still list any of theirs within the starred ones.
        XCTAssertEqual(
            filterIDs(
                V2FilterSelection(filters: [.starred, .unread, .running]),
                unread: ["chat-old"],
                working: ["telegram", "chat-new"],
                starred: starred
            ),
            ["telegram", "chat-old"]
        )
        XCTAssertEqual(filterIDs(V2FilterSelection(filters: [.starred, .source(.chat)]), starred: starred), ["chat-old"])
        XCTAssertEqual(filterIDs(V2FilterSelection(filters: [.starred])), [])
        // A starred run shows under Starred alone, not only under Scheduled.
        XCTAssertEqual(
            filterIDs(V2FilterSelection(filters: [.starred]), starred: ["run-old", "chat-new", "run-archived"]),
            ["chat-new", "run-old"]
        )
    }

    func testV2StarredFlattensSavesAndCountsWithinTheRest() {
        let selection = V2FilterSelection(filters: [.unread, .starred, .source(.chat)])
        XCTAssertTrue(V2FilterSelection(filters: [.starred]).flattens, "Starred lists every starred chat, sections open")
        XCTAssertEqual(selection.rawValue, "starred,unread,source.chat")
        XCTAssertEqual(V2FilterSelection(rawValue: selection.rawValue), selection)
        XCTAssertEqual(selection.statuses, [.unread])
        XCTAssertEqual(selection.sources, [.source(.chat)])
        XCTAssertEqual(selection.emptyStateFilter, .starred)
        // Starred counts the starred rows among what's chosen; every other
        // count stays within the starred ones.
        XCTAssertEqual(V2FilterSelection(filters: [.unread]).facet(.starred), V2FilterSelection(filters: [.unread, .starred]))
        XCTAssertEqual(selection.facet(.running), V2FilterSelection(filters: [.running, .starred, .source(.chat)]))
        XCTAssertEqual(selection.facet(.voice), V2FilterSelection(filters: [.unread, .starred, .voice]))
    }

    func testSessionStarsFollowTheConversationPerProfile() throws {
        let compacted = SessionSummary(
            id: "chat-2", alternateIds: ["chat-1"], title: "chat", model: "Hermes", updatedLabel: "now",
            lastActivityAt: nil, profile: "default", source: .chat, isActive: false, isArchived: false,
            lineageRootId: "chat-1"
        )
        let original = filterRow("chat-1", source: .chat)
        var stars = SessionStars()
        stars.set(original, starred: true, profile: "default")
        XCTAssertTrue(stars.isStarred(original, profile: "default"))
        XCTAssertTrue(stars.isStarred(compacted, profile: "default"), "A compacted chat keeps its star")
        XCTAssertFalse(stars.isStarred(original, profile: "work"), "Stars are per profile")

        // Starring twice keeps one entry; unstarring by either id clears it.
        stars.set(compacted, starred: true, profile: "default")
        XCTAssertEqual(stars.idsByProfile["default"], ["chat-1"])
        stars.set(compacted, starred: false, profile: "default")
        XCTAssertFalse(stars.isStarred(original, profile: "default"))
        XCTAssertTrue(stars.idsByProfile.isEmpty)

        let suite = "SessionStarsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        stars.set(original, starred: true, profile: "work")
        stars.save(to: defaults)
        XCTAssertEqual(SessionStars(defaults: defaults), stars)
        stars.forget(profile: "work")
        stars.save(to: defaults)
        XCTAssertNil(defaults.data(forKey: SessionStars.storageKey))
    }

    func testV2AllHidesProjectChatsExceptWhileSearching() {
        let inMainList: (SessionSummary) -> Bool = { $0.id != "chat-old" }
        let rows = filterChats.filter { !$0.isArchived }
        XCTAssertEqual(
            V2ChatsView.allRows(rows, searching: false, inMainList: inMainList).map(\.id),
            ["chat-new", "voice", "telegram"]
        )
        // A search finds a project's chat too (#708).
        XCTAssertEqual(
            V2ChatsView.allRows(rows, searching: true, inMainList: inMainList).map(\.id),
            ["chat-new", "voice", "telegram", "chat-old"]
        )
    }

    func testV2SearchPreviewNamesTheProject() {
        XCTAssertEqual(V2ChatsView.searchPreview("Last reply", projectTitle: "Website"), "Website · Last reply")
        XCTAssertEqual(V2ChatsView.searchPreview("", projectTitle: "Website"), "Website")
        XCTAssertEqual(V2ChatsView.searchPreview("Last reply", projectTitle: nil), "Last reply")
    }

    func testV2FiltersSaveAsOneValue() {
        let selection = V2FilterSelection(filters: [.source(.chat), .unread, .scheduled])
        XCTAssertEqual(selection.rawValue, "unread,scheduled,source.chat")
        XCTAssertEqual(V2FilterSelection(rawValue: selection.rawValue), selection)
        // A single filter an earlier build saved reads as itself, "all" as none.
        XCTAssertEqual(V2FilterSelection(rawValue: "voice"), V2FilterSelection(filters: [.voice]))
        XCTAssertEqual(V2FilterSelection(rawValue: "all"), .empty)
        XCTAssertEqual(V2FilterSelection(rawValue: ""), .empty)
        XCTAssertEqual(V2FilterSelection.empty.rawValue, "all")
        XCTAssertEqual(V2FilterSelection(rawValue: "unread, bogus"), V2FilterSelection(filters: [.unread]))
    }

    func testV2FiltersAllClearsTheRest() {
        XCTAssertTrue(V2FilterSelection.empty.contains(.all))
        let selection = V2FilterSelection.empty.setting(.unread, on: true).setting(.source(.chat), on: true)
        XCTAssertFalse(selection.contains(.all))
        XCTAssertTrue(selection.contains(.unread))
        XCTAssertEqual(selection.setting(.unread, on: false), V2FilterSelection(filters: [.source(.chat)]))
        XCTAssertEqual(selection.setting(.all, on: true), .empty)
        XCTAssertEqual(selection.setting(.all, on: false), selection, "All can't be turned off")
    }

    func testV2FiltersMenuCountsBesideWhatIsChosen() {
        let selection = V2FilterSelection(filters: [.unread, .source(.telegram)])
        // With Unread on, Chat counts unread chats, whatever source is chosen.
        XCTAssertEqual(selection.facet(.source(.chat)), V2FilterSelection(filters: [.unread, .source(.chat)]))
        // A status counts within the chosen sources.
        XCTAssertEqual(selection.facet(.running), V2FilterSelection(filters: [.running, .source(.telegram)]))
        XCTAssertEqual(selection.facet(.all), .empty)
    }

    func testV2FiltersLiveOnesSitOutWithoutLiveStatus() {
        let selection = V2FilterSelection(filters: [.running, .needsApproval, .unread, .voice])
        XCTAssertEqual(selection.withoutLive, V2FilterSelection(filters: [.unread, .voice]))
        XCTAssertTrue(V2FilterSelection(filters: [.running]).withoutLive.isEmpty)
        XCTAssertTrue(selection.flattens)
        XCTAssertFalse(V2FilterSelection(filters: [.voice, .scheduled]).flattens, "Sources keep the list nested")
        XCTAssertEqual(selection.emptyStateFilter, .unread)
        XCTAssertEqual(V2FilterSelection(filters: [.scheduled]).emptyStateFilter, .scheduled)
    }

    func testV2FiltersMergeKeepsEachListsOrder() {
        let merged = V2FilterSelection.mergedByRecency(
            [filterRow("a", source: .chat, at: 30), filterRow("c", source: .chat, at: 10), filterRow("e", source: .chat, at: 5)],
            [filterRow("x", source: .cron, at: 20), filterRow("t", source: .cron, at: 5), filterRow("y", source: .cron)]
        )
        // Ties keep the first list first; a run without a time goes last.
        XCTAssertEqual(merged.map(\.id), ["a", "x", "c", "e", "t", "y"])
    }

    @MainActor
    func testVoiceButtonRecentsAreTheNewestInListOrderOnTies() {
        let sessions = [
            filterRow("old", source: .chat, at: 10),
            filterRow("untimed", source: .chat),
            filterRow("tie-first", source: .chat, at: 40),
            filterRow("newest", source: .chat, at: 90),
            filterRow("tie-second", source: .chat, at: 40),
            filterRow("middle", source: .chat, at: 20)
        ]
        XCTAssertEqual(V2VoiceButton.mostRecent(sessions, limit: 3).map(\.id), ["newest", "tie-first", "tie-second"])
        // The whole list comes back newest first; no time counts as oldest.
        XCTAssertEqual(
            V2VoiceButton.mostRecent(sessions, limit: 6).map(\.id),
            ["newest", "tie-first", "tie-second", "middle", "old", "untimed"]
        )
        XCTAssertEqual(V2VoiceButton.mostRecent(Array(sessions.prefix(2)), limit: 3).map(\.id), ["old", "untimed"])
        XCTAssertTrue(V2VoiceButton.mostRecent([], limit: 3).isEmpty)
    }

    func testChatsListGivesEveryRowOfANestItsOwnItem() {
        func node(_ id: String, _ children: [SessionNesting.Node] = []) -> SessionNesting.Node {
            SessionNesting.Node(session: filterRow(id, source: .chat), children: children)
        }
        let nodes = [
            node("call", [node("job", [node("job-of-job")]), node("job-2")]),
            node("chat"),
            node("closed", [node("hidden")])
        ]
        let items = V2ChatsListItem.items(nodes, expanded: ["call"])

        // One item per List row, in list order: an open nest lists its
        // descendants depth first, a closed one only its "3 jobs" line.
        XCTAssertEqual(
            items.map(\.id),
            ["call", "nest:call", "job", "job-of-job", "job-2", "chat", "closed", "nest:closed"]
        )
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)

        var children: [(id: String, depth: Int, parent: String, isLast: Bool)] = []
        var nests: [(key: String, isExpanded: Bool)] = []
        for item in items {
            switch item.kind {
            case .session: break
            case .nest(_, let key, let isExpanded): nests.append((key, isExpanded))
            case .child(let session, let depth, let parentTitle, let isLast):
                children.append((session.id, depth, parentTitle, isLast))
            }
        }
        XCTAssertEqual(nests.map(\.key), ["call", "closed"])
        XCTAssertEqual(nests.map(\.isExpanded), [true, false])
        XCTAssertEqual(children.map(\.depth), [0, 1, 0])
        XCTAssertEqual(children.map(\.parent), ["call", "call", "call"])
        // Only the nest's last row draws the hairline that closes it.
        XCTAssertEqual(children.map(\.isLast), [false, false, true])

        XCTAssertEqual(V2ChatsListItem.leaf(filterRow("pinned", source: .chat)).id, "pinned")

        // A nest opens by its stored id, which outlives the runtime id the
        // row is listed under.
        var reconciled = filterRow("runtime", source: .chat)
        reconciled.storedSessionId = "stored"
        let renamed = [SessionNesting.Node(session: reconciled, children: [node("its-job")])]
        XCTAssertEqual(
            V2ChatsListItem.items(renamed, expanded: ["stored"]).map(\.id),
            ["runtime", "nest:runtime", "its-job"]
        )
        XCTAssertEqual(V2ChatsListItem.items(renamed, expanded: ["runtime"]).map(\.id), ["runtime", "nest:runtime"])
    }
}
