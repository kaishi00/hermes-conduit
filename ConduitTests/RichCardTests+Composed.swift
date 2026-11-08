//
//  RichCardTests+Composed.swift
//  ConduitTests
//
//  Composed cards, buttons on any card and taps (Cards Hermes shows in
//  docs/FEATURE_MAP.md, issue 1946): the card as the views read it, the
//  rules both sides share beyond the vectors, and what a live model is
//  offered. An extension of an existing class, so the test planner needs no
//  new entry.
//

import XCTest
@testable import Conduit

extension AppStateVoiceCapabilityTests {
    private var emailCard: [String: Any] {
        [
            "type": "composed", "title": "Email to Mei", "live": "email-mei",
            "sections": [
                ["items": [["kind": "badge", "text": "Not sent", "tone": "warning"]]],
                ["layout": "row", "more": true, "items": [
                    ["kind": "field", "id": "to", "input": "text", "label": "To", "value": "mei@example.com"],
                    ["kind": "field", "id": "when", "input": "choice", "options": ["Now", "Tonight"], "value": "tonight"],
                    ["kind": "button", "label": "Open Gmail", "action": "open", "target": "https://mail.google.com/"],
                ]],
            ],
            "actions": [
                ["label": "Send", "action": "tap", "id": "send", "style": "primary", "confirm": "Send to Mei?"],
                ["label": "Discard", "action": "tap", "id": "discard", "style": "destructive"],
            ],
        ]
    }

