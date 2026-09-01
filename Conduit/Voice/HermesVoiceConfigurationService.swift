//
//  HermesVoiceConfigurationService.swift
//  Conduit
//
//  Profile-scoped voice configuration is intentionally kept on the Hermes
//  host. This client only reads redacted credential metadata and submits a new
//  value when the user explicitly saves one.
//

import Combine
import Foundation

struct VoiceCredentialStatus: Equatable, Identifiable {
    let key: String
    let isSet: Bool
    let description: String

    var id: String { key }
}

struct VoiceProviderReadiness: Equatable, Identifiable {
    let id: String
    let kind: VoiceProviderDescriptor.Kind
    let status: String
    let isActive: Bool
    /// The gateway's own picker row label. Provider selection is submitted
    /// under this name so Hermes — not Conduit — owns the row→config mapping.
    let displayName: String
    /// Structured marker for the managed Nous route, set once at parse time
    /// from upstream semantics (`managed_nous_feature` for the row's kind, or
    /// the legacy managed-row label). Selection writes for these rows are
    /// server-owned: when the toolset provider endpoint is unavailable they
    /// must fail closed, never fall back to a raw config write of "nous".
    let isManagedNous: Bool
    let requiredCredentials: [VoiceCredentialStatus]
}

struct VoiceTypedField: Equatable, Identifiable {
    enum Kind: Equatable { case text, decimal, choice([String]) }

    let key: String
    let label: String
    let help: String
    let kind: Kind
    let defaultValue: String

    var id: String { key }
}

struct VoiceProviderConfiguration: Equatable, Identifiable {
    let descriptor: VoiceProviderDescriptor
    let fields: [VoiceTypedField]
    let readiness: VoiceProviderReadiness?

    var id: String { "\(descriptor.kind.rawValue).\(descriptor.id)" }
}

struct VoiceConfigurationSnapshot: Equatable {
    var profile: String
    var capability: VoiceCapabilitySnapshot
    var sttProviders: [VoiceProviderConfiguration]
    var ttsProviders: [VoiceProviderConfiguration]
    var selectedSTTProvider: String
    var selectedTTSProvider: String
    /// Values are explicit strings, never credential values.
    var values: [String: String]
    var credentials: [VoiceCredentialStatus]

    static func unavailable(profile: String, reason: String) -> Self {
        .init(
            profile: profile,
            capability: .init(
                isGatewayConnected: false,
                supportsTranscription: false,
                supportsSpeech: false,
                unavailableReason: reason
            ),
            sttProviders: [], ttsProviders: [], selectedSTTProvider: "",
            selectedTTSProvider: "", values: [:], credentials: []
        )
    }
}

/// A small adapter protocol makes the schema/config parser deterministic in
/// tests without exposing WebKit or dashboard cookies to the view layer.
@MainActor
protocol VoiceConfigurationRequesting: AnyObject {
    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any]
}

@MainActor
extension DashboardTicketBridge: VoiceConfigurationRequesting {
    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        try await requestJSON(path: path, method: method, body: body, timeoutMilliseconds: 12_000)
    }
}

@MainActor
final class HermesVoiceConfigurationService: ObservableObject {
    @Published private(set) var snapshot: VoiceConfigurationSnapshot
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let requester: VoiceConfigurationRequesting
    let profile: String

    init(requester: VoiceConfigurationRequesting, profile: String) {
        self.requester = requester
        self.profile = profile
        snapshot = .unavailable(profile: profile, reason: "Voice settings have not been loaded.")
    }

