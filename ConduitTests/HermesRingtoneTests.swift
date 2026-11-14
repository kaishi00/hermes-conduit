//
//  HermesRingtoneTests.swift
//  ConduitTests
//
//  The ringtone a call from Hermes rings with (issue 2445). In
//  VoiceConversationControllerTests, like HermesCallsTests.swift, as the
//  unit suite is at its class cap.
//

import AVFoundation
import XCTest
@testable import Conduit

extension VoiceConversationControllerTests {
    private func ringtoneDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "HermesRingtoneTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testCallsRingWithIOSDefaultUntilATonesPicked() {
        let store = HermesRingtoneStore(defaults: ringtoneDefaults())
        XCTAssertEqual(store.forAll, .system)
        XCTAssertEqual(store.ringtone(profile: "furina"), .system)
        XCTAssertNil(HermesRingtone.system.ringtoneSound, "iOS's own: CallKit is given no sound")
        // A value a later build wrote and this one doesn't know.
        store.defaults.set("gong", forKey: HermesRingtoneStore.allKey)
        XCTAssertEqual(store.forAll, .system)
    }

    func testABotsOwnRingtoneWinsOverEveryBots() {
        let store = HermesRingtoneStore(defaults: ringtoneDefaults())
        store.forAll = .chime
        XCTAssertEqual(store.ringtone(profile: "furina"), .chime)
        store.setOwn(.orbit, profile: "Furina")
        XCTAssertEqual(store.own(profile: "furina"), .orbit, "A bot is its profile, as for its contact's address")
        XCTAssertEqual(store.ringtone(profile: "furina"), .orbit)
        XCTAssertEqual(store.ringtone(profile: "nova"), .chime, "Other bots keep every bot's")
        XCTAssertEqual(store.ringtone(profile: "default"), .chime)
        // iOS's own can be one bot's too, while the others ring with a tone.
        store.setOwn(.system, profile: "default")
        XCTAssertEqual(store.ringtone(profile: "default"), .system)
        store.setOwn(nil, profile: "furina")
        XCTAssertNil(store.own(profile: "furina"))
        XCTAssertEqual(store.ringtone(profile: "furina"), .chime)
        store.setOwn(nil, profile: "default")
        XCTAssertNil(store.defaults.object(forKey: HermesRingtoneStore.botsKey), "Nothing kept once no bot has its own")
        store.forAll = .system
        XCTAssertNil(store.defaults.object(forKey: HermesRingtoneStore.allKey))
    }

    func testACallNamingNoProfileRingsWithEveryBots() {
        let store = HermesRingtoneStore(defaults: ringtoneDefaults())
        store.forAll = .signal
        store.setOwn(.beacon, profile: nil)
        store.setOwn(.beacon, profile: "  ")
        XCTAssertNil(store.defaults.object(forKey: HermesRingtoneStore.botsKey))
        XCTAssertEqual(store.ringtone(profile: nil), .signal)
        XCTAssertNil(HermesRingtoneStore.bot(nil))
        XCTAssertNotNil(HermesRingtoneStore.bot("default"))
    }

    func testTheWatchKeepsTheRingtonesTheIPhoneShares() throws {
        let phone = HermesRingtoneStore(defaults: ringtoneDefaults("phone"))
        phone.forAll = .lantern
        phone.setOwn(.signal, profile: "furina")
        let context = WatchPhoneContext(callsRing: true, ringtone: phone.forAll.rawValue, botRingtones: phone.bots)
        let decoded = try JSONDecoder().decode(WatchPhoneContext.self, from: JSONEncoder().encode(context))
        let watch = HermesRingtoneStore(defaults: ringtoneDefaults("watch"))
        watch.keep(decoded)
        XCTAssertEqual(watch.ringtone(profile: "Furina"), .signal)
        XCTAssertEqual(watch.ringtone(profile: "nova"), .lantern)
        XCTAssertEqual(watch.ringtone(profile: nil), .lantern, "A sealed push names no profile: every bot's")
        // An older iPhone app's context names no ringtone: the last stands.
        let older = try JSONDecoder().decode(WatchPhoneContext.self, from: JSONEncoder().encode(WatchPhoneContext(voices: [:], callsRing: true)))
        XCTAssertNil(older.ringtone)
        watch.keep(older)
        watch.keep(nil)
        XCTAssertEqual(watch.ringtone(profile: "furina"), .signal)
        // Back to iOS's own, with no bot keeping its own.
        watch.keep(WatchPhoneContext(ringtone: HermesRingtone.system.rawValue, botRingtones: [:]))
        XCTAssertEqual(watch.ringtone(profile: "furina"), .system)
        XCTAssertNil(watch.defaults.object(forKey: HermesRingtoneStore.botsKey))
        // A tone a newer iPhone app has and this Watch app doesn't.
        watch.keep(WatchPhoneContext(ringtone: "gong", botRingtones: [try XCTUnwrap(HermesRingtoneStore.bot("furina")): "gong"]))
        XCTAssertEqual(watch.ringtone(profile: "furina"), .system)
    }

    func testEveryToneIsInTheBundleAsCallKitTakesIt() throws {
        // CallKit rings with a file from the app bundle by its name, and
        // takes linear PCM in a WAV no longer than 30 seconds.
        for ringtone in HermesRingtone.allCases where ringtone != .system {
            let url = try XCTUnwrap(ringtone.bundledURL, "\(ringtone.rawValue) isn't in the app bundle")
            XCTAssertEqual(ringtone.ringtoneSound, url.lastPathComponent)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatLinearPCM)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            XCTAssertGreaterThan(seconds, 2)
            XCTAssertLessThan(seconds, 30)
            XCTAssertFalse(ringtone.title.isEmpty)
        }
        XCTAssertEqual(Set(HermesRingtone.allCases.map(\.title)).count, HermesRingtone.allCases.count)
    }
}
