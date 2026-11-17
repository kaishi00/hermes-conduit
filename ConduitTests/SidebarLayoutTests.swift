//
//  SidebarLayoutTests.swift
//  Conduit
//
//  Coverage for the iPad persistent-sidebar layout policy and the drawer
//  dismissal helper shared by the sidebar's session-opening flows.
//

import Combine
import SwiftUI
import XCTest
@testable import Conduit

final class SidebarLayoutTests: XCTestCase {
    private let phone = UIUserInterfaceIdiom.phone
    private let pad = UIUserInterfaceIdiom.pad

    private func resolve(
        _ idiom: UIUserInterfaceIdiom,
        prefersPersistentSidebar: Bool,
        availableWidth: CGFloat
    ) -> SidebarPresentation {
        SidebarLayoutPolicy.resolvePresentation(
            idiom: idiom,
            prefersPersistentSidebar: prefersPersistentSidebar,
            availableWidth: availableWidth
        )
    }

    // MARK: - Layout resolution

    func testPhoneUsesDrawerRegardlessOfPreferenceOrWidth() {
        for prefersPersistentSidebar in [false, true] {
            for width: CGFloat in [0, 320, 430, 768, 1024, 1366] {
                XCTAssertEqual(
                    resolve(phone, prefersPersistentSidebar: prefersPersistentSidebar, availableWidth: width),
                    .drawer,
                    "iPhone must keep the drawer (preference \(prefersPersistentSidebar), width \(width))."
                )
            }
        }
    }

    func testIPadWithPreferenceOffUsesDrawerAtAnyWidth() {
        for width: CGFloat in [0, 512, 683, 750, 768, 1024, 1366] {
            XCTAssertEqual(
                resolve(pad, prefersPersistentSidebar: false, availableWidth: width),
                .drawer,
                "Opt-out must keep the drawer at width \(width)."
            )
        }
    }

    func testIPadWithPreferenceOnAndWideWindowUsesPersistentSidebar() {
        // Full-screen landscape, full-screen portrait (768), and wide
        // Split View / Stage Manager tiles all clear the threshold.
        for width: CGFloat in [768, 834, 1024, 1194, 1366] {
            XCTAssertEqual(
                resolve(pad, prefersPersistentSidebar: true, availableWidth: width),
                .persistent,
                "Wide iPad window (\(width)) with the opt-in should host the persistent sidebar."
            )
        }
    }

    func testIPadWithPreferenceOnAndNarrowWindowFallsBackToDrawer() {
        // Split View halves, small Stage Manager tiles, and undetermined
        // pre-layout widths must keep the drawer.
        for width: CGFloat in [0, 320, 417, 512, 683, 750] {
            XCTAssertEqual(
                resolve(pad, prefersPersistentSidebar: true, availableWidth: width),
                .drawer,
                "Narrow iPad window (\(width)) must fall back to the drawer."
            )
        }
    }

    func testPersistentThresholdKeepsMinimumChatWidth() {
        XCTAssertEqual(
            SidebarLayoutMetrics.minimumPersistentLayoutWidth,
            SidebarLayoutMetrics.persistentSidebarWidth + 1 + SidebarLayoutMetrics.minimumChatWidth,
            "The sidebar, the line beside it (#1487) and the chat's least width."
        )

        let threshold = SidebarLayoutMetrics.minimumPersistentLayoutWidth
        XCTAssertEqual(
            resolve(pad, prefersPersistentSidebar: true, availableWidth: threshold),
            .persistent,
            "A window exactly at the threshold still leaves the minimum chat width."
        )
        XCTAssertEqual(
            resolve(pad, prefersPersistentSidebar: true, availableWidth: threshold - 1),
            .drawer,
            "One point below the threshold would squeeze the chat column."
        )
    }

    // MARK: - Return surface

