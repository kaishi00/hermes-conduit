import XCTest
@testable import Conduit

/// The Projects view's Pinned section (#338) lists pinned chats from every
/// project and source, skips archived ones, and follows the search field.
final class SidebarPinnedSessionsTests: XCTestCase {

    private func session(_ id: String, title: String? = nil, source: SessionSource = .chat, archived: Bool = false) -> SessionSummary {
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
            session("a", source: .chat),
            session("b", source: .telegram),
            session("c", source: .voice),
            session("d", archived: true),
            session("e")
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
        let sessions = [session("a", title: "Release notes"), session("b", title: "Groceries")]

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
            [session("a")], query: "", isPinned: { _ in false }, matches: titleMatches
        )
        XCTAssertTrue(result.isEmpty)
    }
}
