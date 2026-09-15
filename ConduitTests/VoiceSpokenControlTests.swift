//
//  VoiceSpokenControlTests.swift
//  Conduit
//
//  Configurable spoken Voice controls: Stop phrases (existing semantics,
//  now editable) and End Conversation phrases (new category that closes the
//  Voice session through the existing Close teardown path).
//

import XCTest
@testable import Conduit

// MARK: - Matching and canonicalization

@MainActor
final class VoiceSpokenCommandMatchingTests: XCTestCase {
    func testDefaultStopPhrasesAreMultilingualBuiltIns() {
        XCTAssertEqual(
            VoiceSpokenCommands.defaultStopPhrases,
            ["stop", "stop talking", "be quiet", "停止", "别说了", "不要说了"])
        XCTAssertEqual(VoiceProfilePreferences().spokenStopPhrases, VoiceSpokenCommands.defaultStopPhrases)
    }

    func testDefaultEndConversationPhrasesAreMultilingualBuiltIns() {
        XCTAssertEqual(
            VoiceSpokenCommands.defaultEndConversationPhrases,
            ["goodbye", "bye", "end conversation", "that's all", "再见", "拜拜", "结束对话", "就这样吧"])
        XCTAssertEqual(VoiceProfilePreferences().spokenEndConversationPhrases,
                       VoiceSpokenCommands.defaultEndConversationPhrases)
    }

    func testOlderPreferenceBlobWithoutEndConversationFieldDecodesWithDefaults() throws {
        let data = try XCTUnwrap(
            #"{"outputMuted":true,"continueWakeConversation":false,"spokenStopPhrases":["stop"]}"#
                .data(using: .utf8)
        )
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)

        XCTAssertEqual(preferences.spokenEndConversationPhrases, VoiceSpokenCommands.defaultEndConversationPhrases)
        XCTAssertEqual(preferences.spokenStopPhrases, ["stop"])
        XCTAssertTrue(preferences.outputMuted)
        XCTAssertTrue(preferences.continuousConversation, "absent continuousConversation still decodes as ON")
        XCTAssertEqual(preferences.resolvedTranscriptionMode, .hermes)
    }

    func testUtteranceCasePunctuationAndWhitespaceNormalizeToMatch() {
        let phrases = ["goodbye"]
        XCTAssertTrue(VoiceSpokenCommands.matches("Goodbye.", phrases: phrases))
        XCTAssertTrue(VoiceSpokenCommands.matches(" GOODBYE ", phrases: phrases))
        XCTAssertTrue(VoiceSpokenCommands.matches("goodbye", phrases: phrases))
        XCTAssertTrue(VoiceSpokenCommands.matches("Goodbye!!!", phrases: phrases))
    }

    func testConfiguredPhrasesAreNormalizedBeforeMatching() {
        let phrases = ["  Goodbye!  ", "BYE"]
        XCTAssertTrue(VoiceSpokenCommands.matches("Goodbye.", phrases: phrases))
        XCTAssertTrue(VoiceSpokenCommands.matches("bye", phrases: phrases))
    }

    func testApostropheVariantsMatchAcrossUtteranceAndPhrase() {
        // The default phrase uses U+0027; ASR often emits U+2019.
        XCTAssertTrue(VoiceSpokenCommands.matches("that's all", phrases: ["that's all"]))
        XCTAssertTrue(VoiceSpokenCommands.matches("that’s all", phrases: ["that's all"]))
        XCTAssertTrue(VoiceSpokenCommands.matches("that's all.", phrases: ["that’s all"]))
        XCTAssertTrue(VoiceSpokenCommands.matches("That’s All!", phrases: ["  that's all  "]))
        XCTAssertFalse(VoiceSpokenCommands.matches("that's all folks", phrases: ["that's all"]))
    }

    func testSubstringUtterancesNeverMatch() {
        XCTAssertTrue(VoiceSpokenCommands.matches("goodbye", phrases: ["goodbye"]))
        XCTAssertFalse(VoiceSpokenCommands.matches("I said goodbye to them", phrases: ["goodbye"]))
        XCTAssertFalse(
            VoiceSpokenCommands.matches("can you stop talking about that", phrases: ["stop", "stop talking"])
        )
    }

    func testEmptyCanonicalUtteranceNeverMatches() {
        XCTAssertFalse(VoiceSpokenCommands.matches("...", phrases: ["!!!"]))
        XCTAssertFalse(VoiceSpokenCommands.matches("   ", phrases: ["stop"]))
    }

    func testCanonicalizedPhraseListTrimsDropsBlanksAndDedupesCaseInsensitively() {
        let canonical = VoiceSpokenCommands.canonicalizedPhraseList(
            ["  Stop ", "", "STOP", "be quiet", "   ", "stop!"]
        )
        XCTAssertEqual(canonical, ["Stop", "be quiet"])
    }

    func testCanonicalizedPhraseListProducesPairwiseDistinctEntries() {
        // The phrase-list editor renders rows with value identity, so the
        // seeded representation must never contain duplicate raw strings —
        // including when it seeds from a legacy blob written before
        // canonicalization existed.
        let canonical = VoiceSpokenCommands.canonicalizedPhraseList(
            ["Stop", "stop", "STOP ", "be quiet", "be quiet.", "", "  ", "halt!"]
        )
        // Display form is the first occurrence, whitespace-trimmed only;
        // "halt!" still matches "halt" at runtime via canonicalization.
        XCTAssertEqual(canonical, ["Stop", "be quiet", "halt!"])
        XCTAssertEqual(Set(canonical).count, canonical.count)
    }

    func testEmptyListDisablesMatchingEntirely() {
        XCTAssertFalse(VoiceSpokenCommands.matches("stop", phrases: []))
        XCTAssertFalse(VoiceSpokenCommands.matches("goodbye", phrases: []))
    }
}