    func testReturnSurfaceSkipsDrawerWhilePersistentSidebarIsActive() {
        XCTAssertFalse(
            SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
                persistentSidebarActive: true,
                drawerPresented: false
            ),
            "The persistent sidebar already shows Sessions; no drawer may open over it."
        )
        XCTAssertFalse(
            SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
                persistentSidebarActive: true,
                drawerPresented: true
            )
        )
    }

    func testReturnSurfacePreservesDrawerBehaviorWhenPersistentIsInactive() {
        XCTAssertTrue(
            SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
                persistentSidebarActive: false,
                drawerPresented: false
            ),
            "Drawer layouts keep opening the sessions drawer for return-surface requests."
        )
        XCTAssertFalse(
            SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
                persistentSidebarActive: false,
                drawerPresented: true
            ),
            "An already-presented drawer is not re-presented."
        )
    }

    // MARK: - Drawer dismissal helper

    @MainActor
    func testDismissSidebarDrawerClosesOpenDrawer() {
        let state = makeAppState()
        state.showSidebar = true

        state.dismissSidebarDrawer()

        XCTAssertFalse(state.showSidebar)
    }

    @MainActor
    func testDismissSidebarDrawerIsNoOpWhenDrawerIsClosed() {
        let state = makeAppState()

        // Session-opening flows call this unconditionally; in the persistent
        // layout the drawer is never presented, so the helper must leave
        // showSidebar untouched rather than force a publication flush.
        state.dismissSidebarDrawer()

        XCTAssertFalse(state.showSidebar)
    }

    /// The V2 Chats list kept under a pushed chat doesn't redraw with every
    /// publish: it waits, then draws once with what it missed.
    @MainActor
    func testCoveredChatsListWaitsUntilItShowsAgain() {
        let state = makeAppState()
        let updates = V2ShownUpdates(state)
        updates.revealDelay = 0.05
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }

        state.sessions = [pinnedTestSession("shown")]
        XCTAssertGreaterThan(sent, 0)

        sent = 0
        updates.isShown = false
        state.sessions = [pinnedTestSession("covered")]
        state.cronSessions = [pinnedTestSession("run", source: .cron)]
        XCTAssertEqual(sent, 0)
        // Shown again by the pop, it draws once the pop has slid, with a
        // publish during the slide.
        updates.isShown = true
        XCTAssertEqual(sent, 0, "the list drew as the pop started")
        state.sessions = [pinnedTestSession("during the pop")]
        XCTAssertEqual(sent, 0)
        waitUntil { sent > 0 }
        settle()
        XCTAssertEqual(sent, 1)

        // Covered again before it drew: the next showing draws.
        sent = 0
        updates.isShown = false
        state.sessions = [pinnedTestSession("covered again")]
        updates.isShown = true
        updates.isShown = false
        settle()
        XCTAssertEqual(sent, 0)
        updates.isShown = true
        waitUntil { sent > 0 }
        XCTAssertEqual(sent, 1)

        // Nothing missed, nothing to draw.
        sent = 0
        updates.isShown = false
        updates.isShown = true
        settle()
        XCTAssertEqual(sent, 0)

        // Shown by a pop with nothing missed, a publish during the slide
        // still waits it out.
        updates.isShown = false
        updates.isShown = true
        state.sessions = [pinnedTestSession("during a pop with nothing missed")]
        XCTAssertEqual(sent, 0, "a publish during the slide drew at once")
        waitUntil { sent > 0 }
        settle()
        XCTAssertEqual(sent, 1)

        // Shown by a tab switch, nothing slides: what it missed draws at
        // once, and so does a publish after.
        sent = 0
        updates.revealDelay = 0
        updates.isShown = false
        state.sessions = [pinnedTestSession("behind another tab")]
        updates.isShown = true
        XCTAssertEqual(sent, 1)
        state.sessions = [pinnedTestSession("after the switch")]
        XCTAssertEqual(sent, 2)

        // The window crosses the split threshold during a pop's wait:
        // nothing slides any more, so what it missed draws then.
        sent = 0
        let covered = V2ListVisibility(tabActive: true, covered: true, split: false)
        let popped = V2ListVisibility(tabActive: true, covered: false, split: false)
        updates.follow(covered, from: popped)
        state.sessions = [pinnedTestSession("under the chat")]
        updates.follow(popped, from: covered)
        XCTAssertEqual(updates.revealDelay, V2ShownUpdates.popSlide)
        XCTAssertEqual(sent, 0)
        updates.follow(V2ListVisibility(tabActive: true, covered: false, split: true), from: popped)
        XCTAssertEqual(sent, 1, "a split change during the wait kept waiting")
        settle()
        XCTAssertEqual(sent, 1)
    }

    /// A row's content compares on what it shows: the list's re-run with
    /// new closures leaves it be; its item or project title changing
    /// redraws it.
    @MainActor
    func testChatsRowComparesOnWhatItShows() {
        func row(_ item: V2ChatsListItem, project: String? = nil, expand: @escaping (String, Bool) -> Void = { _, _ in }) -> V2ChatsRowContent {
            V2ChatsRowContent(item: item, projectTitle: project, profileBadge: { _ in nil }, setExpanded: expand)
        }
        let parent = pinnedTestSession("parent")
        let child = pinnedTestSession("child")
        let nest = V2ChatsListItem(id: "parent", kind: .session(SessionNesting.Node(
            session: parent, children: [SessionNesting.Node(session: child, children: [])])))
        var expansions = 0
        XCTAssertEqual(row(nest), row(nest, expand: { _, _ in expansions += 1 }), "new closures redrew the row")
        XCTAssertNotEqual(row(nest), row(nest, project: "Conduit"))
        let retitledChild = V2ChatsListItem(id: "parent", kind: .session(SessionNesting.Node(
            session: parent, children: [SessionNesting.Node(session: pinnedTestSession("child", title: "Renamed"), children: [])])))
        XCTAssertNotEqual(row(nest), row(retitledChild), "a child's change left the row as it was")
        XCTAssertNotEqual(row(.leaf(parent)), row(.leaf(pinnedTestSession("parent", title: "Renamed"))))
    }

    /// Mounted in a List: the list re-running with the same rows (as it does
    /// when a chat is pushed or popped) leaves their content alone (behind
    /// `.equatable()`, the traits outside it); a changed item redraws its
    /// row.
    @MainActor
    func testChatsListReRunLeavesUnchangedRowsAlone() throws {
        let state = makeAppState()
        let updates = V2ShownUpdates(state)
        let parent = ChatsRowsParentModel(items: [.leaf(pinnedTestSession("a")), .leaf(pinnedTestSession("b"))])
        let host = UIHostingController(rootView: ChatsRowsParent(model: parent).environmentObject(updates))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        TranscriptPerf.reset()
        waitUntil { TranscriptPerf.chatsListRowBodyEvaluations >= 2 }
        XCTAssertGreaterThanOrEqual(TranscriptPerf.chatsListRowBodyEvaluations, 2, "the rows never drew")
        settle()

        TranscriptPerf.reset()
        parent.covered.toggle()
        waitUntil { parent.parentBodies >= 2 }
        settle()
        XCTAssertGreaterThanOrEqual(parent.parentBodies, 2, "the list never re-ran")
        XCTAssertEqual(TranscriptPerf.chatsListRowBodyEvaluations, 0, "the list's re-run redrew unchanged rows")

        parent.items[1] = .leaf(pinnedTestSession("b", title: "Renamed"))
        waitUntil { TranscriptPerf.chatsListRowBodyEvaluations > 0 }
        XCTAssertGreaterThan(TranscriptPerf.chatsListRowBodyEvaluations, 0, "a changed item left its row as it was")
    }

    @MainActor
    private final class ChatsRowsParentModel: ObservableObject {
        @Published var covered = false
        @Published var items: [V2ChatsListItem]
        var parentBodies = 0
        init(items: [V2ChatsListItem]) { self.items = items }
    }

    /// Re-runs on its model's every change with new closures for each row,
    /// as V2ChatsView does when the shell's covered flag flips.
    private struct ChatsRowsParent: View {
        @ObservedObject var model: ChatsRowsParentModel
        var body: some View {
            let _ = model.parentBodies += 1
            List {
                Text(model.covered ? "covered" : "shown")
                ForEach(model.items) { item in
                    V2ChatsRow(item: item, projectTitle: nil, profileBadge: { _ in nil }, onRename: { _ in },
                               onDelete: { _ in }, onReorderPinned: { _ in }, setExpanded: { _, _ in })
                }
            }
        }
    }

    /// A project page is covered by a chat pushed over it, not by one
    /// beside it; its rows compare on what they show.
    @MainActor
    func testProjectPageFollowsTheChatsListsGate() {
        var shell = V2ShellContext()
        shell.values.showsChatRows = false
        let covered = V2ProjectPage.visibility(in: shell)
        XCTAssertFalse(covered.isShown)
        shell.values.showsChatRows = true
        XCTAssertTrue(V2ProjectPage.visibility(in: shell).isPop(from: covered))
        shell.values.isSplit = true
        shell.values.hasChatBeside = true
        XCTAssertTrue(V2ProjectPage.visibility(in: shell).isShown, "a chat beside the page covered it")
        XCTAssertFalse(V2ProjectPage.visibility(in: shell).isPop(from: covered))

        func row(_ session: SessionSummary, badge: V2ProfileBadge? = nil) -> V2ProjectSessionRowContent {
            V2ProjectSessionRowContent(session: session, profileBadge: badge)
        }
        let session = pinnedTestSession("chat")
        XCTAssertEqual(row(session), row(session))
        XCTAssertNotEqual(row(session), row(session, badge: V2ProfileBadge(profile: "work", name: "Work", url: nil)))
        XCTAssertNotEqual(row(session), row(pinnedTestSession("chat", title: "Renamed")))
    }

    /// Only a pop on the shown tab waits out a slide: a tab switch, or the
    /// window or the list's toggle putting the list beside the chat,
    /// slides nothing.
    @MainActor
    func testOnlyAPopUncoveringTheChatsListCountsAsAPop() {
        typealias Visibility = V2ListVisibility
        let covered = Visibility(tabActive: true, covered: true, split: false)
        XCTAssertTrue(Visibility(tabActive: true, covered: false, split: false).isPop(from: covered))
        XCTAssertFalse(Visibility(tabActive: true, covered: false, split: true).isPop(from: covered),
                       "the list put beside the chat waited for a slide")
        XCTAssertFalse(Visibility(tabActive: false, covered: false, split: false).isPop(from: covered))
        XCTAssertFalse(Visibility(tabActive: true, covered: false, split: false)
            .isPop(from: Visibility(tabActive: false, covered: false, split: false)),
                       "a tab switch waited for a slide")
        XCTAssertFalse(Visibility(tabActive: true, covered: false, split: false)
            .isPop(from: Visibility(tabActive: false, covered: true, split: false)),
                       "a pop landing from another tab waited for a slide")
    }

    /// Beside a chat on a wide iPad the list shows, but a burst of publishes
    /// (a streaming reply) draws it once, after the delay; its own setting
    /// writes still draw at once.
    @MainActor
    func testChatsListBesideAChatDrawsABurstOnce() {
        let state = makeAppState()
        let suite = "SidebarLayoutTests.beside.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = V2ShownUpdates(state, defaults: defaults, defaultsKeys: ["list.filter"])
        updates.coalesces = true
        updates.coalescingDelay = 0.05
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }

        for index in 0..<20 { state.sessions = [pinnedTestSession("s\(index)")] }
        XCTAssertEqual(sent, 0, "the burst drew before the delay")
        waitUntil { sent > 0 }
        XCTAssertEqual(sent, 1)

        updates.set("scheduled", forKey: "list.filter")
        XCTAssertEqual(sent, 2, "the list's own write waited")

        // Covered before the delay ran out, it draws when shown again.
        sent = 0
        state.sessions = [pinnedTestSession("late")]
        updates.isShown = false
        settle()
        XCTAssertEqual(sent, 0)
        updates.isShown = true
        XCTAssertEqual(sent, 1)

        // Shown again while a burst's draw waits, that draw waits for the
        // slide in too, then the two draw once.
        sent = 0
        updates.revealDelay = 0.3
        state.sessions = [pinnedTestSession("burst")]
        updates.isShown = false
        state.sessions = [pinnedTestSession("covered")]
        updates.isShown = true
        settle()
        XCTAssertEqual(sent, 0, "the burst's draw came during the slide in")
        waitUntil { sent > 0 }
        settle()
        XCTAssertEqual(sent, 1)
    }

    /// Right after launch the connection and the catalog publish many
    /// times a second: while the list scrolls they wait, and draw once when
    /// it rests. A scroll that never rests still draws after the hold limit.
    @MainActor
    func testScrollingChatsListDrawsHeldPublishesOnceItRests() {
        let state = makeAppState()
        let updates = V2ShownUpdates(state)
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        updates.now = { clock }
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }

        updates.setScrolling(true, by: "list")
        for index in 0..<20 { state.sessions = [pinnedTestSession("s\(index)")] }
        XCTAssertEqual(sent, 0, "a publish redrew the list mid-scroll")
        updates.setScrolling(false, by: "list")
        XCTAssertEqual(sent, 1)

        // Nothing held, nothing to draw.
        sent = 0
        updates.setScrolling(true, by: "list")
        updates.setScrolling(false, by: "list")
        XCTAssertEqual(sent, 0)

        // A drag held past the limit draws, then holds again.
        updates.setScrolling(true, by: "list")
        state.sessions = [pinnedTestSession("early")]
        XCTAssertEqual(sent, 0)
        clock += updates.scrollHoldLimit
        state.sessions = [pinnedTestSession("late")]
        XCTAssertEqual(sent, 1)
        state.sessions = [pinnedTestSession("later")]
        XCTAssertEqual(sent, 1)
        updates.setScrolling(false, by: "list")
        XCTAssertEqual(sent, 2)

        // Covered when the scroll rests, it waits to be shown.
        sent = 0
        updates.setScrolling(true, by: "list")
        state.sessions = [pinnedTestSession("covered")]
        updates.isShown = false
        updates.setScrolling(false, by: "list")
        XCTAssertEqual(sent, 0)
        updates.isShown = true
        XCTAssertEqual(sent, 1)
    }

    /// Beside a chat the scroll holds too, and when the hold runs out the
    /// coalesced draw still comes, with no other publish to prompt it.
    @MainActor
    func testScrollingChatsListBesideAChatDrawsWhenTheHoldRunsOut() {
        let state = makeAppState()
        let updates = V2ShownUpdates(state)
        updates.coalesces = true
        updates.coalescingDelay = 0.05
        updates.scrollHoldLimit = 0.2
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }

        updates.setScrolling(true, by: "list")
        state.sessions = [pinnedTestSession("held")]
        XCTAssertEqual(sent, 0, "a publish redrew the list mid-scroll")
        waitUntil { sent > 0 }
        XCTAssertEqual(sent, 1, "the hold ran out beside a chat without drawing")

        updates.setScrolling(false, by: "list")
        settle()
        XCTAssertEqual(sent, 1, "a rest with nothing held drew again")
    }

    /// A held publish draws once the hold runs out even when nothing else
    /// publishes, and covering the list ends its scroll.
    @MainActor
    func testScrollHoldRunsOutWithoutAnotherPublish() {
        let state = makeAppState()
        let updates = V2ShownUpdates(state)
        updates.scrollHoldLimit = 0.1
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }

        updates.setScrolling(true, by: "list")
        state.sessions = [pinnedTestSession("held")]
        XCTAssertEqual(sent, 0)
        waitUntil { sent > 0 }
        XCTAssertEqual(sent, 1, "the hold never ran out on its own")

        updates.isShown = false
        XCTAssertFalse(updates.isScrolling, "a covered list stayed scrolling")
    }

    /// Sessions and Projects both show during their slide: one list coming
    /// to rest doesn't end the other's scroll, and leaving the app ends all.
    @MainActor
    func testScrollHoldFollowsEachListsOwnScroll() {
        let state = makeAppState()
        let updates = V2ShownUpdates(state)
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }

        updates.setScrolling(true, by: "sessions")
        updates.setScrolling(true, by: "projects")
        state.sessions = [pinnedTestSession("held")]
        updates.setScrolling(false, by: "sessions")
        XCTAssertEqual(sent, 0, "one list's rest ended the other's scroll")
        updates.setScrolling(false, by: "projects")
        XCTAssertEqual(sent, 1)

        sent = 0
        updates.setScrolling(true, by: "sessions")
        state.sessions = [pinnedTestSession("left")]
        updates.endScrolling()
        XCTAssertEqual(sent, 1)
        XCTAssertFalse(updates.isScrolling)
    }

    /// One render of the Chats list walks the catalog once per question,
    /// however many filters ask it; the next render asks again.
    @MainActor
    func testChatsRenderMemoSharesWalksWithinARender() {
        let memo = V2ChatsRenderMemo()
        var walks = 0
        let rows = [pinnedTestSession("a")]
        let walk: () -> [SessionSummary] = { walks += 1; return rows }

        _ = memo.sourceRows(nil, walk)
        _ = memo.sourceRows(nil, walk)
        _ = memo.sourceRows(.cron, walk)
        XCTAssertEqual(walks, 2)

        _ = memo.filterRows("all", searching: false, walk)
        _ = memo.filterRows("all", searching: false, walk)
        _ = memo.filterRows("all", searching: true, walk)
        XCTAssertEqual(walks, 4)

        var lookups = 0
        _ = memo.category("a") { lookups += 1; return .voice }
        XCTAssertEqual(memo.category("a") { lookups += 1; return .cron }, .voice)
        XCTAssertEqual(lookups, 1)

        memo.reset()
        _ = memo.sourceRows(nil, walk)
        _ = memo.category("a") { lookups += 1; return .cron }
        XCTAssertEqual(walks, 5)
        XCTAssertEqual(lookups, 2)
    }

    /// An equal key reuses the tree; a change to any member rebuilds it.
    @MainActor
    func testSessionsNestingCacheRebuildsOnEveryKeyMember() {
        let cache = V2SessionsNestingCache()
        var builds = 0
        let build: () -> (pinned: [SessionNesting.Node], recent: [SessionNesting.Node]) = {
            builds += 1
            return ([], [])
        }
        let base = V2SessionsNestingCache.Key(
            rows: [pinnedTestSession("a")],
            query: "",
            flattens: false,
            pinnedIDs: [],
            tags: [:],
            linksRevision: 0,
            dashboard: nil,
            profile: "default",
            profiles: ["default"],
            order: PinnedChatOrder(),
            groupsByProfile: false
        )
        _ = cache.sections(for: base, build: build)
        _ = cache.sections(for: base, build: build)
        XCTAssertEqual(builds, 1)

        let changes: [(inout V2SessionsNestingCache.Key) -> Void] = [
            { $0.rows.append(self.pinnedTestSession("b")) },
            { $0.query = "x" },
            { $0.flattens = true },
            { $0.pinnedIDs = ["a"] },
            { $0.tags = ["-|default": ["a": VoiceSessionTag(kind: .job, parentID: "b", parentTitle: nil)]] },
            { $0.linksRevision = 1 },
            { $0.dashboard = UUID() },
            { $0.profile = "work" },
            { $0.profiles = ["default", "work"] },
            { $0.order = PinnedChatOrder(idsByProfile: ["default": ["a"]]) },
            { $0.groupsByProfile = true },
        ]
        for (index, change) in changes.enumerated() {
            var key = base
            change(&key)
            _ = cache.sections(for: key, build: build)
            XCTAssertEqual(builds, 2 * index + 2, "change \(index) should rebuild")
            _ = cache.sections(for: base, build: build)
            XCTAssertEqual(builds, 2 * index + 3)
        }
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// SwiftUI redraws every `@AppStorage` view on any defaults write, and a
    /// chat saves its scroll position there: the list reads its settings
    /// through the gate, which passes on only its own keys' changes, and
    /// only while the list shows.
    @MainActor
    func testChatsListRedrawsOnlyForItsOwnSettingsAndOnlyWhileShown() {
        let state = makeAppState()
        let suite = "SidebarLayoutTests.listDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = V2ShownUpdates(state, defaults: defaults, defaultsKeys: ["list.filter"])
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }

        defaults.set(Data([1, 2, 3]), forKey: "conduit.chatResume.v1")
        settle()
        XCTAssertEqual(sent, 0, "another key's write redrew the list")

        updates.set("scheduled", forKey: "list.filter")
        XCTAssertEqual(sent, 1, "the list's own write redraws it at once")
        settle()
        XCTAssertEqual(sent, 1, "the write's notification redrew the list again")

        // A write from elsewhere arrives through the notification.
        defaults.set("all", forKey: "list.filter")
        settle()
        XCTAssertEqual(sent, 2)

        updates.isShown = false
        defaults.set("scheduled", forKey: "list.filter")
        settle()
        XCTAssertEqual(sent, 2)
        updates.isShown = true
        XCTAssertEqual(sent, 3)
    }

    /// The Chats and drawer menus' Needs you entry watches the store: on a
    /// dashboard whose plugin keeps no list, another combined dashboard's
    /// first wait brings it with nothing else redrawing, and its last one
    /// takes it away (all-live stage 4a).
    @MainActor
    func testTheNeedsYouMenuEntryComesWithAnotherDashboardsFirstWait() throws {
        let state = makeAppState()
        XCTAssertFalse(state.servesNeedsYou)
        let host = UIHostingController(rootView: VStack { NeedsYouMenuEntry(store: state.needsYou) {} }.environmentObject(state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        NeedsYouMenuEntry.lastShown = nil
        waitUntil { NeedsYouMenuEntry.lastShown != nil }
        XCTAssertEqual(NeedsYouMenuEntry.lastShown, false)

        let there = UUID()
        state.needsYou.applyOther([NeedsYouItem(waitID: "w", profile: "default", kind: .approval, sessionIDs: ["s"])],
                                  profile: "default", dashboardID: there)
        waitUntil { NeedsYouMenuEntry.lastShown == true }
        XCTAssertEqual(NeedsYouMenuEntry.lastShown, true, "another dashboard's wait brings the entry")

        state.needsYou.forgetOtherDashboards(otherThan: [])
        waitUntil { NeedsYouMenuEntry.lastShown == false }
        XCTAssertEqual(NeedsYouMenuEntry.lastShown, false, "and its going takes it away")
    }

    /// A combined dashboard's badge past the palette: each place's hue
    /// keeps clear of the palette's and of the ones before it.
    @MainActor
    func testBadgeHuesPastThePaletteKeepClearOfEachOther() {
        // The hues the generated ones keep clear of are the palette's own.
        XCTAssertEqual(CombinedDashboardBadge.paletteHues.count, CombinedDashboardBadge.palette.count)
        for (color, listed) in zip(CombinedDashboardBadge.palette, CombinedDashboardBadge.paletteHues) {
            var hue: CGFloat = 0
            XCTAssertTrue(UIColor(color).getHue(&hue, saturation: nil, brightness: nil, alpha: nil))
            XCTAssertEqual(Double(hue), listed, accuracy: 0.002, "paletteHues drifted from the palette")
        }
        let hues = (6..<12).map(CombinedDashboardBadge.generatedHue)
        for (at, hue) in hues.enumerated() {
            for other in CombinedDashboardBadge.paletteHues + hues[..<at] {
                let apart = min(abs(hue - other), 1 - abs(hue - other))
                XCTAssertGreaterThan(apart, 0.03, "hue \(hue) sits on \(other)")
            }
        }
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    @MainActor
    private func makeAppState() -> AppState {
        let defaults = makeScratchDefaults("SidebarLayoutTests")
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: .live
        )
    }

    // MARK: - Projects view Pinned section (#338)
    //
    // Pinned chats from every project and source, archived ones skipped,
    // narrowed by the search field.

    private func pinnedTestSession(_ id: String, title: String? = nil, source: SessionSource = .chat, archived: Bool = false) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: title ?? id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: source,
            isActive: false,
            isArchived: archived,
            lineageRootId: nil
        )
    }

    private func titleMatches(_ session: SessionSummary, _ query: String) -> Bool {
        session.title.localizedCaseInsensitiveContains(query)
    }

    func testListsPinnedChatsFromEverySourceInOrderAndSkipsArchived() {
        let sessions = [
            pinnedTestSession("a", source: .chat),
            pinnedTestSession("b", source: .telegram),
            pinnedTestSession("c", source: .voice),
            pinnedTestSession("d", archived: true),
            pinnedTestSession("e")
        ]
        let pinned: Set<String> = ["a", "b", "c", "d"]

        let result = SidebarPinnedSessions.forProjectsView(
            sessions,
            query: "",
            isPinned: { pinned.contains($0.id) },
            matches: titleMatches
        )

        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    func testSearchNarrowsPinnedChatsAndBlankSearchKeepsAll() {
        let sessions = [pinnedTestSession("a", title: "Release notes"), pinnedTestSession("b", title: "Groceries")]

        let narrowed = SidebarPinnedSessions.forProjectsView(
            sessions, query: "  release ", isPinned: { _ in true }, matches: titleMatches
        )
        XCTAssertEqual(narrowed.map(\.id), ["a"])

        let blank = SidebarPinnedSessions.forProjectsView(
            sessions, query: "   ", isPinned: { _ in true }, matches: titleMatches
        )
        XCTAssertEqual(blank.map(\.id), ["a", "b"])
    }

    func testNothingPinnedGivesAnEmptySection() {
        let result = SidebarPinnedSessions.forProjectsView(
            [pinnedTestSession("a")], query: "", isPinned: { _ in false }, matches: titleMatches
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// Issue 2671: a Mac keeps the Sessions list's bar hidden, as before
    /// #2580; an iPhone and an iPad keep it shown for the pushed header.
    func testListKeepsItsBarShownExceptOnAMac() {
        XCTAssertTrue(V2ListNavigationBarPolicy.keepsBarShown(onMac: false))
        XCTAssertFalse(V2ListNavigationBarPolicy.keepsBarShown(onMac: true))
    }

    /// The Sessions list keeps its navigation bar shown (#2580): while the
    /// list is on top its keeper takes the bar's height out of the list's
    /// safe area and keeps the bar's touches and VoiceOver off; a page pushed
    /// over it gets the bar back as any screen has it, and the list takes it
    /// again once it's on top. Dismantled, the list's inset goes back to 0.
    @MainActor
    func testListKeepsItsShownBarOutOfTheWayOnlyWhileItsOnTop() {
        let list = UIViewController()
        let navigation = UINavigationController(navigationBarClass: SizableNavigationBar.self, toolbarClass: nil)
        navigation.setViewControllers([list], animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let bar = navigation.navigationBar
        XCTAssertFalse(navigation.isNavigationBarHidden)

        func waitUntil(_ what: String, _ condition: @escaping () -> Bool) {
            let met = expectation(description: what)
            func poll(_ triesLeft: Int) {
                if condition() { return met.fulfill() }
                guard triesLeft > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll(triesLeft - 1) }
            }
            poll(100)
            wait(for: [met], timeout: 3)
        }

        let keeper = V2ListNavigationBar.KeeperView()
        list.view.addSubview(keeper)
        waitUntil("the list takes the bar out of the way") {
            !bar.isUserInteractionEnabled && bar.accessibilityElementsHidden
        }
        XCTAssertGreaterThan(bar.bounds.height, 0)
        XCTAssertEqual(list.additionalSafeAreaInsets.top, -bar.bounds.height, "the list lies where it did under a hidden bar")

        // A chat pushed over the list: the bar is the chat's.
        navigation.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()
        waitUntil("the pushed page gets the bar back") {
            bar.isUserInteractionEnabled && !bar.accessibilityElementsHidden
        }

        // Back on the list: it takes the bar again.
        navigation.popViewController(animated: false)
        window.layoutIfNeeded()
        waitUntil("the list takes the bar again after the pop") {
            !bar.isUserInteractionEnabled && bar.accessibilityElementsHidden
        }
        XCTAssertEqual(list.additionalSafeAreaInsets.top, -bar.bounds.height)

        // The bar's height changes with the window (a turned phone, a
        // resized iPad window): the list's inset follows it, each time.
        for height in [CGFloat(70), 32] {
            // UIKit lays the bar out by its own height and lays it out
            // again whenever the list's safe area changes, so the test bar
            // reports the height it's given and announces it as a resize.
            (bar as? SizableNavigationBar)?.height = height
            navigation.view.setNeedsLayout()
            navigation.view.layoutIfNeeded()
            waitUntil("the list's inset follows a \(height) pt bar") {
                bar.bounds.height == height && list.additionalSafeAreaInsets.top == -height
            }
        }

        V2ListNavigationBar.dismantleUIView(keeper, coordinator: ())
        XCTAssertEqual(list.additionalSafeAreaInsets.top, 0)
        XCTAssertTrue(bar.isUserInteractionEnabled)
        XCTAssertFalse(bar.accessibilityElementsHidden)
        keeper.removeFromSuperview()
    }

    /// A keeper whose lookups ran out before its stack held the list
    /// (issue 2592) looks again on a later update of the list, and manages
    /// the bar once it finds the stack.
    @MainActor
    func testTheListBarKeeperFindsItsStackOnALaterUpdate() {
        let list = UIViewController()
        let navigation = UINavigationController(rootViewController: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let bar = navigation.navigationBar

        let keeper = V2ListNavigationBar.KeeperView()
        keeper.retries = 0
        var stackWired = false
        keeper.findPage = { view in stackWired ? SystemBackSwipeGate.pushedPage(of: view) : nil }
        list.view.addSubview(keeper)
        XCTAssertTrue(bar.isUserInteractionEnabled, "no stack found: the bar isn't managed yet")
        XCTAssertEqual(list.additionalSafeAreaInsets.top, 0)

        stackWired = true
        keeper.sync()
        XCTAssertFalse(bar.isUserInteractionEnabled, "a later update finds the stack")
        XCTAssertTrue(bar.accessibilityElementsHidden)
        XCTAssertEqual(list.additionalSafeAreaInsets.top, -bar.bounds.height)

        V2ListNavigationBar.dismantleUIView(keeper, coordinator: ())
        keeper.removeFromSuperview()
    }
}

/// A navigation bar whose height a test sets, standing in for the bar's
/// height changing with the window.
private final class SizableNavigationBar: UINavigationBar {
    /// The height the bar reports, whatever UIKit lays it out at. Setting it
    /// sets the bounds, so whoever observes them hears of the change.
    var height: CGFloat? {
        didSet { bounds = super.bounds }
    }

    override var bounds: CGRect {
        get {
            var reported = super.bounds
            if let height { reported.size.height = height }
            return reported
        }
        set { super.bounds = newValue }
    }
}