    convenience init(bridge: DashboardTicketBridge, profile: String) {
        self.init(requester: bridge, profile: profile)
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        async let schemaResult = result(for: "/api/config/schema")
        async let configResult = result(for: "/api/config")
        async let sttResult = result(for: "/api/tools/toolsets/stt/config")
        async let ttsResult = result(for: "/api/tools/toolsets/tts/config")
        async let environmentResult = result(for: "/api/env")

        let schema = await schemaResult
        let config = await configResult
        let stt = await sttResult
        let tts = await ttsResult
        let environment = await environmentResult

        guard case .success(let configObject) = config else {
            let reason = "This gateway does not expose Hermes voice configuration. Text chat is unchanged."
            snapshot = .unavailable(profile: profile, reason: reason)
            errorMessage = Self.message(from: config)
            return
        }

        let parsed = VoiceConfigurationParser.parse(
            profile: profile,
            schema: try? schema.get(),
            config: configObject,
            sttReadiness: try? stt.get(),
            ttsReadiness: try? tts.get(),
            environment: try? environment.get(),
            // STT toolset readiness is intentionally NOT passed to the
            // parser: it cannot influence transcription capability, only the
            // picker population and diagnostics built from its rows.
            ttsToolsetConfigAvailable: (try? tts.get()) != nil
        )
        snapshot = parsed
        // Toolset config was added after some public gateways. Its absence is
        // a capability limitation, not a failed text-chat connection.
        if (try? stt.get()) == nil && (try? tts.get()) == nil {
            errorMessage = "This Hermes gateway is too old to report voice readiness."
        }
    }

    /// Provider selection follows the Hermes client contract: when the row
    /// came from the toolset readiness matrix, its display name is submitted
    /// to the toolset provider endpoint and the GATEWAY owns the config write
    /// (managed "Nous Subscription" rows become `stt.provider = nous` on
    /// current Hermes and the gateway-intent equivalent on older ones).
    /// Writing a Conduit-side ID such as "nous" directly would corrupt the
    /// profile config on gateways that predate that value.
    func saveProvider(_ provider: String, kind: VoiceProviderDescriptor.Kind) async -> Bool {
        let providers = kind == .stt ? snapshot.sttProviders : snapshot.ttsProviders
        guard let row = providers.first(where: { $0.descriptor.id == provider })?.readiness else {
            // Schema-only provider (gateway without toolset readiness). The
            // raw ID is a plain vendor config value, safe to write directly —
            // except the canonical managed Nous ID, whose meaning is
            // server-owned and never written raw.
            guard provider.lowercased() != "nous" else {
                errorMessage = "Hermes must translate this managed selection; its provider endpoint is unavailable."
                return false
            }
            return await saveVendorSelection(provider, kind: kind)
        }
        if await saveProviderSelection(rowName: row.displayName, kind: kind) { return true }
        // The toolset endpoint failed. Managed Nous rows must fail closed:
        // "nous" is only meaningful on gateways whose provider endpoint
        // translates the row, so it is never raw-written through the legacy
        // config fallback. Vendor rows carry IDs that ARE the config values
        // upstream persists, so their legacy write stays safe.
        guard !row.isManagedNous else { return false }
        errorMessage = nil
        return await saveVendorSelection(provider, kind: kind)
    }

    /// Legacy provider-selection fallback for gateways whose toolset provider
    /// endpoint is unavailable. Writes the section atomically the way
    /// upstream's single-provider selection model expects: the vendor value
    /// lands in `<section>.provider` and any stale `use_gateway`
    /// gateway-routing intent is removed — a leftover `use_gateway: true`
    /// would override the user's fresh BYOK selection on legacy runtimes.
    /// Like the other config editors, this is a full-document GET→PUT, so a
    /// concurrent profile-config edit from another writer could be clobbered;
    /// the single-writer UI flow makes that a deliberate, pre-existing
    /// trade-off rather than a new one.
    private func saveVendorSelection(_ vendor: String, kind: VoiceProviderDescriptor.Kind) async -> Bool {
        let sectionKey = kind.rawValue
        guard var config = try? await requester.requestJSON(path: profilePath("/api/config"), method: "GET", body: nil) else {
            errorMessage = "Could not load voice settings to save this change."
            return false
        }
        var section = config[sectionKey] as? [String: Any] ?? [:]
        section["provider"] = vendor
        section.removeValue(forKey: "use_gateway")
        config[sectionKey] = section
        do {
            _ = try await requester.requestJSON(
                path: profilePath("/api/config"), method: "PUT",
                body: ["config": config]
            )
            await reload()
            return true
        } catch {
            errorMessage = "Could not save \(sectionKey).provider: \(error.localizedDescription)"
            return false
        }
    }

