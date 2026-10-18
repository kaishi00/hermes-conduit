import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Tasks › Board (V2): every lane the dashboard reports is a reachable
/// column, Blocked and Done included. The dashboard's GET /board always
/// answers its full lane list (triage, todo, scheduled, ready, running,
/// blocked, review, done, plus archived when asked for); the board keeps
/// all of them, in workflow order, each with its own name and count.
@MainActor
final class KanbanColumnBoardTests: XCTestCase {
    static let serverLanes = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]

    /// A task row shaped like the dashboard's `_task_dict` (asdict of the
    /// task plus the board's derived fields).
    static func serverTask(_ id: String, status: String) -> [String: Any] {
        [
            "id": id, "title": "Task \(id)", "body": "Body", "assignee": "default", "status": status,
            "priority": 0, "created_by": "user", "created_at": 1_792_000_000, "started_at": NSNull(),
            "completed_at": status == "done" ? 1_792_000_100 : NSNull(), "workspace_kind": "scratch",
            "workspace_path": NSNull(), "tenant": NSNull(), "result": NSNull(), "skills": [String](),
            "age": ["created_age_seconds": 100, "started_age_seconds": NSNull(), "time_to_complete_seconds": NSNull()],
            "latest_summary": NSNull(), "link_counts": ["parents": 0, "children": 0],
            "comment_count": 0, "progress": NSNull()
        ]
    }

    /// The board this bug was found on: 3 Blocked, 13 Done, every other
    /// lane empty.
    static func serverBoard(includeArchived: Bool = false, extraLanes: [String] = []) -> [String: Any] {
        var lanes = serverLanes + extraLanes
        if includeArchived { lanes.append("archived") }
        let columns: [[String: Any]] = lanes.map { lane in
            let count = lane == "blocked" ? 3 : (lane == "done" ? 13 : (lane == "archived" ? 27 : 0))
            return ["name": lane, "tasks": (0..<count).map { serverTask("t_\(lane)_\($0)", status: lane) }]
        }
        return ["columns": columns, "tenants": [String](), "assignees": ["default"], "latest_event_id": 42, "now": 1_792_000_200]
    }

    static func decodedBoard(_ json: [String: Any]) throws -> KanbanBoard {
        try JSONDecoder().decode(KanbanBoard.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Column set and status mapping

    func testEveryServerLaneIsAColumnInWorkflowOrder() throws {
        let board = try Self.decodedBoard(Self.serverBoard())
        let columns = KanbanBoardFilterPolicy.visibleColumns(board: board, search: "", assignee: nil, tenant: nil)
        XCTAssertEqual(columns.map(\.name), Self.serverLanes)
        let summaries = KanbanColumnBoardPolicy.summaries(for: columns)
        XCTAssertEqual(summaries.map(\.status), Self.serverLanes)
        XCTAssertEqual(summaries.map(\.count), [0, 0, 0, 0, 0, 3, 0, 13])
    }

    func testBlockedAndDoneMapToTheirOwnColumns() throws {
        let board = try Self.decodedBoard(Self.serverBoard())
        let summaries = KanbanColumnBoardPolicy.summaries(
            for: KanbanBoardFilterPolicy.visibleColumns(board: board, search: "", assignee: nil, tenant: nil)
        )
        let blocked = try XCTUnwrap(summaries.first { $0.status == "blocked" })
        XCTAssertEqual(blocked.title, AppLocalization.string("Blocked"))
        XCTAssertEqual(blocked.count, 3)
        XCTAssertFalse(blocked.isLocked)
        let done = try XCTUnwrap(summaries.first { $0.status == "done" })
        XCTAssertEqual(done.title, AppLocalization.string("Done"))
        XCTAssertEqual(done.count, 13)
        XCTAssertFalse(done.isLocked)
        // Every card sits in the column of its own status.
        for column in board.columns {
            XCTAssertTrue(column.tasks.allSatisfy { $0.status == column.name }, column.name)
        }
        // The system lanes keep their lock.
        XCTAssertEqual(summaries.filter(\.isLocked).map(\.status), ["scheduled", "running", "review"])
    }

    func testArchivedAndUnknownLanesStayOnTheBoard() throws {
        let board = try Self.decodedBoard(Self.serverBoard(includeArchived: true, extraLanes: ["qa_hold"]))
        let columns = KanbanBoardFilterPolicy.visibleColumns(board: board, search: "", assignee: nil, tenant: nil)
        XCTAssertEqual(columns.map(\.name), Self.serverLanes + ["archived", "qa_hold"])
        let summaries = KanbanColumnBoardPolicy.summaries(for: columns)
        XCTAssertEqual(summaries.first { $0.status == "archived" }?.count, 27)
        XCTAssertEqual(summaries.last?.title, "Qa Hold")
        XCTAssertEqual(summaries.last?.isLocked, true)
    }

    /// A search narrows the cards, never the lanes: Blocked and Done stay
    /// reachable with their filtered counts.
    func testFiltersKeepEveryColumn() throws {
        let board = try Self.decodedBoard(Self.serverBoard())
        let columns = KanbanBoardFilterPolicy.visibleColumns(board: board, search: "t_done_1", assignee: nil, tenant: nil)
        XCTAssertEqual(columns.map(\.name), Self.serverLanes)
        // t_done_1 and t_done_10…12.
        XCTAssertEqual(KanbanColumnBoardPolicy.summaries(for: columns).map(\.count), [0, 0, 0, 0, 0, 0, 0, 4])
    }

    func testJumpBarMarksTheScrolledColumnOrTheFirst() throws {
        let board = try Self.decodedBoard(Self.serverBoard())
        XCTAssertEqual(KanbanColumnBoardPolicy.currentColumn(scrolledTo: nil, in: board.columns), "triage")
        XCTAssertEqual(KanbanColumnBoardPolicy.currentColumn(scrolledTo: "done", in: board.columns), "done")
        // A lane the new snapshot no longer has falls back to the first.
        XCTAssertEqual(KanbanColumnBoardPolicy.currentColumn(scrolledTo: "gone", in: board.columns), "triage")
        XCTAssertNil(KanbanColumnBoardPolicy.currentColumn(scrolledTo: "done", in: []))
    }

    // MARK: - The real board, hosted

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scrollView = view as? UIScrollView { found.append(scrollView) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    private func pump(_ host: UIView, until condition: () -> Bool = { false }, iterations: Int = 100) {
        for _ in 0..<iterations {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            host.setNeedsLayout()
            host.layoutIfNeeded()
            if condition() { return }
        }
    }

    /// KanbanView(columnsLayout:) over a store answering the board above,
    /// at an iPhone 17 Pro's width with V2's side gutters.
    func testHostedBoardReachesEveryColumnAndScrollsOnlySideways() throws {
        let suiteName = "KanbanColumnBoardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let bridge = DashboardTicketBridge(baseURL: "https://kanban.example.test")
        bridge.webViewCanRun = { false }
        appState.installDashboardTicketBridgeForTesting(bridge)
        let requester = ColumnBoardRequester(board: Self.serverBoard())
        let store = KanbanStore(defaults: defaults, serviceFactory: { _ in KanbanService(requester: requester) })

        let host = UIHostingController(
            rootView: KanbanView(columnsLayout: true, store: store)
                .padding(.horizontal, 14)
                .environmentObject(appState)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window

        // The board: the sideways scroll view taller than the jump bar.
        func board() -> UIScrollView? {
            scrollViews(in: host.view).first { $0.bounds.height > 200 && $0.contentSize.width > $0.bounds.width + 1 }
        }
        // One vertical card list per column.
        func columnLists() -> [UIScrollView] {
            scrollViews(in: host.view).filter { abs($0.bounds.width - 250) < 0.5 }
        }
        pump(host.view, until: { board() != nil && columnLists().count == Self.serverLanes.count })
        XCTAssertEqual(store.board?.columns.map(\.name), Self.serverLanes)

        let boardScroll = try XCTUnwrap(board(), "the column board did not appear")
        // Every lane is laid out, not only those on screen.
        XCTAssertEqual(columnLists().count, Self.serverLanes.count)
        // Eight 250 pt columns, their padding and spacing fit in the content.
        XCTAssertGreaterThanOrEqual(boardScroll.contentSize.width, CGFloat(Self.serverLanes.count) * 270)
        // Sideways only: no refresh control of its own and no vertical
        // bounce, so a swipe that isn't level still moves along the lanes.
        XCTAssertNil(boardScroll.refreshControl)
        XCTAssertFalse(boardScroll.alwaysBounceVertical)
        XCTAssertLessThanOrEqual(boardScroll.contentSize.height, boardScroll.bounds.height + 0.5)
        // Each column's list refreshes instead.
        XCTAssertTrue(columnLists().allSatisfy { $0.refreshControl != nil })

        // The far end shows Done, with its 13 cards laid out.
        boardScroll.setContentOffset(
            CGPoint(x: boardScroll.contentSize.width - boardScroll.bounds.width, y: 0),
            animated: false
        )
        pump(host.view, iterations: 10)
        let visible = boardScroll.convert(boardScroll.bounds, to: nil)
        let doneList = try XCTUnwrap(columnLists().max { lhs, rhs in
            lhs.convert(lhs.bounds, to: nil).minX < rhs.convert(rhs.bounds, to: nil).minX
        })
        XCTAssertTrue(visible.intersects(doneList.convert(doneList.bounds, to: nil)), "Done is out of reach")
        XCTAssertGreaterThan(doneList.contentSize.height, 13 * 40)

        // The jump bar above lists every lane.
        let jumpBar = try XCTUnwrap(scrollViews(in: host.view).first { $0 !== boardScroll && $0.bounds.height < 60 })
        XCTAssertGreaterThan(jumpBar.contentSize.width, jumpBar.bounds.width)
    }
}

@MainActor
private final class ColumnBoardRequester: DashboardJSONRequester {
    let board: [String: Any]

    init(board: [String: Any]) { self.board = board }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        switch path.components(separatedBy: "?").first ?? path {
        case "/api/plugins/kanban/boards":
            return ["boards": [["slug": "default", "name": "Default", "is_current": true, "total": 43]], "current": "default"]
        case "/api/plugins/kanban/board":
            return board
        default:
            return [:]
        }
    }
}