    func testAComposedCardReadsItsSectionsFieldsAndButtons() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(RichCard.cards(raw: [emailCard], schema: schema).first)
        XCTAssertEqual(card.kind, .composed)
        XCTAssertEqual(card.sections.count, 2)
        XCTAssertTrue(card.sections[1].row && card.sections[1].more)
        let field = try XCTUnwrap(card.sections[1].elements[1].field)
        XCTAssertEqual(field.input, .choice)
        XCTAssertEqual(field.value, "Tonight", "a choice keeps the option as written")
        XCTAssertEqual(card.sections[1].elements[2].button?.openURL, URL(string: "https://mail.google.com/"))
        XCTAssertEqual(card.actions.map(\.id), ["send", "discard"])
        XCTAssertEqual(card.actions.first?.confirm, "Send to Mei?")
        XCTAssertFalse(card.normalizedJSON.isEmpty, "a tap sends the card back as the chat holds it")
    }

    func testAnyCardCarriesButtons() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(RichCard.cards(raw: [[
            "type": "callout", "callout": ["text": "Your vet visit is due."],
            "actions": [["label": "Call", "action": "open", "target": "tel:+14155550100"],
                        ["label": "Bad", "action": "open", "target": "javascript:alert(1)"]],
        ]], schema: schema).first)
        XCTAssertEqual(card.actions.map(\.label), ["Call"])
        let reset = try XCTUnwrap(RichCard.cards(raw: [[
            "type": "callout", "callout": ["text": "Hi"],
            "actions": [["label": "/reset", "action": "tap", "id": "r"], ["label": "Go", "action": "tap", "id": "g"]],
        ]], schema: schema).first)
        XCTAssertEqual(reset.actions.map(\.label), ["Go"], "a tap sends its label, so it must be a plain message")
    }

    @MainActor
    func testFieldValuesAreKeptForACardDrawnAgain() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(RichCard.cards(raw: [[
            "type": "composed", "title": "Kept", "sections": [["items": [
                ["kind": "field", "id": "note", "input": "text"]]]],
        ]], schema: schema).first)
        let memory = RichCardFieldMemory()
        let chat = RichCardActionContext.chat(dashboard: "d", profile: "p", sessionID: "a")
        XCTAssertNil(memory.kept(card: card, chat: chat))
        memory.keep(card: card, chat: chat, values: ["note": "typed"], open: true)
        XCTAssertEqual(memory.kept(card: card, chat: chat)?.values, ["note": "typed"])
        XCTAssertEqual(memory.kept(card: card, chat: chat)?.open, true)
        XCTAssertNil(memory.kept(card: card, chat: RichCardActionContext.chat(dashboard: "d", profile: "p", sessionID: "b")),
                     "the same card in another chat starts on its own")
        XCTAssertNil(memory.kept(card: card, chat: RichCardActionContext.chat(dashboard: "d", profile: "q", sessionID: "a")),
                     "or on another profile")
        memory.keep(card: card, chat: nil, values: ["note": "saved copy"], open: true)
        XCTAssertNil(memory.kept(card: card, chat: nil), "outside a chat nothing is kept")
        // The least recently kept card goes past the cap; the one typed in stays.
        for index in 0..<RichCardFieldMemory.maxCards {
            memory.keep(card: card, chat: "other-\(index)", values: [:], open: false)
            if index == RichCardFieldMemory.maxCards / 2 {
                memory.keep(card: card, chat: chat, values: ["note": "again"], open: true)
            }
        }
        XCTAssertEqual(memory.kept(card: card, chat: chat)?.values, ["note": "again"])
        XCTAssertNil(memory.kept(card: card, chat: "other-0"))
    }

    @MainActor
    func testATapShowsSentOnlyInItsOwnChat() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(RichCard.cards(raw: [emailCard], schema: schema).first)
        let memory = RichCardTapMemory()
        let mine = RichCardTapMemory.key(card: card, button: "send", chat: "p\u{1F}a")
        let other = RichCardTapMemory.key(card: card, button: "send", chat: "p\u{1F}b")
        memory.set(mine, .sent)
        XCTAssertEqual(memory.state(mine), .sent)
        XCTAssertNil(memory.state(other))
        memory.set(other, .sending)
        memory.set(other, nil)
        XCTAssertEqual(memory.state(mine), .sent, "another chat's failed tap leaves this one's alone")
    }

    @MainActor
    func testATapAndTypedValuesFollowTheChatToItsDurableId() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(RichCard.cards(raw: [emailCard], schema: schema).first)
        let runtime = "d\u{1F}p\u{1F}runtime-a", durable = "d\u{1F}p\u{1F}stored-a", other = "d\u{1F}p\u{1F}stored-b"
        let same: @MainActor (String, String) -> Bool = { lhs, rhs in
            lhs == rhs || Set([lhs, rhs]) == Set([runtime, durable])
        }
        let taps = RichCardTapMemory()
        taps.set(RichCardTapMemory.key(card: card, button: "send", chat: runtime), .sending)
        XCTAssertEqual(taps.state(card: card, button: "send", chat: durable, sameChat: same), .sending,
                       "a tap on its way keeps its spinner, and holds its button, once the chat gets its durable id")
        XCTAssertNil(taps.state(card: card, button: "send", chat: durable), "only through the chat's own test")
        XCTAssertNil(taps.state(card: card, button: "send", chat: other, sameChat: same))
        taps.set(RichCardTapMemory.key(card: card, button: "send", chat: runtime), .sent)
        XCTAssertEqual(taps.state(card: card, button: "send", chat: durable, sameChat: same), .sent)

        let fields = RichCardFieldMemory()
        fields.keep(card: card, chat: runtime, values: ["note": "typed"], open: true, sameChat: same)
        XCTAssertEqual(fields.kept(card: card, chat: durable, sameChat: same)?.values, ["note": "typed"],
                       "a card drawn again after the id changed, off screen meanwhile, keeps what was typed")
        XCTAssertNil(fields.kept(card: card, chat: other, sameChat: same))
        fields.keep(card: card, chat: durable, values: ["note": "more"], open: true, sameChat: same)
        XCTAssertEqual(fields.kept(card: card, chat: runtime, sameChat: same)?.values, ["note": "more"],
                       "one entry for the chat, not one per id")
    }

    func testANumberFieldTakesOnlyANumberInRange() throws {
        let field = try XCTUnwrap(RichField(json: ["id": "seats", "input": "number", "min": 1, "max": 8]))
        XCTAssertEqual(field.numberText("3"), "3")
        XCTAssertEqual(field.numberText("3,5"), "3.5", "a comma keypad's decimal point")
        XCTAssertEqual(field.numberText(""), "")
        XCTAssertNil(field.numberText("12"))
        XCTAssertNil(field.numberText("0"))
        XCTAssertNil(field.numberText("two"))
        XCTAssertEqual(field.numberRange, "1 – 8")
        XCTAssertEqual(try XCTUnwrap(RichField(json: ["id": "n", "input": "number"])).numberRange, "123")
    }

    func testATapsMessageGoesOnlyToItsChatWithNoDraft() {
        let tapped = RichCardActionContext.chat(dashboard: "d", profile: "p", sessionID: "s1")!
        func may(open: String? = "d\u{1F}p\u{1F}s1", enabled: Bool = true, draft: String = "") -> Bool {
            RichCardActionContext.mayFollowUp(tappedIn: tapped, openChat: open, composerIsEnabled: enabled, draft: draft)
        }
        XCTAssertTrue(may())
        XCTAssertTrue(may(draft: "  \n"))
        XCTAssertFalse(may(open: RichCardActionContext.chat(dashboard: "d", profile: "p", sessionID: "other")),
                       "the user switched chats while the tap was on its way, even to one sharing a runtime id")
        XCTAssertFalse(may(open: RichCardActionContext.chat(dashboard: "d", profile: "q", sessionID: "s1")))
        XCTAssertFalse(may(open: nil))
        XCTAssertFalse(may(enabled: false))
        XCTAssertFalse(may(draft: "typed meanwhile"))
        XCTAssertFalse(RichCardActionContext.mayFollowUp(tappedIn: tapped, openChat: tapped, composerIsEnabled: true,
                                                         draft: "", stagedAttachments: true),
                       "a photo staged meanwhile would go along with the message")
        XCTAssertNil(RichCardActionContext.chat(dashboard: "d", profile: "p", sessionID: ""))
    }

    func testAFieldWhosePlaceholderAsksForASecretIsDropped() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(RichCard.cards(raw: [[
            "type": "composed", "title": "Notes", "sections": [["items": [
                ["kind": "field", "id": "notes", "input": "text", "placeholder": "Paste your API key"],
                ["kind": "field", "id": "topic", "input": "text", "placeholder": "What it's about"],
            ]]],
        ]], schema: schema).first)
        XCTAssertEqual(card.sections[0].elements.compactMap { $0.field?.id }, ["topic"])
    }

    func testFieldsNeverAskForSecrets() {
        for name in ["password", "Your Passcode", "api_key", "apiKey", "OTP", "PIN", "card-cvv", "One time code",
                     "auth token", "client_secret", "SSH private key", "Recovery key", "Verification code", "license_key",
                     "Passphrase", "TOTP", "Master key", "App credentials",
                     "2FA code", "Two-factor code", "Login code", "パスワード", "Passwort", "Contraseña",
                     "Mot de passe", "Пароль", "Kata sandi", "비밀번호를 입력", "인증 코드", "密码", "Access code",
                     "Unlock code", "Security key", "Bestätigungscode", "Código de verificación",
                     "Code de vérification", "Kode verifikasi", "Doğrulama kodu", "Код подтверждения",
                     "Pincode", "pin_code", "MFA code", "mfaCode", "PIN码", "输入PIN", "OTP認証", "ＰＩＮコード", "ＭＦＡ"] {
            XCTAssertTrue(RichCardSchema.namesSecret(name), name)
        }
        for name in ["Spin class", "Subject", "Opinion", "Pinned note", "to", "Topic", "Key dates", "Zip code", "メモ",
                     "Betreff", "Тема", "Spinning クラス", "Comfort level", "Spin code",
                     "Hairpin code", "ＳＰＩＮ"] {
            XCTAssertFalse(RichCardSchema.namesSecret(name), name)
        }
    }

    func testOpenButtonsOpenOnlySafeLinks() {
        XCTAssertTrue(RichCardSchema.isOpenable("https://a.test/x"))
        XCTAssertTrue(RichCardSchema.isOpenable("MAPS:?q=Vet"))
        XCTAssertTrue(RichCardSchema.isOpenable("calshow:1234"))
        XCTAssertFalse(RichCardSchema.isOpenable("http://a.test/x"), "https only on the web")
        XCTAssertFalse(RichCardSchema.isOpenable("javascript:alert(1)"))
        XCTAssertFalse(RichCardSchema.isOpenable("https://a.test/a b"))
        XCTAssertFalse(RichCardSchema.isOpenable("https://a.test/\"x"))
    }

    func testATapsMessageNamesTheButtonAndTheCard() {
        XCTAssertEqual(RichCardActionContext.message(label: "Send", title: "Email to Mei"), "Send · Email to Mei")
        XCTAssertEqual(RichCardActionContext.message(label: "Do it", title: nil), "Do it")
        XCTAssertEqual(RichCardActionContext.message(label: "Open", title: "@notes.md"), "Open",
                       "a title that would make the message a file reference stays out")
        XCTAssertEqual(RichCardActionContext.tapPath(profile: "work"),
                       "/api/plugins/conduit_push/boards/taps?profile=work")
        XCTAssertEqual(RichCardActionContext.dropPath(profile: "work", id: "ab12"),
                       "/api/plugins/conduit_push/boards/taps?profile=work&id=ab12")
    }

    func testALiveModelsButtonsOpenAndCopyOnly() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let parameter = schema.liveToolParameter(description: "Cards")
        let card = try XCTUnwrap(parameter["items"] as? [String: Any])
        let properties = try XCTUnwrap(card["properties"] as? [String: Any])
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any])
        let button = try XCTUnwrap((actions["items"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual((button["action"] as? [String: Any])?["enum"] as? [String], ["open", "copy"])
        let sections = try XCTUnwrap(properties["sections"] as? [String: Any])
        let section = try XCTUnwrap((sections["items"] as? [String: Any])?["properties"] as? [String: Any])
        let element = try XCTUnwrap(((section["items"] as? [String: Any])?["items"] as? [String: Any])?["properties"]
            as? [String: Any])
        XCTAssertFalse(((element["kind"] as? [String: Any])?["enum"] as? [String] ?? []).contains("field"))
        XCTAssertEqual((element["action"] as? [String: Any])?["enum"] as? [String], ["open", "copy"])
    }

    @MainActor
    func testATapShowsAsSentUntilTheHoldPasses() throws {
        let schema = try XCTUnwrap(RichCardSchema.bundled)
        let card = try XCTUnwrap(RichCard.cards(raw: [emailCard], schema: schema).first)
        let memory = RichCardTapMemory()
        let key = RichCardTapMemory.key(card: card, button: "send", chat: "p\u{1F}a")
        memory.set(key, .sent)
        XCTAssertEqual(memory.state(key), .sent)
        XCTAssertNil(memory.state(key, now: Date().addingTimeInterval(RichCardTapMemory.holdSeconds + 1)))
        memory.set(key, nil)
        XCTAssertNil(memory.state(key))
        memory.set(key, .sending)
        XCTAssertEqual(memory.state(key, now: Date().addingTimeInterval(RichCardTapMemory.holdSeconds + 1)), .sending,
                       "a slow tap keeps its spinner until it's answered")
    }

    func testAChatValueReadsBackItsParts() throws {
        let chat = try XCTUnwrap(RichCardActionContext.chat(dashboard: "d", profile: "p", sessionID: "s\u{1F}x"))
        let parts = try XCTUnwrap(RichCardActionContext.parts(chat))
        XCTAssertEqual(parts.dashboard, "d")
        XCTAssertEqual(parts.profile, "p")
        XCTAssertEqual(parts.sessionID, "s\u{1F}x")
        XCTAssertNil(RichCardActionContext.parts("d\u{1F}p"))
    }

    @MainActor
    func testRepliesBackFromAStagedPhotoStartTheirTapGuardAgain() {
        let store = PredictiveStore()
        store.stagedAttachmentsChanged(true)
        let removed = Date()
        store.stagedAttachmentsChanged(false)
        XCTAssertTrue(store.tapIsGuarded(now: removed), "a tap meant for the photo's row doesn't send a reply")
        XCTAssertFalse(store.tapIsGuarded(now: removed.addingTimeInterval(Predictive.tapGuard + 0.1)))
    }

    func testAnUnsetDateFieldStartsWithNoDay() throws {
        let field = try XCTUnwrap(RichField(json: ["id": "day", "input": "date"]))
        XCTAssertEqual(field.startingValue, "", "a tap never sends a day the user didn't pick")
        XCTAssertNil(RichFieldDates.date(field.startingValue))
        XCTAssertEqual(try XCTUnwrap(RichField(json: ["id": "day", "input": "date", "value": "2026-11-08"])).startingValue,
                       "2026-11-08")
    }

    func testADateFieldKeepsOnlyARealDay() {
        for (value, real) in [("2026-02-31", false), ("2026-02-29", false), ("2028-02-29", true), ("2100-02-29", false),
                              ("2000-02-29", true), ("2026-13-01", false), ("0000-01-01", false),
                              ("2026-11-08T24:00", false), ("2026-11-08T23:59", true), ("2026-04-31T09:00", false),
                              ("Friday", false)] {
            XCTAssertEqual(RichCardSchema.isRealDate(value), real, value)
        }
    }

    @MainActor
    func testAStagedPhotoKeepsTheComposerFromEmpty() {
        let store = PredictiveStore()
        XCTAssertTrue(store.isEmpty)
        store.stagedAttachmentsChanged(true)
        XCTAssertFalse(store.isEmpty, "a card's send would take the photo along")
        store.forgetAll()
        XCTAssertFalse(store.isEmpty, "sign-out leaves what the composer has staged to the composer")
        store.stagedAttachmentsChanged(false)
        store.draftChanged("hi")
        XCTAssertFalse(store.isEmpty)
        store.forgetAll()
        XCTAssertTrue(store.isEmpty)
    }

    func testAFieldsDateReadsAndWritesAsTheSchemaDoes() throws {
        let date = try XCTUnwrap(RichFieldDates.date("2026-11-08T09:30"))
        XCTAssertEqual(RichFieldDates.text(date, timed: true), "2026-11-08T09:30")
        XCTAssertEqual(RichFieldDates.text(date, timed: false), "2026-11-08")
        XCTAssertNil(RichFieldDates.date("Friday"))
    }
}
