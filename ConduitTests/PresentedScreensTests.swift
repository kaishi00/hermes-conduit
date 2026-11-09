//
//  PresentedScreensTests.swift
//  ConduitTests
//
//  Confirmations Hermes asks the phone to present (PresentedScreens.swift).
//  An extension of an existing class, so the test planner needs no new entry.
//

import CoreLocation
import XCTest
@testable import Conduit

extension AppStateVoiceCapabilityTests {
    func testPresentedConfirmParsesTheHostsPrompt() throws {
        let prompt = try XCTUnwrap(PresentedConfirm(json: [
            "id": "p1", "title": " Send to Mei? ", "preview": "**Hi Mei**, running late.",
            "action_label": "Send", "spoken_yes": ["send it", " ", "go ahead"], "session_id": "",
            "expires_at": Date().addingTimeInterval(60).timeIntervalSince1970,
        ]))
        XCTAssertEqual(prompt.title, "Send to Mei?")
        XCTAssertEqual(prompt.actionLabel, "Send")
        XCTAssertEqual(prompt.spokenYes, ["send it", "go ahead"])
        XCTAssertNil(prompt.sessionID)
        XCTAssertFalse(prompt.isExpired())
        XCTAssertNil(PresentedConfirm(json: ["id": "p2", "title": "  "]))
        XCTAssertNil(PresentedConfirm(json: ["title": "No id"]))
    }

    func testPresentedConfirmNeedsTheUsersOwnYes() {
        let prompt = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send", spokenYes: ["send it"])
        XCTAssertTrue(prompt.isConfirmed(by: "yes"))
        XCTAssertTrue(prompt.isConfirmed(by: "Send it."))
        XCTAssertTrue(prompt.isConfirmed(by: "Yes, send it please"))
        XCTAssertFalse(prompt.isConfirmed(by: "send it?"))
        XCTAssertFalse(prompt.isConfirmed(by: "don't send it"))
        XCTAssertFalse(prompt.isConfirmed(by: "send it to Alex instead"))
        XCTAssertFalse(prompt.isConfirmed(by: "what does it say"))
        XCTAssertFalse(prompt.isConfirmed(by: ""))
    }

