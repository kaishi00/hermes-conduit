//
//  ProfileTimeZoneTests.swift
//  Conduit
//
//  The profile `timezone` setting is checked before it is saved: Hermes
//  reads it with zoneinfo, which wants the exact IANA spelling and quietly
//  falls back to the server's local time for anything else.
//

import XCTest
@testable import Conduit

final class ProfileTimeZoneTests: XCTestCase {
    func testBlankMeansTheServersLocalTime() {
        XCTAssertEqual(ProfileTimeZone.resolve(""), .serverLocal)
        XCTAssertEqual(ProfileTimeZone.resolve("   \n"), .serverLocal)
        XCTAssertEqual(ProfileTimeZone.resolve("").storedValue, "")
    }

    func testAKnownNameIsKeptAndTrimmed() {
        XCTAssertEqual(ProfileTimeZone.resolve("America/Toronto"), .identifier("America/Toronto"))
        XCTAssertEqual(ProfileTimeZone.resolve("  Europe/Paris "), .identifier("Europe/Paris"))
    }

    func testAnyLetterCaseBecomesTheCanonicalSpelling() {
        XCTAssertEqual(ProfileTimeZone.resolve("america/toronto"), .identifier("America/Toronto"))
        XCTAssertEqual(ProfileTimeZone.resolve("EUROPE/PARIS").storedValue, "Europe/Paris")
    }

    func testSpacesStandInForUnderscores() {
        XCTAssertEqual(ProfileTimeZone.resolve("america/new york"), .identifier("America/New_York"))
    }

    func testUTCIsAccepted() {
        XCTAssertEqual(ProfileTimeZone.resolve("utc"), .identifier("UTC"))
    }

    func testAnythingElseIsRefused() {
        for value in ["Toronto", "EST5", "America/Torronto", "+05:00", "local"] {
            XCTAssertEqual(ProfileTimeZone.resolve(value), .invalid, value)
            XCTAssertNil(ProfileTimeZone.resolve(value).storedValue, value)
        }
    }

    func testThisDevicesZoneIsAlwaysAValidChoice() {
        let device = TimeZone.current.identifier
        XCTAssertEqual(ProfileTimeZone.resolve(device), .identifier(device))
    }

    func testMatchingIgnoresCaseAndSpaces() {
        XCTAssertTrue(ProfileTimeZone.matches(" america/toronto", "America/Toronto"))
        XCTAssertFalse(ProfileTimeZone.matches("", "America/Toronto"))
    }

    // MARK: Schedule zone label

    func testASchedulesZoneIsNamedOnlyWhenItDiffersFromTheDevice() {
        let paris = TimeZone(identifier: "Europe/Paris")!
        XCTAssertEqual(ProfileTimeZone.scheduleZoneLabel(profileSetting: "America/Toronto", device: paris), "America/Toronto")
        XCTAssertEqual(ProfileTimeZone.scheduleZoneLabel(profileSetting: "america/toronto", device: paris), "America/Toronto")
        XCTAssertNil(ProfileTimeZone.scheduleZoneLabel(profileSetting: "Europe/Paris", device: paris))
    }

    func testAZoneWithTheDevicesRulesNeedsNoLabel() {
        // Toronto and New York share offsets and transitions.
        let newYork = TimeZone(identifier: "America/New_York")!
        XCTAssertNil(ProfileTimeZone.scheduleZoneLabel(profileSetting: "America/Toronto", device: newYork))
    }

    func testTheServersOwnZoneOrAnUnknownOneIsNotNamed() {
        let paris = TimeZone(identifier: "Europe/Paris")!
        XCTAssertNil(ProfileTimeZone.scheduleZoneLabel(profileSetting: nil, device: paris))
        XCTAssertNil(ProfileTimeZone.scheduleZoneLabel(profileSetting: "", device: paris))
        XCTAssertNil(ProfileTimeZone.scheduleZoneLabel(profileSetting: "Mars/Olympus", device: paris))
    }
}
