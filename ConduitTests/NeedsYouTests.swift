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

    /// Issue 2683: a card drawn from its row answers through the gateway
    /// the list named, else the profile's pairing key, else the gateway the
    /// host reported; and its answer is then sealed, never plaintext.
    func testANeedsYouCardAnswersThroughItsProfilesGatewaySealed() throws {
        let dashboard = UUID()
        func key(_ gateway: String, profile: String?, installation: String = "inst", dashboardID: UUID? = nil,
                 at: TimeInterval = 1, retired: Bool = false) -> E2EKeyRecord {
            var record = E2EKeyRecord(kid: "kid-\(gateway)", secret: Data(repeating: 7, count: 32), installationID: installation,
                                      gatewayID: gateway, dashboardID: (dashboardID ?? dashboard).uuidString, profile: profile,
                                      createdAt: Date(timeIntervalSince1970: at))
            if retired { record = record.retired(at: Date()) }
            return record
        }
        func resolve(listed: String? = nil, records: [E2EKeyRecord], reported: String? = nil) -> String? {
            AppState.needsYouCardGatewayID(listed: listed, dashboardID: dashboard, profile: "Atlas",
                                           installationID: "inst", records: records, reported: reported)
        }
        let records = [
            key("gw-old", profile: "atlas", at: 1),
            key("gw-atlas", profile: "atlas", at: 2),
            key("gw-retired", profile: "atlas", at: 3, retired: true),
            key("gw-other-phone", profile: "atlas", installation: "other", at: 4),
            key("gw-other-dashboard", profile: "atlas", dashboardID: UUID(), at: 5),
            key("gw-default", profile: "default", at: 6),
        ]
        XCTAssertEqual(resolve(listed: "gw-listed", records: records, reported: "gw-reported"), "gw-listed")
        XCTAssertEqual(resolve(records: records, reported: "gw-reported"), "gw-atlas", "the profile's newest current key")
        XCTAssertEqual(resolve(records: [key("gw-default", profile: "default")], reported: "gw-reported"), "gw-reported")
        XCTAssertNil(resolve(records: []))

        let body = PushNotificationService.respondBody(requestID: "conduit-push-abc123def456", answer: "staging",
                                                       relayGatewayID: resolve(records: records))
        let sealed = try PushNotificationService.sealedRespondBody(body, requestID: "conduit-push-abc123def456",
                                                                   installationID: "inst", records: records)
        XCTAssertNotEqual(sealed["answer"], "staging", "an encrypted pairing never gets the answer in plaintext")
        XCTAssertEqual(sealed["gateway_id"], "gw-atlas")
    }

    /// Issue 2683: the list's gateway reaches every row, an empty one none.
    func testTheWaitingListsGatewayReachesItsRows() throws {
        let rows = [needsYouWait("q1", "s1", at: 1, kind: "question"), needsYouWait("a1", "s2", at: 2)]
        let items = try XCTUnwrap(NeedsYouItem.items(listed: ["waiting": rows, "gateway_id": " gw-1 "], profile: "atlas"))
        XCTAssertEqual(items.map(\.relayGatewayID), ["gw-1", "gw-1"])
        let older = try XCTUnwrap(NeedsYouItem.items(listed: ["waiting": rows], profile: "atlas"))
        XCTAssertEqual(older.map(\.relayGatewayID), [nil, nil], "an older plugin names none")
        XCTAssertEqual(NeedsYouItem.items(listed: ["waiting": rows, "gateway_id": "  "], profile: "atlas")?.map(\.relayGatewayID), [nil, nil])
        XCTAssertNil(NeedsYouItem.items(listed: ["error": "boom"], profile: "atlas"), "an error body is a failed read")
    }

    /// Issue 2683: a row-drawn card's gateway outlives a relaunch only for
    /// a pairing this iPhone holds a current key for, and then answers
    /// sealed from the kept copy.
    func testARowDrawnCardsGatewayIsKeptAcrossRelaunchOnlyWhenEncrypted() {
        let current = E2EKeyRecord(kid: "k1", secret: Data(repeating: 3, count: 32), installationID: "inst", gatewayID: "gw-e2e",
                                   dashboardID: nil, profile: nil, createdAt: Date())
        XCTAssertTrue(PushNotificationService.keepsGatewayAcrossRelaunch("gw-e2e", installationID: "inst", records: [current]))
        XCTAssertFalse(PushNotificationService.keepsGatewayAcrossRelaunch("gw-plain", installationID: "inst", records: [current]))
        XCTAssertFalse(PushNotificationService.keepsGatewayAcrossRelaunch("gw-e2e", installationID: "other", records: [current]))
        XCTAssertFalse(PushNotificationService.keepsGatewayAcrossRelaunch("gw-e2e", installationID: "inst",
                                                                          records: [current.retired(at: Date())]))

        let key = PushNotificationService.encryptedDecisionGatewaysKey
        let saved = UserDefaults.standard.array(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        PushNotificationService.persistEncryptedGatewayID("gw-e2e", requestID: "conduit-push-2683aaaaaaaa")
        // The session map is empty for it after a relaunch; the kept copy answers.
        XCTAssertEqual(PushNotificationService.shared.relayGatewayID(forRequestID: "conduit-push-2683aaaaaaaa"), "gw-e2e")
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
