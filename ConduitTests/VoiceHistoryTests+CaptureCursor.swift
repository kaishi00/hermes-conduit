//
//  VoiceHistoryTests+CaptureCursor.swift
//  Conduit
//
//  #1004: a live call's capture picks up where the last one stopped, and
//  still takes every line when the engine changed the lines before it.
//

import XCTest
@testable import Conduit

@MainActor
private func cursorRecorder() -> VoiceTranscriptRecorder {
    VoiceTranscriptRecorder(
        engine: .gptLive,
        profile: "default",
        save: { request in
            VoiceTranscriptSaveResult(sessionID: "row-1", written: (request.turns.last?.index ?? -1) + 1)
        },
        title: { _ in "Call" }
    )
}

extension HermesVoiceGatewayTimeoutTests {
    func testRecorderCaptureGoesOnFromWhereTheLastOneStopped() {
        let recorder = cursorRecorder()
        var transcript = (0..<200).map { VoiceConversationTranscriptEntry(speaker: $0.isMultiple(of: 2) ? .user : .assistant, text: "Line \($0)") }
        let streaming = VoiceConversationTranscriptEntry(speaker: .assistant, text: "Still talking")
        transcript.append(streaming)
        recorder.capture(transcript, unsettled: [streaming.id])
        XCTAssertEqual(recorder.turns.count, 200)

        // The streaming line settles and two more arrive.
        transcript.append(VoiceConversationTranscriptEntry(speaker: .user, text: "Next"))
        transcript.append(VoiceConversationTranscriptEntry(speaker: .assistant, text: "Okay."))
        recorder.capture(transcript, unsettled: [])
        XCTAssertEqual(recorder.turns.suffix(3).map(\.text), ["Still talking", "Next", "Okay."])
        XCTAssertEqual(recorder.turns.map(\.index), Array(0..<203))
    }

    func testRecorderCaptureRescansWhenTheEngineDroppedAnEarlierLine() {
        let recorder = cursorRecorder()
        let first = VoiceConversationTranscriptEntry(speaker: .user, text: "Plan dinners")
        let dropped = VoiceConversationTranscriptEntry(speaker: .assistant, text: "Sure.")
        let held = VoiceConversationTranscriptEntry(speaker: .assistant, text: "Tacos?")
        recorder.capture([first, dropped, held], unsettled: [held.id])
        XCTAssertEqual(recorder.turns.map(\.text), ["Plan dinners", "Sure."])

        // The engine removes a line before the cursor (GPT-Live drops a
        // reply it replaced): what follows is still taken, once.
        let later = VoiceConversationTranscriptEntry(speaker: .user, text: "Yes, tacos")
        recorder.capture([first, held, later], unsettled: [])
        XCTAssertEqual(recorder.turns.map(\.text), ["Plan dinners", "Sure.", "Tacos?", "Yes, tacos"])
        recorder.capture([first, held, later], unsettled: [])
        XCTAssertEqual(recorder.turns.count, 4)
    }
}
