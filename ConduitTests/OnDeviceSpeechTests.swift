//
//  OnDeviceSpeechTests.swift
//  Conduit
//
//  Classic voice replies spoken on this iPhone, and the fallback from a
//  failing Hermes voice. An extension of the gateway tests: the hosted CI
//  plan is at its class budget, and these cover the same speech streams.
//

import AVFoundation
import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    // MARK: - Who speaks

    func testUnsetSpeechOutputSpeaksOnThisIPhoneUnlessHermesHasItsOwnVoice() {
        func snapshot(_ provider: String, ready: Bool) -> VoiceCapabilitySnapshot {
            VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: ready,
                unavailableReason: nil,
                selectedTTSProvider: provider
            )
        }

        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: snapshot("edge", ready: true)), .onDevice)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: snapshot("Edge", ready: true)), .onDevice)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: snapshot("elevenlabs", ready: false)), .onDevice)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: .unavailable), .onDevice)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: snapshot("openai", ready: true)), .hermes)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: .hermes, snapshot: snapshot("edge", ready: true)), .hermes)
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: .onDevice, snapshot: snapshot("openai", ready: true)), .onDevice)
    }

    func testSpeechOutputChoiceSurvivesAndUnknownOnesReadAsAutomatic() throws {
        var preferences = VoiceProfilePreferences()
        preferences.speechOutput = .hermes
        let saved = try JSONDecoder().decode(
            VoiceProfilePreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        XCTAssertEqual(saved.speechOutput, .hermes)

        let newer = try JSONDecoder().decode(
            VoiceProfilePreferences.self,
            from: Data(#"{"speechOutput":"somethingNew","continuousConversation":false}"#.utf8)
        )
        XCTAssertNil(newer.speechOutput)
        XCTAssertFalse(newer.continuousConversation)
    }

    // MARK: - Which iPhone voice

    private func iPhoneVoice(_ id: String, _ name: String, _ language: String, quality: Int = 1) -> IPhoneVoiceOption {
        IPhoneVoiceOption(id: id, name: name, language: language, quality: quality)
    }

    func testAutomaticVoiceNeverPicksAScreenReaderVoiceOverTheDefaultOne() {
        // iOS lists its Eloquence voices (Eddy, Flo…) at default quality, often first.
        let eddy = iPhoneVoice("com.apple.eloquence.en-US.Eddy", "Eddy", "en-US")
        let samantha = iPhoneVoice("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US")
        let fred = iPhoneVoice("com.apple.speech.synthesis.voice.Fred", "Fred", "en-US")
        XCTAssertEqual(IPhoneVoices.best([eddy, fred, samantha], wanted: "en", region: "US", systemDefault: samantha.id), samantha)
        // With no default named, still not Eddy, and not by list order.
        XCTAssertEqual(IPhoneVoices.best([eddy, fred, samantha], wanted: "en", region: "US", systemDefault: nil)?.isScreenReaderVoice, false)
        XCTAssertEqual(
            IPhoneVoices.best([samantha, fred], wanted: "en", region: "US", systemDefault: nil),
            IPhoneVoices.best([fred, samantha], wanted: "en", region: "US", systemDefault: nil)
        )
    }

    func testAutomaticVoicePrefersPremiumThenEnhancedThenThePhonesRegion() {
        let basic = iPhoneVoice("basic", "Samantha", "en-US")
        let enhanced = iPhoneVoice("enhanced", "Daniel", "en-GB", quality: 2)
        let premiumUS = iPhoneVoice("premium-us", "Ava", "en-US", quality: 3)
        let premiumAU = iPhoneVoice("premium-au", "Lee", "en-AU", quality: 3)
        XCTAssertEqual(IPhoneVoices.best([basic, enhanced], wanted: "en", region: "US", systemDefault: basic.id), enhanced)
        XCTAssertEqual(IPhoneVoices.best([basic, enhanced, premiumUS, premiumAU], wanted: "en", region: "AU", systemDefault: basic.id), premiumAU)
        XCTAssertEqual(IPhoneVoices.best([basic, enhanced, premiumUS, premiumAU], wanted: "en-US", region: "AU", systemDefault: nil), premiumUS)
    }

    @MainActor
    func testInstalledVoicesAreKeptUntilForgotten() {
        let saved = IPhoneVoices.readInstalled
        defer {
            IPhoneVoices.readInstalled = saved
            IPhoneVoices.forgetInstalled()
        }
        var reads = 0
        var listed = [iPhoneVoice("samantha", "Samantha", "en-US")]
        IPhoneVoices.readInstalled = {
            reads += 1
            return listed
        }
        IPhoneVoices.forgetInstalled()
        XCTAssertEqual(IPhoneVoices.installed().map(\.id), ["samantha"])
        // A voice downloaded meanwhile is read once the list is forgotten.
        listed.append(iPhoneVoice("ava", "Ava", "en-US", quality: 3))
        XCTAssertEqual(IPhoneVoices.installed().map(\.id), ["samantha"])
        XCTAssertEqual(reads, 1)
        IPhoneVoices.forgetInstalled()
        XCTAssertEqual(IPhoneVoices.installed().map(\.id), ["samantha", "ava"])
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testIOSSayingTheVoicesChangedReadsThemAgain() {
        let saved = IPhoneVoices.readInstalled
        defer {
            IPhoneVoices.readInstalled = saved
            IPhoneVoices.forgetInstalled()
        }
        var listed = [iPhoneVoice("samantha", "Samantha", "en-US")]
        IPhoneVoices.readInstalled = { listed }
        IPhoneVoices.forgetInstalled()
        XCTAssertEqual(IPhoneVoices.installed().map(\.id), ["samantha"])
        listed.append(iPhoneVoice("ava", "Ava", "en-US", quality: 3))
        NotificationCenter.default.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        XCTAssertEqual(IPhoneVoices.installed().map(\.id), ["samantha", "ava"])
    }

    func testAutomaticOverADeletedPickClearsIt() {
        // The deleted voice shows as Automatic; picking Automatic still saves.
        XCTAssertTrue(IPhoneVoices.pickChangesSaved(nil, saved: "daniel"))
        XCTAssertFalse(IPhoneVoices.pickChangesSaved(nil, saved: nil))
        XCTAssertFalse(IPhoneVoices.pickChangesSaved("ava", saved: "ava"))
        XCTAssertTrue(IPhoneVoices.pickChangesSaved("ava", saved: nil))
    }

    func testACantoneseReplySpeaksWithACantoneseVoice() {
        // NLLanguageRecognizer can tell colloquial Cantonese apart as "yue".
        let tag = OnDeviceSpeechStream.detectedTag("yue")
        XCTAssertEqual(tag, "zh-HK")
        XCTAssertEqual(IPhoneVoices.languageKey(tag), "zh-TW")
        let mandarinTW = iPhoneVoice("meijia", "Meijia", "zh-TW", quality: 3)
        let cantonese = iPhoneVoice("sinji", "Sinji", "zh-HK")
        XCTAssertEqual(IPhoneVoices.pick([mandarinTW, cantonese], wanted: tag, chosen: nil, region: "US", systemDefault: nil), cantonese)
        XCTAssertEqual(OnDeviceSpeechStream.detectedTag("de"), "de")
        XCTAssertEqual(OnDeviceSpeechStream.speechLanguage(of: Locale(identifier: "yue-Hant-HK")), "zh-HK")
        // A script named outright wins over the region.
        XCTAssertEqual(IPhoneVoices.languageKey("zh-Hans-HK"), "zh-CN")
        XCTAssertEqual(OnDeviceSpeechStream.speechLanguage(of: Locale(identifier: "zh-Hans-HK")), "zh-CN")
        XCTAssertEqual(IPhoneVoices.languageKey("zh-Hant-CN"), "zh-TW")
    }

    @MainActor
    func testALanguageWithNoInstalledVoiceUsesIOSsOwn() {
        let saved = IPhoneVoices.readInstalled
        defer {
            IPhoneVoices.readInstalled = saved
            IPhoneVoices.forgetInstalled()
        }
        IPhoneVoices.readInstalled = { [] }
        IPhoneVoices.forgetInstalled()
        XCTAssertEqual(
            IPhoneVoices.voice(for: "en-US")?.identifier,
            AVSpeechSynthesisVoice(language: "en-US")?.identifier
        )
    }

    func testAScreenReaderVoiceNeverWinsOverAnyOtherVoice() {
        let eloquence = iPhoneVoice("com.apple.eloquence.en-US.Flo", "Flo", "en-US", quality: 2)
        let basic = iPhoneVoice("samantha", "Samantha", "en-US")
        XCTAssertEqual(IPhoneVoices.best([eloquence, basic], wanted: "en", region: "US", systemDefault: nil), basic)
        XCTAssertEqual(IPhoneVoices.best([eloquence], wanted: "en", region: "US", systemDefault: nil), eloquence)
    }

    func testPickedVoiceSpeaksItsLanguageUntilItsDeleted() {
        let ava = iPhoneVoice("ava", "Ava", "en-US", quality: 3)
        let daniel = iPhoneVoice("daniel", "Daniel", "en-GB")
        let anna = iPhoneVoice("anna", "Anna", "de-DE", quality: 3)
        let all = [ava, daniel, anna]
        XCTAssertEqual(IPhoneVoices.pick(all, wanted: "en", chosen: "daniel", region: "US", systemDefault: nil), daniel)
        // A German reply never borrows the English pick.
        XCTAssertEqual(IPhoneVoices.pick(all, wanted: "de", chosen: "daniel", region: "US", systemDefault: nil), anna)
        // Deleted from the iPhone: back to the best installed.
        XCTAssertEqual(IPhoneVoices.pick([ava, anna], wanted: "en", chosen: "daniel", region: "US", systemDefault: nil), ava)
        XCTAssertNil(IPhoneVoices.pick(all, wanted: "fr", chosen: nil, region: "US", systemDefault: nil))
    }

    func testVoicePicksAreSavedPerLanguageForEveryRegion() throws {
        let suite = "IPhoneVoicesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(IPhoneVoices.languageKey("en-US"), "en")
        XCTAssertEqual(IPhoneVoices.languageKey("EN_gb"), "en")
        // Chinese keeps Simplified Mandarin, Traditional Mandarin and Cantonese apart.
        XCTAssertEqual(IPhoneVoices.languageKey("zh-TW"), "zh-TW")
        XCTAssertEqual(IPhoneVoices.languageKey("zh-Hant-TW"), "zh-TW")
        XCTAssertEqual(IPhoneVoices.languageKey("zh-HK"), "zh-TW")
        XCTAssertEqual(IPhoneVoices.languageKey("zh-CN"), "zh-CN")
        XCTAssertEqual(IPhoneVoices.languageKey("zh"), "zh-CN")
        // Replies are told apart by script only, so a Cantonese pick speaks
        // the Traditional replies language(of:) tags zh-TW, never Simplified.
        let mandarinCN = iPhoneVoice("tingting", "Tingting", "zh-CN", quality: 3)
        let mandarinTW = iPhoneVoice("meijia", "Meijia", "zh-TW")
        let cantonese = iPhoneVoice("sinji", "Sinji", "zh-HK")
        let chinese = [mandarinCN, mandarinTW, cantonese]
        XCTAssertEqual(OnDeviceSpeechStream.speechLanguage(of: Locale(identifier: "zh-Hant")), "zh-TW")
        XCTAssertEqual(OnDeviceSpeechStream.speechLanguage(of: Locale(identifier: "zh-HK")), "zh-TW")
        XCTAssertEqual(OnDeviceSpeechStream.speechLanguage(of: Locale(identifier: "zh-Hans")), "zh-CN")
        XCTAssertEqual(OnDeviceSpeechStream.speechLanguage(of: Locale(identifier: "de-AT")), "de")
        XCTAssertEqual(IPhoneVoices.pick(chinese, wanted: "zh-TW", chosen: "sinji", region: "US", systemDefault: nil), cantonese)
        XCTAssertEqual(IPhoneVoices.pick(chinese, wanted: "zh-TW", chosen: nil, region: "US", systemDefault: nil), mandarinTW)
        // Not even a Premium Cantonese voice speaks Mandarin replies unpicked.
        let premiumCantonese = iPhoneVoice("sinji-premium", "Sinji", "zh-HK", quality: 3)
        XCTAssertEqual(IPhoneVoices.pick([mandarinTW, premiumCantonese], wanted: "zh-TW", chosen: nil, region: "HK", systemDefault: nil), mandarinTW)
        XCTAssertEqual(IPhoneVoices.pick(chinese, wanted: "zh-CN", chosen: "sinji", region: "US", systemDefault: nil), mandarinCN)
        IPhoneVoices.setChosenVoice("daniel", for: "en-GB", defaults: defaults)
        IPhoneVoices.setChosenVoice("anna", for: "de", defaults: defaults)
        XCTAssertEqual(IPhoneVoices.chosenVoice(for: "en", defaults: defaults), "daniel")
        XCTAssertEqual(IPhoneVoices.chosenVoice(for: "en-US", defaults: defaults), "daniel")
        IPhoneVoices.setChosenVoice(nil, for: "en", defaults: defaults)
        XCTAssertNil(IPhoneVoices.chosenVoice(for: "en-AU", defaults: defaults))
        XCTAssertEqual(IPhoneVoices.chosenVoice(for: "de-DE", defaults: defaults), "anna")
    }

    // MARK: - Speaking on this iPhone

    func testSentencesStartSpeakingWhileTheReplyStreams() {
        var text = "Hello there. The value is 3.5 now"
        XCTAssertEqual(OnDeviceSpeechStream.takeCompleteSentences(from: &text), "Hello there.")
        XCTAssertEqual(text, " The value is 3.5 now")

        var unfinished = "Still going"
        XCTAssertNil(OnDeviceSpeechStream.takeCompleteSentences(from: &unfinished))
        XCTAssertEqual(unfinished, "Still going")

        var chinese = "你好。今天"
        XCTAssertEqual(OnDeviceSpeechStream.takeCompleteSentences(from: &chinese), "你好。")
        XCTAssertEqual(chinese, "今天")
    }

    func testAReplyTooShortToTellWaitsForASentenceThatSaysItsLanguage() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let stream = OnDeviceSpeechStream(
            synthesizer: synthesizer,
            fallbackLanguage: "en",
            onStart: { _ in },
            onPCM16: { _, _ in }
        )
        try await stream.append("42. ")
        synthesizer.finishCurrent(audio: Data([1, 0]))
        try await stream.append("Die Hauptstadt von Deutschland ist Berlin, und die Stadt ist im Sommer sehr schön. ")
        await waitUntil { synthesizer.spoken.count == 2 }
        synthesizer.finishCurrent(audio: Data([1, 0]))
        try await stream.append("Danach kommt München. ")
        await waitUntil { synthesizer.spoken.count == 3 }
        XCTAssertEqual(synthesizer.languages, ["en", "de", "de"])
        stream.cancel()
    }

    func testOnDeviceStreamSpeaksEverySentenceInOrderThenFinishes() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        var started: [Double] = []
        var played: [Data] = []
        let stream = OnDeviceSpeechStream(
            synthesizer: synthesizer,
            fallbackLanguage: "en",
            onStart: { started.append($0) },
            onPCM16: { data, _ in played.append(data) }
        )

        try await stream.append("First sentence. Sec")
        XCTAssertEqual(synthesizer.spoken, ["First sentence."])
        try await stream.append("ond one")
        let finishing = Task { try await stream.finish() }
        await Task.yield()
        synthesizer.finishCurrent(audio: Data([1, 0]))
        await waitUntil { synthesizer.spoken.count == 2 }
        XCTAssertEqual(synthesizer.spoken, ["First sentence.", "Second one"])
        synthesizer.finishCurrent(audio: Data([2, 0]))

        let streamedPCM = try await finishing.value
        XCTAssertTrue(streamedPCM)
        XCTAssertEqual(started, [22_050])
        XCTAssertEqual(played, [Data([1, 0]), Data([2, 0])])
    }

    func testOnDeviceStreamDoesNotReadMarkdownMarks() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let stream = OnDeviceSpeechStream(
            synthesizer: synthesizer,
            fallbackLanguage: "fr",
            onStart: { _ in },
            onPCM16: { _, _ in }
        )

        try await stream.append("La capitale est **Québec**. Le `code` et 5 ** 3")
        XCTAssertEqual(synthesizer.spoken, ["La capitale est Québec."])
        let finishing = Task { try await stream.finish() }
        await Task.yield()
        synthesizer.finishCurrent(audio: Data([1, 0]))
        await waitUntil { synthesizer.spoken.count == 2 }
        // A spaced mark is the text's own ("5 ** 3").
        XCTAssertEqual(synthesizer.spoken.last, "Le code et 5 ** 3")
        synthesizer.finishCurrent(audio: Data([2, 0]))
        _ = try await finishing.value
    }

    func testCancellingTheOnDeviceStreamStopsSpeech() async throws {
        let synthesizer = FakeSpeechSynthesizer()
        let stream = OnDeviceSpeechStream(
            synthesizer: synthesizer,
            fallbackLanguage: "en",
            onStart: { _ in },
            onPCM16: { _, _ in }
        )
        try await stream.append("Hello. ")
        stream.cancel()

        XCTAssertEqual(synthesizer.stopCount, 1)
        do {
            try await stream.append("More. ")
            XCTFail("a cancelled stream takes no more text")
        } catch is CancellationError {}
    }

    // MARK: - Falling back from Hermes

    func testHermesFailureBeforeAudioIsSpokenOnThisIPhone() async throws {
        let hermes = ScriptedSpeechStream(finishError: DashboardTicketBridgeError.requestFailed("Edge 403"))
        let onDevice = ScriptedSpeechStream()
        var fellBack = false
        let stream = try await FallbackSpeechStream.open(
            hermes: { _, _, _ in hermes },
            onDevice: { _, _ in onDevice },
            onFallback: { _ in fellBack = true },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )

        try await stream.append("Hello ")
        try await stream.append("there.")
        let streamedPCM = try await stream.finish()

        XCTAssertTrue(fellBack)
        XCTAssertTrue(streamedPCM)
        XCTAssertEqual(onDevice.appended.joined(), "Hello there.")
        XCTAssertTrue(onDevice.finished)
    }

    func testHermesThatCannotOpenIsSpokenOnThisIPhone() async throws {
        let onDevice = ScriptedSpeechStream()
        let stream = try await FallbackSpeechStream.open(
            hermes: { _, _, _ in throw DashboardTicketBridgeError.requestFailed("no ticket") },
            onDevice: { _, _ in onDevice },
            onFallback: { _ in },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )

        try await stream.append("Hi.")
        _ = try await stream.finish()

        XCTAssertEqual(onDevice.appended, ["Hi."])
    }

    func testHermesFailureAfterAudioStartedIsNotReplayed() async throws {
        let hermes = ScriptedSpeechStream(finishError: DashboardTicketBridgeError.requestFailed("dropped"))
        let onDevice = ScriptedSpeechStream()
        let stream = try await FallbackSpeechStream.open(
            hermes: { onStart, onPCM16, _ in
                hermes.onFinish = {
                    try onStart(24_000)
                    try onPCM16(Data([0, 0]), 24_000)
                }
                return hermes
            },
            onDevice: { _, _ in onDevice },
            onFallback: { _ in XCTFail("audio already played") },
            onStart: { _ in },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )

        try await stream.append("Hello.")
        do {
            _ = try await stream.finish()
            XCTFail("the Hermes failure is the caller's once audio played")
        } catch {}
        XCTAssertTrue(onDevice.appended.isEmpty)
    }

    func testAudioRefusedAsACancellationIsNotSpokenOnThisIPhone() async throws {
        // Read Aloud ends a reading that opened under a held microphone with
        // a cancellation (issue 1770): never a Hermes failure to fall back
        // from, which would keep the iPhone's voice for later reads.
        let hermes = ScriptedSpeechStream()
        let onDevice = ScriptedSpeechStream()
        let stream = try await FallbackSpeechStream.open(
            hermes: { onStart, _, _ in
                hermes.onFinish = { try onStart(24_000) }
                return hermes
            },
            onDevice: { _, _ in onDevice },
            onFallback: { _ in XCTFail("a cancellation isn't a Hermes failure") },
            onStart: { _ in throw CancellationError() },
            onPCM16: { _, _ in },
            onEncodedAudio: { _ in }
        )

        try await stream.append("Hello.")
        do {
            _ = try await stream.finish()
            XCTFail("the cancellation reaches the caller")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(onDevice.appended.isEmpty)
    }

    func testGatewaySpeaksOnThisIPhoneWhenChosen() async throws {
        let onDevice = ScriptedSpeechStream()
        let gateway = HermesVoiceGateway(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            baseURL: "https://example.com",
            profile: "default",
            speechOutput: { .onDevice },
            makeOnDeviceSpeech: { _, _ in onDevice }
        )

        let stream = try await gateway.openSpeechStream(onStart: { _ in }, onPCM16: { _, _ in }, onEncodedAudio: { _ in })

        XCTAssertTrue(stream === onDevice)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }
}