    private func saveProviderSelection(rowName: String, kind: VoiceProviderDescriptor.Kind) async -> Bool {
        do {
            let response = try await requester.requestJSON(
                path: profilePath("/api/tools/toolsets/\(kind.rawValue)/provider"),
                method: "PUT",
                body: ["provider": rowName]
            )
            if let error = response["error"] as? String, !error.isEmpty {
                errorMessage = "Could not select \(rowName): \(error)"
                return false
            }
            await reload()
            if response["needs_nous_auth"] as? Bool == true {
                // The write landed; Hermes is flagging that the managed route
                // still needs sign-in. Diagnostic, never a silent failure.
                let feature = kind == .stt ? "speech-to-text" : "speech"
                errorMessage = "Hermes saved this selection, but the Nous subscription needs sign-in before \(feature) can use it."
            }
            return true
        } catch {
            errorMessage = "Could not select \(rowName): \(error.localizedDescription)"
            return false
        }
    }

    func save(value: String, for key: String) async -> Bool {
        guard var config = try? await requester.requestJSON(path: profilePath("/api/config"), method: "GET", body: nil) else {
            errorMessage = "Could not load voice settings to save this change."
            return false
        }
        Self.setNested(value, in: &config, dottedKey: key)
        do {
            _ = try await requester.requestJSON(
                path: profilePath("/api/config"), method: "PUT",
                body: ["config": config]
            )
            snapshot.values[key] = value
            if key == "stt.provider" { snapshot.selectedSTTProvider = value }
            if key == "tts.provider" { snapshot.selectedTTSProvider = value }
            return true
        } catch {
            errorMessage = "Could not save \(key): \(error.localizedDescription)"
            return false
        }
    }

    /// This deliberately never requests `/api/env/reveal`; the only read
    /// state in Conduit is whether a credential is configured.
    func saveCredential(_ value: String, key: String) async -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            _ = try await requester.requestJSON(
                path: profilePath("/api/env"), method: "PUT",
                body: ["key": key, "value": value, "profile": profile]
            )
            replaceCredential(VoiceCredentialStatus(key: key, isSet: true, description: credentialDescription(key)))
            await reload()
            return true
        } catch {
            errorMessage = "Could not save credential: \(error.localizedDescription)"
            return false
        }
    }

    /// Call after a live voice operation reports that a route is absent. This
    /// does not disconnect Hermes or change ordinary text-chat capabilities.
    func markAudioEndpointUnavailable(kind: VoiceProviderDescriptor.Kind, reason: String) {
        switch kind {
        case .stt: snapshot.capability.supportsTranscription = false
        case .tts: snapshot.capability.supportsSpeech = false
        }
        snapshot.capability.unavailableReason = reason
    }

    private func result(for path: String) async -> Result<[String: Any], Error> {
        do { return .success(try await requester.requestJSON(path: profilePath(path), method: "GET", body: nil)) }
        catch { return .failure(error) }
    }

    private func profilePath(_ path: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    private func replaceCredential(_ credential: VoiceCredentialStatus) {
        snapshot.credentials.removeAll { $0.key == credential.key }
        snapshot.credentials.append(credential)
        snapshot.credentials.sort { $0.key < $1.key }
    }

    private func credentialDescription(_ key: String) -> String {
        snapshot.credentials.first(where: { $0.key == key })?.description ?? key
    }

    private static func message(from result: Result<[String: Any], Error>) -> String? {
        if case .failure(let error) = result { return error.localizedDescription }
        return nil
    }

    private static func setNested(_ value: String, in object: inout [String: Any], dottedKey: String) {
        let pieces = dottedKey.split(separator: ".").map(String.init)
        guard let leaf = pieces.last else { return }
        setNested(value, in: &object, path: Array(pieces.dropLast()), leaf: leaf)
    }

    private static func setNested(_ value: String, in object: inout [String: Any], path: [String], leaf: String) {
        guard let key = path.first else { object[leaf] = value; return }
        var child = object[key] as? [String: Any] ?? [:]
        setNested(value, in: &child, path: Array(path.dropFirst()), leaf: leaf)
        object[key] = child
    }
}