// MARK: - Multilingual built-in commands

@MainActor
final class VoiceSpokenMultilingualCommandTests: XCTestCase {
    private var defaults: [String] { VoiceSpokenCommands.defaultStopPhrases }
    private var endDefaults: [String] { VoiceSpokenCommands.defaultEndConversationPhrases }

    /// The required built-in Chinese commands — recognized regardless of the
    /// selected App Language, because command matching never consults the
    /// UI locale.
    func testChineseEndConversationCommandsMatchExactly() {
        XCTAssertTrue(VoiceSpokenCommands.matches("再见", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("结束对话", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("拜拜", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("就这样吧", phrases: endDefaults))
    }

    func testChineseEndConversationCanonicalizesTrailingPunctuation() {
        // ASR commonly emits the full stop as part of the utterance; the
        // canonicalizer strips leading/trailing punctuation, so「再见。」
        // still matches exactly.
        XCTAssertTrue(VoiceSpokenCommands.matches("再见。", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("再见！", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches(" 拜拜。 ", phrases: endDefaults))
    }

    func testChineseStopCommandsMatchExactly() {
        XCTAssertTrue(VoiceSpokenCommands.matches("停止", phrases: defaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("别说了", phrases: defaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("不要说了", phrases: defaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("停止。", phrases: defaults))
    }

    func testEmbeddedChinesePhrasesNeverMatch() {
        // Exact whole-utterance semantics — no substring or fuzzy matching.
        XCTAssertFalse(VoiceSpokenCommands.matches("我跟他说再见了", phrases: endDefaults))
        XCTAssertFalse(VoiceSpokenCommands.matches("不要停止这个任务", phrases: defaults))
        XCTAssertFalse(VoiceSpokenCommands.matches("别说了吗", phrases: defaults))
        XCTAssertFalse(VoiceSpokenCommands.matches("我想停止", phrases: defaults))
    }

    func testEnglishCommandsStillMatchWithMultilingualDefaults() {
        XCTAssertTrue(VoiceSpokenCommands.matches("stop", phrases: defaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("Stop.", phrases: defaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("stop talking", phrases: defaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("be quiet", phrases: defaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("goodbye", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("Goodbye.", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("bye", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("end conversation", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("that's all", phrases: endDefaults))
        XCTAssertTrue(VoiceSpokenCommands.matches("that’s all.", phrases: endDefaults))
    }

    func testRecognitionIsLanguageIndependentOfAppLanguageSelection() {
        // Command matching consults only the phrase lists, never the App
        // Language selection — pin that by actually changing the persisted
        // selection between matches (restored in defer).
        let standardDefaults = UserDefaults.standard
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }
        for language in AppLanguage.allCases {
            standardDefaults.set(language.rawValue, forKey: AppLanguageStore.defaultsKey)
            XCTAssertEqual(AppLanguage.current, language)
            XCTAssertTrue(VoiceSpokenCommands.matches("停止", phrases: defaults),
                          "Stop must match under \(language)")
            XCTAssertTrue(VoiceSpokenCommands.matches("再见", phrases: endDefaults),
                          "End Conversation must match under \(language)")
            XCTAssertTrue(VoiceSpokenCommands.matches("stop", phrases: defaults),
                          "English Stop must match under \(language)")
        }
    }

    // MARK: - Persistence migration for extended built-ins

    func testStoredOriginalDefaultListMigratesToMultilingualDefaults() throws {
        let data = try XCTUnwrap(
            #"{"spokenStopPhrases":["stop","stop talking","be quiet"],"spokenEndConversationPhrases":["goodbye","bye","end conversation","that's all"]}"#
                .data(using: .utf8)
        )
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)
        XCTAssertEqual(preferences.spokenStopPhrases, VoiceSpokenCommands.defaultStopPhrases)
        XCTAssertEqual(preferences.spokenEndConversationPhrases, VoiceSpokenCommands.defaultEndConversationPhrases)
    }

    func testCustomizedStoredListsArePreservedUntouched() throws {
        let data = try XCTUnwrap(
            #"{"spokenStopPhrases":["stop","halt","停止"],"spokenEndConversationPhrases":["再见"]}"#
                .data(using: .utf8)
        )
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)
        XCTAssertEqual(preferences.spokenStopPhrases, ["stop", "halt", "停止"])
        XCTAssertEqual(preferences.spokenEndConversationPhrases, ["再见"])
    }

    func testStoredListMissingABuiltInIsNotMigrated() throws {
        // A list that merely overlaps an old default (the user deleted
        // "be quiet") must not be "fixed" — deliberate removals stick.
        let data = try XCTUnwrap(
            #"{"spokenStopPhrases":["stop","stop talking"]}"#.data(using: .utf8)
        )
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)
        XCTAssertEqual(preferences.spokenStopPhrases, ["stop", "stop talking"])
    }

    func testEmptyStoredListsStayEmpty() throws {
        let data = try XCTUnwrap(
            #"{"spokenStopPhrases":[],"spokenEndConversationPhrases":[]}"#.data(using: .utf8)
        )
        let preferences = try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)
        XCTAssertEqual(preferences.spokenStopPhrases, [])
        XCTAssertEqual(preferences.spokenEndConversationPhrases, [])
    }

    func testMigrationCanonicalizesBeforeComparing() {
        // Case/apostrophe/whitespace variants of the original defaults are
        // still "never customized".
        XCTAssertEqual(
            VoiceSpokenCommands.migratedDefaultPhrases(
                [" Stop ", "Stop Talking", "be quiet"],
                previous: VoiceSpokenCommands.previousDefaultStopPhrases,
                current: VoiceSpokenCommands.defaultStopPhrases),
            VoiceSpokenCommands.defaultStopPhrases)
        XCTAssertEqual(
            VoiceSpokenCommands.migratedDefaultPhrases(
                ["that’s all", "Bye.", "Goodbye!", "END CONVERSATION"],
                previous: VoiceSpokenCommands.previousDefaultEndConversationPhrases,
                current: VoiceSpokenCommands.defaultEndConversationPhrases),
            VoiceSpokenCommands.defaultEndConversationPhrases)
        XCTAssertNotEqual(
            VoiceSpokenCommands.migratedDefaultPhrases(
                ["stop", "stop talking", "be quiet", "halt"],
                previous: VoiceSpokenCommands.previousDefaultStopPhrases,
                current: VoiceSpokenCommands.defaultStopPhrases),
            VoiceSpokenCommands.defaultStopPhrases)
    }
}

// MARK: - Controller runtime behavior

@MainActor
final class VoiceConversationSpokenEndCommandTests: XCTestCase {
    func testEndConversationPhraseIsConsumedAndClosesThroughClosePath() async {
        let (controller, capture, gateway, spy, flags) = makeController(transcript: "Goodbye.")
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))
        await driveUtterance(controller)
        await flags.endConversations.waitUntil(1)
        await flags.interrupts.waitUntil(1)

        XCTAssertEqual(flags.endConversations.value, 1, "the Close teardown seam must be requested exactly once")
        XCTAssertEqual(gateway.transcriptionCount, 1)
        XCTAssertEqual(spy.texts, [], "the command must never be submitted to Hermes")
        XCTAssertEqual(flags.interrupts.value, 1, "an active Hermes turn is cancelled through the same seam as Stop")
        XCTAssertFalse(controller.hasLiveVoiceSession, "the voice session must be fully closed")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1, "closing must not relisten")
        XCTAssertTrue(controller.conversationTranscript.isEmpty, "locally consumed commands create no transcript entry")
    }

    func testEndConversationFallbackStopsControllerWithoutCloseSeam() async {
        let (controller, capture, _, spy, flags) = makeController(transcript: "goodbye", wiresCloseSeam: false)
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))
        await driveUtterance(controller)
        let stopped = await controller.waitForState(.idle)
        XCTAssertTrue(stopped, "without a Close seam the controller must still stop itself")
        await drainPendingMainActorWork()

        XCTAssertEqual(flags.endConversations.value, 0)
        XCTAssertFalse(controller.hasLiveVoiceSession, "without a Close seam the controller must still stop itself")
        XCTAssertEqual(capture.startCount, 1)
    }

    func testEndConversationClosesWithContinuousConversationOn() async {
        let (controller, capture, _, spy, flags) = makeController(transcript: "goodbye")
        var preferences = preferences(endConversation: ["goodbye"])
        preferences.continuousConversation = true
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)
        await flags.endConversations.waitUntil(1)
        await flags.interrupts.waitUntil(1)
        await drainPendingMainActorWork()

        XCTAssertFalse(controller.hasLiveVoiceSession, "continuous ON must not resurrect the session")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(flags.endConversations.value, 1)
    }

    func testEndConversationClosesWithContinuousConversationOff() async {
        let (controller, capture, _, spy, flags) = makeController(transcript: "goodbye")
        var preferences = preferences(endConversation: ["goodbye"])
        preferences.continuousConversation = false
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)
        await flags.endConversations.waitUntil(1)
        await flags.interrupts.waitUntil(1)
        await drainPendingMainActorWork()

        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(flags.endConversations.value, 1)
    }

    func testConflictPrecedenceEndConversationWinsOverStop() async {
        let (controller, capture, _, spy, flags) = makeController(transcript: "stop")
        var preferences = preferences(endConversation: ["stop"])
        preferences.spokenStopPhrases = ["stop"]
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)
        await flags.endConversations.waitUntil(1)
        await flags.interrupts.waitUntil(1)

        XCTAssertEqual(flags.endConversations.value, 1, "the stronger action must be deterministic")
        XCTAssertFalse(controller.hasLiveVoiceSession, "end must close, not stop-and-relisten")
        XCTAssertEqual(flags.interrupts.value, 1)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testConfiguredStopPhraseIsConsumedInterruptsAndRelistensEvenWithContinuousOff() async {
        let (controller, capture, gateway, spy, flags) = makeController(transcript: "Halt.")
        var preferences = preferences(endConversation: ["goodbye"])
        preferences.spokenStopPhrases = [" halt "]
        preferences.continuousConversation = false
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)
        await flags.interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "stop reopened listening")

        XCTAssertEqual(gateway.transcriptionCount, 1)
        XCTAssertEqual(spy.texts, [])
        XCTAssertEqual(flags.interrupts.value, 1)
        XCTAssertEqual(controller.state, .listening, "Stop remains a recovery restart even with continuous OFF")
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertTrue(controller.hasLiveVoiceSession)
        XCTAssertEqual(
            controller.conversationTranscript.last?.speaker, .user,
            "existing Stop transcript semantics are preserved"
        )
    }

    func testHeadsetBargeInThenGoodbyeEndsSessionWithoutStaleRelisten() async {
        let (controller, capture, gateway, spy, flags) = makeController(
            transcript: "Question",
            routePolicy: .fullDuplex
        )
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))

        await driveToSpeaking(controller, gateway: gateway)
        gateway.transcript = "goodbye"
        let bargeInStart = Date()
        controller.ingestAudioLevel(0.5, at: bargeInStart)
        controller.ingestAudioLevel(0.5, at: bargeInStart.addingTimeInterval(0.31))
        await flags.interrupts.waitUntil(1)
        let relistened = await controller.waitForState(.listening)
        XCTAssertTrue(relistened, "full-duplex barge-in must reopen listening first")
        XCTAssertEqual(controller.state, .listening, "full-duplex barge-in must reopen listening first")
        let startsAfterBargeIn = capture.startCount

        await driveUtterance(controller, silentFinish: true)
        await flags.endConversations.waitUntil(1)
        await flags.interrupts.waitUntil(2)

        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(flags.interrupts.value, 2, "one barge-in interruption plus one End Conversation interruption")
        XCTAssertEqual(capture.startCount, startsAfterBargeIn, "no stale relisten after the session closed")
    }

