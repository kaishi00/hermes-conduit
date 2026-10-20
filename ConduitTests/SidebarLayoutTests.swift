//
//  SidebarLayoutTests.swift
//  Conduit
//
//  Coverage for the iPad persistent-sidebar layout policy and the drawer
//  dismissal helper shared by the sidebar's session-opening flows.
//

import Combine
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
        for width: CGFloat in [0, 320, 417, 512, 683, 749] {
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
            SidebarLayoutMetrics.persistentSidebarWidth + SidebarLayoutMetrics.minimumChatWidth
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
        updates.isShown = true
        XCTAssertEqual(sent, 1)

        // Nothing missed, nothing to draw.
        sent = 0
        updates.isShown = false
        updates.isShown = true
        XCTAssertEqual(sent, 0)
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

        updates.isScrolling = true
        for index in 0..<20 { state.sessions = [pinnedTestSession("s\(index)")] }
        XCTAssertEqual(sent, 0, "a publish redrew the list mid-scroll")
        updates.isScrolling = false
        XCTAssertEqual(sent, 1)

        // Nothing held, nothing to draw.
        sent = 0
        updates.isScrolling = true
        updates.isScrolling = false
        XCTAssertEqual(sent, 0)

        // A drag held past the limit draws, then holds again.
        updates.isScrolling = true
        state.sessions = [pinnedTestSession("early")]
        XCTAssertEqual(sent, 0)
        clock += updates.scrollHoldLimit
        state.sessions = [pinnedTestSession("late")]
        XCTAssertEqual(sent, 1)
        state.sessions = [pinnedTestSession("later")]
        XCTAssertEqual(sent, 1)
        updates.isScrolling = false
        XCTAssertEqual(sent, 2)

        // Covered when the scroll rests, it waits to be shown.
        sent = 0
        updates.isScrolling = true
        state.sessions = [pinnedTestSession("covered")]
        updates.isShown = false
        updates.isScrolling = false
        XCTAssertEqual(sent, 0)
        updates.isShown = true
        XCTAssertEqual(sent, 1)
    }

    /// Beside a chat the scroll holds too, and a scroll past the hold
    /// limit still draws, after the coalescing delay.
    @MainActor
    func testScrollingChatsListBesideAChatDrawsPastTheHoldLimit() {
        let state = makeAppState()
        let updates = V2ShownUpdates(state)
        updates.coalesces = true
        updates.coalescingDelay = 0.05
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        updates.now = { clock }
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }

        updates.isScrolling = true
        state.sessions = [pinnedTestSession("early")]
        settle()
        XCTAssertEqual(sent, 0, "a publish redrew the list mid-scroll")

        clock += updates.scrollHoldLimit
        state.sessions = [pinnedTestSession("late")]
        waitUntil { sent > 0 }
        XCTAssertEqual(sent, 1, "the hold limit never drew beside a chat")

        state.sessions = [pinnedTestSession("later")]
        settle()
        XCTAssertEqual(sent, 1, "the draw didn't restart the hold")
        updates.isScrolling = false
        waitUntil { sent > 1 }
        XCTAssertEqual(sent, 2)
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

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    @MainActor
    private func makeAppState() -> AppState {
        let suite = "SidebarLayoutTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
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
}
