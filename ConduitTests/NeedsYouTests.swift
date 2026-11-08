//
//  NeedsYouTests.swift
//  ConduitTests
//
//  Hermes is waiting on you (issue 1705): the plugin's list of waiting
//  chats as the store reads it, and when it shows a banner. An extension of
//  ChatOnScreenTests (main actor, the same pushes' neighbour), so the test
//  plan gains no class.
//

import XCTest
@testable import Conduit

extension ChatOnScreenTests {
    private func needsYouWait(_ id: String, _ session: String, at: Double, kind: String = "approval") -> [String: Any] {
        ["id": id, "kind": kind, "session_ids": [session, "rt-\(session)"], "title": "Chat \(session)",
         "summary": "Run the migration?", "questions": kind == "question" ? 2 : 0, "at": at]
    }

    func testNeedsYouReadsThePluginsWaitsAndSkipsOnesNamingNoChat() throws {
        let item = try XCTUnwrap(NeedsYouItem(host: needsYouWait("a1", "s1", at: 1_800_000_000), profile: "atlas"))
        XCTAssertEqual(item.kind, .approval)
        XCTAssertEqual(item.sessionIDs, ["s1", "rt-s1"])
        XCTAssertEqual(item.title, "Chat s1")
        XCTAssertEqual(item.since, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(item.id, "atlas\u{1F}a1", "two profiles' ids never collide")
        let question = try XCTUnwrap(NeedsYouItem(host: needsYouWait("q1", "s2", at: 1, kind: "question"), profile: "atlas"))
        XCTAssertEqual(question.questions, 2)
        XCTAssertNil(NeedsYouItem(host: ["id": "x", "kind": "approval", "session_ids": [" "]], profile: "atlas"))
        XCTAssertNil(NeedsYouItem(host: ["id": "x", "kind": "other", "session_ids": ["s"]], profile: "atlas"))
    }

    func testNeedsYouBannersOnlyANewWaitOutsideTheOpenChat() {
        let store = NeedsYouStore()
        let dashboard = UUID()
        func items(_ hosts: [[String: Any]], _ profile: String = "atlas") -> [NeedsYouItem] {
            hosts.compactMap { NeedsYouItem(host: $0, profile: profile) }
        }
        // The first read shows what already waited, with no banner.
        store.apply(items([needsYouWait("a1", "s1", at: 10)]), profile: "atlas", dashboardID: dashboard) { _ in false }
        XCTAssertEqual(store.items.map(\.waitID), ["a1"])
        XCTAssertNil(store.banner)
        // A new wait in another chat: a banner.
        store.apply(items([needsYouWait("a1", "s1", at: 10), needsYouWait("a2", "s2", at: 20)]),
                    profile: "atlas", dashboardID: dashboard) { _ in false }
        XCTAssertEqual(store.items.map(\.waitID), ["a2", "a1"], "newest first")
        XCTAssertEqual(store.banner?.waitID, "a2")
        // Answered anywhere: it leaves the list, and its banner goes.
        store.apply(items([needsYouWait("a1", "s1", at: 10)]), profile: "atlas", dashboardID: dashboard) { _ in false }
        XCTAssertNil(store.banner)
        // A new wait in the open chat: its card is on screen, no banner.
        store.apply(items([needsYouWait("a1", "s1", at: 10), needsYouWait("a3", "s3", at: 30)]),
                    profile: "atlas", dashboardID: dashboard) { $0.sessionIDs.contains("s3") }
        XCTAssertNil(store.banner)
        XCTAssertEqual(store.count(for: "ATLAS", matches: AppState.profilesMatch), 2)
        // Another profile's first read keeps atlas's and shows no banner.
        store.apply(items([needsYouWait("b1", "s9", at: 40)], "nahida"), profile: "nahida", dashboardID: dashboard) { _ in false }
        XCTAssertEqual(store.items.count, 3)
        XCTAssertNil(store.banner)
        XCTAssertEqual(store.count(for: "nahida", matches: AppState.profilesMatch), 1)
        // A profile gone from the strip leaves the list.
        store.forget(profilesOtherThan: ["atlas"])
        XCTAssertEqual(store.items.map(\.profile), ["atlas", "atlas"])
        // Another dashboard starts over.
        store.apply([], profile: "atlas", dashboardID: UUID()) { _ in false }
        XCTAssertTrue(store.items.isEmpty)
    }

    func testNeedsYouBannerIsDismissedOnlyForItsOwnWait() {
        let store = NeedsYouStore()
        let dashboard = UUID()
        store.apply([], profile: "atlas", dashboardID: dashboard) { _ in false }
        let read = [needsYouWait("a1", "s1", at: 10)].compactMap { NeedsYouItem(host: $0, profile: "atlas") }
        store.apply(read, profile: "atlas", dashboardID: dashboard) { _ in false }
        let other = NeedsYouItem(waitID: "zz", profile: "atlas", kind: .approval, sessionIDs: ["s9"])
        store.dismissBanner(other)
        XCTAssertEqual(store.banner?.waitID, "a1")
        store.dismissBanner(read[0])
        XCTAssertNil(store.banner)
        XCTAssertEqual(store.items.count, 1, "the wait stays listed")
    }

    func testNeedsYouReadsNeverOverlapAndABurstMakesOneMoreRead() async {
        let store = NeedsYouStore()
        var reads = 0
        await store.coalescing {
            reads += 1
            guard reads == 1 else { return }
            // Two asks while the first read runs: one more read after it.
            await store.coalescing { reads += 100 }
            await store.coalescing { reads += 100 }
        }
        XCTAssertEqual(reads, 2)
    }
}
