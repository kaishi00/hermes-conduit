import Foundation
import XCTest
@testable import Conduit

/// Conduit for desktop, offered once from Chats (OtherAppOffer.swift): the
/// plugin's /link-status record, the three-day wait and the one-time rule.
final class OtherAppOfferTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "OtherAppOfferTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func status(seenAt: Any, open: Int) -> [String: Any] {
        ["ok": true, "clients": ["ios": ["seen_at": 1.0, "open_sockets": 1], "desktop": ["seen_at": seenAt, "open_sockets": open]]]
    }

    func testReadsWhetherConduitForDesktopReachedTheHost() throws {
        let data = #"{"ok":true,"clients":{"ios":{"seen_at":5.0,"open_sockets":1},"desktop":{"seen_at":null,"open_sockets":0}}}"#.data(using: .utf8)!
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(OtherAppOffer.hostClients(from: parsed), .init(desktopSeen: false, desktopOpen: false))
        XCTAssertEqual(OtherAppOffer.hostClients(from: status(seenAt: 1_800_000_000.0, open: 0)), .init(desktopSeen: true, desktopOpen: false))
        XCTAssertEqual(OtherAppOffer.hostClients(from: status(seenAt: NSNull(), open: 2)), .init(desktopSeen: true, desktopOpen: true))
    }

    func testAPluginBefore0207SaysNothing() {
        XCTAssertNil(OtherAppOffer.hostClients(from: ["ok": true, "app": ["state": "connected"]]))
    }

    func testOffersOnlyWhereNothingSaysThePersonHasIt() {
        let none = OtherAppOffer.HostClients(desktopSeen: false, desktopOpen: false)
        let days = OtherAppOffer.daysBeforeOffer
        XCTAssertTrue(OtherAppOffer.offersDesktop(none, daysUsed: days, done: false, pairedComputer: false))
        XCTAssertFalse(OtherAppOffer.offersDesktop(none, daysUsed: days - 1, done: false, pairedComputer: false))
        XCTAssertFalse(OtherAppOffer.offersDesktop(none, daysUsed: days, done: true, pairedComputer: false))
        XCTAssertFalse(OtherAppOffer.offersDesktop(none, daysUsed: days, done: false, pairedComputer: true))
        XCTAssertFalse(OtherAppOffer.offersDesktop(.init(desktopSeen: true, desktopOpen: false), daysUsed: days, done: false, pairedComputer: false))
        XCTAssertFalse(OtherAppOffer.offersDesktop(nil, daysUsed: days, done: false, pairedComputer: false))
    }

    func testCountsSeparateDaysNotLaunches() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ d: Int, hour: Int = 9) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))!
        }
        XCTAssertEqual(OtherAppOffer.noteDayUsed(now: day(1), calendar: calendar, defaults: defaults), 1)
        XCTAssertEqual(OtherAppOffer.noteDayUsed(now: day(1, hour: 20), calendar: calendar, defaults: defaults), 1)
        XCTAssertEqual(OtherAppOffer.noteDayUsed(now: day(3), calendar: calendar, defaults: defaults), 2)
        XCTAssertEqual(OtherAppOffer.noteDayUsed(now: day(9), calendar: calendar, defaults: defaults), 3)
        XCTAssertEqual(OtherAppOffer.noteDayUsed(now: day(10), calendar: calendar, defaults: defaults), 3)
    }

    func testTheCardStaysRetiredAndAPairedComputerCounts() {
        XCTAssertFalse(OtherAppOffer.isDone(defaults: defaults))
        OtherAppOffer.retire(defaults: defaults)
        XCTAssertTrue(OtherAppOffer.isDone(defaults: defaults))
        XCTAssertFalse(OtherAppOffer.pairedComputer(defaults: defaults))
        OtherAppOffer.notePairedComputer(defaults: defaults)
        XCTAssertTrue(OtherAppOffer.pairedComputer(defaults: defaults))
    }
}