@MainActor
private final class FakeSpeechSynthesizer: OnDeviceSpeechSynthesizing {
    var spoken: [String] = []
    var languages: [String?] = []
    var stopCount = 0
    private var onAudio: (@MainActor (Data, Double) -> Void)?
    private var onDone: (@MainActor () -> Void)?

    func speak(
        _ text: String,
        language: String?,
        onAudio: @escaping @MainActor (Data, Double) -> Void,
        onDone: @escaping @MainActor () -> Void
    ) {
        spoken.append(text)
        languages.append(language)
        self.onAudio = onAudio
        self.onDone = onDone
    }

    func stop() {
        stopCount += 1
        onAudio = nil
        onDone = nil
    }

    func finishCurrent(audio: Data) {
        let done = onDone
        onAudio?(audio, 22_050)
        onAudio = nil
        onDone = nil
        done?()
    }
}

@MainActor
private final class ScriptedSpeechStream: VoiceSpeechStream {
    var appended: [String] = []
    var finished = false
    var cancelled = false
    var onFinish: (@MainActor () throws -> Void)?
    private let finishError: Error?

    init(finishError: Error? = nil) {
        self.finishError = finishError
    }

    func append(_ text: String) async throws {
        appended.append(text)
    }

    func finish() async throws -> Bool {
        try onFinish?()
        if let finishError { throw finishError }
        finished = true
        return true
    }

    func cancel() {
        cancelled = true
    }
}
