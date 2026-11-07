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
        XCTAssertNil(memory.kept(card: card, chat: ["a"]))
        memory.keep(card: card, chat: ["a"], values: ["note": "typed"], open: true)
        XCTAssertEqual(memory.kept(card: card, chat: ["a"])?.values, ["note": "typed"])
        XCTAssertEqual(memory.kept(card: card, chat: ["a"])?.open, true)
        XCTAssertEqual(memory.kept(card: card, chat: ["a", "a2"])?.values, ["note": "typed"],
                       "a chat that gained an id is the same chat")
        XCTAssertNil(memory.kept(card: card, chat: ["b"]), "the same card in another chat starts on its own")
        XCTAssertNil(memory.kept(card: card, chat: []), "outside a chat too")
        // The least recently kept card goes past the cap; the one typed in stays.
        for index in 0..<RichCardFieldMemory.maxCards {
            memory.keep(card: card, chat: ["other-\(index)"], values: [:], open: false)
            if index == RichCardFieldMemory.maxCards / 2 {
                memory.keep(card: card, chat: ["a", "a2"], values: ["note": "again"], open: true)
            }
        }
        XCTAssertEqual(memory.kept(card: card, chat: ["a2"])?.values, ["note": "again"])
        XCTAssertNil(memory.kept(card: card, chat: ["other-0"]))
    }

    @MainActor
    func testATapShowsSentOnlyInItsOwnChat() {
        let memory = RichCardTapMemory()
        memory.set("k", .sent, chat: ["a"])
        XCTAssertEqual(memory.state("k", chat: ["a", "a2"]), .sent)
        XCTAssertNil(memory.state("k", chat: ["b"]))
        XCTAssertNil(memory.state("k", chat: ["a"], now: .now.addingTimeInterval(RichCardTapMemory.holdSeconds + 1)))
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
    }

    func testATapsMessageGoesOnlyToItsChatWithNoDraft() {
        func may(open: [String] = ["s1"], profile: String = "p", enabled: Bool = true, draft: String = "") -> Bool {
            RichCardActionContext.mayFollowUp(tappedIn: ["s1", "s2"], profile: "p", openSessionIDs: open,
                                              openProfile: profile, composerIsEnabled: enabled, draft: draft)
        }
        XCTAssertTrue(may())
        XCTAssertTrue(may(draft: "  \n"))
        XCTAssertFalse(may(open: ["other"]), "the user switched chats while the tap was on its way")
        XCTAssertFalse(may(profile: "q"))
        XCTAssertFalse(may(enabled: false))
        XCTAssertFalse(may(draft: "typed meanwhile"))
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
                     "Mot de passe", "Пароль", "Kata sandi", "비밀번호를 입력", "密码", "Access code",
                     "Unlock code", "Security key", "Bestätigungscode", "Código de verificación",
                     "Code de vérification", "Kode verifikasi", "Doğrulama kodu", "Код подтверждения"] {
            XCTAssertTrue(RichCardSchema.namesSecret(name), name)
        }
        for name in ["Spin class", "Subject", "Opinion", "Pinned note", "to", "Topic", "Key dates", "Zip code", "メモ",
                     "Betreff", "Тема"] {
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
        let key = RichCardTapMemory.key(card: card, button: "send")
        memory.set(key, .sent, chat: [])
        XCTAssertEqual(memory.state(key, chat: []), .sent)
        XCTAssertNil(memory.state(key, chat: [], now: Date().addingTimeInterval(RichCardTapMemory.holdSeconds + 1)))
        memory.set(key, nil, chat: [])
        XCTAssertNil(memory.state(key, chat: []))
    }

    func testAFieldsDateReadsAndWritesAsTheSchemaDoes() throws {
        let date = try XCTUnwrap(RichFieldDates.date("2026-11-08T09:30"))
        XCTAssertEqual(RichFieldDates.text(date, timed: true), "2026-11-08T09:30")
        XCTAssertEqual(RichFieldDates.text(date, timed: false), "2026-11-08")
        XCTAssertNil(RichFieldDates.date("Friday"))
    }
}
