//
//  SidebarLayoutTests+AllProfiles.swift
//  Conduit
//
//  The Chats list's All view: which profiles it lists, how the profile in
//  use's own list and the combined read merge, how it groups by profile,
//  and how its settings are kept per dashboard.
//

import XCTest
@testable import Conduit

extension SidebarLayoutTests {
    private func allRow(_ id: String, profile: String?, at time: TimeInterval?) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: time,
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    func testAllProfilesIncludesEveryProfileNotLeftOut() {
        let profiles = ["default", "Atlas", "nova"]
        XCTAssertEqual(AllProfilesChats.included(profiles, excluded: []), profiles)
        XCTAssertEqual(AllProfilesChats.included(profiles, excluded: ["atlas"]), ["default", "nova"])
        // Every one left out lists them all rather than nothing.
        XCTAssertEqual(AllProfilesChats.included(profiles, excluded: profiles), profiles)
        XCTAssertFalse(AllProfilesChats.isAvailable(profiles: ["default"]))
        XCTAssertTrue(AllProfilesChats.isAvailable(profiles: ["default", "atlas"]))
    }

    func testAllProfilesLeavesCronRunsAndSessionsThatArentChatsOut() {
        // A Kanban worker's transcript can't open as a chat (Hermes 4132),
        // and Hermes' pickers hide tool integrations and one-shot runs.
        XCTAssertTrue(AllProfilesChats.sessionsPath.contains("&exclude_sources=cron,kanban,oneshot,tool&"))
    }

    func testAllProfilesMergesOwnListWithOtherProfilesNewestFirst() {
        let own = [allRow("d-new", profile: "default", at: 500), allRow("d-old", profile: "default", at: 100)]
        let combined = [
            allRow("a-mid", profile: "atlas", at: 300),
            // The profile in use's rows from the combined read are its own
            // list's, which wins.
            allRow("d-stale", profile: "default", at: 900),
            allRow("n-left-out", profile: "nova", at: 800),
            allRow("x-unlisted", profile: "ghost", at: 700),
            allRow("a-untimed", profile: "Atlas", at: nil)
        ]
        let rows = AllProfilesChats.rows(
            active: "default",
            activeRows: own,
            combined: combined,
            included: ["default", "atlas"]
        )
        XCTAssertEqual(rows.map(\.id), ["d-new", "a-mid", "d-old", "a-untimed"])
    }

    func testAllProfilesFallsBackToCombinedRowsWhileOwnListIsEmpty() {
        let combined = [
            allRow("d-one", profile: "default", at: 200),
            allRow("a-one", profile: "atlas", at: 300)
        ]
        let rows = AllProfilesChats.rows(
            active: "default",
            activeRows: [],
            combined: combined,
            included: ["default", "atlas"]
        )
        XCTAssertEqual(rows.map(\.id), ["a-one", "d-one"])
    }

    func testAllProfilesLeavesOutTheProfileInUseWhenExcluded() {
        let rows = AllProfilesChats.rows(
            active: "default",
            activeRows: [allRow("d-one", profile: "default", at: 900)],
            combined: [allRow("a-one", profile: "atlas", at: 100), allRow("d-two", profile: "default", at: 800)],
            included: ["atlas"]
        )
        XCTAssertEqual(rows.map(\.id), ["a-one"])
    }

    func testAllProfilesGroupsFollowTheStripOrder() {
        let rows = [
            allRow("a-one", profile: "atlas", at: 500),
            allRow("d-one", profile: nil, at: 400),
            allRow("a-two", profile: "ATLAS", at: 300)
        ]
        let groups = AllProfilesChats.groups(
            rows,
            profiles: ["default", "atlas", "nova"],
            fallback: "default",
            owner: { $0.profile }
        )
        XCTAssertEqual(groups.map(\.profile), ["default", "atlas"])
        XCTAssertEqual(groups.map { $0.items.map(\.id) }, [["d-one"], ["a-one", "a-two"]])
    }