enum VoiceConfigurationParser {
    static func parse(
        profile: String,
        schema: [String: Any]?,
        config: [String: Any],
        sttReadiness: [String: Any]?,
        ttsReadiness: [String: Any]?,
        environment: [String: Any]?,
        ttsToolsetConfigAvailable: Bool
    ) -> VoiceConfigurationSnapshot {
        let selectedSTT = nestedString(config, "stt.provider") ?? "local"
        let selectedTTS = nestedString(config, "tts.provider") ?? "edge"
        let readiness = readinessRows(sttReadiness, kind: .stt) + readinessRows(ttsReadiness, kind: .tts)
        let credentials = mergedCredentials(
            credentialRows(environment) + readiness.flatMap(\.requiredCredentials)
        )
        let schemaProviderIDs = providerIDs(schema)
        let sttIDs = unique(schemaProviderIDs.stt + readiness.filter { $0.kind == .stt }.map(\.id) + [selectedSTT])
        let ttsIDs = unique(schemaProviderIDs.tts + readiness.filter { $0.kind == .tts }.map(\.id) + [selectedTTS])
        let values = allVoiceValues(config)

        let stt = sttIDs.map { id in providerConfiguration(id: id, kind: .stt, readiness: readiness, credentials: credentials) }
        let tts = ttsIDs.map { id in providerConfiguration(id: id, kind: .tts, readiness: readiness, credentials: credentials) }
        let sttEnabled = nestedBool(config, "stt.enabled") ?? true
        let selectedTTSReady = selectedProviderIsReady(tts, selectedID: selectedTTS)
        // Hermes Desktop's dictation principle: once the profile config is
        // loaded, `stt.enabled != false` is the only capability gate. The
        // toolset readiness response is picker/diagnostic surface — its
        // availability says nothing about POST /api/audio/transcribe, and its
        // metadata cannot model every runtime credential source
        // (stt.openai.api_key, VOICE_TOOLS_OPENAI_KEY, OPENAI_API_KEY,
        // managed Nous sign-in). A real endpoint problem surfaces from the
        // actual transcription attempt.
        let supportsTranscription = sttEnabled
        let supportsSpeech = ttsToolsetConfigAvailable && selectedTTSReady
        let unavailableReason: String?
        if !sttEnabled {
            unavailableReason = "Speech-to-text is disabled for this Hermes profile."
        } else if !supportsSpeech {
            unavailableReason = "The selected text-to-speech provider is not ready for this profile."
        } else {
            unavailableReason = nil
        }
        let capability = VoiceCapabilitySnapshot(
            isGatewayConnected: true,
            supportsTranscription: supportsTranscription,
            supportsSpeech: supportsSpeech,
            unavailableReason: unavailableReason
        )
        return .init(
            profile: profile, capability: capability, sttProviders: stt, ttsProviders: tts,
            selectedSTTProvider: selectedSTT, selectedTTSProvider: selectedTTS,
            values: values, credentials: credentials
        )
    }

    private static func providerConfiguration(
        id: String, kind: VoiceProviderDescriptor.Kind,
        readiness: [VoiceProviderReadiness], credentials: [VoiceCredentialStatus]
    ) -> VoiceProviderConfiguration {
        let catalog = catalogDescriptor(id: id, kind: kind)
        let descriptor = catalog ?? VoiceProviderDescriptor(
            id: id, displayName: id.replacingOccurrences(of: "_", with: " ").capitalized,
            kind: kind, supportsStreaming: kind == .tts
        )
        let row = readiness.first { $0.id == id && $0.kind == kind }
        let fields = typedFields(id: id, kind: kind)
        let required = row?.requiredCredentials ?? credentials.filter { credential in
            (id == "stepfun" && credential.key == "STEPFUN_API_KEY") ||
            (id == "xiaomi_mimo" && credential.key == "MIMO_API_KEY")
        }
        return .init(descriptor: descriptor, fields: fields, readiness: row.map {
            .init(id: $0.id, kind: $0.kind, status: $0.status, isActive: $0.isActive, displayName: $0.displayName, isManagedNous: $0.isManagedNous, requiredCredentials: required)
        })
    }

