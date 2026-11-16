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

    /// Issue 2556: a question's row carries its card as the push did, for
    /// the chat to draw when Hermes drew none there.
    func testAQuestionsRowCarriesItsCard() throws {
        var row = needsYouWait("q1", "s2", at: 1, kind: "question")
        XCTAssertNil(try XCTUnwrap(NeedsYouItem(host: row, profile: "atlas")).card, "an older plugin sends none")
        row["decision"] = [
            "kind": "clarify", "request_id": "conduit-push-abc", "question": "Which environment?",
            "questions": [
                ["qid": "q0", "question": "Which environment?", "choices": ["staging", "production"]],
                ["qid": "q1", "question": "Anything else?"]
            ]
        ] as [String: Any]
        guard case let .clarifyBatch(requestId, questions)? = try XCTUnwrap(NeedsYouItem(host: row, profile: "atlas")).card else {
            return XCTFail("the batch's card")
        }
        XCTAssertEqual(requestId, "conduit-push-abc")
        XCTAssertEqual(questions.map(\.id), ["q0", "q1"])
        XCTAssertEqual(questions.first?.choices.map(\.value), ["staging", "production"])
        // Only the plugin's own ids are answerable through the relay.
        row["decision"] = ["kind": "clarify", "request_id": "native-1", "question": "Which?"]
        XCTAssertNil(try XCTUnwrap(NeedsYouItem(host: row, profile: "atlas")).card)
        // An approval is answered on its chat's own card.
        var approval = needsYouWait("a1", "s1", at: 1)
        approval["decision"] = ["kind": "approval", "session_key": "s1", "description": "Run it?", "choices": ["once", "deny"]] as [String: Any]
        XCTAssertNil(try XCTUnwrap(NeedsYouItem(host: approval, profile: "atlas")).card)
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

    func testTheLoneAllChipSumsOnlyTheProfilesItLists() {
        let store = NeedsYouStore()
        let dashboard = UUID()
        func items(_ hosts: [[String: Any]], _ profile: String) -> [NeedsYouItem] {
            hosts.compactMap { NeedsYouItem(host: $0, profile: profile) }
        }
        store.apply(items([needsYouWait("a1", "s1", at: 10), needsYouWait("a2", "s2", at: 20)], "atlas"),
                    profile: "atlas", dashboardID: dashboard) { _ in false }
        store.apply(items([needsYouWait("b1", "s9", at: 30)], "nahida"),
                    profile: "nahida", dashboardID: dashboard) { _ in false }
        // Both profiles All lists: every wait counts.
        XCTAssertEqual(V2ProfileStrip.waiting(in: ["atlas", "nahida"], needsYou: store,
                                              matches: AppState.profilesMatch), 3)
        // A profile All leaves out isn't counted, and no profiles is none.
        XCTAssertEqual(V2ProfileStrip.waiting(in: ["nahida"], needsYou: store,
                                              matches: AppState.profilesMatch), 1)
        XCTAssertEqual(V2ProfileStrip.waiting(in: [], needsYou: store,
                                              matches: AppState.profilesMatch), 0)
    }

    /// Another combined dashboard's waits stay apart from this one's: the
    /// list shows both, newest first, the chips count only this one's, a
    /// new wait there banners, and one let go says nothing more.
    func testAnotherCombinedDashboardsWaitsListApartAndBanner() {
        let store = NeedsYouStore()
        let here = UUID(), there = UUID()
        store.apply([NeedsYouItem(waitID: "h1", profile: "default", kind: .question, sessionIDs: ["a"], since: Date(timeIntervalSince1970: 10))],
                    profile: "default", dashboardID: here) { _ in false }
        store.applyOther([NeedsYouItem(waitID: "t1", profile: "default", kind: .approval, sessionIDs: ["b"], since: Date(timeIntervalSince1970: 20))],
                         profile: "default", dashboardID: there)
        XCTAssertEqual(store.everyItem.map(\.waitID), ["t1", "h1"], "newest first, both")
        XCTAssertEqual(store.count(for: "default", matches: AppState.profilesMatch), 1, "the chip counts this dashboard's")
        XCTAssertNil(store.banner, "a first read there shows no banner")
        XCTAssertNotEqual(store.everyItem[0].id, NeedsYouItem(waitID: "t1", profile: "default", kind: .approval, sessionIDs: ["b"]).id,
                          "its id carries its dashboard")

        store.applyOther([
            NeedsYouItem(waitID: "t1", profile: "default", kind: .approval, sessionIDs: ["b"], since: Date(timeIntervalSince1970: 20)),
            NeedsYouItem(waitID: "t2", profile: "default", kind: .question, sessionIDs: ["c"], since: Date(timeIntervalSince1970: 30)),
        ], profile: "default", dashboardID: there)
        XCTAssertEqual(store.banner?.waitID, "t2")
        XCTAssertEqual(store.banner?.dashboardID, there)

        // The one on screen's own reads never banner it again, nor take it.
        store.apply([], profile: "default", dashboardID: here) { _ in false }
        XCTAssertEqual(store.banner?.waitID, "t2")

        store.forgetOtherDashboards(otherThan: [])
        XCTAssertNil(store.banner, "let go: its banner goes")
        XCTAssertEqual(store.everyItem.map(\.waitID), [], "and its rows")

        // Read again later, it starts over: a first read, no banner.
        store.applyOther([NeedsYouItem(waitID: "t3", profile: "default", kind: .question, sessionIDs: ["d"])], profile: "default", dashboardID: there)
        XCTAssertNil(store.banner)
        // Switched to: it's read as this dashboard's from then.
        store.reset(dashboardID: there)
        XCTAssertTrue(store.otherDashboards.isEmpty)
    }

    /// One Hermes saved at two addresses, both in the group: a wait both
    /// list shows once, as this dashboard's, and banners once, from this
    /// dashboard; one in the chat on screen banners from neither (issue 2631).
    func testAWaitTwoDashboardsOfOneHermesListShowsOnce() throws {
        let store = NeedsYouStore()
        let here = UUID(), twin = UUID()
        func wait(_ id: String, _ at: Double) -> NeedsYouItem {
            NeedsYouItem(waitID: id, profile: "default", kind: .approval, sessionIDs: ["s-\(id)"],
                         since: Date(timeIntervalSince1970: at))
        }
        store.apply([wait("w1", 10)], profile: "default", dashboardID: here) { _ in false }
        store.applyOther([wait("w1", 10)], profile: "default", dashboardID: twin)
        XCTAssertEqual(store.everyItem.map(\.waitID), ["w1"])
        XCTAssertNil(store.everyItem.first?.dashboardID, "as this dashboard's")

        store.apply([wait("w1", 10), wait("w2", 20)], profile: "default", dashboardID: here) { _ in false }
        store.applyOther([wait("w1", 10), wait("w2", 20)], profile: "default", dashboardID: twin)
        XCTAssertEqual(store.banner?.waitID, "w2")
        XCTAssertNil(store.banner?.dashboardID, "the banner is this dashboard's copy")
        XCTAssertEqual(store.everyItem.map(\.waitID), ["w2", "w1"])

        // The twin's read lands first for a wait in the chat on screen.
        store.applyOther([wait("w1", 10), wait("w2", 20), wait("w3", 30)], profile: "default", dashboardID: twin,
                         isOpenChat: { $0.waitID == "w3" })
        XCTAssertEqual(store.banner?.waitID, "w2", "no banner for the chat on screen")
        XCTAssertEqual(store.everyItem.map(\.waitID), ["w3", "w2", "w1"])

        // The twin's read banners a new wait first; once dismissed, this
        // dashboard's own read of it banners nothing again.
        store.applyOther([wait("w1", 10), wait("w2", 20), wait("w3", 30), wait("w4", 40)], profile: "default", dashboardID: twin)
        let twinBanner = store.banner
        XCTAssertEqual(twinBanner?.waitID, "w4")
        store.dismissBanner(try XCTUnwrap(twinBanner))
        store.apply([wait("w1", 10), wait("w2", 20), wait("w3", 30), wait("w4", 40)], profile: "default", dashboardID: here) { _ in false }
        XCTAssertNil(store.banner, "its banner showed once, from the twin")
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