    func testSpeakerSafeRouteStaysHalfDuplexDuringTTSWithCommandPhrasesConfigured() async {
        let (controller, capture, gateway, spy, flags) = makeController(
            transcript: "Question",
            routePolicy: .speakerSafeHalfDuplex
        )
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))

        await driveToSpeaking(controller, gateway: gateway)
        gateway.transcript = "goodbye"
        XCTAssertTrue(controller.isPlaybackCaptureSuspended)

        // The suspended-capture gate rejects barge-in scheduling inline in
        // ingestAudioLevel, so the negative result is exact without settling.
        let leakStart = Date()
        controller.ingestAudioLevel(0.5, at: leakStart)
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.31))
        controller.ingestAudioLevel(0.5, at: leakStart.addingTimeInterval(0.62))

        XCTAssertEqual(controller.state, .speaking, "half-duplex playback must not open a command window")
        XCTAssertEqual(flags.endConversations.value, 0, "commands are recognized only on the transcription path")
        XCTAssertEqual(flags.interrupts.value, 0)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testSpeakerSafeManualInterruptThenGoodbyeEndsSession() async {
        let (controller, capture, gateway, spy, flags) = makeController(
            transcript: "Question",
            routePolicy: .speakerSafeHalfDuplex
        )
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))

        await driveToSpeaking(controller, gateway: gateway)
        gateway.transcript = "goodbye"
        await controller.interruptAssistantPlayback()
        XCTAssertEqual(controller.state, .listening)

        await driveUtterance(controller, silentFinish: true)
        await flags.endConversations.waitUntil(1)
        await flags.interrupts.waitUntil(2)

        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(flags.interrupts.value, 2, "manual Interrupt plus End Conversation interruption")
        XCTAssertEqual(flags.endConversations.value, 1)
    }

    func testUserPauseSuppressesSpokenCommandRecognition() async {
        let (controller, capture, gateway, spy, flags) = makeController(transcript: "goodbye")
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        controller.pauseMicrophone()

        // Drain the capture pump so the paused-runtime rejection of all
        // three events is provably processed before the negative assertions.
        let start = Date()
        capture.emit(level: 0.4, at: start)
        capture.emit(level: 0.4, at: start.addingTimeInterval(0.4))
        capture.emit(level: 0, at: start.addingTimeInterval(1.4))
        await drainPendingMainActorWork()

        XCTAssertEqual(gateway.transcriptionCount, 0, "no transcription while the user paused the microphone")
        XCTAssertEqual(flags.endConversations.value, 0)
        XCTAssertEqual(spy.texts, [])
        XCTAssertTrue(controller.isMicrophonePaused)
        XCTAssertTrue(controller.hasLiveVoiceSession)
    }

    func testLateAssistantEventsAfterSpokenEndCannotRestartCaptureOrPlayback() async {
        let (controller, capture, _, spy, flags) = makeController(transcript: "goodbye")
        controller.setProfilePreferences(preferences(endConversation: ["goodbye"]))
        await driveUtterance(controller)
        await flags.endConversations.waitUntil(1)
        let startsAtClose = capture.startCount

        // The closed session rejects these synchronously (no awaited turn).
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "late answer"))
        controller.receiveAssistantEvent(.completed(sessionID: "session", content: "late answer"))
        await drainPendingMainActorWork()

        XCTAssertFalse(controller.hasLiveVoiceSession)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(capture.startCount, startsAtClose, "stale events must not reopen capture")
    }

    func testEmptyPhraseListsSubmitUtterancesNormally() async {
        let (controller, _, _, spy, flags) = makeController(transcript: "goodbye")
        var preferences = preferences(endConversation: [])
        preferences.spokenStopPhrases = []
        controller.setProfilePreferences(preferences)
        await driveUtterance(controller)
        await spy.waitUntilSubmitted(1)

        XCTAssertEqual(flags.endConversations.value, 0)
        XCTAssertEqual(spy.texts, ["goodbye"], "with both lists empty nothing is consumed locally")
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertTrue(controller.hasLiveVoiceSession)
    }

    // MARK: fixtures

    @MainActor
    final class Flags {
        let interrupts = AwaitableCounter()
        let endConversations = AwaitableCounter()
    }

    /// Weak holder so the Close-seam closure (mirroring AppState
    /// closeVoiceConversation) can reach the controller after init.
    private final class ControllerBox {
        weak var controller: VoiceConversationController?
    }

    private func makeController(
        transcript: String,
        routePolicy: VoiceBargeInRoutePolicy? = nil,
        wiresCloseSeam: Bool = true
    ) -> (VoiceConversationController, MockCapture, MockGateway, SubmitSpy, Flags) {
        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: transcript, startsPlaybackOnOpen: true)
        let spy = SubmitSpy()
        let flags = Flags()
        let box = ControllerBox()
        // Explicitly typed locals: the combined init expression otherwise
        // blows up the Swift type checker (multiline + ternary closures).
        let routeProvider: (@MainActor () -> VoiceBargeInRoutePolicy)?
        if let routePolicy {
            routeProvider = { routePolicy }
        } else {
            routeProvider = nil
        }
        let submitAction: @MainActor (String) async -> Bool = { await spy.submit($0) }
        let interruptAction: @MainActor () async -> Bool = {
            // The End Conversation teardown cancels the utterance task that
            // called it; the Hermes interrupt must still run in an
            // uncancelled task (HermesClient.rpc throws CancellationError
            // for cancelled work, which would leave the turn alive).
            XCTAssertFalse(Task.isCancelled)
            flags.interrupts.increment()
            return true
        }
        let endAction: (@MainActor () -> Void)?
        if wiresCloseSeam {
            endAction = {
                flags.endConversations.increment()
                box.controller?.endVoiceSession()
            }
        } else {
            endAction = nil
        }
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: routeProvider,
            submit: submitAction,
            interrupt: interruptAction,
            onEndConversation: endAction
        )
        box.controller = controller
        return (controller, capture, gateway, spy, flags)
    }

    private func preferences(endConversation: [String]) -> VoiceProfilePreferences {
        var preferences = VoiceProfilePreferences()
        preferences.spokenEndConversationPhrases = endConversation
        return preferences
    }

    /// Drives one complete listening -> transcription cycle through the VAD
    /// finish path (the same deterministic pattern the existing suites use).
    /// `silentFinish` skips arming a fresh turn for callers whose capture is
    /// already live (post barge-in / manual Interrupt). This does NOT wait --
    /// each caller awaits the semantic completion of the utterance it drove
    /// (end-conversation teardown, stop relisten, or submission).
    private func driveUtterance(_ controller: VoiceConversationController, silentFinish: Bool = false) async {
        if !silentFinish {
            controller.beginVoiceTurn(sessionID: "session")
            await controller.startListening()
        }
        let start = Date()
        controller.ingestAudioLevel(0.1, at: start)
        controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
    }

    private func driveToSpeaking(_ controller: VoiceConversationController, gateway: MockGateway) async {
        controller.beginVoiceTurn(sessionID: "session")
        await controller.startListening()
        let utteranceStart = Date()
        controller.ingestAudioLevel(0.1, at: utteranceStart)
        controller.ingestAudioLevel(0, at: utteranceStart.addingTimeInterval(1.3))
        await gateway.waitUntilTranscriptionStarted()
        XCTAssertEqual(controller.state, .thinking)
        controller.receiveAssistantEvent(.started(sessionID: "session"))
        controller.receiveAssistantEvent(.delta(sessionID: "session", text: "Answer."))
        let speaking = await controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the assistant reply is audible")
        XCTAssertEqual(controller.state, .speaking)
    }
}