    func testPresentedConfirmRefusalsNeverConfirmWhateverHermesListedAsAYes() {
        let refusals = ["no", "cancel", "wait", "never", "not", "absolutely not", "definitely not", "of course not",
                        "i don't want it", "hell no", "that's a no"]
        let prompt = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                      spokenYes: ["send it", "no problem"] + refusals)
        for refusal in refusals {
            let listed = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                          spokenYes: [refusal])
            XCTAssertFalse(listed.isConfirmed(by: refusal), refusal)
            XCTAssertFalse(listed.isConfirmed(by: refusal.capitalized + "."), refusal)
        }
        // A genuine yes still confirms, a no-led one included.
        XCTAssertTrue(prompt.isConfirmed(by: "send it"))
        XCTAssertTrue(prompt.isConfirmed(by: "No problem"))
        XCTAssertTrue(prompt.isConfirmed(by: "yes"))
    }

    func testPresentedConfirmRefusalVerbsNeverConfirmWhateverHermesListedAsAYes() {
        // A refusal said with its verb, in each shipped language.
        let refusals = ["reject", "Reject it.", "deny", "refuse", "decline", "I decline",
                        "ablehnen", "lehne ab", "rechazar", "recházalo", "refuser", "je refuse", "rejeter",
                        "recusar", "rejeita", "отклонить", "отклони", "rifiuta", "odrzuć", "reddet", "tolak",
                        "거절", "거절해요", "拒绝", "拒絕", "拒否します"]
        for refusal in refusals {
            let listed = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                          spokenYes: [refusal])
            XCTAssertFalse(listed.isConfirmed(by: refusal), refusal)
        }
        let prompt = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                      spokenYes: ["send it"])
        XCTAssertTrue(prompt.isConfirmed(by: "send it"))
    }

    func testPresentedConfirmARefusalAnywhereInTheWordsNeverConfirms() {
        // Not at the start, or said only through the verb: still a no.
        let refusals = ["不", "不不不", "Momento", "Sekunde", "Sebentar", "send it, no wait", "yes, send it, no wait", "send it. wait", "send it later, not now", "please cancel",
                        "raczej nie", "chyba nie", "şimdi gönderme", "нет, не отправляй",
                        "지금 보내지 마", "보내지마세요", "보내지 않을래요", "그건 하지 말아요",
                        "我不想发", "先别发", "現在別發", "送らないで", "送信しないでください", "やっぱりやめて"]
        for refusal in refusals {
            let listed = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                          spokenYes: [refusal])
            XCTAssertFalse(listed.isConfirmed(by: refusal), refusal)
        }
        // A phrase in any shipped language that says yes still confirms.
        // A negating character or a length of time inside a yes isn't a no.
        for yes in ["send it", "envíalo", "wyślij", "gönder", "보내 줘", "发吧", "送って", "the second one",
                    "沒問題", "没有问题", "特别好，发吧", "发给别人", "不错，发吧", "問題ありません", "すみません、送って"] {
            let listed = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                          spokenYes: [yes])
            XCTAssertTrue(listed.isConfirmed(by: yes), yes)
        }
    }

    func testAVoiceConfirmNeedsWordsFromAfterThePanelAndYieldsToATap() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1") { _, _ in
            ["ok": true, "prompts": [["id": "p1", "title": "Send?", "preview": "Hi", "action_label": "Send",
                                      "spoken_yes": ["send it"]]]]
        }
        let prompt = try XCTUnwrap(sync.prompts.first)

        // A yes from before the panel appeared answers something else.
        let earlier = UUID()
        sync.noteShown(prompt.id, userTurn: earlier)
        var confirmed = false
        let stale = await PresentVoiceTool.run(["action": "confirm", "id": prompt.id], sync: sync,
                                               lastUserTurn: { (earlier, "yes") }) { _, _ in confirmed = true }
        XCTAssertNotNil(stale["error"])
        XCTAssertFalse(confirmed)

        // Tapped Not now while the spoken words were on their way: the tap stands.
        var calls = 0
        let tapped = await PresentVoiceTool.run(["action": "confirm", "id": prompt.id], sync: sync, lastUserTurn: {
            calls += 1
            if calls == 1 {
                sync.answer(prompt, outcome: .declined, via: .tap)
                return (UUID(), "hmm")
            }
            return (UUID(), "yes")
        }) { _, _ in confirmed = true }
        XCTAssertNotNil(tapped["error"])
        XCTAssertFalse(confirmed)
        XCTAssertTrue(sync.prompts.isEmpty)

        // A second tap on the panel already gone doesn't change the answer.
        sync.answer(prompt, outcome: .confirmed, via: .tap)
        let all = defaults.dictionary(forKey: "conduit.presentedScreens.results.v1") as? [String: [[String: Any]]]
        XCTAssertEqual(all?["host|default"]?.first?["outcome"] as? String, "declined")
    }

    /// A live call's decline is the user's too (issue 2039): the model
    /// can't turn a confirmation down on its own judgment, or on words from
    /// before the panel appeared, and the panel stays for their tap.
    func testAVoiceDeclineNeedsTheUsersOwnNoFromAfterThePanel() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1") { _, _ in
            ["ok": true, "prompts": [["id": "p1", "title": "Send?", "preview": "Hi", "action_label": "Send",
                                      "spoken_yes": ["send it"]]]]
        }
        let prompt = try XCTUnwrap(sync.prompts.first)
        let earlier = UUID()
        sync.noteShown(prompt.id, userTurn: earlier)
        var declined = false

        // Words with no no in them, or a no from before it appeared, decline nothing.
        let unasked = await PresentVoiceTool.run(["action": "decline", "id": prompt.id], sync: sync,
                                                 lastUserTurn: { (UUID(), "what's the weather like") }) { _, _ in declined = true }
        XCTAssertNotNil(unasked["error"])
        let stale = await PresentVoiceTool.run(["action": "decline", "id": prompt.id], sync: sync,
                                               lastUserTurn: { (earlier, "no") }) { _, _ in declined = true }
        XCTAssertNotNil(stale["error"])
        XCTAssertFalse(declined)
        XCTAssertEqual(sync.prompts.map(\.id), ["p1"], "it stays on screen for the user")

        // So the user's tap still answers it.
        sync.answer(prompt, outcome: .confirmed, via: .tap)
        let all = defaults.dictionary(forKey: "conduit.presentedScreens.results.v1") as? [String: [[String: Any]]]
        XCTAssertEqual(all?["host|default"]?.first?["outcome"] as? String, "confirmed")

        // A no-led yes isn't a no; a no, not now or don't send is.
        XCTAssertFalse(prompt.isDeclined(by: "No problem"))
        XCTAssertFalse(prompt.isDeclined(by: "No problem at all"))
        XCTAssertFalse(prompt.isDeclined(by: "not a problem"))
        XCTAssertFalse(prompt.isDeclined(by: "I don't know"))
        XCTAssertFalse(prompt.isDeclined(by: "I do not know"))
        XCTAssertFalse(prompt.isDeclined(by: "no idea"))
        XCTAssertFalse(prompt.isDeclined(by: "Yeah, send it, no problem"))
        XCTAssertFalse(prompt.isDeclined(by: "Yes, that's fine, no problem"))
        XCTAssertFalse(prompt.isDeclined(by: "I have no problem with that"))
        XCTAssertFalse(prompt.isDeclined(by: "I don't remember"))
        XCTAssertFalse(prompt.isDeclined(by: "send it, no rush"))
        XCTAssertFalse(prompt.isDeclined(by: "send it"))
        // A question with a not in it asks; it doesn't answer.
        XCTAssertFalse(prompt.isDeclined(by: "shouldn't we check the address first?"))
        XCTAssertFalse(prompt.isDeclined(by: "can't we wait？"))
        // A refusal verb under a not, or in a question missing its "?".
        XCTAssertFalse(prompt.isDeclined(by: "I wouldn't decline it"))
        XCTAssertFalse(prompt.isDeclined(by: "I never refuse"))
        XCTAssertFalse(prompt.isDeclined(by: "should we decline it"))
        XCTAssertFalse(prompt.isDeclined(by: "how about we decline it"))
        XCTAssertFalse(prompt.isDeclined(by: "what about we decline it"))
        XCTAssertFalse(prompt.isDeclined(by: "do we decline it"))
        XCTAssertFalse(prompt.isDeclined(by: "have we declined it"))
        XCTAssertFalse(prompt.isDeclined(by: "who declined it"))
        XCTAssertFalse(prompt.isDeclined(by: "don't decline it"))
        XCTAssertFalse(prompt.isDeclined(by: "do not reject it"))
        XCTAssertFalse(prompt.isDeclined(by: "可以拒绝吗"))
        XCTAssertFalse(prompt.isDeclined(by: "断ってもいいか"))
        XCTAssertFalse(prompt.isDeclined(by: "我不拒绝"))
        XCTAssertFalse(prompt.isDeclined(by: "断らない"))
        XCTAssertFalse(prompt.isDeclined(by: "I don't want to decline it"))
        XCTAssertFalse(prompt.isDeclined(by: "I haven't declined it yet"))
        // A wait holds, and a wait with a change asks for the change.
        XCTAssertFalse(prompt.isDeclined(by: "hold on"))
        XCTAssertFalse(prompt.isDeclined(by: "Wait, make it Wednesday"))
        XCTAssertFalse(prompt.isDeclined(by: "No, make it for Alex"))
        XCTAssertFalse(prompt.isDeclined(by: "Well, no, make it for Alex"))
        XCTAssertFalse(prompt.isDeclined(by: "Oh, no, make it Wednesday"))
        XCTAssertFalse(prompt.isDeclined(by: "Не надо, сделай для Алекса"))
        XCTAssertFalse(prompt.isDeclined(by: "Never mind, make it for Alex"))
        XCTAssertFalse(prompt.isDeclined(by: "Don't send it to Alex; send it to Bob"))
        XCTAssertFalse(prompt.isDeclined(by: "Don't send it to Alex and send it to Bob"))
        XCTAssertFalse(prompt.isDeclined(by: "Don't send it to Alex. Send it to Bob"))
        XCTAssertFalse(prompt.isDeclined(by: "Don't send it, send it to Bob"))
        XCTAssertFalse(prompt.isDeclined(by: "Don't send it to Alex, send it to Hermes"))
        XCTAssertFalse(prompt.isDeclined(by: "Cancel the email, send it"))
        XCTAssertFalse(prompt.isDeclined(by: "I refuse, send it to Bob instead"))
        XCTAssertFalse(prompt.isDeclined(by: "No, Alex declined it"))
        XCTAssertFalse(prompt.isDeclined(by: "No lo rechazo"))
        XCTAssertFalse(prompt.isDeclined(by: "No cancelar el envío"))
        XCTAssertFalse(prompt.isDeclined(by: "No, no lo rechazo"))
        XCTAssertFalse(prompt.isDeclined(by: "No, no cancelar el envío"))
        XCTAssertFalse(prompt.isDeclined(by: "Don't cancel the email"))
        XCTAssertFalse(prompt.isDeclined(by: "Bitte nicht abbrechen"))
        XCTAssertFalse(prompt.isDeclined(by: "不要取消"))
        XCTAssertFalse(prompt.isDeclined(by: "No, send it"))
        XCTAssertFalse(prompt.isDeclined(by: "不用发愁"))
        XCTAssertFalse(prompt.isDeclined(by: "Not now, send it"))
        XCTAssertFalse(prompt.isDeclined(by: "Not yet, go ahead"))
        XCTAssertFalse(prompt.isDeclined(by: "Storniere es nicht"))
        XCTAssertFalse(prompt.isDeclined(by: "Storniere es bitte nicht"))
        XCTAssertFalse(prompt.isDeclined(by: "Abbrechen bitte nicht"))
        XCTAssertFalse(prompt.isDeclined(by: "거절할까요"))
        XCTAssertFalse(prompt.isDeclined(by: "취소할까요"))
        for yes in ["No send it", "No wait send it", "No go ahead", "No wait, go ahead"] {
            XCTAssertFalse(prompt.isDeclined(by: yes), yes)
        }
        XCTAssertFalse(prompt.isDeclined(by: "不，发吧"))
        XCTAssertFalse(prompt.isDeclined(by: "不，不要取消"))
        XCTAssertFalse(prompt.isDeclined(by: "No, go ahead"))
        XCTAssertFalse(prompt.isDeclined(by: "No rechazo la oferta"))
        XCTAssertFalse(prompt.isDeclined(by: "Don't send it to Alex\nsend it to Bob"))
        XCTAssertFalse(prompt.isDeclined(by: "不要，改到周三"))
        XCTAssertFalse(prompt.isDeclined(by: "我不想发给Alex，发给Bob"))
        XCTAssertFalse(prompt.isDeclined(by: "我没有说不发"))
        XCTAssertFalse(prompt.isDeclined(by: "送らないでとは言ってない"))
        // A Chinese or Japanese question, and one in another language.
        XCTAssertFalse(prompt.isDeclined(by: "取消吗"))
        XCTAssertFalse(prompt.isDeclined(by: "不发吗"))
        XCTAssertFalse(prompt.isDeclined(by: "要不要发"))
        XCTAssertFalse(prompt.isDeclined(by: "取消呢"))
        XCTAssertFalse(prompt.isDeclined(by: "取消吗，谢谢"))
        XCTAssertFalse(prompt.isDeclined(by: "Soll ich es ablehnen"))
        XCTAssertFalse(prompt.isDeclined(by: "Czy mam odrzucić"))
        XCTAssertFalse(prompt.isDeclined(by: "hold on, I'm not ready"))
        XCTAssertFalse(prompt.isDeclined(by: "wait, the address isn't right"))
        // Not knowing, in the other shipped languages.
        for unsure in ["No sé", "Não sei", "Tidak tahu", "Je ne sais pas", "Ich weiß nicht", "不知道", "わからない",
                       "Don't know", "Don't remember", "Do not know"] {
            XCTAssertFalse(prompt.isDeclined(by: unsure), unsure)
        }
        XCTAssertTrue(PresentVoiceTool.note(for: prompt).contains("with confirm or decline and its id"))
        for no in ["no", "Not now.", "don't send it", "cancel", "decline", "decline it", "I refuse", "not yet", "nein", "不要", "拒绝", "先不",
                   "Don't share", "Don't answer", "Don't start", "Don't send the email", "Cancel the email", "No, forget it",
                   "Cancel the email, please", "Cancel the email.", "我不想发", "送らないで",
                   "Please cancel the email", "No, cancel the email", "Don't send it, thanks", "Decline it, please",
                   "No, I refuse", "No, thanks, cancel the email", "No, lo rechazo", "不要发", "不用发", "不要发短信", "别发微信", "不用发个消息", "Storniere es", "Anula el envío", "我不想发送", "不要發送", "No way", "No chance", "不，拒绝", "いや、断る", "No thanks", "No don't send it"] {
            XCTAssertTrue(prompt.isDeclined(by: no), no)
        }
    }

    /// A no said after the panel appeared declines it.
    func testAVoiceDeclineTakesTheUsersNo() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1") { _, _ in
            ["ok": true, "prompts": [["id": "p1", "title": "Send?", "preview": "Hi", "action_label": "Send"]]]
        }
        let prompt = try XCTUnwrap(sync.prompts.first)
        sync.noteShown(prompt.id, userTurn: UUID())
        var outcome: PresentedConfirmOutcome?
        let said = await PresentVoiceTool.run(["action": "decline", "id": prompt.id], sync: sync,
                                              lastUserTurn: { (UUID(), "No, not now") }) { _, answer in outcome = answer }
        XCTAssertEqual(said["result"], "Declined. Hermes won't do it.")
        XCTAssertEqual(outcome, .declined)

        // A no still on its way when the model called is waited for.
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1") { _, _ in
            ["ok": true, "prompts": [["id": "p2", "title": "Send?", "preview": "Hi", "action_label": "Send"]]]
        }
        let next = try XCTUnwrap(sync.prompts.first { $0.id == "p2" })
        sync.noteShown(next.id, userTurn: UUID())
        var calls = 0
        outcome = nil
        let late = await PresentVoiceTool.run(["action": "decline", "id": next.id], sync: sync, lastUserTurn: {
            calls += 1
            return calls == 1 ? (UUID(), "what's the weather like") : (UUID(), "No, not now")
        }) { _, answer in outcome = answer }
        XCTAssertGreaterThan(calls, 1)
        XCTAssertEqual(late["result"], "Declined. Hermes won't do it.")
        XCTAssertEqual(outcome, .declined)
    }

    /// Answers still waiting for a dashboard's host, Say instead's words
    /// included, go when it's signed out of; another dashboard's stay
    /// (issue 2041).
    func testUnsentAnswersGoWithTheirDashboard() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        let leaving = UUID(), staying = UUID()
        for dashboard in [leaving, staying] {
            await sync.sync(scope: "\(dashboard.uuidString)|default", profile: "default", installationID: "install-1") { _, _ in
                ["ok": true, "prompts": [["id": "p-\(dashboard.uuidString)", "title": "Share?", "preview": "",
                                          "action_label": "Share"]]]
            }
            let prompt = try XCTUnwrap(sync.prompts.first)
            sync.answer(prompt, outcome: .edit, via: .tap, editText: "Tell them Thursday")
        }
        func scopes() -> Set<String> {
            Set((defaults.dictionary(forKey: "conduit.presentedScreens.results.v1") ?? [:]).keys)
        }
        XCTAssertEqual(scopes(), ["\(leaving.uuidString)|default", "\(staying.uuidString)|default"])

        sync.forgetAnswers(dashboardID: leaving)
        XCTAssertEqual(scopes(), ["\(staying.uuidString)|default"])
        sync.forgetAnswers(dashboardID: nil)
        XCTAssertNil(defaults.object(forKey: "conduit.presentedScreens.results.v1"))
    }

    /// The request holds the dashboard bridge: a finished sync keeps
    /// nothing of it, like the agent settings sync.
    func testAFinishedSyncKeepsNoHoldOnItsRequest() async throws {
        final class Bridge {}
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        weak var released: Bridge?
        do {
            let bridge = Bridge()
            released = bridge
            await sync.sync(scope: "host|default", profile: "default", installationID: "install-1") { _, _ in
                withExtendedLifetime(bridge) {}
                return ["ok": true, "prompts": []]
            }
        }
        XCTAssertNil(released, "The sync let go of its request and the bridge it holds")
    }

    func testAGoConfirmationCarriesWhereMapsOpens() async throws {
        let prompt = try XCTUnwrap(PresentedConfirm(json: [
            "id": "p1", "title": "Directions to Heathrow?", "action_label": "Go",
            "maps": ["to": " Heathrow Terminal 5 ", "mode": "transit"],
        ]))
        XCTAssertEqual(prompt.maps, PresentedMapsTarget(to: "Heathrow Terminal 5", mode: .transit))
        XCTAssertEqual(PresentedConfirm(json: ["id": "p2", "title": "Go?", "maps": ["to": "Paris"]])?.maps?.mode, .driving)
        XCTAssertNil(PresentedConfirm(json: ["id": "p3", "title": "Go?", "maps": ["to": "Paris", "mode": "rocket"]])?.maps)
        XCTAssertEqual(PresentedConfirm(json: ["id": "p5", "title": "Go?", "maps": ["to": "Paris", "mode": "Walking"]])?.maps?.mode, .walking)
        XCTAssertNil(PresentedConfirm(json: ["id": "p4", "title": "Send?"])?.maps)

        // Each exchange tells the host this Conduit opens Apple Maps for them.
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var sent: [String: Any] = [:]
        await PresentedScreensSync(defaults: defaults).sync(scope: "host|default", profile: "default",
                                                            installationID: "install-1") { _, body in
            sent = body
            return ["ok": true, "prompts": []]
        }
        XCTAssertEqual(sent["features"] as? [String], ["maps-navigate", "show-cards", "chat-cards", "info-cards", "media-cards", "live-cards", "text-drafts", "board-cards", "room-boards", "diff-cards", "composed-cards", "review-cards", "room-asks", "link-asks", "room-work"])
    }

    func testRunWorksAskIsARoomsAskToStartWork() throws {
        let prompt = try XCTUnwrap(PresentedConfirm(json: [
            "id": "w1", "title": "Start “Compare flights”?", "preview": "Compare the three flights.",
            "action_label": "Start", "spoken_yes": ["start it"], "session_id": "room_abc",
            "room": ["id": "zoo-trip", "name": "Zoo trip", "work": true],
        ]))
        XCTAssertEqual(prompt.room, PresentedRoom(id: "zoo-trip", name: "Zoo trip", work: true))
        XCTAssertTrue(prompt.isAsk, "answered with Change it, never an Edit into the room's hidden chat")
        XCTAssertEqual(PresentVoiceTool.describe(prompt)["starts_work_for_room"] as? String, "Zoo trip")
        XCTAssertNil(PresentVoiceTool.describe(prompt)["room"])
        XCTAssertEqual(PresentedConfirm(json: ["id": "p", "title": "Share?", "room": ["id": "r", "work": "yes"]])?.room?.work,
                       false, "only a true work flag")
        XCTAssertEqual(PresentVoiceTool.describe(prompt)["plain_yes_counts"] as? Bool, false)
        // A plain yes may have answered something else: work starts only on its phrase.
        XCTAssertFalse(prompt.isConfirmed(by: "yes", bareYes: false))
        XCTAssertTrue(prompt.isConfirmed(by: "Yes, start it"))
        XCTAssertEqual(SpokenApprovals.answer("Yes", waiting: SpokenApprovals.Waiting(presented: [prompt]))?.approve, nil)
        XCTAssertEqual(SpokenApprovals.answer("Start it", waiting: SpokenApprovals.Waiting(presented: [prompt]))?.approve, true)
        XCTAssertEqual(SpokenApprovals.answer("Don't start.", waiting: SpokenApprovals.Waiting(presented: [prompt]))?.approve, false)
        XCTAssertNil(SpokenApprovals.answer("Don't start, look at trains", waiting: SpokenApprovals.Waiting(presented: [prompt])))
        let send = try XCTUnwrap(PresentedConfirm(json: [
            "id": "w2", "title": "Send to W1?", "preview": "Add the toilets.", "action_label": "Send",
            "spoken_yes": ["send it"], "session_id": "room_abc", "room": ["id": "zoo-trip", "name": "Zoo trip", "work": true],
        ]))
        XCTAssertEqual(PresentVoiceTool.describe(send)["sends_to_work_for_room"] as? String, "Zoo trip")
        XCTAssertNil(PresentVoiceTool.describe(send)["starts_work_for_room"])
        XCTAssertEqual(SpokenApprovals.answer("don't send it", waiting: SpokenApprovals.Waiting(presented: [send]))?.approve, false)
    }

    func testAVoiceConfirmOfRoomWorkNeedsItsPhrase() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1") { _, _ in
            ["ok": true, "prompts": [["id": "w1", "title": "Start “Compare flights”?", "preview": "Compare them.",
                                      "action_label": "Start", "spoken_yes": ["start it"], "session_id": "room_abc",
                                      "room": ["id": "zoo-trip", "name": "Zoo trip", "work": true]]]]
        }
        let prompt = try XCTUnwrap(sync.prompts.first)
        sync.noteShown(prompt.id, userTurn: UUID())
        var outcome: PresentedConfirmOutcome?
        let plain = await PresentVoiceTool.run(["action": "confirm", "id": prompt.id], sync: sync,
                                               lastUserTurn: { (UUID(), "yes") }) { _, answer in outcome = answer }
        XCTAssertEqual(plain["error"], "Not confirmed: a plain yes doesn't start work. Ask the user to say \"start it\", and confirm only after they do.",
                       "a plain yes never starts work")
        XCTAssertNil(outcome)
        let said = await PresentVoiceTool.run(["action": "confirm", "id": prompt.id], sync: sync,
                                              lastUserTurn: { (UUID(), "start it") }) { _, answer in outcome = answer }
        XCTAssertNil(said["error"])
        XCTAssertEqual(outcome, .confirmed)
    }

    func testARoomsAskNamesItsRoomAndSaysInsteadWithTheWords() async throws {
        let prompt = try XCTUnwrap(PresentedConfirm(json: [
            "id": "p1", "title": "Laifu asks whether you're free on the 22nd", "preview": "You're free all day.",
            "action_label": "Share", "spoken_yes": ["share it"], "session_id": "room_abc",
            "room": ["id": "zoo-trip", "name": " Zoo trip "],
        ]))
        XCTAssertEqual(prompt.room, PresentedRoom(id: "zoo-trip", name: "Zoo trip"))
        XCTAssertTrue(prompt.isConfirmed(by: "Share it."))
        // A room without an id is still a room's ask (no Edit into the room's hidden chat).
        XCTAssertEqual(PresentedConfirm(json: ["id": "p2", "title": "Send?", "room": ["name": "No id"]])?.room,
                       PresentedRoom(id: "", name: "No id"))
        let unnamed = try XCTUnwrap(PresentedConfirm(json: ["id": "p4", "title": "Send?", "room": ["id": "r"]]))
        XCTAssertEqual(PresentVoiceTool.describe(unnamed)["room"] as? String, "a room")
        XCTAssertNil(PresentedConfirm(json: ["id": "p3", "title": "Send?"])?.room)
        XCTAssertEqual(PresentVoiceTool.describe(prompt)["room"] as? String, "Zoo trip")

        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        var bodies: [[String: Any]] = []
        let room: [String: Any] = ["id": "zoo-trip", "name": "Zoo trip"]
        let listed: [[String: Any]] = [
            ["id": "p1", "title": "Laifu asks", "action_label": "Share", "room": room],
            ["id": "p2", "title": "Mona asks", "action_label": "Share", "room": room],
            ["id": "p3", "title": "Noor asks", "action_label": "Share", "room": room],
        ]
        let exchange: PresentedScreensSync.Request = { _, body in
            bodies.append(body)
            let prompts: [[String: Any]] = bodies.count == 1 ? listed : []
            return ["ok": true, "prompts": prompts]
        }
        await sync.sync(scope: "host|default", profile: "default", installationID: "i", request: exchange)
        let first = try XCTUnwrap(sync.prompts.first { $0.id == "p1" })
        let second = try XCTUnwrap(sync.prompts.first { $0.id == "p2" })
        let third = try XCTUnwrap(sync.prompts.first { $0.id == "p3" })
        sync.answer(first, outcome: .edit, via: .tap, editText: "  Only the afternoon.  ")
        // Say instead with nothing typed sends no words (the host reads it as Don't share).
        sync.answer(second, outcome: .edit, via: .tap, editText: "   ")
        sync.answer(third, outcome: .edit, via: .tap, editText: String(repeating: "a", count: 2_500))
        await sync.sync(scope: "host|default", profile: "default", installationID: "i", request: exchange)
        let results = try XCTUnwrap(bodies.last?["results"] as? [[String: Any]])
        XCTAssertEqual(results.first { $0["id"] as? String == "p1" }?["edit_text"] as? String, "Only the afternoon.")
        XCTAssertEqual(results.first { $0["id"] as? String == "p1" }?["outcome"] as? String, "edit")
        XCTAssertNil(results.first { $0["id"] as? String == "p2" }?["edit_text"])
        XCTAssertEqual((results.first { $0["id"] as? String == "p3" }?["edit_text"] as? String)?.count, 2_000)
    }

    func testALinksAskNamesThemAndSharesOnlyAnAnswerThereIs() async throws {
        let answer = try XCTUnwrap(PresentedConfirm(json: [
            "id": "p1", "title": "Free on 2026-11-22?", "preview": "Busy 22:00-24:00 on 2026-11-22.",
            "action_label": "Share", "spoken_yes": ["share it"],
            "link": ["id": "lnk_1", "name": " Laifu ", "share": true],
        ]))
        XCTAssertEqual(answer.link, PresentedLink(id: "lnk_1", name: "Laifu", share: true))
        XCTAssertTrue(answer.isAsk)
        XCTAssertTrue(answer.canConfirm)
        XCTAssertTrue(answer.isConfirmed(by: "Share it."))
        XCTAssertEqual(PresentVoiceTool.describe(answer)["asked_by"] as? String, "Laifu's Hermes")
        XCTAssertNil(PresentVoiceTool.describe(answer)["can_confirm"])

        // Their question has no answer to Share: no yes confirms it, by voice or otherwise.
        let question = try XCTUnwrap(PresentedConfirm(json: [
            "id": "p2", "title": "Laifu's Hermes asks", "preview": "Can Laifu borrow the tent?",
            "action_label": "Share", "link": ["id": "lnk_1", "name": "Laifu", "share": false],
        ]))
        XCTAssertFalse(question.canConfirm)
        XCTAssertFalse(question.isConfirmed(by: "yes"))
        XCTAssertEqual(PresentVoiceTool.describe(question)["can_confirm"] as? Bool, false)
        XCTAssertTrue(PresentVoiceTool.note(for: question).contains("they type their answer on the panel"))
        // A Link that doesn't say there's something to share has nothing to Share.
        XCTAssertEqual(PresentedConfirm(json: ["id": "p3", "title": "Asks", "link": ["id": "l"]])?.canConfirm, false)
        // A Link that can't be read is still a Link's ask, with nothing to Share.
        XCTAssertEqual(PresentedConfirm(json: ["id": "p5", "title": "Asks", "link": "lnk_1"])?.link,
                       PresentedLink(id: "", name: "", share: false))
        XCTAssertNil(PresentedConfirm(json: ["id": "p6", "title": "Send?", "link": NSNull()])?.link)
        XCTAssertNil(PresentedConfirm(json: ["id": "p4", "title": "Send?"])?.link)
        XCTAssertEqual(PresentedConfirm(json: ["id": "p4", "title": "Send?"])?.canConfirm, true)

        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        await sync.sync(scope: "host|default", profile: "default", installationID: "i") { _, _ in
            ["ok": true, "prompts": [["id": "p2", "title": "Laifu's Hermes asks", "preview": "Tent?", "action_label": "Share",
                                      "link": ["id": "lnk_1", "name": "Laifu", "share": false]]]]
        }
        let listed = try XCTUnwrap(sync.prompts.first)
        sync.noteShown(listed.id, userTurn: UUID())
        var confirmed = false
        let refused = await PresentVoiceTool.run(["action": "confirm", "id": listed.id], sync: sync,
                                                 lastUserTurn: { (UUID(), "yes") }) { _, _ in confirmed = true }
        XCTAssertNotNil(refused["error"])
        XCTAssertFalse(confirmed)
        XCTAssertEqual(sync.prompts.map(\.id), ["p2"])
        // Nothing sends a Share for it, whoever asks.
        sync.answer(listed, outcome: .confirmed, via: .tap)
        XCTAssertEqual(sync.prompts.map(\.id), ["p2"])
        // Say instead answers it with their words.
        var bodies: [[String: Any]] = []
        sync.answer(listed, outcome: .edit, via: .tap, editText: " Yes, it's in the garage. ")
        await sync.sync(scope: "host|default", profile: "default", installationID: "i") { _, body in
            bodies.append(body)
            return ["ok": true, "prompts": []]
        }
        let results = try XCTUnwrap(bodies.last?["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["edit_text"] as? String, "Yes, it's in the garage.")
        XCTAssertEqual(results.first?["outcome"] as? String, "edit")
    }

    func testMapsOpensWithDirectionsFromALinkOnlyItMade() throws {
        let to = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        XCTAssertEqual(MapsNavigator.mapsURL(to: to, mode: .walking)?.absoluteString, "maps://?daddr=51.500000,-0.120000&dirflg=w")
        XCTAssertEqual(MapsNavigator.mapsURL(to: to, mode: .cycling)?.absoluteString, "maps://?daddr=51.500000,-0.120000")
        let url = try XCTUnwrap(MapsNavigator.mapsURL(to: to, mode: .driving))
        XCTAssertEqual(MapsNavigator.url(fromNotification: [MapsNavigator.urlKey: url.absoluteString]), url)
        XCTAssertNil(MapsNavigator.url(fromNotification: [MapsNavigator.urlKey: "https://example.com"]))
        XCTAssertNil(MapsNavigator.url(fromNotification: ["aps": [:]]))
    }

    func testOnlyASentNavigateOpensMapsWithoutATap() {
        let sent = #"{"ok": true, "action": "navigate", "status": "sent", "prompt_id": "p1", "to": "Paris"}"#
        XCTAssertEqual(AppState.mapsNavigatePromptID(sent), "p1")
        XCTAssertNil(AppState.mapsNavigatePromptID(#"{"ok": true, "action": "directions", "to": "navigate street"}"#))
        XCTAssertNil(AppState.mapsNavigatePromptID(#"{"ok": false, "action": "navigate", "error": "not_set_up"}"#))
        XCTAssertNil(AppState.mapsNavigatePromptID("navigate"))
        XCTAssertNil(AppState.mapsNavigatePromptID(nil))
    }

    func testAnAnswerSyncedDuringABusyExchangeStillReachesTheHost() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        // The host lists the confirmation until the answer lands; the first
        // three exchanges wait until the test lets them answer.
        var bodies: [[String: Any]] = []
        var held: [CheckedContinuation<Void, Never>] = []
        let exchange: PresentedScreensSync.Request = { _, body in
            bodies.append(body)
            if bodies.count <= 3 { await withCheckedContinuation { held.append($0) } }
            return ["ok": true, "prompts": [["id": "p1", "title": "Send?", "action_label": "Send"]]]
        }
        func waitForExchange(_ count: Int) async {
            while bodies.count < count || held.isEmpty { await Task.yield() }
        }
        // Another trigger while an exchange is on its way: it coalesces.
        func syncAgain() async {
            await sync.sync(scope: "host|default", profile: "default", installationID: "i", request: exchange)
        }

        let first = Task { await sync.sync(scope: "host|default", profile: "default", installationID: "i", request: exchange) }
        await waitForExchange(1)
        await syncAgain() // a tool started
        held.removeFirst().resume()
        await waitForExchange(2)
        await syncAgain() // the tool finished
        held.removeFirst().resume()
        await waitForExchange(3)
        // The user answers while the third exchange is on its way.
        let prompt = try XCTUnwrap(sync.prompts.first)
        sync.answer(prompt, outcome: .confirmed, via: .tap)
        await syncAgain()
        held.removeFirst().resume()
        await first.value

        XCTAssertEqual(bodies.count, 4, "the sync asked for after the answer runs")
        let results = bodies.last?["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["id"] as? String, "p1")
        XCTAssertEqual(results?.first?["outcome"] as? String, "confirmed")
    }

    func testAnExpiredConfirmIsntShown() {
        let prompt = PresentedConfirm(id: "p1", title: "Buy it?", preview: "", actionLabel: "Buy",
                                      expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(prompt.isExpired())
    }

    func testHermesCardsAreHandedOnOnceAndNotFromBeforeTheApp() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        var handed: [[String]] = []
        sync.onCards = { cards in handed.append(cards.map(\.id)) }
        var cards: [[String: Any]] = [["id": "old", "title": "Before", "markdown": "| a |"]]
        let exchange: PresentedScreensSync.Request = { _, _ in ["ok": true, "prompts": [], "cards": cards] }

        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1", request: exchange)
        XCTAssertEqual(handed, [], "a card from before this app's first exchange was for another conversation")

        cards.append(["id": "new", "title": "Forecast", "markdown": " | Mon | 20 | "])
        cards.append(["id": "empty", "title": "Nothing", "markdown": "  "])
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1", request: exchange)
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1", request: exchange)
        XCTAssertEqual(handed, [["new"]], "once, and never a card with nothing to show")
        XCTAssertEqual(PresentedCard(json: cards[1]), PresentedCard(id: "new", title: "Forecast", markdown: "| Mon | 20 |"))

        // Another host or profile starts over.
        await sync.sync(scope: "host|bot", profile: "bot", installationID: "install-1", request: exchange)
        XCTAssertEqual(handed, [["new"]])
    }

    func testAHermesCardDrawsItsPlacesAndLeavesOutTheirOwnText() throws {
        let map: [String: Any] = ["type": "map", "places": [["name": "Kin Khao", "lat": 37.7853, "lon": -122.4089]]]
        let drawn = try XCTUnwrap(PresentedCard(json: [
            "id": "dinner", "title": "Dinner", "markdown": "- **Kin Khao**", "cards": [map], "fallback": true,
        ]))
        XCTAssertEqual(drawn.cards.count, 1)
        XCTAssertEqual(drawn.markdown, "", "the places' own text would show them twice")

        let written = try XCTUnwrap(PresentedCard(json: [
            "id": "plan", "title": "Plan", "markdown": "| a |", "cards": [map],
        ]))
        XCTAssertEqual(written.markdown, "| a |", "what Hermes wrote shows beside the cards")
        XCTAssertNotEqual(drawn, PresentedCard(id: "dinner", title: "Dinner", markdown: ""), "the cards count")
    }
}
