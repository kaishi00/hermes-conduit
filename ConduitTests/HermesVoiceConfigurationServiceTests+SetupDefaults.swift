//
//  VoiceSetupDefaultsTests.swift
//  Conduit
//
//  The one-switch happy path: turning Voice on fills in only what is
//  missing, so classic Voice works without anything installed on Hermes.
//  An extension of the voice configuration tests: the hosted CI plan is at
//  its class budget, and these cover the same parsed snapshot.
//

import XCTest
@testable import Conduit

extension HermesVoiceConfigurationServiceTests {
    /// The App Store reviewer's setup: nothing chosen, Hermes' default local
    /// Whisper not installed, the default Edge voice ready.
    func testFreshProfileGetsOnDeviceSpeechToTextAndKeepsEdge() {
        let plan = VoiceSetupDefaults.plan(
            transcriptionModeChosen: false,
            appleSpeechAvailability: .permissionRequired(localeIdentifier: "en-US"),
            snapshot: setupSnapshot(selectedTTS: "edge", ttsRows: [setupEdgeRow(active: true)])
        )

        XCTAssertEqual(plan, .init(usesOnDeviceTranscription: true, switchesSpeechToEdge: false))
    }

    func testASpeechToTextChoiceAlreadyMadeIsKept() {
        let plan = VoiceSetupDefaults.plan(
            transcriptionModeChosen: true,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US"),
            snapshot: setupSnapshot(selectedTTS: "edge", ttsRows: [setupEdgeRow(active: true)])
        )

        XCTAssertFalse(plan.usesOnDeviceTranscription)
    }

    /// A language the iPhone can't transcribe stays on Hermes.
    func testUnsupportedOnDeviceLanguageKeepsHermesSpeechToText() {
        let plan = VoiceSetupDefaults.plan(
            transcriptionModeChosen: false,
            appleSpeechAvailability: .unsupported(localeIdentifier: "xx-XX"),
            snapshot: setupSnapshot(selectedTTS: "edge", ttsRows: [setupEdgeRow(active: true)])
        )

        XCTAssertFalse(plan.usesOnDeviceTranscription)
    }

    func testAnAssistantVoiceThatIsNotReadySwitchesToReadyEdge() {
        let snapshot = setupSnapshot(
            selectedTTS: "elevenlabs",
            ttsRows: [
                ["name": "ElevenLabs", "tts_provider": "elevenlabs", "status": "needs_keys", "is_active": true],
                setupEdgeRow(active: false),
            ]
        )

        XCTAssertFalse(snapshot.capability.supportsSpeech)
        XCTAssertTrue(VoiceSetupDefaults.canSwitchSpeechToEdge(snapshot))
        XCTAssertTrue(VoiceSetupDefaults.plan(
            transcriptionModeChosen: true,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US"),
            snapshot: snapshot
        ).switchesSpeechToEdge)
    }

    func testAReadyAssistantVoiceIsNeverReplaced() {
        let snapshot = setupSnapshot(
            selectedTTS: "openai",
            ttsRows: [
                ["name": "OpenAI TTS", "tts_provider": "openai", "status": "ready", "is_active": true],
                setupEdgeRow(active: false),
            ]
        )

        XCTAssertTrue(snapshot.capability.supportsSpeech)
        XCTAssertFalse(VoiceSetupDefaults.canSwitchSpeechToEdge(snapshot))
    }

    func testEdgeThatIsNotReadyIsNotOffered() {
        let snapshot = setupSnapshot(
            selectedTTS: "elevenlabs",
            ttsRows: [
                ["name": "ElevenLabs", "tts_provider": "elevenlabs", "status": "needs_keys", "is_active": true],
                ["name": "Microsoft Edge TTS", "tts_provider": "edge", "status": "needs_install", "is_active": false],
            ]
        )

        XCTAssertFalse(VoiceSetupDefaults.canSwitchSpeechToEdge(snapshot))
    }

    /// Edge already selected but not ready: switching to it again fixes
    /// nothing, so the step points at the provider list instead.
    func testEdgeAlreadySelectedIsNotSwitchedAgain() {
        let snapshot = setupSnapshot(
            selectedTTS: "edge",
            ttsRows: [["name": "Microsoft Edge TTS", "tts_provider": "edge", "status": "needs_install", "is_active": true]]
        )

        XCTAssertFalse(snapshot.capability.supportsSpeech)
        XCTAssertFalse(VoiceSetupDefaults.canSwitchSpeechToEdge(snapshot))
    }

    func testDisconnectedSnapshotChangesNothing() {
        let plan = VoiceSetupDefaults.plan(
            transcriptionModeChosen: true,
            appleSpeechAvailability: .ready(localeIdentifier: "en-US"),
            snapshot: .unavailable(profile: "default", reason: "Not loaded")
        )

        XCTAssertEqual(plan, .init())
    }

    func testProviderReadinessReadsUnselectedRows() {
        let snapshot = setupSnapshot(
            selectedTTS: "edge",
            ttsRows: [setupEdgeRow(active: true)],
            sttRows: [
                ["name": "Local Whisper", "status": "needs_install", "is_active": true],
                ["name": "Groq", "status": "ready", "is_active": false],
            ]
        )

        XCTAssertEqual(VoiceSetupDefaults.providerReadiness("local", in: snapshot.sttProviders), .notReady(status: "needs_install"))
        XCTAssertEqual(VoiceSetupDefaults.providerReadiness("groq", in: snapshot.sttProviders), .ready)
        XCTAssertEqual(VoiceSetupDefaults.providerReadiness("deepinfra", in: snapshot.sttProviders), .unknown)
    }

    func testSetupDefaultsEdgeHasAReadableName() {
        XCTAssertEqual(VoiceConfigurationParser.catalogDescriptor(id: "edge", kind: .tts)?.displayName, "Edge TTS")
    }

    // MARK: - Helpers

    private func setupEdgeRow(active: Bool) -> [String: Any] {
        ["name": "Microsoft Edge TTS", "tts_provider": "edge", "status": "ready", "is_active": active]
    }

    private func setupSnapshot(
        selectedTTS: String,
        ttsRows: [[String: Any]],
        sttRows: [[String: Any]] = [["name": "Local Whisper", "status": "needs_install", "is_active": true]]
    ) -> VoiceConfigurationSnapshot {
        VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["enabled": true, "provider": "local"], "tts": ["provider": selectedTTS]],
            sttReadiness: ["providers": sttRows],
            ttsReadiness: ["providers": ttsRows],
            environment: [:],
            ttsToolsetConfigAvailable: true
        )
    }
}
