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
            ttsToolsetConfigAvailable: true
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
            ttsToolsetConfigAvailable: false
        )

        XCTAssertEqual(snapshot.credentials, [.init(key: "MIMO_API_KEY", isSet: true, description: "MiMo key")])
        // Profile config loaded with no stt.enabled=false: the missing
        // toolset readiness surface cannot disable Hermes transcription —
        // only TTS remains unconfirmed (no readiness rows to vouch for it).
        XCTAssertTrue(snapshot.capability.supportsTranscription)
        XCTAssertFalse(snapshot.capability.supportsSpeech)
        XCTAssertEqual(snapshot.capability.unavailableReason, "The selected text-to-speech provider is not ready for this profile.")
    }

    /// Toolset readiness metadata is picker/diagnostic surface only: when
    /// /api/tools/toolsets/stt/config is unavailable but the profile config
    /// loads, Hermes transcription stays attemptable and the unavailable
    /// reason must not claim the audio endpoint is absent.
    func testMissingToolsetReadinessDoesNotDisableHermesTranscription() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            sttReadiness: nil,
            ttsReadiness: nil,
            environment: [:],
            ttsToolsetConfigAvailable: false
        )

        XCTAssertTrue(snapshot.capability.supportsTranscription)
        XCTAssertNotEqual(
            snapshot.capability.unavailableReason,
            "This Hermes gateway does not expose a speech-to-text endpoint."
        )
        XCTAssertNotEqual(
            snapshot.capability.unavailableReason,
            "This Hermes gateway does not provide voice endpoints. Text chat remains available."
        )
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
            ttsToolsetConfigAvailable: true
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
            ttsToolsetConfigAvailable: true
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
            ttsToolsetConfigAvailable: true
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
            ttsToolsetConfigAvailable: true
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
            ttsToolsetConfigAvailable: true
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
            ttsToolsetConfigAvailable: true
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
            ttsToolsetConfigAvailable: true
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
    /// legacy direct config write: their raw IDs are plain vendor values, and
    /// the section write strips any stale `use_gateway` intent.
    func testSchemaOnlyProviderSelectionFallsBackToDirectConfigWrite() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": [
                "stt": ["enabled": true, "provider": "stepfun", "use_gateway": true],
                "tts": ["provider": "stepfun"]
            ],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("stepfun", kind: .stt)

        XCTAssertTrue(saved)
        XCTAssertTrue(requester.recorded.contains { $0.method == "PUT" && $0.path == "/api/config" })
        XCTAssertFalse(requester.recorded.contains { $0.path == "/api/tools/toolsets/stt/provider" })
        let configPUT = requester.recorded.first { $0.method == "PUT" && $0.path == "/api/config" }
        let writtenSection = (configPUT?.body?["config"] as? [String: Any])?["stt"] as? [String: Any]
        XCTAssertEqual(writtenSection?["provider"] as? String, "stepfun")
        XCTAssertNil(writtenSection?["use_gateway"])
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

    /// When the toolset provider endpoint is unavailable, the legacy vendor
    /// fallback must update the section atomically: write the vendor provider
    /// AND remove stale `use_gateway` gateway-routing intent — a leftover
    /// `use_gateway: true` would override the fresh BYOK selection on legacy
    /// runtimes.
    func testLegacyVendorFallbackRemovesStaleUseGatewayFromSTT() async throws {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": [
                "stt": ["provider": "openai", "use_gateway": true],
                "tts": ["provider": "edge"]
            ],
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
        let configPUT = requester.recorded.first { $0.method == "PUT" && $0.path == "/api/config" }
        let writtenSection = try XCTUnwrap((configPUT?.body?["config"] as? [String: Any])?["stt"] as? [String: Any])
        XCTAssertEqual(writtenSection["provider"] as? String, "openai")
        XCTAssertNil(writtenSection["use_gateway"])
    }

    func testLegacyVendorFallbackRemovesStaleUseGatewayFromTTS() async throws {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": [
                "stt": ["provider": "local"],
                "tts": ["provider": "openai", "use_gateway": true]
            ],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": [
                "providers": [
                    ["name": "Nous Subscription", "tts_provider": "openai", "requires_nous_auth": true, "managed_nous_feature": "tts", "status": "needs_auth", "is_active": false],
                    ["name": "OpenAI TTS", "tts_provider": "openai", "status": "needs_keys", "is_active": false]
                ]
            ]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("openai", kind: .tts)

        XCTAssertTrue(saved)
        let configPUT = requester.recorded.first { $0.method == "PUT" && $0.path == "/api/config" }
        let writtenSection = try XCTUnwrap((configPUT?.body?["config"] as? [String: Any])?["tts"] as? [String: Any])
        XCTAssertEqual(writtenSection["provider"] as? String, "openai")
        XCTAssertNil(writtenSection["use_gateway"])
    }

    /// If the legacy fallback's config PUT itself fails, the selection fails
    /// loudly with an error message and nothing is reported as saved.
    func testLegacyVendorFallbackFailsLoudWhenConfigPutFails() async {
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
        requester.failingPUTPaths = ["/api/config"]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.saveProvider("openai", kind: .stt)

        XCTAssertFalse(saved)
        XCTAssertTrue(service.errorMessage?.hasPrefix("Could not save stt.provider") ?? false)
    }

    /// Managed Nous identity is structural, not label-based: a managed row
    /// with an unfamiliar display name must still fail closed when the
    /// toolset provider endpoint is unavailable — never raw-write "nous"
    /// through the legacy config fallback.
    func testManagedNousRowWithUnfamiliarDisplayNameFailsClosed() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]],
            "/api/tools/toolsets/stt/config": [
                "providers": [
                    ["name": "Managed Speech", "managed_nous_feature": "stt", "stt_provider": "openai", "status": "needs_auth", "is_active": false]
                ]
            ],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let nousRow = service.snapshot.sttProviders.first { $0.descriptor.id == "nous" }?.readiness
        XCTAssertEqual(nousRow?.displayName, "Managed Speech")
        XCTAssertEqual(nousRow?.isManagedNous, true)

        let saved = await service.saveProvider("nous", kind: .stt)

        XCTAssertFalse(saved)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertFalse(requester.recorded.contains { $0.method == "PUT" && $0.path == "/api/config" })
    }

    /// A gateway whose toolset readiness endpoints are entirely unavailable
    /// still exposes Hermes transcription once the profile config loads —
    /// the readiness surface missing is a diagnostics limitation, not a
    /// transcription capability limitation.
    func testReloadCapabilitySurvivesUnavailableToolsetReadinessEndpoint() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "edge"]]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")

        await service.reload()

        XCTAssertTrue(service.snapshot.capability.supportsTranscription)
        XCTAssertNotEqual(
            service.snapshot.capability.unavailableReason,
            "This Hermes gateway does not provide voice endpoints. Text chat remains available."
        )
    }

    // MARK: - TTS provider configuration parity (custom OpenAI-compatible endpoints)

    /// Upstream reads `tts.openai.base_url` (tools/tts_tool_openai.py: the
    /// config override beats the managed-gateway default) and accepts
    /// `tts.openai.speed` clamped to 0.25–4.0. `tts.openai.instruction` is
    /// never read upstream — speaking style arrives only through the
    /// per-request TTS tool parameter — so the editor must not offer it.
    /// The upstream-supported keys stay singular: no duplicate editors.
    func testOpenAITTSExposesBaseURLAndSpeedWithoutDeadInstructionKey() {
        let fields = VoiceConfigurationParser.typedFields(id: "openai", kind: .tts)
        XCTAssertEqual(fields.first { $0.key == "tts.openai.base_url" }?.kind, .text)
        let speed = fields.first { $0.key == "tts.openai.speed" }
        XCTAssertEqual(speed?.kind, .decimal)
        XCTAssertEqual(speed?.numericRange, 0.25...4.0)
        XCTAssertFalse(fields.contains { $0.key == "tts.openai.instruction" })
        XCTAssertEqual(fields.count, Set(fields.map(\.key)).count)
        XCTAssertTrue(fields.contains { $0.key == "tts.openai.model" })
        XCTAssertTrue(fields.contains { $0.key == "tts.openai.voice" })
        XCTAssertTrue(fields.contains { $0.key == "tts.openai.language" })
    }

    /// The managed Nous TTS route shares the vendor config section upstream,
    /// so its editors carry the same endpoint keys and the same dead-key
    /// exclusion.
    func testManagedNousTTSEditorsShareOpenAIEndpointKeys() {
        let fields = VoiceConfigurationParser.typedFields(id: "nous", kind: .tts)
        XCTAssertTrue(fields.contains { $0.key == "tts.openai.base_url" })
        XCTAssertTrue(fields.contains { $0.key == "tts.openai.speed" })
        XCTAssertFalse(fields.contains { $0.key == "tts.openai.instruction" })
    }

    /// Upstream clamps OpenAI speech speed into [0.25, 4.0]
    /// (`max(0.25, min(4.0, speed))`) and reads the stored value with
    /// `float(config.get("speed", default))`, so an absent key restores
    /// the default while a stored empty string would be a parse error.
    /// Conduit therefore accepts empty/whitespace as a clear (removal),
    /// accepts comma-decimal input, and rejects malformed or out-of-range
    /// non-empty values instead of silently letting upstream clamp them.
    func testOpenAISpeedValidationAcceptsClearAndRejectsInvalidValues() {
        XCTAssertNil(VoiceConfigurationParser.validationMessage(for: "1", key: "tts.openai.speed"))
        XCTAssertNil(VoiceConfigurationParser.validationMessage(for: "0.25", key: "tts.openai.speed"))
        XCTAssertNil(VoiceConfigurationParser.validationMessage(for: "4.0", key: "tts.openai.speed"))
        XCTAssertNil(VoiceConfigurationParser.validationMessage(for: "0,25", key: "tts.openai.speed"))
        XCTAssertNil(VoiceConfigurationParser.validationMessage(for: "", key: "tts.openai.speed"))
        XCTAssertNil(VoiceConfigurationParser.validationMessage(for: "   ", key: "tts.openai.speed"))
        XCTAssertNil(VoiceConfigurationParser.validationMessage(for: "", key: "tts.openai.base_url"))
        XCTAssertNotNil(VoiceConfigurationParser.validationMessage(for: "0.1", key: "tts.openai.speed"))
        XCTAssertNotNil(VoiceConfigurationParser.validationMessage(for: "4.5", key: "tts.openai.speed"))
        XCTAssertNotNil(VoiceConfigurationParser.validationMessage(for: "0,1", key: "tts.openai.speed"))
        XCTAssertNotNil(VoiceConfigurationParser.validationMessage(for: "fast", key: "tts.openai.speed"))
    }

    /// Clearing speed (empty or whitespace-only) removes the override key
    /// from the profile config — upstream's `.get("speed", default)`
    /// fallback then applies — and the snapshot no longer carries the key.
    func testClearingOpenAISpeedRemovesTheOverride() async throws {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": [
                "stt": ["enabled": true, "provider": "openai"],
                "tts": ["provider": "openai", "openai": ["speed": 1.5, "voice": "alloy"]]
            ],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.save(value: "  ", for: "tts.openai.speed")

        XCTAssertTrue(saved)
        let configPUT = requester.recorded.first { $0.method == "PUT" && $0.path == "/api/config" }
        let openai = try XCTUnwrap(
            ((configPUT?.body?["config"] as? [String: Any])?["tts"] as? [String: Any])?["openai"] as? [String: Any]
        )
        XCTAssertNil(openai["speed"])
        XCTAssertEqual(openai["voice"] as? String, "alloy")
        XCTAssertNil(service.snapshot.values["tts.openai.speed"])
    }

    /// Locale canonicalization is scoped to the validated ranged decimal:
    /// an unrelated non-ranged decimal value such as a StepFun sample rate
    /// of "24,000" must pass through untouched.
    func testCommaCanonicalizationDoesNotRewriteUnrangedDecimalFields() {
        XCTAssertEqual(
            VoiceConfigurationParser.storedValue(for: "1,5", key: "tts.openai.speed"),
            "1.5"
        )
        XCTAssertEqual(
            VoiceConfigurationParser.storedValue(for: "24,000", key: "tts.stepfun.sample_rate"),
            "24,000"
        )
        XCTAssertNil(VoiceConfigurationParser.validationMessage(for: "24,000", key: "tts.stepfun.sample_rate"))
    }

    /// Comma-decimal input from locale decimal pads is canonicalized to the
    /// "." form Hermes parses with float().
    func testSavingCommaDecimalSpeedIsCanonicalizedForHermes() async throws {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": [
                "stt": ["enabled": true, "provider": "openai"],
                "tts": ["provider": "openai"]
            ],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.save(value: "1,5", for: "tts.openai.speed")

        XCTAssertTrue(saved)
        let configPUT = requester.recorded.first { $0.method == "PUT" && $0.path == "/api/config" }
        let openai = try XCTUnwrap(
            ((configPUT?.body?["config"] as? [String: Any])?["tts"] as? [String: Any])?["openai"] as? [String: Any]
        )
        XCTAssertEqual(openai["speed"] as? String, "1.5")
        XCTAssertEqual(service.snapshot.values["tts.openai.speed"], "1.5")
    }

    /// The save path must refuse an out-of-range speed before any config
    /// write reaches the gateway.
    func testSavingOutOfRangeOpenAISpeedIsRejectedBeforeConfigWrite() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": ["stt": ["enabled": true, "provider": "openai"], "tts": ["provider": "openai"]],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.save(value: "9", for: "tts.openai.speed")

        XCTAssertFalse(saved)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertFalse(requester.recorded.contains { $0.method == "PUT" && $0.path == "/api/config" })
    }

    /// A configured custom endpoint parses into the snapshot values and the
    /// OpenAI provider's editable fields.
    func testConfiguredOpenAIBaseURLParsesIntoSnapshotAndFields() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default", schema: nil,
            config: [
                "stt": ["enabled": true, "provider": "openai"],
                "tts": ["provider": "openai", "openai": ["base_url": "https://tts.example.com/v1", "speed": 1.5]]
            ],
            sttReadiness: ["providers": []],
            ttsReadiness: ["providers": [["name": "OpenAI TTS", "tts_provider": "openai", "status": "ready", "is_active": true]]],
            environment: [:],
            ttsToolsetConfigAvailable: true
        )

        XCTAssertEqual(snapshot.values["tts.openai.base_url"], "https://tts.example.com/v1")
        XCTAssertEqual(snapshot.values["tts.openai.speed"], "1.5")
        let openai = snapshot.ttsProviders.first { $0.descriptor.id == "openai" }
        XCTAssertTrue(openai?.fields.contains { $0.key == "tts.openai.base_url" } ?? false)
        XCTAssertTrue(openai?.fields.contains { $0.key == "tts.openai.speed" } ?? false)
    }

    /// Field saves flow through the profile-scoped full-document config
    /// write — the exact dotted key, under the profile's request scope, with
    /// pre-existing provider values preserved.
    func testSavingOpenAIBaseURLWritesProfileScopedConfigKey() async throws {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config?profile=research": [
                "stt": ["enabled": true, "provider": "openai"],
                "tts": ["provider": "openai", "openai": ["voice": "alloy"]]
            ],
            "/api/tools/toolsets/stt/config?profile=research": ["providers": []],
            "/api/tools/toolsets/tts/config?profile=research": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "research")
        await service.reload()

        let saved = await service.save(value: "https://tts.example.com/v1", for: "tts.openai.base_url")

        XCTAssertTrue(saved)
        let configPUT = requester.recorded.first { $0.method == "PUT" && $0.path == "/api/config?profile=research" }
        let tts = try XCTUnwrap((configPUT?.body?["config"] as? [String: Any])?["tts"] as? [String: Any])
        let openai = try XCTUnwrap(tts["openai"] as? [String: Any])
        XCTAssertEqual(openai["base_url"] as? String, "https://tts.example.com/v1")
        XCTAssertEqual(openai["voice"] as? String, "alloy")
        XCTAssertEqual(service.snapshot.values["tts.openai.base_url"], "https://tts.example.com/v1")
    }

    /// Clearing a text override REMOVES the key from the profile config
    /// rather than writing an empty string: Hermes reads provider keys with
    /// `config.get(key, default)`, which only applies the default when the
    /// key is absent — a stored "" would be used verbatim and break
    /// synthesis. Removal is behavior-identical for keys upstream treats as
    /// unset when empty (`base_url`'s falsy-or chains).
    func testClearingOpenAIBaseURLRemovesTheOverride() async throws {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": [
                "stt": ["enabled": true, "provider": "openai"],
                "tts": ["provider": "openai", "openai": ["base_url": "https://tts.example.com/v1", "voice": "alloy"]]
            ],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()
        XCTAssertEqual(service.snapshot.values["tts.openai.base_url"], "https://tts.example.com/v1")

        // Whitespace-only input is a clear, never a persisted override.
        let saved = await service.save(value: "   ", for: "tts.openai.base_url")

        XCTAssertTrue(saved)
        let configPUT = requester.recorded.first { $0.method == "PUT" && $0.path == "/api/config" }
        let openai = try XCTUnwrap(
            ((configPUT?.body?["config"] as? [String: Any])?["tts"] as? [String: Any])?["openai"] as? [String: Any]
        )
        XCTAssertNil(openai["base_url"])
        // Unrelated provider values survive the removal.
        XCTAssertEqual(openai["voice"] as? String, "alloy")
        XCTAssertNil(service.snapshot.values["tts.openai.base_url"])
    }

    /// Clearing the ElevenLabs voice override removes `voice_id` entirely
    /// (upstream reads it with `.get(key, DEFAULT)`), prunes the provider
    /// section when it becomes empty, and leaves the snapshot consistent
    /// with an absent override.
    func testClearingElevenLabsVoiceIDRemovesTheOverride() async throws {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": [
                "stt": ["enabled": true, "provider": "local"],
                "tts": ["provider": "elevenlabs", "elevenlabs": ["voice_id": "custom-voice"]]
            ],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.save(value: "", for: "tts.elevenlabs.voice_id")

        XCTAssertTrue(saved)
        let configPUT = requester.recorded.first { $0.method == "PUT" && $0.path == "/api/config" }
        let tts = try XCTUnwrap((configPUT?.body?["config"] as? [String: Any])?["tts"] as? [String: Any])
        // The emptied section is pruned so no empty {} lingers in config.
        XCTAssertNil(tts["elevenlabs"])
        XCTAssertEqual(tts["provider"] as? String, "elevenlabs")
        XCTAssertNil(service.snapshot.values["tts.elevenlabs.voice_id"])
    }

    /// A failed config PUT must leave the snapshot matching the server: the
    /// in-memory values only update once the write is confirmed, so the
    /// settings UI never shows a cleared override that did not persist.
    func testFailedClearKeepsSnapshotConsistentWithServer() async {
        let requester = MockVoiceConfigurationRequester()
        requester.routes = [
            "/api/config": [
                "stt": ["enabled": true, "provider": "openai"],
                "tts": ["provider": "openai", "openai": ["base_url": "https://tts.example.com/v1"]]
            ],
            "/api/tools/toolsets/stt/config": ["providers": []],
            "/api/tools/toolsets/tts/config": ["providers": []]
        ]
        requester.failingPUTPaths = ["/api/config"]
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")
        await service.reload()

        let saved = await service.save(value: "", for: "tts.openai.base_url")

        XCTAssertFalse(saved)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(service.snapshot.values["tts.openai.base_url"], "https://tts.example.com/v1")
    }

    /// Hermes keys ElevenLabs TTS as `voice_id`/`model_id`
    /// (tools/tts_tool_providers.py) and reads `base_url` for both
    /// whole-file and streaming synthesis. The old generic
    /// `voice`/`model`/`language` keys were never read there.
    func testElevenLabsTTSFieldsTargetUpstreamKeys() {
        let fields = VoiceConfigurationParser.typedFields(id: "elevenlabs", kind: .tts)
        XCTAssertEqual(fields.first { $0.key == "tts.elevenlabs.voice_id" }?.kind, .text)
        XCTAssertEqual(fields.first { $0.key == "tts.elevenlabs.model_id" }?.kind, .text)
        XCTAssertEqual(fields.first { $0.key == "tts.elevenlabs.base_url" }?.kind, .text)
        XCTAssertFalse(fields.contains { $0.key == "tts.elevenlabs.model" })
        XCTAssertFalse(fields.contains { $0.key == "tts.elevenlabs.voice" })
        XCTAssertFalse(fields.contains { $0.key == "tts.elevenlabs.language" })
        XCTAssertFalse(fields.contains { $0.key == "tts.elevenlabs.instruction" })
    }

    /// Provider-specific editors stay scoped: openai/elevenlabs fields must
    /// not leak into other providers' editors, and unknown providers keep
    /// the full generic surface (plugin configs live in their own sections
    /// upstream).
    func testProviderSpecificFieldsStayScopedToTheirProvider() {
        for id in ["stepfun", "xiaomi_mimo", "acme_voice"] {
            let fields = VoiceConfigurationParser.typedFields(id: id, kind: .tts)
            XCTAssertFalse(fields.contains { $0.key == "tts.openai.base_url" }, id)
            XCTAssertFalse(fields.contains { $0.key == "tts.openai.speed" }, id)
            XCTAssertFalse(fields.contains { $0.key == "tts.elevenlabs.base_url" }, id)
            XCTAssertTrue(fields.allSatisfy { $0.key.hasPrefix("tts.\(id).") }, id)
        }
        let unknown = VoiceConfigurationParser.typedFields(id: "acme_voice", kind: .tts)
        XCTAssertTrue(unknown.contains { $0.key == "tts.acme_voice.model" })
        XCTAssertTrue(unknown.contains { $0.key == "tts.acme_voice.language" })
        XCTAssertTrue(unknown.contains { $0.key == "tts.acme_voice.voice" })
        XCTAssertTrue(unknown.contains { $0.key == "tts.acme_voice.instruction" })
    }

    /// Streaming labels require positive evidence: a provider Conduit has no
    /// catalog entry for must not be labeled streaming-capable.
    func testUnknownTTSProviderDoesNotClaimStreamingCapability() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default", schema: nil,
            config: ["stt": ["enabled": true, "provider": "local"], "tts": ["provider": "acme_voice"]],
            sttReadiness: ["providers": []],
            ttsReadiness: ["providers": [["name": "Acme Voice", "tts_provider": "acme_voice", "status": "ready", "is_active": true]]],
            environment: [:],
            ttsToolsetConfigAvailable: true
        )

        let unknown = snapshot.ttsProviders.first { $0.descriptor.id == "acme_voice" }
        XCTAssertEqual(unknown?.descriptor.displayName, "Acme Voice")
        XCTAssertFalse(unknown?.descriptor.supportsStreaming ?? true)
    }

    /// Known streaming capability is catalogued from upstream evidence
    /// (StreamingTTSProvider registrations: elevenlabs, openai, gemini,
    /// xai) — and the claim stays attached to the right kind.
    func testKnownStreamingTTSProvidersCarryPositiveEvidence() {
        for id in ["elevenlabs", "xai", "gemini"] {
            XCTAssertEqual(VoiceConfigurationParser.catalogDescriptor(id: id, kind: .tts)?.supportsStreaming, true, id)
        }
        XCTAssertEqual(VoiceConfigurationParser.catalogDescriptor(id: "elevenlabs", kind: .stt)?.supportsStreaming, false)
    }

    /// Profiles configured before the ElevenLabs key fix may still carry the
    /// legacy `voice`/`model`/`language` values. They stay visible in the
    /// parsed values (so nothing is silently dropped), but no editor is
    /// offered because upstream never reads them.
    func testLegacyElevenLabsKeysRemainParsedWithoutEditors() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default", schema: nil,
            config: [
                "stt": ["enabled": true, "provider": "local"],
                "tts": [
                    "provider": "elevenlabs",
                    "elevenlabs": ["voice": "legacy-voice", "model": "legacy-model", "voice_id": "current-voice"]
                ]
            ],
            sttReadiness: ["providers": []],
            ttsReadiness: ["providers": [["name": "ElevenLabs", "tts_provider": "elevenlabs", "status": "ready", "is_active": true]]],
            environment: [:],
            ttsToolsetConfigAvailable: true
        )

        XCTAssertEqual(snapshot.values["tts.elevenlabs.voice"], "legacy-voice")
        XCTAssertEqual(snapshot.values["tts.elevenlabs.model"], "legacy-model")
        let elevenlabs = snapshot.ttsProviders.first { $0.descriptor.id == "elevenlabs" }
        XCTAssertFalse(elevenlabs?.fields.contains { $0.key == "tts.elevenlabs.voice" } ?? true)
        XCTAssertFalse(elevenlabs?.fields.contains { $0.key == "tts.elevenlabs.model" } ?? true)
        XCTAssertTrue(elevenlabs?.fields.contains { $0.key == "tts.elevenlabs.voice_id" } ?? false)
    }
}

@MainActor
private final class MockVoiceConfigurationRequester: VoiceConfigurationRequesting {
    var routes: [String: [String: Any]] = [:]
    /// Paths whose PUT requests must fail (route-missing already fails GETs
    /// and PUTs alike; this simulates a read-succeeds/write-fails gateway).
    var failingPUTPaths: Set<String> = []
    private(set) var recorded: [(path: String, method: String, body: [String: Any]?)] = []

    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        recorded.append((path: path, method: method, body: body))
        if method == "PUT", failingPUTPaths.contains(path) {
            throw DashboardTicketBridgeError.requestFailed("Mock PUT failure for \(path)")
        }
        guard let response = routes[path] else {
            throw DashboardTicketBridgeError.requestFailed("No mock response for \(path)")
        }
        return response
    }
}