    func testAllProfilesGroupListsPinnedChatsAndItsNewestFiveUntilShowMore() {
        // Pinned first, then nine more, newest first.
        let ids = ["p1", "p2"] + (1...9).map { "r\($0)" }
        let pinned: Set<String> = ["p1", "p2"]
        let preview = AllProfilesChats.preview(
            ids,
            showsAll: false,
            isPinned: { pinned.contains($0) },
            isOpen: { $0 == "r8" }
        )
        // Every pinned chat, the five newest, and the open chat past them.
        XCTAssertEqual(preview.shown, ["p1", "p2", "r1", "r2", "r3", "r4", "r5", "r8"])
        XCTAssertEqual(preview.hidden, 3)

        let all = AllProfilesChats.preview(ids, showsAll: true, isPinned: { pinned.contains($0) }, isOpen: { _ in false })
        XCTAssertEqual(all.shown, ids)
        XCTAssertEqual(all.hidden, 0)

        // Five or fewer leave nothing for Show more.
        let few = AllProfilesChats.preview(["a", "b", "c"], showsAll: false, isPinned: { _ in false }, isOpen: { _ in false })
        XCTAssertEqual(few.shown, ["a", "b", "c"])
        XCTAssertEqual(few.hidden, 0)
    }

    func testAllProfilesGroupKeepsANestWhoseOpenChatIsNestedPastTheFive() {
        let open = SessionNesting.Node(session: allRow("open-child", profile: "atlas", at: 1), children: [])
        let nodes = (1...6).map { index in
            SessionNesting.Node(
                session: allRow("r\(index)", profile: "atlas", at: TimeInterval(100 - index)),
                children: index == 6 ? [SessionNesting.Node(session: allRow("mid", profile: "atlas", at: 2), children: [open])] : []
            )
        }
        let isOpen: (SessionSummary) -> Bool = { $0.id == "open-child" }
        XCTAssertTrue(AllProfilesChats.holdsOpen(nodes[5], isOpen: isOpen))
        XCTAssertFalse(AllProfilesChats.holdsOpen(nodes[0], isOpen: isOpen))
        let preview = AllProfilesChats.preview(
            nodes,
            showsAll: false,
            isPinned: { _ in false },
            isOpen: { AllProfilesChats.holdsOpen($0, isOpen: isOpen) }
        )
        XCTAssertEqual(preview.shown.map(\.id), ["r1", "r2", "r3", "r4", "r5", "r6"])
        XCTAssertEqual(preview.hidden, 0)
    }

    func testAllProfilesGroupKeepsANestWhoseChildIsNewestThoughItsRootIsOld() {
        // Roots in the list's order; r6's own row is old, its child new.
        let nodes = (1...6).map { index in
            SessionNesting.Node(
                session: allRow("r\(index)", profile: "atlas", at: TimeInterval(100 - index)),
                children: index == 6 ? [SessionNesting.Node(session: allRow("new-child", profile: "atlas", at: 500), children: [])] : []
            )
        }
        let preview = AllProfilesChats.preview(
            nodes,
            showsAll: false,
            isPinned: { _ in false },
            isOpen: { _ in false },
            activity: ChatListSection.latestActivity(in:)
        )
        // The nest with the newest chat stays; the list keeps its order.
        XCTAssertEqual(preview.shown.map(\.id), ["r1", "r2", "r3", "r4", "r6"])
        XCTAssertEqual(preview.hidden, 1)
    }

    func testAllProfilesSettingsAreKeptPerDashboard() throws {
        let suite = "AllProfilesChatsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = UUID()
        let work = UUID()

        var settings = AllProfilesChatsSettings(defaults: defaults)
        XCTAssertEqual(settings[dashboard: home], AllProfilesChatsSettings.Dashboard())
        settings[dashboard: home].isOn = true
        settings[dashboard: home].excluded = ["nova"]
        settings[dashboard: work].groupsByProfile = true
        settings.save(to: defaults)

        let reread = AllProfilesChatsSettings(defaults: defaults)
        XCTAssertEqual(reread[dashboard: home].isOn, true)
        XCTAssertEqual(reread[dashboard: home].excluded, ["nova"])
        XCTAssertEqual(reread[dashboard: home].groupsByProfile, false)
        XCTAssertEqual(reread[dashboard: work].isOn, false)
        XCTAssertEqual(reread[dashboard: work].groupsByProfile, true)

        // Back to the defaults everywhere, nothing is stored.
        var cleared = reread
        cleared[dashboard: home] = AllProfilesChatsSettings.Dashboard()
        cleared[dashboard: work] = AllProfilesChatsSettings.Dashboard()
        cleared.save(to: defaults)
        XCTAssertNil(defaults.data(forKey: AllProfilesChatsSettings.storageKey))
    }