    /// Display catalog matching Hermes' current STT picker. Providers outside
    /// this table (plugin rows such as StepFun/Xiaomi MiMo, or future
    /// gateways) fall back to a generated descriptor and still work.
    static func catalogDescriptor(id: String, kind: VoiceProviderDescriptor.Kind) -> VoiceProviderDescriptor? {
        switch (id, kind) {
        case ("local", .stt):
            return .init(id: id, displayName: "Local", kind: kind, models: ["tiny", "base", "small", "medium", "large-v3"], supportsStreaming: false)
        case ("nous", .stt), ("openai", .stt):
            // The managed Nous route resolves models from the same
            // OpenAI-compatible catalog as the direct key.
            return .init(id: id, displayName: id == "nous" ? "Nous Subscription" : "OpenAI", kind: kind, models: ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "gpt-transcribe"], supportsStreaming: false)
        case ("groq", .stt):
            return .init(id: id, displayName: "Groq", kind: kind, models: ["whisper-large-v3-turbo", "whisper-large-v3", "distil-whisper-large-v3-en"], supportsStreaming: false)
        case ("xai", .stt):
            return .init(id: id, displayName: "xAI", kind: kind, supportsStreaming: false)
        case ("elevenlabs", .stt):
            return .init(id: id, displayName: "ElevenLabs Scribe", kind: kind, supportsStreaming: false)
        case ("deepinfra", .stt):
            return .init(id: id, displayName: "DeepInfra", kind: kind, supportsStreaming: false)
        case ("nous", .tts):
            return .init(id: id, displayName: "Nous Subscription", kind: kind, supportsStreaming: true)
        case ("openai", .tts):
            return .init(id: id, displayName: "OpenAI", kind: kind, supportsStreaming: true)
        case ("stepfun", .stt):
            return .init(id: id, displayName: "StepFun", kind: kind, models: ["stepaudio-2.5-asr", "step-asr"], supportsStreaming: false)
        case ("stepfun", .tts):
            return .init(id: id, displayName: "StepFun", kind: kind, models: ["stepaudio-2.5-tts"], voices: [], supportsStreaming: true)
        case ("xiaomi_mimo", .stt):
            return .init(id: id, displayName: "Xiaomi MiMo", kind: kind, models: ["mimo-v2.5-asr"], supportsStreaming: false)
        case ("xiaomi_mimo", .tts):
            return .init(id: id, displayName: "Xiaomi MiMo", kind: kind, models: ["mimo-v2.5-tts"], voices: ["mimo_default", "冰糖", "茉莉", "苏打", "白桦", "Mia", "Chloe", "Milo", "Dean"], supportsStreaming: true)
        default: return nil
        }
    }

    static func typedFields(id: String, kind: VoiceProviderDescriptor.Kind) -> [VoiceTypedField] {
        // The managed Nous selection shares the vendor's config section
        // upstream (Hermes resolves stt.nous through stt.openai), so its
        // editors must read and write the vendor keys.
        let root = id == "nous" ? "\(kind.rawValue).openai" : "\(kind.rawValue).\(id)"
        // Hermes keys the ElevenLabs STT model `stt.elevenlabs.model_id`.
        let modelKey = kind == .stt && id == "elevenlabs" ? "model_id" : "model"
        let defaultModel = id == "local" && kind == .stt ? "base" : ""
        var shared = [
            VoiceTypedField(key: "\(root).\(modelKey)", label: "Model", help: "You can enter any installed model identifier.", kind: .text, defaultValue: defaultModel),
            VoiceTypedField(key: "\(root).language", label: "Language", help: "Leave blank for automatic language detection.", kind: .text, defaultValue: "")
        ]
        if kind == .tts {
            let instructionKey = id == "xiaomi_mimo" ? "delivery_instructions" : "instruction"
            shared += [
                .init(key: "\(root).voice", label: "Voice ID", help: "Built-in voices are suggestions; custom voice IDs remain supported.", kind: .text, defaultValue: ""),
                .init(key: "\(root).\(instructionKey)", label: "Delivery instruction", help: "Optional speaking style guidance sent to the provider.", kind: .text, defaultValue: "")
            ]
        }
        if id == "stepfun" {
            shared += [
                .init(key: "\(root).endpoint_preset", label: "Endpoint", help: "Open Platform, Step Plan, International, or a custom endpoint.", kind: .choice(["open_platform", "step_plan", "international", "custom"]), defaultValue: "open_platform"),
                .init(key: "\(root).endpoint", label: "Custom endpoint", help: "Used only when Endpoint is Custom.", kind: .text, defaultValue: "")
            ]
            if kind == .tts {
                shared += [
                    .init(key: "\(root).speed", label: "Speed", help: "Provider speech-rate multiplier.", kind: .decimal, defaultValue: "1"),
                    .init(key: "\(root).volume", label: "Volume", help: "Provider output volume multiplier.", kind: .decimal, defaultValue: "1"),
                    .init(key: "\(root).sample_rate", label: "Sample rate", help: "PCM sample rate requested from Hermes.", kind: .decimal, defaultValue: "24000")
                ]
            }
        }
        return shared
    }

    private static func providerIDs(_ schema: [String: Any]?) -> (stt: [String], tts: [String]) {
        let fields = schema?["fields"] as? [[String: Any]] ?? []
        var stt: [String] = []
        var tts: [String] = []
        for field in fields {
            let key = (field["key"] as? String ?? field["name"] as? String ?? "").lowercased()
            guard key == "stt.provider" || key == "tts.provider" else { continue }
            let values = optionStrings(field["options"] ?? field["choices"])
            if key.hasPrefix("stt") { stt += values } else { tts += values }
        }
        return (unique(stt), unique(tts))
    }

    private static func optionStrings(_ value: Any?) -> [String] {
        if let strings = value as? [String] { return strings }
        if let rows = value as? [[String: Any]] {
            return rows.compactMap { $0["value"] as? String ?? $0["id"] as? String ?? $0["name"] as? String }
        }
        return []
    }

    private static func readinessRows(_ payload: [String: Any]?, kind: VoiceProviderDescriptor.Kind) -> [VoiceProviderReadiness] {
        let rows = payload?["providers"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            let id = providerID(for: row, kind: kind)
            guard let id, !id.isEmpty else { return nil }
            let envRows = row["env_vars"] as? [[String: Any]] ?? []
            let credentials = envRows.compactMap { item -> VoiceCredentialStatus? in
                guard let key = item["key"] as? String else { return nil }
                return .init(key: key, isSet: item["is_set"] as? Bool ?? false, description: item["prompt"] as? String ?? key)
            }
            let status: String
            if let text = row["status"] as? String { status = text }
            else if let object = row["status"] as? [String: Any] { status = object["state"] as? String ?? object["label"] as? String ?? "Unknown" }
            else { status = "Unknown" }
            // providerID resolves to "nous" only for the managed route (the
            // managed feature marker or the legacy managed-row label), so the
            // canonical ID doubles as the structured managed marker.
            return .init(id: id, kind: kind, status: status, isActive: row["is_active"] as? Bool ?? false, displayName: row["name"] as? String ?? id, isManagedNous: id == "nous", requiredCredentials: credentials)
        }
    }

    /// Hermes' toolset response keys each row by its picker label; only TTS
    /// rows additionally carry a `tts_provider` config key. Normalize rows to
    /// the provider IDs Hermes itself writes into `stt.provider`/`tts.provider`
    /// so Conduit never conflates two different routes.
    ///
    /// The managed "Nous Subscription" row is its own selection upstream:
    /// current Hermes writes `stt.provider = "nous"` (serviced by the
    /// OpenAI-compatible implementation through the managed gateway) while the
    /// direct "OpenAI" row writes `stt.provider = "openai"` with the user's
    /// own key. The two must stay distinct — the row's vendor field, when
    /// present, names the shared implementation, not the selection — so the
    /// managed flags decide identity before any vendor field is read.
    private static func providerID(for row: [String: Any], kind: VoiceProviderDescriptor.Kind) -> String? {
        let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if row["managed_nous_feature"] as? String == kind.rawValue || name.lowercased() == "nous subscription" {
            return "nous"
        }
        if kind == .stt, let id = row["stt_provider"] as? String, !id.isEmpty { return id }
        if kind == .tts, let id = row["tts_provider"] as? String, !id.isEmpty { return id }
        guard !name.isEmpty else { return nil }
        switch name.lowercased() {
        case "local whisper": return "local"
        case "openai", "openai tts": return "openai"
        case "elevenlabs scribe": return "elevenlabs"
        case "microsoft edge tts": return "edge"
        default: break
        }
        return name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .lowercased()
    }

    private static func credentialRows(_ payload: [String: Any]?) -> [VoiceCredentialStatus] {
        guard let payload else { return [] }
        return payload.compactMap { key, value in
            guard let row = value as? [String: Any], key == "STEPFUN_API_KEY" || key == "MIMO_API_KEY" else { return nil }
            return .init(key: key, isSet: row["is_set"] as? Bool ?? false, description: row["description"] as? String ?? key)
        }.sorted { $0.key < $1.key }
    }

    private static func mergedCredentials(_ values: [VoiceCredentialStatus]) -> [VoiceCredentialStatus] {
        var result: [String: VoiceCredentialStatus] = [:]
        for value in values {
            if let existing = result[value.key] {
                result[value.key] = .init(
                    key: value.key,
                    isSet: existing.isSet || value.isSet,
                    description: existing.description == existing.key ? value.description : existing.description
                )
            } else {
                result[value.key] = value
            }
        }
        return result.values.sorted { $0.key < $1.key }
    }

    private static func allVoiceValues(_ config: [String: Any]) -> [String: String] {
        var values: [String: String] = [:]
        for root in ["stt", "tts"] {
            guard let section = config[root] as? [String: Any] else { continue }
            flatten(section, prefix: root, output: &values)
        }
        return values
    }

    private static func flatten(_ object: [String: Any], prefix: String, output: inout [String: String]) {
        for (key, value) in object {
            let path = "\(prefix).\(key)"
            if let nested = value as? [String: Any] { flatten(nested, prefix: path, output: &output) }
            else if let text = value as? String { output[path] = text }
            else if let number = value as? NSNumber { output[path] = number.stringValue }
        }
    }

    private static func nestedString(_ object: [String: Any], _ key: String) -> String? {
        var current: Any = object
        for piece in key.split(separator: ".") {
            guard let map = current as? [String: Any], let next = map[String(piece)] else { return nil }
            current = next
        }
        return current as? String
    }

    private static func nestedBool(_ object: [String: Any], _ key: String) -> Bool? {
        var current: Any = object
        for piece in key.split(separator: ".") {
            guard let map = current as? [String: Any], let next = map[String(piece)] else { return nil }
            current = next
        }
        if let value = current as? Bool { return value }
        if let value = current as? NSNumber { return value.boolValue }
        if let value = current as? String {
            switch value.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    private static func selectedProviderIsReady(
        _ providers: [VoiceProviderConfiguration],
        selectedID: String
    ) -> Bool {
        guard let selected = providers.first(where: { $0.descriptor.id == selectedID }),
              let readiness = selected.readiness else { return false }
        return readiness.isActive && readiness.status.lowercased() == "ready"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || !seen.insert(value).inserted ? nil : value
        }
    }
}
