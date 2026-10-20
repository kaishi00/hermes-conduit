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

    static let urlKey = "voice.speech_server.url"
    static let apiKeyKey = "voice.speech_server.api_key"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your voice is recognized by a server you run, such as Hugging Face speech-to-speech or the one Hermes Live Voice starts. Hermes connects to it for Conduit, so it can run on another machine on your network.", systemImage: "server.rack")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let status, status.pluginMissing {
                Text(SpeechServerStatus.pluginMissingReason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server address").font(.subheadline.weight(.semibold))
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Key").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(status?.hasKey == true ? AppLocalization.string("Set") : AppLocalization.string("None"))
                            .font(.caption)
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
                        Task { await runTest() }
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
                            .font(.footnote)
                            .disabled(isSaving)
                    }
                }
                .buttonStyle(.borderless)

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("voice.speechServer.saveError")
                }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(testResult.connected ? .green : .orange)
                        .accessibilityIdentifier("voice.speechServer.testResult")
                } else if let status, status.configured, !status.available, let reason = status.reason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
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
        let saved = await save(url, for: Self.urlKey)
        await refreshStatus(submittedURL: saved ? url : nil)
    }

    private func saveAll() async {
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        saveError = nil
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var submitted: String?
        if url != savedURL {
            guard await save(url, for: Self.urlKey) else { return }
            submitted = url
        }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            guard await save(key, for: Self.apiKeyKey) else {
                // The address may have landed; show what the host has now.
                await refreshStatus(submittedURL: submitted)
                return
            }
            if keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == key {
                keyDraft = ""
            }
        }
        await refreshStatus(submittedURL: submitted)
        if status?.available == true { await runTest() }
    }

    private func removeKey() async {
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        saveError = nil
        _ = await save("", for: Self.apiKeyKey)
        await refreshStatus(submittedURL: nil)
    }

    /// Saves one value; on failure the service's reason is kept for this view.
    private func save(_ value: String, for key: String) async -> Bool {
        let saved = await service.save(value: value, for: key)
        if !saved {
            saveError = service.errorMessage ?? AppLocalization.string("Could not load voice settings to save this change.")
        }
        return saved
    }

    private func refreshStatus(submittedURL: String?) async {
        let loaded = await service.speechServerStatus()
        status = loaded
        // Show what the host will dial (http becomes ws, a bare host gets
        // the realtime path) once it accepted the address, unless the user
        // has typed something else since.
        if let submittedURL, let url = loaded.url,
           urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) == submittedURL {
            urlDraft = url
        }
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        testResult = await service.testSpeechServer()
    }
}
