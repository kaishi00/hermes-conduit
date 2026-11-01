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

        // Nothing shown: a Hermes that doesn't answer is one to connect to,
        // and only one that answers without the routes needs updating.
        let unkeptRequester = MockVoiceConfigurationRequester()
        let unkept = HermesVoiceConfigurationService(requester: unkeptRequester, profile: "default")
        await unkept.reload()
        XCTAssertEqual(unkept.answered, false)
        XCTAssertFalse(unkept.snapshot.capability.isGatewayConnected)
        XCTAssertEqual(unkept.snapshot.capability.unavailableReason, "Connect to Hermes before starting voice.")
        unkeptRequester.missingRoutes = ["/api/config"]
        await unkept.reload()
        XCTAssertEqual(
            unkept.snapshot.capability.unavailableReason,
            "This Hermes server doesn't offer voice settings. Update Hermes to use Voice. Text chat still works."
        )
    }

    /// Which keys are set is never kept on the phone, but a read of it
    /// that fails keeps what the page showed, a key saved since included.
    func testAKeyReadThatFailsKeepsWhichKeysAreSet() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = Self.keptVoiceAnswers.merging([
            "/api/env": [
                "ELEVENLABS_API_KEY": ["is_set": true, "redacted_value": "sk-e...abcd"],
                "GEMINI_API_KEY": ["is_set": false],
            ],
        ]) { $1 }
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()
        XCTAssertEqual(service.credential("ELEVENLABS_API_KEY")?.isSet, true)

        requester.routes["/api/env"] = nil
        await service.reload()
        XCTAssertEqual(service.answered, true)
        XCTAssertTrue(service.snapshot.environmentLoaded)
        XCTAssertEqual(service.credential("ELEVENLABS_API_KEY")?.isSet, true, "Still set, as shown")
        XCTAssertEqual(service.credential("GEMINI_API_KEY")?.isSet, false)

        // A save, then a read of the keys that fails.
        requester.routes["/api/env"] = [:]
        requester.failingGETPaths = ["/api/env"]
        let saved = await service.saveCredential("gm-key", key: "GEMINI_API_KEY")
        XCTAssertTrue(saved)
        XCTAssertEqual(service.credential("GEMINI_API_KEY")?.isSet, true, "The save since")
        XCTAssertEqual(service.credential("ELEVENLABS_API_KEY")?.isSet, true)
    }

    /// Until Hermes says which keys are set, the key rows offer no field,
    /// the config read answered or not: a key Hermes holds would be
    /// written over unseen. Once it says, they know, the config's read
    /// failing or not.
    func testTheKeyRowsWaitUntilHermesSaysWhichKeysAreSet() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = Self.keptVoiceAnswers
        let service = HermesVoiceConfigurationService(
            requester: requester, profile: "default", answers: KeptVoiceAnswers(Self.keptVoiceAnswers).answers
        )
        XCTAssertTrue(service.awaitsKeys, "/api/env is never kept")

        await service.reload()
        XCTAssertEqual(service.answered, true)
        XCTAssertTrue(service.awaitsKeys, "Its read failed")

        requester.routes["/api/env"] = ["GEMINI_API_KEY": ["is_set": false]]
        await service.reload()
        XCTAssertFalse(service.awaitsKeys)

        // Only the config's read failing: the kept page learns the keys.
        let opened = HermesVoiceConfigurationService(
            requester: requester, profile: "default", answers: KeptVoiceAnswers(Self.keptVoiceAnswers).answers
        )
        requester.failingGETPaths = ["/api/config"]
        await opened.reload()
        XCTAssertEqual(opened.answered, false)
        XCTAssertFalse(opened.awaitsKeys, "Hermes said which keys are set")

        // So does a page Hermes answered without the keys, on a Hermes
        // without the speech toolsets' routes, which keeps none.
        let toolsets: Set<String> = ["/api/tools/toolsets/stt/config", "/api/tools/toolsets/tts/config"]
        let older = MockVoiceConfigurationRequester()
        older.routes = Self.keptVoiceAnswers.filter { !toolsets.contains($0.key) }
        older.missingRoutes = toolsets
        let answeredBefore = HermesVoiceConfigurationService(
            requester: older, profile: "default", answers: KeptVoiceAnswers([:]).answers
        )
        await answeredBefore.reload()
        XCTAssertEqual(answeredBefore.answered, true)
        XCTAssertTrue(answeredBefore.awaitsKeys, "Its read failed")
        older.routes["/api/env"] = ["GEMINI_API_KEY": ["is_set": false]]
        older.failingGETPaths = ["/api/config"]
        await answeredBefore.reload()
        XCTAssertEqual(answeredBefore.answered, false)
        XCTAssertTrue(answeredBefore.snapshot.capability.isGatewayConnected)
        XCTAssertFalse(answeredBefore.awaitsKeys, "Hermes said which keys are set")
    }

    /// The Voice replies model shows Hermes' answer unless a pick's write
    /// was out when it was asked or went out since, or a read asked after
    /// it answered first (its models left too), writes one pick at a time,
    /// and a write Hermes refuses puts back what it holds and says why.
    func testTheVoiceRepliesModelKeepsAPickOverAnOlderAnswer() throws {
        let chats = VoiceReplyModelSetting(provider: "auto", model: "", reasoningEffort: "none")
        let fast = VoiceReplyModelSetting(provider: "openrouter", model: "fast", reasoningEffort: "none")
        let fastTag = VoiceJobModelSettingsSection.tag(provider: "openrouter", model: "fast")
        var picks = VoiceReplyModelPicks()
        picks.showKept(chats)
        picks.selection = fastTag
        XCTAssertNil(picks.writeAsked(), "The pickers wait for Hermes")

        let first = picks.readAsked()
        picks.hermesAnswered(chats, to: first)
        XCTAssertEqual(picks.selection, VoiceReplyModelPicks.sameAsChats)
        picks.selection = fastTag
        let askedBefore = picks.readAsked()
        let write = picks.writeAsked()
        XCTAssertEqual(write, fast)
        XCTAssertTrue(picks.writing)
        picks.reasoning = "high"
        XCTAssertNil(picks.writeAsked(), "One write at a time")
        picks.reasoning = "none"
        let askedDuring = picks.readAsked()
        picks.hermesAnswered(chats, to: askedBefore)
        XCTAssertEqual(picks.selection, fastTag, "Asked before the write")
        picks.writeEnded(fast, refusal: nil)
        picks.hermesAnswered(chats, to: askedDuring)
        XCTAssertEqual(picks.saved, fast, "Asked while it was out")
        XCTAssertEqual(picks.selection, fastTag)

        picks.reasoning = "high"
        let refused = try XCTUnwrap(picks.writeAsked())
        picks.writeEnded(refused, refusal: "Hermes requires confirmation before using this model.")
        XCTAssertEqual(picks.reasoning, "none", "What Hermes holds")
        XCTAssertEqual(picks.saved, fast)
        XCTAssertEqual(picks.refusal, "Hermes requires confirmation before using this model.")
        XCTAssertNil(picks.writeAsked(), "Putting it back writes nothing")

        let after = picks.readAsked()
        picks.hermesAnswered(chats, to: after)
        XCTAssertEqual(picks.saved, chats, "Asked after the writes")
        XCTAssertEqual(picks.selection, VoiceReplyModelPicks.sameAsChats)

        let older = picks.readAsked()
        let newer = picks.readAsked()
        XCTAssertTrue(picks.hermesAnswered(fast, to: newer))
        XCTAssertFalse(picks.hermesAnswered(chats, to: older), "Its models are older too")
        XCTAssertEqual(picks.saved, fast, "Asked before a read that answered first")
        XCTAssertEqual(picks.selection, fastTag)

        let stale = picks.readAsked()
        let fresh = picks.readAsked()
        picks.hermesAnswered(fast, to: fresh)
        picks.readDidFail(stale)
        XCTAssertFalse(picks.readFailed, "A failure older than what's shown says nothing")
        let failing = picks.readAsked()
        picks.readDidFail(failing)
        XCTAssertTrue(picks.readFailed)
    }

    /// A pick Hermes' price check asks about stays offered: Use It Anyway
    /// writes it again with the user's yes, showing it meanwhile, and the
    /// helper's slot goes with every write.
    func testAPickThePriceCheckAsksAboutCanBeConfirmed() throws {
        let chats = VoiceReplyModelSetting(task: "compression", provider: "auto", model: "", reasoningEffort: nil)
        var picks = VoiceReplyModelPicks()
        picks.hermesAnswered(chats, to: picks.readAsked())
        XCTAssertNil(picks.confirmAsked(), "Nothing asked about yet")
        picks.selection = VoiceJobModelSettingsSection.tag(provider: "openrouter", model: "big")
        let pick = try XCTUnwrap(picks.writeAsked())
        XCTAssertEqual(pick.task, "compression")
        picks.writeEnded(pick, result: .needsConfirmation("big costs more."))
        XCTAssertEqual(picks.refusal, "big costs more.")
        XCTAssertEqual(picks.confirmable, pick)
        XCTAssertEqual(picks.selection, VoiceReplyModelPicks.sameAsChats, "What Hermes holds until confirmed")

        let confirmed = try XCTUnwrap(picks.confirmAsked())
        XCTAssertEqual(confirmed, pick)
        XCTAssertTrue(picks.writing)
        XCTAssertNil(picks.refusal)
        XCTAssertNil(picks.confirmable)
        XCTAssertEqual(picks.selection, VoiceJobModelSettingsSection.tag(provider: "openrouter", model: "big"))
        XCTAssertNil(picks.writeAsked(), "Showing it writes nothing more")
        picks.writeEnded(confirmed, result: .saved)
        XCTAssertEqual(picks.saved, pick)

        // Another pick drops the offer.
        picks.selection = VoiceReplyModelPicks.sameAsChats
        let back = try XCTUnwrap(picks.writeAsked())
        picks.writeEnded(back, result: .needsConfirmation("ask"))
        picks.selection = VoiceJobModelSettingsSection.tag(provider: "openrouter", model: "other")
        _ = picks.writeAsked()
        XCTAssertNil(picks.confirmable)

        let body = pick.assignmentBody(profile: "work", confirmed: true)
        XCTAssertEqual(body["task"] as? String, "compression")
        XCTAssertEqual(body["confirm_expensive_model"] as? Bool, true)
        XCTAssertNil(pick.assignmentBody(profile: "work")["confirm_expensive_model"], "Hermes checks the price unless the user said yes")
    }

    /// Hermes' helper slots, as Models & providers lists them: built-ins
    /// named by Conduit, plugin slots by their label, Pulse's left to
    /// Settings > Pulse, a slot that follows another named after it.
    func testHelperModelSlotsAreNamedAndPulsesIsLeftOut() {
        let slots = HelperModelSlot.slots(in: ["tasks": [
            ["task": "vision", "provider": "auto", "model": ""],
            ["task": "title_generation", "provider": "openrouter", "model": "fast/titles", "reasoning_effort": "low"],
            ["task": "brand_new_slot", "provider": "auto", "model": ""],
            ["task": "pulse_memory", "provider": "auto", "model": "", "label": "Pulse memory", "plugin": "conduit_push"],
            ["task": "conduit_predict", "provider": "auto", "model": "", "label": "Conduit predictions", "plugin": "conduit_push"],
            ["task": "notes_digest", "provider": "auto", "model": "", "label": "Notes digest", "hint": "Digests notes.",
             "plugin": "notes", "inherit_from": "compression"],
            ["task": "compression", "provider": "auto", "model": ""],
            ["task": ""],
        ]])
        XCTAssertEqual(slots.map(\.id), ["vision", "title_generation", "brand_new_slot", "conduit_predict", "notes_digest", "compression"])
        XCTAssertEqual(slots[0].title, AppLocalization.string("Image reading"))
        XCTAssertEqual(slots[0].value, AppLocalization.string("Same as chats"))
        XCTAssertEqual(slots[1].value, "fast/titles")
        XCTAssertEqual(slots[1].setting.reasoningEffort, "low")
        XCTAssertEqual(slots[2].title, "Brand new slot", "a slot a newer Hermes added reads as its key")
        XCTAssertEqual(slots[3].title, AppLocalization.string("Conduit predictions"))
        XCTAssertEqual(slots[4].title, "Notes digest")
        XCTAssertEqual(slots[4].caption, "Digests notes.")
        let compaction = AppLocalization.string("Compaction")
        XCTAssertEqual(slots[4].value, AppLocalization.string("Same as \(compaction)"))
        XCTAssertEqual(slots[4].followTitle, AppLocalization.string("Same as \(compaction)"))
        XCTAssertEqual(slots[5].followTitle, AppLocalization.string("Same as chats"))
    }

    /// A provider pinned without a model is a choice of its own, named
    /// as its default model; "Same as chats" unpins it. A slot on an
    /// endpoint of its own names its host and keeps it while its provider
    /// stays.
    func testAPinnedProviderAndAnEndpointAreShownAndKept() throws {
        let pinned = try XCTUnwrap(VoiceReplyModelSetting(row: ["task": "vision", "provider": "openrouter", "model": ""]))
        XCTAssertTrue(pinned.providerOnly)
        XCTAssertFalse(pinned.followsChats)
        var picks = VoiceReplyModelPicks()
        picks.hermesAnswered(pinned, to: picks.readAsked())
        XCTAssertEqual(picks.selection, VoiceJobModelSettingsSection.tag(provider: "openrouter", model: ""))
        XCTAssertNil(picks.writeAsked(), "Showing it writes nothing")
        let choices = VoiceJobModelSettingsSection.modelChoices(
            defaultTitle: "chats", defaultTag: VoiceReplyModelPicks.sameAsChats, selection: picks.selection, providers: []
        )
        XCTAssertEqual(choices.last?.title, VoiceJobModelSettingsSection.providerDefaultTitle("openrouter"))
        picks.selection = VoiceReplyModelPicks.sameAsChats
        let unpinned = try XCTUnwrap(picks.writeAsked())
        XCTAssertEqual(unpinned.provider, "auto")
        XCTAssertTrue(unpinned.followsChats)

        let local = try XCTUnwrap(VoiceReplyModelSetting(row: [
            "task": "title_generation", "provider": "custom", "model": "qwen3",
            "base_url": "http://user:pw@192.168.1.20:1234/v1",
        ]))
        XCTAssertEqual(local.endpointHost, "192.168.1.20:1234", "Its host, never its path or credentials")
        let slot = try XCTUnwrap(HelperModelSlot.slots(in: ["tasks": [[
            "task": "title_generation", "provider": "custom", "model": "qwen3", "base_url": "http://192.168.1.20:1234/v1",
        ]]]).first)
        XCTAssertEqual(slot.value, "qwen3 · 192.168.1.20:1234")
        var endpointPicks = VoiceReplyModelPicks()
        endpointPicks.hermesAnswered(local, to: endpointPicks.readAsked())
        XCTAssertNil(endpointPicks.writeAsked(), "Its endpoint goes with the pick Hermes holds")
        XCTAssertNotNil(endpointPicks.endpointCaption)
        endpointPicks.reasoning = "low"
        let sameProvider = try XCTUnwrap(endpointPicks.writeAsked())
        XCTAssertEqual(sameProvider.assignmentBody(profile: "default")["base_url"] as? String, local.baseURL)
        endpointPicks.writeEnded(sameProvider, result: .saved)
        endpointPicks.selection = VoiceJobModelSettingsSection.tag(provider: "openrouter", model: "fast")
        let moved = try XCTUnwrap(endpointPicks.writeAsked())
        XCTAssertNil(moved.baseURL, "Another provider moves it off the endpoint")
        XCTAssertNil(moved.assignmentBody(profile: "default")["base_url"])
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

        // A read that fails keeps the fast model, Assistant speech's status
        // (so its setup step doesn't change) and the speech server's shown,
        // and says it failed.
        let shownVoice = service.speechServerVoice
        XCTAssertEqual(shownVoice?.apiKey, "sk-local")
        requester.routes[SpeechServerSpeechStream.statusPath] = nil
        let failedVoice = await service.speechServerVoiceStatus()
        XCTAssertTrue(failedVoice.readFailed)
        XCTAssertNotNil(failedVoice.reason)
        XCTAssertEqual(service.lastFrontModel?.model, "qwen3-8b")
        XCTAssertEqual(service.speechServerVoice, shownVoice)
        // A new key while the read still fails: the status shown carries
        // it, the old one having stopped working.
        requester.routes[SpeechServerSpeechStream.keyPath] = ["api_key": "sk-new"]
        let rotated = await service.rotateSpeechServerVoiceKey()
        XCTAssertTrue(rotated)
        var withNewKey = shownVoice
        withNewKey?.apiKey = "sk-new"
        XCTAssertEqual(service.speechServerVoice, withNewKey)
        requester.routes[SpeechServerTranscription.statusPath] = nil
        let failed = await service.speechServerStatus()
        XCTAssertTrue(failed.readFailed)
        XCTAssertNotNil(failed.reason)
        XCTAssertEqual(service.speechServer?.url, "ws://box:9000/v1/realtime")
        XCTAssertEqual(kept.saved[SpeechServerTranscription.statusPath]?["url"] as? String, "ws://box:9000/v1/realtime")

        // With nothing shown, the failure is what the step shows, so the
        // page's next check reads it again.
        let unkept = HermesVoiceConfigurationService(requester: MockVoiceConfigurationRequester(), profile: "default")
        _ = await unkept.speechServerStatus()
        XCTAssertEqual(unkept.speechServer?.readFailed, true)
        _ = await unkept.speechServerVoiceStatus()
        XCTAssertEqual(unkept.speechServerVoice?.readFailed, true)
    }

    /// A speech toolset whose read fails while the config answers keeps the
    /// readiness shown, so a ready voice doesn't flip to not ready.
    func testAToolsetReadThatFailsKeepsItsReadiness() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": Self.keptVoiceAnswers["/api/config"] ?? [:],
            "/api/tools/toolsets/stt/config": Self.keptVoiceAnswers["/api/tools/toolsets/stt/config"] ?? [:],
        ]
        let service = HermesVoiceConfigurationService(
            requester: requester, profile: "default", answers: KeptVoiceAnswers(Self.keptVoiceAnswers).answers
        )

        await service.reload()

        XCTAssertEqual(service.answered, true)
        XCTAssertTrue(service.snapshot.capability.supportsSpeech, "The Edge voice stays ready")
        XCTAssertEqual(service.snapshot.selectedTTSProvider, "edge")
        XCTAssertNil(service.errorMessage, "Not the message for a Hermes without toolset readiness")
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

    var answers: KeptAnswers {
        KeptAnswers(
            kept: { route in self.saved[route] },
            keep: { route, _, read in
                let answer = try await read()
                self.saved[route] = answer
                return answer
            }
        )
    }
}
