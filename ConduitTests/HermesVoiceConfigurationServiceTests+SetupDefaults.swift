//
//  HermesVoiceConfigurationServiceTests+SetupDefaults.swift
//  Conduit
//
//  The one-switch happy path: turning Voice on fills in only what is
//  missing, so classic Voice works without anything installed on Hermes.
//  Hermes' speech config is never changed: unless the profile has its own
//  Hermes voice, this iPhone speaks the replies.
//  An extension of the voice configuration tests: the hosted CI plan is at
//  its class budget, and these cover the same parsed snapshot.
//

import XCTest
@testable import Conduit

extension HermesVoiceConfigurationServiceTests {
    /// The App Store reviewer's setup: nothing chosen, Hermes' default local
    /// Whisper not installed. Replies need nothing: this iPhone speaks them.
    func testFreshProfileGetsOnDeviceSpeechToText() {
        let plan = VoiceSetupDefaults.plan(
            transcriptionModeChosen: false,
            appleSpeechAvailability: .permissionRequired(localeIdentifier: "en-US"),
            snapshot: setupSnapshot(selectedTTS: "edge", ttsRows: [setupEdgeRow(active: true)])
        )

        XCTAssertEqual(plan, .init(usesOnDeviceTranscription: true))
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

    /// Edge, Hermes' default, breaks whenever Microsoft changes its
    /// handshake: a profile left on it speaks on this iPhone.
    func testParsedEdgeVoiceIsSpokenOnThisIPhoneAndAnOwnVoiceOnHermes() {
        let edge = setupSnapshot(selectedTTS: "edge", ttsRows: [setupEdgeRow(active: true)])
        XCTAssertEqual(edge.capability.selectedTTSProvider, "edge")
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: edge.capability), .onDevice)

        let openAI = setupSnapshot(
            selectedTTS: "openai",
            ttsRows: [["name": "OpenAI TTS", "tts_provider": "openai", "status": "ready", "is_active": true]]
        )
        XCTAssertEqual(VoiceSpeechOutput.resolved(chosen: nil, snapshot: openAI.capability), .hermes)
    }

    /// A provider Conduit has no catalog entry for (a plugin's, or a
    /// custom OpenAI-compatible one) that Hermes reports ready is ready,
    /// even though Hermes computes `is_active` only for the built-ins it can
    /// match to `tts.provider`.
    func testAReadyProviderConduitDoesNotKnowIsReady() {
        for row: [String: Any] in [
            ["name": "Speechbox", "tts_provider": "speechbox", "status": "ready", "is_active": false],
            ["name": "Speechbox", "status": "ready"],
            ["name": "Speechbox voices", "tts_provider": "speechbox", "status": ["state": "ready"]],
        ] {
            let snapshot = setupSnapshot(selectedTTS: "speechbox", ttsRows: [row, setupEdgeRow(active: false)])

            XCTAssertTrue(snapshot.capability.supportsSpeech, "\(row)")
            XCTAssertNil(snapshot.capability.unavailableReason)
            XCTAssertEqual(VoiceSetupDefaults.providerReadiness("speechbox", in: snapshot.ttsProviders), .ready)
        }
    }

    /// The same provider reporting a problem is not ready.
    func testAProviderConduitDoesNotKnowThatIsNotReadyIsNotReady() {
        let snapshot = setupSnapshot(
            selectedTTS: "speechbox",
            ttsRows: [["name": "Speechbox", "tts_provider": "speechbox", "status": "needs_keys", "is_active": true], setupEdgeRow(active: false)]
        )

        XCTAssertFalse(snapshot.capability.supportsSpeech)
        XCTAssertEqual(VoiceSetupDefaults.providerReadiness("speechbox", in: snapshot.ttsProviders), .notReady(status: "needs_keys"))
    }

    /// Two rows naming one provider: the one Hermes marks active decides.
    func testTheActiveRowSpeaksForAProviderListedTwice() {
        let snapshot = setupSnapshot(
            selectedTTS: "speechbox",
            ttsRows: [
                ["name": "Speechbox", "tts_provider": "speechbox", "status": "needs_keys", "is_active": false],
                ["name": "Speechbox (plugin)", "tts_provider": "speechbox", "status": "ready", "is_active": true],
            ]
        )

        XCTAssertTrue(snapshot.capability.supportsSpeech)
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
