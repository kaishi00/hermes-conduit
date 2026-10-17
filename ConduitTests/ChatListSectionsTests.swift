//
//  ChatListSectionsTests.swift
//  Conduit
//
//  The Chats list's date sections and their saved open/closed state
//  (#696). An extension of the nesting suite, so the planner gains no
//  class.
//

import XCTest
@testable import Conduit

extension SessionNestingModelTests {
    private var sectionCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// Friday 17 October 2026, 10:00 in Berlin.
    private var sectionNow: Date {
        sectionCalendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 10))!
    }

    private func at(day: Int, hour: Int) -> TimeInterval {
        sectionCalendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!.timeIntervalSince1970
    }

    private func sectionRow(_ id: String, activity: TimeInterval?, children: [SessionNesting.Node] = []) -> SessionNesting.Node {
        SessionNesting.Node(
            session: SessionSummary(
                id: id,
                alternateIds: [],
                title: id,
                model: "claude",
                updatedLabel: "",
                lastActivityAt: activity,
                profile: "default",
                source: .chat,
                isActive: false,
                isArchived: false
            ),
            children: children
        )
    }

    private func sectionLayout(_ groups: [ChatListSection.DateGroup]) -> [ChatListSection: [String]] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.section, $0.nodes.map(\.id)) })
    }

    func testDateSectionsFollowCalendarDays() {
        let section = { ChatListSection.dateSection(for: $0, now: self.sectionNow, calendar: self.sectionCalendar) }
        XCTAssertEqual(section(at(day: 17, hour: 0)), .today)
        XCTAssertEqual(section(at(day: 16, hour: 23)), .yesterday)
        XCTAssertEqual(section(at(day: 16, hour: 0)), .yesterday)
        XCTAssertEqual(section(at(day: 15, hour: 23)), .lastSevenDays)
        XCTAssertEqual(section(at(day: 11, hour: 0)), .lastSevenDays)
        XCTAssertEqual(section(at(day: 10, hour: 23)), .older)
    }

    func testRecentRootsSplitByDayInListOrderWithoutEmptySections() {
        let groups = ChatListSection.byDate(
            [
                sectionRow("a", activity: at(day: 17, hour: 9)),
                sectionRow("b", activity: at(day: 17, hour: 8)),
                sectionRow("c", activity: at(day: 13, hour: 8)),
                sectionRow("d", activity: at(day: 1, hour: 8)),
            ],
            now: sectionNow,
            calendar: sectionCalendar
        )
        XCTAssertEqual(groups.map(\.section), [.today, .lastSevenDays, .older])
        XCTAssertEqual(sectionLayout(groups), [.today: ["a", "b"], .lastSevenDays: ["c"], .older: ["d"]])
    }

    func testANestFilesUnderItsNewestRow() {
        let call = sectionRow("call", activity: at(day: 17, hour: 9))
        let groups = ChatListSection.byDate(
            [sectionRow("chat", activity: at(day: 2, hour: 8), children: [call])],
            now: sectionNow,
            calendar: sectionCalendar
        )
        XCTAssertEqual(sectionLayout(groups), [.today: ["chat"]])
    }

    func testARowWithoutATimestampFollowsTheRowBeforeIt() {
        let groups = ChatListSection.byDate(
            [
                sectionRow("untimed-top", activity: nil),
                sectionRow("old", activity: at(day: 1, hour: 8)),
                sectionRow("untimed", activity: nil),
            ],
            now: sectionNow,
            calendar: sectionCalendar
        )
        XCTAssertEqual(sectionLayout(groups), [.today: ["untimed-top"], .older: ["old", "untimed"]])
    }

    func testCollapsedSectionsRoundTripAndDefaultToTheOlderOnes() {
        XCTAssertEqual(ChatListSection.collapsed(from: ChatListSection.defaultCollapsedRaw), [.lastSevenDays, .older])
        XCTAssertEqual(ChatListSection.storageValue([.older, .pinned]), "pinned,older")
        XCTAssertEqual(ChatListSection.collapsed(from: "pinned,older,bogus"), [.pinned, .older])
        XCTAssertEqual(ChatListSection.collapsed(from: ""), [])
    }

    func testTheActiveRowsSectionIsWhereverItsRootIsListed() {
        let pinned = [sectionRow("pin", activity: at(day: 1, hour: 8))]
        let recent = ChatListSection.byDate(
            [
                sectionRow("new", activity: at(day: 17, hour: 9)),
                sectionRow("old", activity: at(day: 1, hour: 8), children: [sectionRow("job", activity: at(day: 2, hour: 8))]),
            ],
            now: sectionNow,
            calendar: sectionCalendar
        )
        XCTAssertEqual(ChatListSection.section(of: "pin", pinned: pinned, recent: recent), .pinned)
        XCTAssertEqual(ChatListSection.section(of: "new", pinned: pinned, recent: recent), .today)
        XCTAssertEqual(ChatListSection.section(of: "job", pinned: pinned, recent: recent), .older)
        XCTAssertNil(ChatListSection.section(of: "gone", pinned: pinned, recent: recent))
    }
}
