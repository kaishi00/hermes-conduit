//
//  ContextUploadPolicyTests.swift
//  ConduitTests
//
//  When calendar, health and a message's location go to Hermes again: the
//  spacing between routine passes, what Low Power and Low Data Mode hold
//  back, an upload with nothing new left out, and a message's fix reused
//  or not sent again. Written as an extension of an existing suite: the CI
//  test planner is at capacity for new XCTestCase classes.
//

import CoreLocation
import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    private static let uploadNow = Date(timeIntervalSince1970: 1_760_400_000)
    private static let lowPower = DeviceConditions(lowPowerMode: true)
    private static let lowData = DeviceConditions(lowDataMode: true)

    func testContextUploadsStretchOnlyForLowPowerAndLowData() {
        XCTAssertEqual(ContextUploadPolicy.stretch(DeviceConditions()), 1)
        XCTAssertEqual(ContextUploadPolicy.stretch(DeviceConditions(expensivePath: true)), 1, "Cellular alone isn't Low Data")
        XCTAssertEqual(ContextUploadPolicy.stretch(Self.lowData), 2)
        XCTAssertEqual(ContextUploadPolicy.stretch(DeviceConditions(lowPowerMode: true, lowDataMode: true)), 3,
                       "Low Power wins, the stretches don't multiply")
    }

    func testAPassIsDueOnceItsSpacingHasPassed() {
        let now = Self.uploadNow
        XCTAssertTrue(ContextUploadPolicy.isDue(lastAttempt: nil, spacing: 30, now: now))
        XCTAssertTrue(ContextUploadPolicy.isDue(lastAttempt: now, spacing: 0, now: now), "No spacing: always due")
        XCTAssertFalse(ContextUploadPolicy.isDue(lastAttempt: now.addingTimeInterval(-29), spacing: 30, now: now))
        XCTAssertTrue(ContextUploadPolicy.isDue(lastAttempt: now.addingTimeInterval(-30), spacing: 30, now: now))
        XCTAssertTrue(ContextUploadPolicy.isDue(lastAttempt: now.addingTimeInterval(60), spacing: 30, now: now),
                      "A clock that moved back doesn't hold passes off")
        XCTAssertNil(ContextUploadPolicy.remainingSpacing(lastAttempt: now.addingTimeInterval(-30), spacing: 30, now: now))
        XCTAssertEqual(ContextUploadPolicy.remainingSpacing(lastAttempt: now.addingTimeInterval(-52), spacing: 60, now: now) ?? 0,
                       8, accuracy: 1e-9)
    }

    func testPhonePassesSpaceRoutineMomentsAndNeverWhatWasAskedFor() {
        let normal = DeviceConditions()
        for reason in [PhoneSyncReason.foreground, .messageSent, .calendarChanged, .backgroundRefresh] {
            XCTAssertEqual(ContextUploadPolicy.phoneSpacing(for: reason, conditions: normal), 30, "\(reason)")
            XCTAssertEqual(ContextUploadPolicy.phoneSpacing(for: reason, conditions: Self.lowPower), 90, "\(reason)")
            XCTAssertEqual(ContextUploadPolicy.phoneSpacing(for: reason, conditions: Self.lowData), 60, "\(reason)")
        }
        XCTAssertEqual(ContextUploadPolicy.phoneSpacing(for: .voiceCall, conditions: Self.lowPower), 30,
                       "A call reads what's there: not stretched")
        for reason in [PhoneSyncReason.connected, .focusChanged, .push, .answered, .manual, .turnedOn] {
            XCTAssertEqual(ContextUploadPolicy.phoneSpacing(for: reason, conditions: Self.lowPower), 0, "\(reason)")
        }
    }

    func testAPhoneUploadWithNothingNewWaitsForTheKeepalive() {
        let now = Self.uploadNow
        let recent = now.addingTimeInterval(-60)
        func needed(news: Bool = false, frame: String = "f", last: String? = "f", posted: Date? = recent,
                    pending: Bool = true, at: Date = now) -> Bool {
            ContextUploadPolicy.phoneIngestNeeded(carriesNews: news, frame: frame, lastFrame: last, lastPosted: posted,
                                                  hostReportsPending: pending, now: at)
        }
        XCTAssertFalse(needed(), "Same sharing and time zone, nothing to send")
        XCTAssertTrue(needed(news: true))
        XCTAssertTrue(needed(frame: "g"), "Sharing or the time zone changed")
        XCTAssertTrue(needed(last: nil), "Never posted for this host")
        XCTAssertTrue(needed(posted: nil))
        XCTAssertTrue(needed(pending: false), "An older plugin's status doesn't say what's waiting: the upload does")
        XCTAssertFalse(needed(at: recent.addingTimeInterval(ContextUploadPolicy.phoneKeepalive - 1)))
        XCTAssertTrue(needed(at: recent.addingTimeInterval(ContextUploadPolicy.phoneKeepalive)), "Keepalive")
        XCTAssertTrue(needed(at: recent.addingTimeInterval(-1)), "A clock that moved back")

        // While the user is there the keepalive is a quarter hour, so the
        // host's "as of" stays recent; the user asking always posts.
        func keepalive(_ reason: PhoneSyncReason) -> TimeInterval { ContextUploadPolicy.phoneKeepalive(for: reason) }
        for reason in [PhoneSyncReason.foreground, .messageSent, .voiceCall, .connected, .answered] {
            XCTAssertEqual(keepalive(reason), 15 * 60, "\(reason)")
        }
        for reason in [PhoneSyncReason.calendarChanged, .focusChanged, .backgroundRefresh, .push] {
            XCTAssertEqual(keepalive(reason), 3 * 3600, "\(reason)")
        }
        XCTAssertEqual(keepalive(.manual), 0)
        XCTAssertEqual(keepalive(.turnedOn), 0)
        func neededWhilePresent(after elapsed: TimeInterval) -> Bool {
            ContextUploadPolicy.phoneIngestNeeded(carriesNews: false, frame: "f", lastFrame: "f", lastPosted: recent,
                                                  hostReportsPending: true, keepalive: keepalive(.messageSent),
                                                  now: recent.addingTimeInterval(elapsed))
        }
        XCTAssertFalse(neededWhilePresent(after: 14 * 60))
        XCTAssertTrue(neededWhilePresent(after: 15 * 60))
        XCTAssertTrue(ContextUploadPolicy.phoneIngestNeeded(carriesNews: false, frame: "f", lastFrame: "f", lastPosted: now,
                                                            hostReportsPending: true, keepalive: 0, now: now))
    }

    func testPhoneStatusCountsTheBatteryInFivePercentSteps() throws {
        func battery(_ level: Double) throws -> Double {
            let comparable = PhoneSyncEngine.comparableStatus(["battery": level, "charging": false, "at": "2026-10-14T00:00:00Z"])
            XCTAssertNil(comparable["at"], "Its time changes every time")
            XCTAssertEqual(comparable["charging"] as? Bool, false)
            return try XCTUnwrap(comparable["battery"] as? Double)
        }
        XCTAssertEqual(try battery(0.84), 0.8, accuracy: 1e-9)
        XCTAssertEqual(try battery(0.81), 0.8, accuracy: 1e-9)
        XCTAssertEqual(try battery(0.86), 0.85, accuracy: 1e-9)
        XCTAssertEqual(try battery(0.19), 0.19, accuracy: 1e-9, "Low levels count by the percent")
        XCTAssertNil(PhoneSyncEngine.comparableStatus(["charging": true])["battery"])
    }

    func testHealthPassesSpaceRoutineMomentsAndShareTheThrottleWithACall() {
        let normal = DeviceConditions()
        XCTAssertEqual(ContextUploadPolicy.healthSpacing(for: .foreground, conditions: normal), 180)
        XCTAssertEqual(ContextUploadPolicy.healthSpacing(for: .foreground, conditions: Self.lowPower), 540)
        XCTAssertEqual(ContextUploadPolicy.healthSpacing(for: .healthChanged, conditions: normal), 60)
        XCTAssertEqual(ContextUploadPolicy.healthSpacing(for: .backgroundRefresh, conditions: Self.lowData), 120)
        XCTAssertEqual(ContextUploadPolicy.healthSpacing(for: .voiceCall, conditions: normal), 180,
                       "A call reuses a pass from the last three minutes")
        XCTAssertEqual(ContextUploadPolicy.healthSpacing(for: .voiceCall, conditions: Self.lowPower), 180)
        for reason in [HealthSyncReason.connected, .manual, .turnedOn] {
            XCTAssertEqual(ContextUploadPolicy.healthSpacing(for: reason, conditions: Self.lowPower), 0, "\(reason)")
        }
    }

    func testHealthResendsRecentDaysWholeEverySixHoursExceptOnLowData() {
        let now = Self.uploadNow
        let routine = ContextUploadPolicy.healthPass(for: .foreground, conditions: DeviceConditions())
        XCTAssertEqual(routine, HealthPassOptions())
        XCTAssertTrue(ContextUploadPolicy.healthResendsRecent(routine, lastWhole: nil, now: now))
        XCTAssertFalse(ContextUploadPolicy.healthResendsRecent(routine, lastWhole: now.addingTimeInterval(-5 * 3600), now: now))
        XCTAssertTrue(ContextUploadPolicy.healthResendsRecent(routine, lastWhole: now.addingTimeInterval(-6 * 3600), now: now))
        XCTAssertTrue(ContextUploadPolicy.healthResendsRecent(routine, lastWhole: now.addingTimeInterval(60), now: now))

        let lowData = ContextUploadPolicy.healthPass(for: .healthChanged, conditions: Self.lowData)
        XCTAssertTrue(lowData.lowData)
        XCTAssertFalse(ContextUploadPolicy.healthResendsRecent(lowData, lastWhole: nil, now: now), "Only what changed")

        // A pass with nothing to send still posts every quarter hour.
        XCTAssertTrue(ContextUploadPolicy.healthNeedsKeepalive(lastPosted: nil, now: now))
        XCTAssertFalse(ContextUploadPolicy.healthNeedsKeepalive(lastPosted: now.addingTimeInterval(-14 * 60), now: now))
        XCTAssertTrue(ContextUploadPolicy.healthNeedsKeepalive(lastPosted: now.addingTimeInterval(-15 * 60), now: now))

        // A pass already running covers a request only if it does as much.
        let whole = HealthPassOptions(resendRecent: true)
        XCTAssertTrue(whole.covers(routine))
        XCTAssertFalse(routine.covers(whole), "Sync now during a routine pass runs again after it")
        XCTAssertFalse(lowData.covers(routine), "A Low Data pass leaves out history")
        XCTAssertTrue(routine.covers(lowData))
        XCTAssertTrue(lowData.covers(lowData))

        // Sync now and turning sharing on send everything, whatever the mode.
        for reason in [HealthSyncReason.manual, .turnedOn] {
            let asked = ContextUploadPolicy.healthPass(for: reason, conditions: DeviceConditions(lowPowerMode: true, lowDataMode: true))
            XCTAssertEqual(asked, HealthPassOptions(resendRecent: true, lowData: false), "\(reason)")
            XCTAssertTrue(ContextUploadPolicy.healthResendsRecent(asked, lastWhole: now, now: now))
        }
    }

    func testAMessageReusesARecentFixOnlyWhileStillAndSharpEnough() {
        let precise = kCLLocationAccuracyNearestTenMeters
        func reuses(age: TimeInterval, accuracy: Double = 15, speed: Double = -1, wanted: Double = precise) -> Bool {
            ContextUploadPolicy.reusesFix(age: age, accuracy: accuracy, speed: speed, wanted: wanted)
        }
        XCTAssertTrue(reuses(age: 10, speed: 30), "What iOS's cache answers anyway, even moving")
        XCTAssertTrue(reuses(age: 4 * 60, speed: 0), "Still, a few minutes old")
        XCTAssertTrue(reuses(age: 4 * 60, speed: 1.2), "Walking pace")
        XCTAssertTrue(reuses(age: 90), "Speed unknown: only recent and sharp")
        XCTAssertFalse(reuses(age: 3 * 60), "Speed unknown and minutes old")
        XCTAssertFalse(reuses(age: 90, accuracy: 80, wanted: kCLLocationAccuracyHundredMeters), "Speed unknown and rough")
        XCTAssertFalse(reuses(age: 4 * 60, speed: 12), "Driving: a new fix")
        XCTAssertFalse(reuses(age: 6 * 60, speed: 0), "Too old")
        XCTAssertFalse(reuses(age: 60, accuracy: 300), "Too rough for a precise ask")
        XCTAssertTrue(reuses(age: 60, accuracy: 60, wanted: kCLLocationAccuracyHundredMeters))
        XCTAssertTrue(reuses(age: 4 * 60, accuracy: 90, speed: 0, wanted: kCLLocationAccuracyHundredMeters))
        XCTAssertFalse(reuses(age: 60, accuracy: -1), "Invalid")
        XCTAssertFalse(reuses(age: -5), "From the future")
    }

    func testAMessagesFixIsSentAgainOnlyWhenItMovedOrAged() {
        let now = Self.uploadNow
        let host = LocationTalkingUpload.Host(keyAgreements: 1, generation: "g1")
        let here = LocationRawFix(latitude: 51.5321, longitude: -0.0755, accuracy: 20, timestamp: now)
        let last = LocationTalkingUpload(fix: here, precision: .precise, host: host, sentAt: now.addingTimeInterval(-120))
        func news(_ fix: LocationRawFix = here, precision: LocationPrecision = .precise,
                  host: LocationTalkingUpload.Host = host, last: LocationTalkingUpload? = last,
                  at: Date = now, conditions: DeviceConditions = DeviceConditions()) -> Bool {
            ContextUploadPolicy.messageFixIsNews(fix, precision: precision, host: host, last: last, now: at, conditions: conditions)
        }
        func moved(_ meters: Double, accuracy: Double = 20) -> LocationRawFix {
            // About 111 km per degree of latitude.
            LocationRawFix(latitude: here.latitude + meters / 111_000, longitude: here.longitude, accuracy: accuracy, timestamp: now)
        }
        XCTAssertTrue(news(last: nil), "Nothing sent yet")
        XCTAssertFalse(news(), "Same place two minutes later")
        XCTAssertFalse(news(moved(60)), "Under 100 m isn't a move")
        XCTAssertTrue(news(moved(250)))
        XCTAssertFalse(news(moved(250, accuracy: 400)), "Within the new fix's own accuracy")
        XCTAssertTrue(news(precision: .area), "Another precision")
        XCTAssertTrue(news(host: LocationTalkingUpload.Host(keyAgreements: 2, generation: "g1")), "A new key drops the host's fix")
        XCTAssertTrue(news(host: LocationTalkingUpload.Host(keyAgreements: 1, generation: "g2")), "A new store too")

        // Repeats every ten minutes, stretched in Low Power Mode up to thirty.
        let sent = last.sentAt
        XCTAssertFalse(news(at: sent.addingTimeInterval(9 * 60)))
        XCTAssertTrue(news(at: sent.addingTimeInterval(10 * 60)))
        XCTAssertFalse(news(at: sent.addingTimeInterval(25 * 60), conditions: Self.lowPower))
        XCTAssertTrue(news(at: sent.addingTimeInterval(30 * 60), conditions: Self.lowPower))
        XCTAssertFalse(news(at: sent.addingTimeInterval(19 * 60), conditions: Self.lowData))
        XCTAssertTrue(news(at: sent.addingTimeInterval(-1)), "A clock that moved back")

        // A much sharper fix after a rough one is news even nearby.
        let rough = LocationTalkingUpload(fix: moved(0, accuracy: 900), precision: .precise, host: host, sentAt: sent)
        XCTAssertTrue(news(moved(50, accuracy: 15), last: rough))
        XCTAssertFalse(news(moved(50, accuracy: 600), last: rough))
    }
}
