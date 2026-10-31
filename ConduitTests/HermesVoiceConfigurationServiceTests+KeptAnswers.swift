import XCTest
@testable import Conduit

/// Voice settings open on what they showed last time, kept on the phone,
/// while Hermes is asked again, and keep it when Hermes can't answer
/// (#1533).
extension HermesVoiceConfigurationServiceTests {
    func testThePageOpensOnItsKeptAnswersUntilHermesAnswers() async {
        let kept = KeptVoiceAnswers(Self.keptVoiceAnswers)
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "openai", "openai": ["voice": "nova"]]],
            "/api/config/schema": ["fields": [:]],
            "/api/tools/toolsets/stt/config": Self.keptVoiceAnswers["/api/tools/toolsets/stt/config"] ?? [:],
            "/api/tools/toolsets/tts/config": ["providers": [["name": "OpenAI TTS", "tts_provider": "openai", "status": "ready", "is_active": true]]],
            "/api/env": ["VOICE_TOOLS_OPENAI_KEY": ["is_set": true, "redacted_value": "sk-p...abcd"]],
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default", answers: kept.answers)

        XCTAssertTrue(service.snapshot.capability.isGatewayConnected, "Drawn before Hermes answers")
        XCTAssertTrue(service.snapshot.capability.supportsSpeech)
        XCTAssertEqual(service.snapshot.selectedTTSProvider, "edge")
        XCTAssertEqual(service.snapshot.values["tts.edge.voice"], "en-US-AriaNeural")
        XCTAssertEqual(service.credential("VOICE_TOOLS_OPENAI_KEY")?.isSet, true, "As the toolset's row said")
        XCTAssertFalse(service.snapshot.environmentLoaded, "Which keys are set isn't kept")
        XCTAssertNil(service.answered)
        XCTAssertTrue(service.isChecking)

        await service.reload()

        XCTAssertEqual(service.answered, true)
        XCTAssertFalse(service.isChecking)
        XCTAssertEqual(service.snapshot.selectedTTSProvider, "openai")
        XCTAssertEqual(service.snapshot.values["tts.openai.voice"], "nova")
        XCTAssertEqual(
            Set(kept.saved.keys),
            ["/api/config", "/api/config/schema", "/api/tools/toolsets/stt/config", "/api/tools/toolsets/tts/config"],
            "/api/env is never kept"
        )
        XCTAssertEqual((kept.saved["/api/config"]?["tts"] as? [String: Any])?["provider"] as? String, "openai")
    }

    /// Without its speech toolsets kept, a voice would read not ready for
    /// want of them: the page waits for Hermes, as before.
    func testAKeptConfigAloneIsntOpenedOn() {
        var answers = Self.keptVoiceAnswers
        answers["/api/tools/toolsets/tts/config"] = nil
        let service = HermesVoiceConfigurationService(
            requester: MockVoiceConfigurationRequester(), profile: "default", answers: KeptVoiceAnswers(answers).answers
        )

        XCTAssertFalse(service.snapshot.capability.isGatewayConnected)
    }

    /// A read that fails keeps the settings shown, kept or answered before,
    /// and says so; with nothing shown it still says why voice can't work.
    func testAReadThatFailsKeepsWhatsShown() async {
        let requester = MockVoiceConfigurationRequester()
        let service = HermesVoiceConfigurationService(
            requester: requester, profile: "default", answers: KeptVoiceAnswers(Self.keptVoiceAnswers).answers
        )

        await service.reload()

        XCTAssertEqual(service.answered, false)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(service.snapshot.capability.isGatewayConnected, "The kept settings stay")
        XCTAssertEqual(service.snapshot.selectedTTSProvider, "edge")

        requester.routes = Self.keptVoiceAnswers.merging(["/api/config": ["tts": ["provider": "openai"]]]) { $1 }
        await service.reload()
        XCTAssertEqual(service.answered, true)
        requester.routes = [:]
        await service.reload()
        XCTAssertEqual(service.answered, false)
        XCTAssertEqual(service.snapshot.selectedTTSProvider, "openai", "So does Hermes' answer from before")

        let unkept = HermesVoiceConfigurationService(requester: MockVoiceConfigurationRequester(), profile: "default")
        await unkept.reload()
        XCTAssertEqual(unkept.answered, false)
        XCTAssertFalse(unkept.snapshot.capability.isGatewayConnected)
        XCTAssertNotNil(unkept.snapshot.capability.unavailableReason)
    }

    /// What a save wrote is what the page opens on next, as the other
    /// settings pages' saves are.
    func testAConfigSaveIsWhatThePageOpensOnNext() async {
        let kept = KeptVoiceAnswers(Self.keptVoiceAnswers)
        let requester = MockVoiceConfigurationRequester()
        requester.routes = ["/api/config": Self.keptVoiceAnswers["/api/config"] ?? [:]]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default", answers: kept.answers)

        let savedVoice = await service.save(value: "en-GB-SoniaNeural", for: "tts.edge.voice")
        XCTAssertTrue(savedVoice)
        let tts = kept.saved["/api/config"]?["tts"] as? [String: Any]
        XCTAssertEqual((tts?["edge"] as? [String: Any])?["voice"] as? String, "en-GB-SoniaNeural")

        let savedStreaming = await service.saveLiveTranscription(true)
        XCTAssertTrue(savedStreaming)
        XCTAssertEqual((kept.saved["/api/config"]?["stt"] as? [String: Any])?["streaming"] as? Bool, true)
    }

    /// Speech to text's speech server opens on the status last read, and
    /// Local's fast model on the one Assistant speech's status gave; the
    /// rest of that status waits for the host, since it hangs on the
    /// server's key, which isn't kept.
    func testTheSpeechServerOpensOnItsKeptStatus() async {
        let kept = KeptVoiceAnswers([
            SpeechServerTranscription.statusPath: ["configured": true, "available": true, "url": "ws://box:8765/v1/realtime", "has_key": true],
            SpeechServerSpeechStream.statusPath: [
                "available": true, "model_path": "/api/plugins/conduit_push/local-live/v1",
                "front_model": ["configured": true, "available": true, "base_url": "http://box:8080/v1", "model": "qwen3-4b"],
            ],
        ])
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            SpeechServerTranscription.statusPath: ["configured": true, "available": true, "url": "ws://box:9000/v1/realtime", "has_key": false],
            SpeechServerSpeechStream.statusPath: [
                "available": true, "model_path": "/api/plugins/conduit_push/local-live/v1", "api_key": "sk-local",
                "front_model": ["configured": true, "available": true, "base_url": "http://box:8080/v1", "model": "qwen3-8b"],
            ],
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default", answers: kept.answers)

        XCTAssertEqual(service.speechServer?.url, "ws://box:8765/v1/realtime", "Drawn before the host answers")
        XCTAssertEqual(service.speechServer?.hasKey, true)
        XCTAssertEqual(service.lastFrontModel?.model, "qwen3-4b")
        XCTAssertNil(service.speechServerVoice, "Assistant speech waits for the host")

        _ = await service.speechServerStatus()
        _ = await service.speechServerVoiceStatus()

        XCTAssertEqual(service.speechServer?.url, "ws://box:9000/v1/realtime")
        let keptStatus = kept.saved[SpeechServerTranscription.statusPath].map(SpeechServerStatus.init(response:))
        XCTAssertEqual(keptStatus?.url, "ws://box:9000/v1/realtime")
        XCTAssertEqual(keptStatus?.hasKey, false)
        XCTAssertEqual(service.lastFrontModel?.model, "qwen3-8b")
        let keptVoice = kept.saved[SpeechServerSpeechStream.statusPath]
        XCTAssertEqual((keptVoice?["front_model"] as? [String: Any])?["model"] as? String, "qwen3-8b")

        // A read that fails keeps the fast model shown.
        requester.routes[SpeechServerSpeechStream.statusPath] = nil
        _ = await service.speechServerVoiceStatus()
        XCTAssertEqual(service.lastFrontModel?.model, "qwen3-8b")
        XCTAssertNil(service.speechServerVoice?.frontModel)
    }

    /// Hermes' answer changes only the fields it changed: one changed on
    /// the page since it asked keeps its text.
    func testHermesAnswerKeepsAFieldChangedHere() {
        let values = VoiceSettingsView.answeredValues(
            ["tts.openai.speed": "1.2", "tts.openai.voice": "nova", "tts.openai.model": "tts-1"],
            shown: ["tts.openai.speed": "1", "tts.openai.voice": "alloy"],
            fields: ["tts.openai.speed": "1", "tts.openai.voice": "sha", "tts.openai.base_url": "http://box:8880/v1"]
        )

        XCTAssertEqual(values, [
            "tts.openai.speed": "1.2",
            "tts.openai.voice": "sha",
            "tts.openai.model": "tts-1",
            "tts.openai.base_url": "http://box:8880/v1",
        ])
    }

    /// The answers a page kept last time: a ready Edge voice and OpenAI
    /// speech to text, its key set.
    static let keptVoiceAnswers: [String: [String: Any]] = [
        "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge", "edge": ["voice": "en-US-AriaNeural"]]],
        "/api/tools/toolsets/stt/config": ["providers": [[
            "name": "OpenAI", "stt_provider": "openai", "status": "ready", "is_active": true,
            "env_vars": [["key": "VOICE_TOOLS_OPENAI_KEY", "is_set": true, "prompt": "OpenAI API key"]],
        ]]],
        "/api/tools/toolsets/tts/config": ["providers": [[
            "name": "Microsoft Edge TTS", "tts_provider": "edge", "status": "ready", "is_active": true,
        ]]],
    ]
}

/// One page's answers kept on the phone, as AppState keeps them.
@MainActor
private final class KeptVoiceAnswers {
    private(set) var saved: [String: [String: Any]]

    init(_ saved: [String: [String: Any]]) {
        self.saved = saved
    }

    var answers: VoiceKeptAnswers {
        VoiceKeptAnswers(
            kept: { route in self.saved[route] },
            keep: { route, read in
                let answer = try await read()
                self.saved[route] = answer
                return answer
            }
        )
    }
}
