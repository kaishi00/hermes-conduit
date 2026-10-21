//
//  AppStateIntegerValueTests.swift
//  Conduit
//
//  The loose integer reading behind cron run times and dashboard pagination:
//  gateway numbers arrive as ints, floats, or strings, and one no Int can
//  hold must read as missing rather than as a wrapped value.
//

import XCTest
@testable import Conduit

final class AppStateIntegerValueTests: XCTestCase {
    func testIntegersAndIntegralStringsReadAsIs() {
        XCTAssertEqual(AppState.integerValue(1_729_435_000), 1_729_435_000)
        XCTAssertEqual(AppState.integerValue(NSNumber(value: 42)), 42)
        XCTAssertEqual(AppState.integerValue("200"), 200)
    }

    func testFractionalEpochsTruncateTowardZero() {
        XCTAssertEqual(AppState.integerValue(NSNumber(value: 1_729_435_000.5)), 1_729_435_000)
        XCTAssertEqual(AppState.integerValue(NSNumber(value: -2.7)), -2)
        XCTAssertEqual(AppState.integerValue("1729435000.5"), 1_729_435_000)
    }

    func testNumbersNoIntCanHoldReadAsMissing() {
        XCTAssertNil(AppState.integerValue(NSNumber(value: 1e300)))
        XCTAssertNil(AppState.integerValue(NSNumber(value: -1e300)))
        XCTAssertNil(AppState.integerValue(NSNumber(value: Double.nan)))
        XCTAssertNil(AppState.integerValue(NSNumber(value: Double.infinity)))
        XCTAssertNil(AppState.integerValue("1e300"))
    }

    func testJSONDecodedFloatsTakeTheSamePath() throws {
        // What JSONSerialization hands decodeCronRun and the pagination reads.
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"a": 1729435000.5, "b": 1e300}"#.utf8)) as? [String: Any]
        )
        XCTAssertEqual(AppState.integerValue(object["a"]), 1_729_435_000)
        XCTAssertNil(AppState.integerValue(object["b"]))
    }

    func testJSONBooleansReadAsMissingRatherThanOneOrZero() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"yes": true, "no": false, "one": 1}"#.utf8)) as? [String: Any]
        )
        XCTAssertNil(AppState.integerValue(object["yes"]))
        XCTAssertNil(AppState.integerValue(object["no"]))
        XCTAssertNil(AppState.integerValue(true))
        XCTAssertEqual(AppState.integerValue(object["one"]), 1, "a JSON 1 is still an integer")
    }

    func testNonNumbersReadAsMissing() {
        XCTAssertNil(AppState.integerValue(nil))
        XCTAssertNil(AppState.integerValue("soon"))
        XCTAssertNil(AppState.integerValue(["1"]))
    }
}
