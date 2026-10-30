//
//  ChatVoiceButtonTests.swift
//  ConduitTests
//
//  What the big button beside a chat's composer does (Chat voice button).
//  An extension of an existing class, so CI plans no new test class.
//

import XCTest
@testable import Conduit

extension ComposerFullEditorTests {
    func testChatVoiceButtonDefaultsToALiveCall() {
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: nil, app: nil), .liveCall)
    }

    func testChatVoiceButtonProfileChoiceWinsOverTheApps() {
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: nil, app: "dictation"), .dictation)
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "live_call", app: "dictation"), .liveCall)
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "dictation", app: "live_call"), .dictation)
    }

    func testChatVoiceButtonSkipsChoicesThisBuildCantDo() {
        // A newer build's value reads as the next choice down.
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "telepathy", app: "dictation"), .dictation)
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "telepathy", app: "telepathy"), .liveCall)
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "voice_message", app: nil), .voiceMessage)
        XCTAssertNil(ChatVoiceButtonAction.offeredChoice("telepathy"))
        XCTAssertNil(ChatVoiceButtonAction.offeredChoice(nil))
        XCTAssertEqual(ChatVoiceButtonAction.offeredChoice("dictation"), .dictation)
        XCTAssertEqual(ChatVoiceButtonAction.offered, [.liveCall, .voiceMessage, .dictation])
    }

    func testVoiceMessagePromptCarriesItsLengthAndWords() {
        XCTAssertEqual(
            VoiceMessage.promptText(duration: 14.4, transcript: "  Pick up milk  "),
            "[Voice message, 0:14. Transcript:]\nPick up milk"
        )
        XCTAssertEqual(
            VoiceMessage.promptText(duration: 61, transcript: ""),
            "[Voice message, 1:01. No transcript: listen to the attached audio file if you can.]"
        )
        XCTAssertEqual(VoiceMessage.durationLabel(3_723), "1:02:03")
    }

    func testVoiceMessageBubbleReadsBackItsPrompt() throws {
        let sent = VoiceMessage.promptText(duration: 14, transcript: "Pick up milk\nand eggs")
        let parsed = try XCTUnwrap(VoiceMessage.parse(sent))
        XCTAssertEqual(parsed.duration, "0:14")
        XCTAssertEqual(parsed.transcript, "Pick up milk\nand eggs")
        let silent = try XCTUnwrap(VoiceMessage.parse(VoiceMessage.promptText(duration: 3, transcript: "")))
        XCTAssertEqual(silent.transcript, "")
        // Typed text that merely mentions one is not a voice message.
        XCTAssertNil(VoiceMessage.parse("I sent a [Voice message, 0:14] earlier"))
        XCTAssertNil(VoiceMessage.parse("Hello"))
    }

    func testVoiceMessageFilesAreKnownByTheirName() {
        XCTAssertTrue(VoiceMessage.isVoiceMessageFile("voice-message-20261022-211500.m4a"))
        XCTAssertTrue(VoiceMessage.isVoiceMessageFile("/tmp/ABC-voice-message-20261022-211500.m4a"))
        XCTAssertFalse(VoiceMessage.isVoiceMessageFile("podcast.m4a"))
    }

    func testVoiceMessageCopiesWhatWasSaid() {
        let message = ChatMessage(
            id: "1",
            role: .user,
            content: VoiceMessage.promptText(duration: 5, transcript: "Call Mona"),
            timestamp: "ts-1"
        )
        XCTAssertEqual(UserMessageCopyButton.copyText(for: message), "Call Mona")
    }

    func testRestingComposerHidesItsMicWhenTheBigButtonDictates() {
        XCTAssertTrue(ComposerBar.showsRestingDictateButton(chatVoiceButton: .liveCall))
        XCTAssertFalse(ComposerBar.showsRestingDictateButton(chatVoiceButton: .dictation))
    }

    func testBigButtonCentresOnATallerRestingComposer() {
        // Level with a one-line bar, as before.
        XCTAssertEqual(V2ConversationScreen.voiceButtonBottomPadding(restingComposerHeight: 0), 10)
        XCTAssertEqual(V2ConversationScreen.voiceButtonBottomPadding(restingComposerHeight: 56), 10)
        // A bar 20 pt taller (a wrapped placeholder, a large Text Size)
        // lifts it by half that.
        XCTAssertEqual(V2ConversationScreen.voiceButtonBottomPadding(restingComposerHeight: 76), 20)
    }

    func testBigButtonSitsLevelWithTheBottomOfAComposerThatStaysExpanded() {
        // A bar last measured taller no longer lifts it.
        XCTAssertEqual(V2ConversationScreen.voiceButtonBottomPadding(restingComposerHeight: 76, composerStaysExpanded: true), 10)
    }

    func testComposerRestsOnIPhoneAndStaysExpandedOnMacAndWideIPad() {
        // An iPhone rests however wide, a Pro Max in landscape too.
        XCTAssertFalse(ComposerLayout.staysExpanded(width: 932, idiom: .phone, onMac: false))
        // An iPad with the room stays expanded; a narrow split rests.
        XCTAssertTrue(ComposerLayout.staysExpanded(width: 744, idiom: .pad, onMac: false))
        XCTAssertTrue(ComposerLayout.staysExpanded(width: ComposerLayout.expandedMinimumWidth, idiom: .pad, onMac: false))
        XCTAssertFalse(ComposerLayout.staysExpanded(width: 507, idiom: .pad, onMac: false))
        // A Mac stays expanded at any width.
        XCTAssertTrue(ComposerLayout.staysExpanded(width: 400, idiom: .pad, onMac: true))
    }

    func testComposerKeepsFocusAfterSendOnMacAndWithAHardwareKeyboard() {
        // Typing carries on into the next message, as in a desktop client.
        XCTAssertTrue(ComposerLayout.keepsFocusAfterSend(onMac: true, hardwareKeyboard: false))
        XCTAssertTrue(ComposerLayout.keepsFocusAfterSend(onMac: false, hardwareKeyboard: true))
        // The on-screen keyboard goes, so the reply has the screen.
        XCTAssertFalse(ComposerLayout.keepsFocusAfterSend(onMac: false, hardwareKeyboard: false))
    }

    func testExpandedComposerBesideTheBigButtonLeavesVoiceAndItsMicToIt() {
        // The big button beside it offers voice, so the slot keeps Send.
        XCTAssertEqual(ComposerBar.trailingControl(action: .unavailable, showsVoiceButton: false), .action)
        // An empty draft shows Send dimmed, not the lock of a composer
        // that can't send; a reconnecting one, an offline copy or a chat still
        // being made (composerIsEnabled false) keeps the lock.
        XCTAssertTrue(ComposerBar.showsEmptyDraftSend(action: .unavailable, voiceButtonBeside: true, composerIsEnabled: true))
        XCTAssertFalse(ComposerBar.showsEmptyDraftSend(action: .unavailable, voiceButtonBeside: true, composerIsEnabled: false))
        XCTAssertFalse(ComposerBar.showsEmptyDraftSend(action: .unavailable, voiceButtonBeside: false, composerIsEnabled: true))
        XCTAssertFalse(ComposerBar.showsEmptyDraftSend(action: .send, voiceButtonBeside: true, composerIsEnabled: true))
        // The row's mic gives way to a big button that dictates.
        XCTAssertFalse(ComposerBar.controlsRowShowsDictate(holdsSendSlot: false, voiceButtonBeside: true, showsRestingDictateButton: false))
        XCTAssertTrue(ComposerBar.controlsRowShowsDictate(holdsSendSlot: false, voiceButtonBeside: true, showsRestingDictateButton: true))
        XCTAssertTrue(ComposerBar.controlsRowShowsDictate(holdsSendSlot: false, voiceButtonBeside: false, showsRestingDictateButton: false))
        XCTAssertFalse(ComposerBar.controlsRowShowsDictate(holdsSendSlot: true, voiceButtonBeside: false, showsRestingDictateButton: true))
    }

    func testProfileVoicePreferencesKeepTheChatVoiceButton() throws {
        var preferences = VoiceProfilePreferences()
        preferences.chatVoiceButton = "dictation"
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(VoiceProfilePreferences.self, from: data).chatVoiceButton, "dictation")
        // Older blobs have no choice: the app's applies.
        let old = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data("{}".utf8))
        XCTAssertNil(old.chatVoiceButton)
    }
}
