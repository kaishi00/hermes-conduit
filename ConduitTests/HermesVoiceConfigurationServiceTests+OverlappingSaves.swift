import XCTest
@testable import Conduit

/// #1004: config saves that overlap, on one settings page or two, each
/// keep the other's change. Before, both read the same old document and
/// the later PUT erased the earlier change (a speech server key saved a
/// moment before the address).
extension HermesVoiceConfigurationServiceTests {
    func testOverlappingConfigSavesKeepEachOthersChanges() async {
        let requester = SlowConfigRequester(config: ["stt": ["provider": "local"]])
        let voicePage = HermesVoiceConfigurationService(requester: requester, profile: "default")
        // The speech server page has a service of its own.
        let speechServerPage = HermesVoiceConfigurationService(requester: requester, profile: "default")

        async let key = speechServerPage.save(value: "sk-secret", for: SpeechServerSettingsView.apiKeyKey)
        async let url = speechServerPage.save(value: "http://10.0.0.2:8000", for: SpeechServerSettingsView.urlKey)
        async let live = voicePage.saveLiveTranscription(true)
        let saved = await [key, url, live]

        XCTAssertEqual(saved, [true, true, true])
        let server = (requester.config["voice"] as? [String: Any])?["speech_server"] as? [String: Any]
        XCTAssertEqual(server?["api_key"] as? String, "sk-secret")
        XCTAssertEqual(server?["url"] as? String, "http://10.0.0.2:8000")
        let stt = requester.config["stt"] as? [String: Any]
        XCTAssertEqual(stt?["streaming"] as? Bool, true)
        XCTAssertEqual(stt?["provider"] as? String, "local")
        XCTAssertEqual(requester.maximumInFlight, 1, "a GET→PUT ran while another was in flight")
    }

    func testAFailedSaveDoesNotHoldUpTheNextOne() async {
        let requester = SlowConfigRequester(config: [:])
        requester.failsPUTsSettingURL = true
        let service = HermesVoiceConfigurationService(requester: requester, profile: "default")

        // Either may reach the queue first: the address save fails either way.
        async let urlSave = service.save(value: "http://10.0.0.2:8000", for: SpeechServerSettingsView.urlKey)
        async let keySave = service.save(value: "sk-secret", for: SpeechServerSettingsView.apiKeyKey)
        let urlSaved = await urlSave
        let keySaved = await keySave

        XCTAssertFalse(urlSaved)
        XCTAssertTrue(keySaved)
        let server = (requester.config["voice"] as? [String: Any])?["speech_server"] as? [String: Any]
        XCTAssertNil(server?["url"])
        XCTAssertEqual(server?["api_key"] as? String, "sk-secret")
    }
}

/// One profile config document, with a pause in every request so
/// overlapping saves interleave unless something keeps them apart.
@MainActor
private final class SlowConfigRequester: VoiceConfigurationRequesting {
    private(set) var config: [String: Any]
    /// Refuses a PUT that sets the speech server address.
    var failsPUTsSettingURL = false
    private var inFlight = 0
    private(set) var maximumInFlight = 0

    init(config: [String: Any]) {
        self.config = config
    }

    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        guard path.hasPrefix("/api/config") || path.contains("/api/config?") else {
            throw DashboardTicketBridgeError.requestFailed("No mock response for \(path)")
        }
        switch method {
        case "GET":
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            let read = config
            for _ in 0..<5 { await Task.yield() }
            return read
        default:
            for _ in 0..<5 { await Task.yield() }
            inFlight -= 1
            let sent = body?["config"] as? [String: Any] ?? [:]
            let server = (sent["voice"] as? [String: Any])?["speech_server"] as? [String: Any]
            if failsPUTsSettingURL, server?["url"] != nil {
                throw DashboardTicketBridgeError.requestFailed("Mock PUT failure")
            }
            config = sent
            return ["ok": true]
        }
    }
}

extension HermesVoiceConfigurationServiceTests {
    /// Capabilities changes Hermes keeps in the profile config wait their
    /// turn with the config saves; keys, tests and reads don't.
    func testCapabilityWritesThatChangeTheConfigJoinTheQueue() {
        XCTAssertTrue(CapabilitiesStore.writesProfileConfig(method: "PUT", path: "/api/tools/toolsets/web/provider?profile=work"))
        XCTAssertTrue(CapabilitiesStore.writesProfileConfig(method: "PUT", path: "/api/mcp/servers/github/enabled"))
        XCTAssertTrue(CapabilitiesStore.writesProfileConfig(method: "DELETE", path: "/api/mcp/servers/github"))
        XCTAssertTrue(CapabilitiesStore.writesProfileConfig(method: "POST", path: "/api/mcp/catalog/install"))
        XCTAssertFalse(CapabilitiesStore.writesProfileConfig(method: "GET", path: "/api/mcp/servers"))
        XCTAssertFalse(CapabilitiesStore.writesProfileConfig(method: "PUT", path: "/api/env?profile=work"))
        XCTAssertFalse(CapabilitiesStore.writesProfileConfig(method: "POST", path: "/api/mcp/servers/github/test"))
    }
}
