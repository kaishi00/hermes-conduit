import XCTest
@testable import Conduit

@MainActor
final class HermesVoiceConfigurationServiceTests: XCTestCase {
    func testParserUsesSchemaProvidersAndProfileConfig() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "research",
            schema: [
                "fields": [
                    ["key": "stt.provider", "options": ["stepfun", "xiaomi_mimo"]],
                    ["key": "tts.provider", "options": [["value": "stepfun"], ["value": "xiaomi_mimo"]]]
                ]
            ],
            config: [
                "stt": ["provider": "xiaomi_mimo", "xiaomi_mimo": ["model": "custom-asr"]],
                "tts": ["provider": "stepfun", "stepfun": ["voice": "custom-voice"]]
            ],
            sttReadiness: ["providers": [["stt_provider": "xiaomi_mimo", "status": "ready", "is_active": true]]],
            ttsReadiness: ["providers": [["tts_provider": "stepfun", "status": "ready", "is_active": true]]],
            environment: [
                "MIMO_API_KEY": ["is_set": true, "redacted_value": "mi…123"],
                "STEPFUN_API_KEY": ["is_set": false, "redacted_value": NSNull()]
            ],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(snapshot.profile, "research")
        XCTAssertEqual(snapshot.selectedSTTProvider, "xiaomi_mimo")
        XCTAssertEqual(snapshot.selectedTTSProvider, "stepfun")
        XCTAssertEqual(snapshot.values["stt.xiaomi_mimo.model"], "custom-asr")
        XCTAssertEqual(snapshot.values["tts.stepfun.voice"], "custom-voice")
        XCTAssertTrue(snapshot.capability.supportsTranscription)
        XCTAssertTrue(snapshot.capability.supportsSpeech)
        XCTAssertEqual(snapshot.sttProviders.map(\.descriptor.id), ["stepfun", "xiaomi_mimo"])
    }

    func testCredentialMetadataDoesNotCarryRedactedOrSecretValue() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default", schema: nil,
            config: ["stt": [String: Any](), "tts": [String: Any]()],
            sttReadiness: nil, ttsReadiness: nil,
            environment: ["MIMO_API_KEY": ["is_set": true, "redacted_value": "should-not-be-copied", "description": "MiMo key"]],
            sttEndpointAvailable: false, ttsEndpointAvailable: false
        )

        XCTAssertEqual(snapshot.credentials, [.init(key: "MIMO_API_KEY", isSet: true, description: "MiMo key")])
        XCTAssertFalse(snapshot.capability.supportsTranscription)
        XCTAssertFalse(snapshot.capability.supportsSpeech)
        XCTAssertEqual(snapshot.capability.unavailableReason, "This Hermes gateway does not provide voice endpoints. Text chat remains available.")
    }

    func testXiaomiCatalogContainsDocumentedBuiltInVoicesAndManualField() {
        let descriptor = VoiceConfigurationParser.catalogDescriptor(id: "xiaomi_mimo", kind: .tts)
        XCTAssertEqual(descriptor?.voices, ["mimo_default", "冰糖", "茉莉", "苏打", "白桦", "Mia", "Chloe", "Milo", "Dean"])
        let fields = VoiceConfigurationParser.typedFields(id: "xiaomi_mimo", kind: .tts)
        XCTAssertTrue(fields.contains { $0.key == "tts.xiaomi_mimo.voice" })
        XCTAssertTrue(fields.contains { $0.key == "tts.xiaomi_mimo.delivery_instructions" })
    }

    func testStepFunFieldKeysStayInTheProviderSections() {
        let fields = VoiceConfigurationParser.typedFields(id: "stepfun", kind: .tts)
        XCTAssertTrue(fields.contains { $0.key == "tts.stepfun.endpoint_preset" })
        XCTAssertTrue(fields.contains { $0.key == "tts.stepfun.endpoint" })
        XCTAssertTrue(fields.contains { $0.key == "tts.stepfun.instruction" })
        XCTAssertTrue(fields.allSatisfy { $0.key.hasPrefix("tts.stepfun.") })
    }

    func testUnsetPluginCredentialStillAppearsFromReadinessMetadata() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["provider": "stepfun"], "tts": ["provider": "stepfun"]],
            sttReadiness: [
                "providers": [[
                    "stt_provider": "stepfun",
                    "status": "needs_keys",
                    "is_active": true,
                    "env_vars": [["key": "STEPFUN_API_KEY", "is_set": false, "prompt": "StepFun API key"]]
                ]]
            ],
            ttsReadiness: ["providers": []],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(snapshot.credentials, [
            .init(key: "STEPFUN_API_KEY", isSet: false, description: "StepFun API key")
        ])
        // Readiness is diagnostic: needs_keys surfaces in Settings but the
        // real transcription attempt is what reports the missing key.
        XCTAssertTrue(snapshot.capability.supportsTranscription)
    }

    func testLocalWhisperReadinessUsesCanonicalProviderAndVisibleDefaultModel() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["provider": "local"], "tts": ["provider": "edge"]],
            sttReadiness: [
                "providers": [[
                    "name": "Local Whisper",
                    "status": "ready",
                    "is_active": true,
                    "env_vars": []
                ]]
            ],
            ttsReadiness: [
                "providers": [[
                    "name": "Microsoft Edge TTS",
                    "tts_provider": "edge",
                    "status": "ready",
                    "is_active": true,
                    "env_vars": []
                ]]
            ],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(snapshot.sttProviders.map(\.descriptor.id), ["local"])
        XCTAssertEqual(snapshot.sttProviders.first?.descriptor.displayName, "Local")
        XCTAssertEqual(snapshot.sttProviders.first?.fields.first(where: { $0.key == "stt.local.model" })?.defaultValue, "base")
        XCTAssertTrue(snapshot.capability.supportsTranscription)
    }

    // MARK: - Nous Subscription vs direct OpenAI (Reddit-reported regression)

    /// Rows shaped exactly like the upstream toolset payload: STT rows carry
    /// only a picker `name` — no `stt_provider` field. The managed Nous row
    /// and the direct OpenAI row must become distinct provider identities and
    /// each must keep its own readiness status.
    func testNousSubscriptionAndDirectOpenAIRemainDistinctProviders() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            sttReadiness: [
                "providers": [
                    ["name": "Nous Subscription", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI", "status": "ready", "is_active": true]
                ]
            ],
            ttsReadiness: ["providers": []],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(snapshot.sttProviders.map(\.descriptor.id), ["nous", "openai"])
        XCTAssertEqual(snapshot.sttProviders.first { $0.descriptor.id == "nous" }?.readiness?.status, "needs_auth")
        XCTAssertEqual(snapshot.sttProviders.first { $0.descriptor.id == "openai" }?.readiness?.status, "ready")
        // Selection attaches to the row it names — never the managed row.
        XCTAssertEqual(snapshot.sttProviders.first { $0.descriptor.id == "openai" }?.readiness?.isActive, true)
        XCTAssertEqual(snapshot.sttProviders.first { $0.descriptor.id == "nous" }?.readiness?.displayName, "Nous Subscription")
    }

    /// The Reddit reproduction: OpenAI selected and ready, Nous Subscription
    /// logged out. The direct route must not inherit the managed row's
    /// needs_auth state and transcription must stay available.
    func testDirectOpenAIIsNotDisabledBecauseNousSubscriptionNeedsAuth() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            sttReadiness: [
                "providers": [
                    ["name": "Nous Subscription", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI", "status": "ready", "is_active": true]
                ]
            ],
            ttsReadiness: [
                "providers": [["name": "Microsoft Edge TTS", "tts_provider": "edge", "status": "ready", "is_active": true]]
            ],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertTrue(snapshot.capability.supportsTranscription)
        XCTAssertNil(snapshot.capability.unavailableReason)
    }

    /// Readiness is a diagnostic: needs_keys on the selected provider must
    /// still surface in Settings, but it must not preemptively disable the
    /// mic — the real transcription attempt reports the provider error.
    func testNeedsKeysReadinessStaysDiagnosticAndDoesNotDisableTranscription() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            sttReadiness: [
                "providers": [
                    ["name": "Nous Subscription", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI", "status": "needs_keys", "is_active": true]
                ]
            ],
            ttsReadiness: [
                "providers": [["name": "Microsoft Edge TTS", "tts_provider": "edge", "status": "ready", "is_active": true]]
            ],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(snapshot.sttProviders.first { $0.descriptor.id == "openai" }?.readiness?.status, "needs_keys")
        XCTAssertTrue(snapshot.capability.supportsTranscription)
    }

    func testDisabledSTTConfigStillDisablesHermesTranscription() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["enabled": false, "provider": "openai"], "tts": ["provider": "edge"]],
            sttReadiness: [
                "providers": [["name": "OpenAI", "status": "ready", "is_active": true]]
            ],
            ttsReadiness: [
                "providers": [["name": "Microsoft Edge TTS", "tts_provider": "edge", "status": "ready", "is_active": true]]
            ],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertFalse(snapshot.capability.supportsTranscription)
        XCTAssertEqual(snapshot.capability.unavailableReason, "Speech-to-text is disabled for this Hermes profile.")
    }

    /// Normalization against Hermes' current STT picker catalog: every row
    /// name maps to the provider ID Hermes writes into stt.provider, and the
    /// managed TTS row stays distinct from the direct OpenAI TTS row even
    /// though both rows' vendor field says "openai".
    func testCurrentUpstreamPickerCatalogMapsToCanonicalProviderIDs() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["provider": "local"], "tts": ["provider": "edge"]],
            sttReadiness: [
                "providers": [
                    ["name": "Local Whisper", "status": "ready", "is_active": true],
                    // Managed flag must outrank the vendor stt_provider field.
                    ["name": "Nous Subscription", "stt_provider": "openai", "requires_nous_auth": true, "managed_nous_feature": "stt", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI", "status": "needs_keys", "is_active": false],
                    ["name": "Groq", "status": "ready", "is_active": false],
                    ["name": "xAI", "status": "ready", "is_active": false],
                    ["name": "ElevenLabs Scribe", "status": "needs_keys", "is_active": false],
                    ["name": "DeepInfra", "status": "needs_keys", "is_active": false]
                ]
            ],
            ttsReadiness: [
                "providers": [
                    ["name": "Nous Subscription", "tts_provider": "openai", "requires_nous_auth": true, "managed_nous_feature": "tts", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI TTS", "tts_provider": "openai", "status": "needs_keys", "is_active": false]
                ]
            ],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(
            snapshot.sttProviders.map(\.descriptor.id),
            ["local", "nous", "openai", "groq", "xai", "elevenlabs", "deepinfra"]
        )
        XCTAssertEqual(
            snapshot.ttsProviders.map(\.descriptor.id),
            ["nous", "openai", "edge"]
        )
        XCTAssertEqual(snapshot.sttProviders.first { $0.descriptor.id == "nous" }?.descriptor.displayName, "Nous Subscription")
        XCTAssertEqual(snapshot.sttProviders.first { $0.descriptor.id == "openai" }?.descriptor.displayName, "OpenAI")
    }

    /// The managed Nous selection resolves model/language through the vendor
    /// config section upstream, so its editors must target stt.openai.* keys.
    func testManagedNousFieldEditorsTargetVendorConfigKeys() {
        let fields = VoiceConfigurationParser.typedFields(id: "nous", kind: .stt)
        XCTAssertTrue(fields.contains { $0.key == "stt.openai.model" })
        XCTAssertTrue(fields.contains { $0.key == "stt.openai.language" })
        let elevenlabs = VoiceConfigurationParser.typedFields(id: "elevenlabs", kind: .stt)
        XCTAssertTrue(elevenlabs.contains { $0.key == "stt.elevenlabs.model_id" })
    }

    // MARK: - Provider selection save path

    /// Row-backed providers must be selected through the gateway's toolset
    /// provider endpoint under the row's display name — Hermes owns the
    /// row→config mapping (managed rows become `stt.provider = nous` on
    /// current gateways and the gateway-intent equivalent on older ones).
    /// Conduit must never write a Conduit-side ID such as "nous" itself.
    func testProviderSelectionSubmitsRowNameToGatewayEndpoint() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            "/api/tools/toolsets/stt/config": [
                "providers": [
                    ["name": "Nous Subscription", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI", "status": "ready", "is_active": true]
                ]
            ],
            "/api/tools/toolsets/tts/config": ["providers": []],
            "/api/tools/toolsets/stt/provider": ["ok": true]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("nous", kind: .stt)

        XCTAssertTrue(saved)
        let providerPUT = requester.recorded.first {
            $0.method == "PUT" && $0.path == "/api/tools/toolsets/stt/provider"
        }
        XCTAssertEqual(providerPUT?.body as? [String: String], ["provider": "Nous Subscription"])
        XCTAssertFalse(requester.recorded.contains { $0.method == "PUT" && $0.path == "/api/config" })
    }

    /// Schema-only providers (gateways without toolset readiness) keep the
    /// legacy direct config write: their raw IDs are plain vendor values.
    func testSchemaOnlyProviderSelectionFallsBackToDirectConfigWrite() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "stepfun"], "tts": ["provider": "stepfun"]],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("stepfun", kind: .stt)

        XCTAssertTrue(saved)
        XCTAssertTrue(requester.recorded.contains { $0.method == "PUT" && $0.path == "/api/config" })
        XCTAssertFalse(requester.recorded.contains { $0.path == "/api/tools/toolsets/stt/provider" })
        XCTAssertEqual(service.snapshot.selectedSTTProvider, "stepfun")
    }

    /// A managed-row selection on a signed-out account still saves — Hermes
    /// writes the selection and flags the missing entitlement, which Conduit
    /// surfaces as a notice instead of hiding it.
    func testManagedSelectionSurfacesNeedsAuthNoticeFromGateway() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            "/api/tools/toolsets/stt/config": [
                "providers": [
                    ["name": "Nous Subscription", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI", "status": "ready", "is_active": true]
                ]
            ],
            "/api/tools/toolsets/tts/config": ["providers": []],
            "/api/tools/toolsets/stt/provider": ["ok": true, "needs_nous_auth": true, "feature": "stt"]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("nous", kind: .stt)

        XCTAssertTrue(saved)
        XCTAssertNotNil(service.errorMessage)
    }

    /// The managed row must fail loud when the gateway's provider endpoint is
    /// unavailable — a direct `stt.provider = "nous"` write is only valid on
    /// gateways whose endpoint translates the row, never as a fallback.
    func testManagedRowSelectionFailsLoudWithoutProviderEndpoint() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            "/api/tools/toolsets/stt/config": [
                "providers": [
                    ["name": "Nous Subscription", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI", "status": "ready", "is_active": true]
                ]
            ],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("nous", kind: .stt)

        XCTAssertFalse(saved)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertFalse(requester.recorded.contains { $0.method == "PUT" && $0.path == "/api/config" })
    }

    /// Vendor rows carry IDs that are valid config values upstream, so when
    /// the provider endpoint is unreachable their selection degrades to the
    /// legacy direct write instead of failing outright.
    func testVendorRowSelectionFallsBackToDirectConfigWriteWhenEndpointMissing() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            "/api/tools/toolsets/stt/config": [
                "providers": [
                    ["name": "Nous Subscription", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI", "status": "ready", "is_active": true]
                ]
            ],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("openai", kind: .stt)

        XCTAssertTrue(saved)
        XCTAssertTrue(requester.recorded.contains { $0.method == "PUT" && $0.path == "/api/config" })
        XCTAssertEqual(service.snapshot.selectedSTTProvider, "openai")
    }

    /// Row-backed TTS selection uses the same gateway contract on the tts
    /// toolset: the row's display name, not a Conduit-side ID.
    func testTTSRowSelectionSubmitsRowNameToGatewayEndpoint() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["provider": "local"], "tts": ["provider": "edge"]],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": [
                "providers": [
                    ["name": "Nous Subscription", "tts_provider": "openai", "requires_nous_auth": true, "managed_nous_feature": "tts", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI TTS", "tts_provider": "openai", "status": "needs_keys", "is_active": false]
                ]
            ],
            "/api/tools/toolsets/tts/provider": ["ok": true]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("nous", kind: .tts)

        XCTAssertTrue(saved)
        let providerPUT = requester.recorded.first {
            $0.method == "PUT" && $0.path == "/api/tools/toolsets/tts/provider"
        }
        XCTAssertEqual(providerPUT?.body as? [String: String], ["provider": "Nous Subscription"])
    }
}

@MainActor
private final class MockVoiceConfigurationRequester: VoiceConfigurationRequesting {
    var routes: [String: [String: Any]] = [:]
    private(set) var recorded: [(path: String, method: String, body: [String: Any]?)] = []

    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        recorded.append((path: path, method: method, body: body))
        guard let response = routes[path] else {
            throw DashboardTicketBridgeError.requestFailed("No mock response for \(path)")
        }
        return response
    }
}