    func testAllProfilesListIDsCarryTheRowsProfile() {
        let nodes = [
            SessionNesting.Node(session: allRow("same", profile: "default", at: 2), children: []),
            SessionNesting.Node(session: allRow("same", profile: "atlas", at: 1), children: [])
        ]
        let ids = V2ChatsListItem.items(nodes, expanded: [], scope: { ($0.profile ?? "") + "|" }).map(\.id)
        XCTAssertEqual(ids, ["default|same", "atlas|same"])
        // Outside All the ids stay the chats' own.
        XCTAssertEqual(V2ChatsListItem.items(nodes, expanded: []).map(\.id), ["same", "same"])
    }

    // MARK: - A project page gathering profiles (issue 1761)

    private func project(_ id: String, path: String?, home: Bool = false) -> ProjectSummary {
        ProjectSummary(id: id, title: id, primaryPath: path, icon: nil, colorHex: nil,
                       isHome: home, sessionCount: 0, previewSessions: [])
    }

    func testAProjectPageFindsTheSameFolderInAnotherProfile() {
        let repo = project("p_atlas", path: "/srv/app/")
        let theirs = [project("home", path: nil, home: true), project("p_other", path: "/srv/other"),
                      project("p_app", path: " /srv/app ")]
        XCTAssertEqual(ProjectAcrossProfiles.match(repo, in: theirs)?.id, "p_app", "same folder, slash and spaces aside")
        XCTAssertEqual(ProjectAcrossProfiles.match(project("home-a", path: nil, home: true), in: theirs)?.id, "home",
                       "Home is Home")
        XCTAssertNil(ProjectAcrossProfiles.match(project("p_none", path: nil), in: theirs), "no folder, no match")
        XCTAssertNil(ProjectAcrossProfiles.match(project("p_x", path: "/srv"), in: theirs))
        XCTAssertEqual(ProjectAcrossProfiles.folderKey("C:\\work\\app\\"), "C:\\work\\app", "a Windows host's folder too")
    }

    func testAProjectPageMergesEachProfilesLanesNewestFirst() {
        let atlas = ProjectProfileLanes(profile: "atlas", lanes: [
            ProjectSessionLane(id: "a-root", title: "app", sessions: [allRow("a1", profile: "atlas", at: 10)], path: "/srv/app"),
            ProjectSessionLane(id: "a-wt", title: "wt", sessions: [allRow("a2", profile: "atlas", at: 5)], path: "/srv/app/.worktrees/wt")
        ])
        let hermes = ProjectProfileLanes(profile: "default", lanes: [
            ProjectSessionLane(id: "h-root", title: "app", sessions: [allRow("h1", profile: "default", at: 20)], path: "/srv/app/")
        ])
        let empty = ProjectProfileLanes(profile: "bot", lanes: [])

        XCTAssertEqual(ProjectAcrossProfiles.profilesWithChats([atlas, empty, hermes]), ["atlas", "default"])
        let merged = ProjectAcrossProfiles.lanes([atlas, hermes, empty])
        XCTAssertEqual(merged.map(\.id), ["a-root", "a-wt"], "one lane per folder, where the page's profile put it")
        XCTAssertEqual(merged[0].sessions.map(\.id), ["h1", "a1"], "newest first across profiles")

        let picked = ProjectAcrossProfiles.lanes([atlas, hermes], filter: "default")
        XCTAssertEqual(picked.map(\.id), ["h-root"], "a pick shows only that profile's lanes")
        XCTAssertEqual(ProjectAcrossProfiles.lanes([atlas]), atlas.lanes, "one profile's lanes as Hermes gave them")
    }
}