// MARK: - Voice doubles

// The voice doubles (MockCapture/MockPlayback/MockGateway, SubmitSpy) live in
// VoiceTestSupport.swift, shared with the other Voice/CarPlay/AppState suites.
// MARK: - AppState persistence

@MainActor
final class AppStateVoiceSpokenPhraseTests: XCTestCase {
    func testSetSpokenStopPhrasesPersistsWithoutClobberingUnrelatedFields() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        var seed = VoiceProfilePreferences()
        seed.outputMuted = true
        seed.continuousConversation = false
        seed.continueWakeConversation = true
        seed.spokenStopPhrases = ["halt"]
        seed.spokenEndConversationPhrases = ["bye"]
        seed.transcriptionMode = .appleOnDevice
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        appState.setSpokenStopPhrases(["Halt", " stop ", "HALT", "  "])

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertEqual(loaded.spokenStopPhrases, ["Halt", "stop"], "entries canonicalize: trimmed, de-duplicated, blanks dropped")
        XCTAssertEqual(loaded.spokenEndConversationPhrases, ["bye"], "the other list must be untouched")
        XCTAssertTrue(loaded.outputMuted)
        XCTAssertFalse(loaded.continuousConversation)
        XCTAssertTrue(loaded.continueWakeConversation)
        XCTAssertEqual(loaded.resolvedTranscriptionMode, .appleOnDevice)
        XCTAssertEqual(
            appState.voiceConversationController.activePreferences.spokenStopPhrases, ["Halt", "stop"],
            "the live controller is reapplied"
        )
    }

    func testSetSpokenEndConversationPhrasesPersistsWithoutClobberingUnrelatedFields() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        var seed = VoiceProfilePreferences()
        seed.outputMuted = false
        seed.spokenStopPhrases = ["stop"]
        seed.spokenEndConversationPhrases = ["goodbye"]
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        appState.setSpokenEndConversationPhrases(["See ya", " goodbye ", "SEE YA", ""])

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertEqual(loaded.spokenEndConversationPhrases, ["See ya", "goodbye"])
        XCTAssertEqual(loaded.spokenStopPhrases, ["stop"])
        XCTAssertFalse(loaded.outputMuted)
        XCTAssertTrue(loaded.continuousConversation)
    }

    func testSpokenPhraseEditsAreProfileScoped() throws {
        let (appState, defaults, suite) = makeAppState(profile: "alpha")
        defer { defaults.removePersistentDomain(forName: suite) }

        var alpha = VoiceProfilePreferences()
        alpha.spokenStopPhrases = ["alpha-stop"]
        alpha.spokenEndConversationPhrases = ["alpha-bye"]
        savePreferences(alpha, defaults: defaults, profile: "alpha", gateway: "https://example.com")

        var beta = VoiceProfilePreferences()
        beta.spokenStopPhrases = ["beta-stop"]
        beta.spokenEndConversationPhrases = ["beta-bye"]
        savePreferences(beta, defaults: defaults, profile: "beta", gateway: "https://example.com")

        XCTAssertEqual(appState.activeProfile, "alpha")
        appState.setSpokenStopPhrases(["new-alpha-stop"])
        appState.setSpokenEndConversationPhrases(["new-alpha-bye"])

        let loadedAlpha = try loadPreferences(defaults: defaults, profile: "alpha", gateway: "https://example.com")
        XCTAssertEqual(loadedAlpha.spokenStopPhrases, ["new-alpha-stop"])
        XCTAssertEqual(loadedAlpha.spokenEndConversationPhrases, ["new-alpha-bye"])
        let loadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertEqual(loadedBeta.spokenStopPhrases, ["beta-stop"])
        XCTAssertEqual(loadedBeta.spokenEndConversationPhrases, ["beta-bye"])

        appState.setActiveProfileForTesting("beta")
        appState.setSpokenStopPhrases(["new-beta-stop"])
        let reloadedAlpha = try loadPreferences(defaults: defaults, profile: "alpha", gateway: "https://example.com")
        let reloadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertEqual(reloadedAlpha.spokenStopPhrases, ["new-alpha-stop"])
        XCTAssertEqual(reloadedBeta.spokenStopPhrases, ["new-beta-stop"])
    }

    func testPhraseEditPreservesLiveMuteOnlyWithLiveSession() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        var seed = VoiceProfilePreferences()
        seed.outputMuted = false
        savePreferences(seed, defaults: defaults, profile: "default", gateway: "https://example.com")

        // Live Voice session muted in memory only (PR #159 semantics).
        appState.voiceConversationController.beginVoiceTurn(sessionID: "live-session")
        appState.voiceConversationController.setOutputMuted(true)

        appState.setSpokenStopPhrases(["quiet"])

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertTrue(loaded.outputMuted, "live mute must be persisted so the reapplied blob cannot regress")
        XCTAssertEqual(loaded.spokenStopPhrases, ["quiet"])
    }

    func testPhraseEditDoesNotCopyStaleControllerMuteWithoutLiveSession() throws {
        let (appState, defaults, suite) = makeAppState(profile: "beta")
        defer { defaults.removePersistentDomain(forName: suite) }

        var alpha = VoiceProfilePreferences()
        alpha.outputMuted = true
        savePreferences(alpha, defaults: defaults, profile: "alpha", gateway: "https://example.com")
        var beta = VoiceProfilePreferences()
        beta.outputMuted = false
        savePreferences(beta, defaults: defaults, profile: "beta", gateway: "https://example.com")

        // Controller still holds profile A's mute after a profile switch
        // before refreshVoiceCapabilities resyncs. No live session.
        appState.voiceConversationController.setProfilePreferences(alpha)
        appState.voiceConversationController.setOutputMuted(true)
        XCTAssertFalse(appState.voiceConversationController.hasLiveVoiceSession)
        XCTAssertEqual(appState.activeProfile, "beta")

        appState.setSpokenStopPhrases(["beta-quiet"])

        let loadedBeta = try loadPreferences(defaults: defaults, profile: "beta", gateway: "https://example.com")
        XCTAssertEqual(loadedBeta.spokenStopPhrases, ["beta-quiet"])
        XCTAssertFalse(loadedBeta.outputMuted, "stale controller mute must not overwrite B's persisted value")
    }

    func testSpokenPhraseEditsDoNotPersistWhileDisconnected() {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }
        appState.connection = nil
        appState.isConnected = false

        appState.setSpokenStopPhrases(["quiet"])
        appState.setSpokenEndConversationPhrases(["bye"])

        XCTAssertNil(
            defaults.data(forKey: "conduit.voice.preferences.v1.disconnected.default"),
            "disconnected phrase edits must not write the orphaned gateway namespace"
        )
    }

    func testEmptyEndConversationListRoundTripsAsEmpty() throws {
        let (appState, defaults, suite) = makeAppState(profile: "default")
        defer { defaults.removePersistentDomain(forName: suite) }

        appState.setSpokenEndConversationPhrases([])

        let loaded = try loadPreferences(defaults: defaults, profile: "default", gateway: "https://example.com")
        XCTAssertEqual(
            loaded.spokenEndConversationPhrases, [],
            "an intentionally emptied list must not silently grow the defaults back"
        )
    }

    // MARK: fixtures

    private func makeAppState(profile: String) -> (AppState, UserDefaults, String) {
        let suite = "AppStateVoiceSpokenPhraseTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        defaults.set(profile, forKey: "conduit.activeProfile")
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )
        appState.voiceCapabilityRequesterForTesting = ImmediateVoiceConfigRequester()
        return (appState, defaults, suite)
    }

    private func preferencesKey(profile: String, gateway: String) -> String {
        "conduit.voice.preferences.v1.\(gateway.lowercased()).\(profile)"
    }

    private func savePreferences(
        _ preferences: VoiceProfilePreferences,
        defaults: UserDefaults,
        profile: String,
        gateway: String
    ) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: preferencesKey(profile: profile, gateway: gateway))
    }

    private func loadPreferences(
        defaults: UserDefaults,
        profile: String,
        gateway: String
    ) throws -> VoiceProfilePreferences {
        let data = try XCTUnwrap(defaults.data(forKey: preferencesKey(profile: profile, gateway: gateway)))
        return try JSONDecoder().decode(VoiceProfilePreferences.self, from: data)
    }
}

