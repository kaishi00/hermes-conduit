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
                    .accessibilityIdentifier("voice.speechServer.test")
                    Spacer()
                    if status?.hasKey == true {
                        Button("Remove key", role: .destructive) { Task { await removeKey() } }
                            .font(.footnote)
                            .disabled(isSaving)
                    }
                }
                .buttonStyle(.borderless)

                if let testResult {
                    Label(testResult.message, systemImage: testResult.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(testResult.connected ? .green : .orange)
                        .accessibilityIdentifier("voice.speechServer.testResult")
                } else if let status, status.configured, !status.available, let reason = status.reason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
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

    private func load() async {
        let loaded = await service.speechServerStatus()
        status = loaded
        if urlDraft.isEmpty { urlDraft = loaded.url ?? "" }
    }

    private func saveURL() async {
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url != savedURL else { return }
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        _ = await service.save(value: url, for: Self.urlKey)
        await refreshStatus()
    }

    private func saveAll() async {
        isSaving = true
        testResult = nil
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if url != savedURL {
            _ = await service.save(value: url, for: Self.urlKey)
        }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, await service.save(value: key, for: Self.apiKeyKey) {
            keyDraft = ""
        }
        isSaving = false
        await refreshStatus()
        if status?.available == true { await runTest() }
    }

    private func removeKey() async {
        isSaving = true
        defer { isSaving = false }
        testResult = nil
        _ = await service.save(value: "", for: Self.apiKeyKey)
        await refreshStatus()
    }

    private func refreshStatus() async {
        let loaded = await service.speechServerStatus()
        status = loaded
        // Show what the host will dial (http becomes ws, a bare host gets
        // the realtime path) once it accepted the address.
        if let url = loaded.url { urlDraft = url }
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        testResult = await service.testSpeechServer()
    }
}
