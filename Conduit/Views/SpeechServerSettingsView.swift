//
//  SpeechServerSettingsView.swift
//  Conduit
//
//  Speech to text through the user's own speech server: its address, an
//  optional key, and a test the Hermes host runs against it. The settings
//  live in the profile's Hermes config (voice.speech_server), which the
//  notifier reads when it relays Conduit's audio.
//

import SwiftUI

struct SpeechServerSettingsView: View {
    @ObservedObject var service: HermesVoiceConfigurationService

    @State private var status: SpeechServerStatus?
    @State private var urlDraft = ""
    @State private var keyDraft = ""
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var testResult: SpeechServerTestResult?
    /// Why the last save failed, shown here rather than only at the top of
    /// the Voice screen.
    @State private var saveError: String?
    /// The profile whose saved values the drafts were loaded from.
    @State private var draftsProfile: String?

    static let urlKey = "voice.speech_server.url"
    static let apiKeyKey = "voice.speech_server.api_key"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your voice is recognized by a server you run, such as Hugging Face speech-to-speech or the one Hermes Live Voice starts. Hermes connects to it for Conduit, so it can run on another machine on your network.", systemImage: "server.rack")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)

            if let status, status.pluginMissing {
                Text(SpeechServerStatus.pluginMissingReason)
                    .scaledFont(.footnote)
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server address").scaledFont(.subheadline.weight(.semibold))
                    TextField(text: $urlDraft, prompt: Text(verbatim: "ws://192.168.1.20:8765/v1/realtime")) {
                        Text("Server address")
                    }
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { Task { await saveURL() } }
                        .accessibilityIdentifier("voice.speechServer.url")
                    Text("Plain ws:// works for home network and Tailscale addresses. A server on the internet needs wss://.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Key").scaledFont(.subheadline.weight(.semibold))
                        Spacer()
                        Text(status?.hasKey == true ? AppLocalization.string("Set") : AppLocalization.string("None"))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SecureField("Optional, for a server behind a login", text: $keyDraft)
                        .accessibilityLabel(Text("Key"))
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("voice.speechServer.key")
                }

                HStack(spacing: 16) {
                    Button("Save") { Task { await saveAll() } }
                        .disabled(isSaving || !hasChanges)
                    Button {
                        Task { await runTest(profile: draftsProfile) }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(isTesting || isSaving || status?.configured != true)
                    .accessibilityLabel(Text("Test connection"))
                    .accessibilityIdentifier("voice.speechServer.test")
                    Spacer()
                    if status?.hasKey == true {
                        Button("Remove key", role: .destructive) { Task { await removeKey() } }
                            .scaledFont(.footnote)
                            .disabled(isSaving)
                    }
                }
                .buttonStyle(.borderless)

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("voice.speechServer.saveError")
                }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(testResult.connected ? .green : .orange)
                        .accessibilityIdentifier("voice.speechServer.testResult")
                } else if let status, status.configured, !status.available, let reason = status.reason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("voice.speechServer.statusReason")
                }
            }
        }
        .task(id: service.profile) { await load() }
    }

    private var savedURL: String { status?.url ?? "" }

    private var hasChanges: Bool {
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return url != savedURL || !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A profile switch starts from that profile's saved values.
    private func load() async {
        draftsProfile = service.profile
        status = nil
        urlDraft = ""
        keyDraft = ""
        testResult = nil
        saveError = nil
        let loaded = await service.speechServerStatus()
        // A newer profile switch replaced this load.
        guard !Task.isCancelled else { return }
        status = loaded
        urlDraft = loaded.url ?? ""
    }

    private func saveURL() async {
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url != savedURL else { return }
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        saveError = nil
        let profile = draftsProfile
        let saved = await save(url, for: Self.urlKey, profile: profile)
        await refreshStatus(submittedURL: saved ? url : nil, profile: profile)
    }

    private func saveAll() async {
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        saveError = nil
        // The drafts belong to this profile. A switch during a save loads the
        // new profile's values; nothing after the switch may touch them, or
        // clearing a key that happens to match would empty the new profile's
        // draft. `draftsProfile` is view state, so it reads the profile now
        // on screen, not the one this call's copy of the view captured.
        let profile = draftsProfile
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var submitted: String?
        if url != savedURL {
            guard await save(url, for: Self.urlKey, profile: profile), draftsProfile == profile else { return }
            submitted = url
        }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            let saved = await save(key, for: Self.apiKeyKey, profile: profile)
            guard draftsProfile == profile else { return }
            guard saved else {
                // The address may have landed; show what the host has now.
                await refreshStatus(submittedURL: submitted, profile: profile)
                return
            }
            if keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == key {
                keyDraft = ""
            }
        }
        await refreshStatus(submittedURL: submitted, profile: profile)
        guard draftsProfile == profile else { return }
        if status?.available == true { await runTest(profile: profile) }
    }

    private func removeKey() async {
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        saveError = nil
        let profile = draftsProfile
        _ = await save("", for: Self.apiKeyKey, profile: profile)
        await refreshStatus(submittedURL: nil, profile: profile)
    }

    // Each helper below writes view state only while the drafts still
    // belong to `profile`: after a switch, the old profile's error, status
    // or test result must not show under the new one (where a stale "Remove
    // key" would act on the new profile).

    /// Saves one value; on failure the service's reason is kept for this view.
    private func save(_ value: String, for key: String, profile: String?) async -> Bool {
        let saved = await service.save(value: value, for: key)
        if !saved, draftsProfile == profile {
            saveError = service.errorMessage ?? AppLocalization.string("Could not load voice settings to save this change.")
        }
        return saved
    }

    private func refreshStatus(submittedURL: String?, profile: String?) async {
        let loaded = await service.speechServerStatus()
        guard draftsProfile == profile else { return }
        status = loaded
        // Show what the host will dial (http becomes ws, a bare host gets
        // the realtime path) once it accepted the address, unless the user
        // has typed something else since.
        if let submittedURL, let url = loaded.url,
           urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) == submittedURL {
            urlDraft = url
        }
    }

    private func runTest(profile: String?) async {
        isTesting = true
        defer { isTesting = false }
        let result = await service.testSpeechServer()
        guard draftsProfile == profile else { return }
        testResult = result
    }
}
