//
//  LocalLiveViews.swift
//  Conduit
//
//  Local Live's Voice settings. Two modes run on the same speech server:
//  Live > Local (agent mode), where a fast model on the Hermes host holds
//  the conversation and hands the work to Hermes as jobs, and Classic's
//  hands-free option, where every utterance is a Hermes turn. The call
//  itself shares Gemini Live's sheet (GeminiLiveVoiceSheet).
//

import SwiftUI
import UIKit

/// What Voice settings needs to show the Local Live options.
struct LocalLiveSettingsModel {
    var enabled: Bool
    var setEnabled: (Bool) -> Void
    /// Agent mode (Live > Local) rather than Classic's hands-free option.
    var agent: Bool = false
    var setAgent: (Bool) -> Void = { _ in }
}

/// The speech server Hermes connects to, and the model address the server
/// asks for each reply.
struct LocalLiveSettingsSection: View {
    @ObservedObject var service: HermesVoiceConfigurationService
    /// Live > Local's section; Classic's hands-free option otherwise.
    var agent = false

    var body: some View {
        ConduitSettingsSection(
            title: agent ? AppLocalization.string("Local") : AppLocalization.string("Your speech server"),
            symbol: "server.rack",
            tint: .conduitAccent
        ) {
            Text(agent
                ? AppLocalization.string("Talk through a speech server you run, with a fast model of your choosing answering right away. Real work goes to Hermes as jobs, with their cards in the call's chat, like the other live modes.")
                : AppLocalization.string("A hands-free call through a speech server you run, such as Hugging Face speech-to-speech. Everything you say goes to Hermes as a turn in the call's chat, and Hermes' reply is spoken as it is written."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("1. Your speech server"))
                .font(.subheadline.weight(.semibold))
            SpeechServerSettingsView(service: service)
            Text(AppLocalization.string("2. Point the server at Hermes"))
                .font(.subheadline.weight(.semibold))
            SpeechServerVoiceSettingsView(service: service, showsIntro: false)
            if agent {
                Text(AppLocalization.string("3. Your fast model"))
                    .font(.subheadline.weight(.semibold))
                LocalLiveFrontModelSettingsView(service: service)
            }
        }
    }
}

/// The fast model Local's calls talk to: any OpenAI-compatible server,
/// saved in the profile's Hermes config (voice.local_live.front_model).
struct LocalLiveFrontModelSettingsView: View {
    @ObservedObject var service: HermesVoiceConfigurationService

    @State private var status: LocalLiveFrontModelStatus?
    @State private var loaded = false
    @State private var urlDraft = ""
    @State private var modelDraft = ""
    @State private var keyDraft = ""
    @State private var isSaving = false
    @State private var saveError: String?

    static let baseURLKey = "voice.local_live.front_model.base_url"
    static let modelKey = "voice.local_live.front_model.model"
    static let apiKeyKey = "voice.local_live.front_model.api_key"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.string("Any OpenAI-compatible server works, on your network (llama.cpp, Ollama, vLLM, LM Studio) or a hosted one. A small, quick model is best: it only talks and hands the work to Hermes."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loaded && status == nil {
                Text(AppLocalization.string("Update the Conduit plugin on your Hermes host to use a fast model."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                field(AppLocalization.string("Server address"), text: $urlDraft, prompt: "http://192.168.1.20:8080/v1",
                      identifier: "voice.localLive.frontModel.url", keyboard: .URL)
                field(AppLocalization.string("Model"), text: $modelDraft, prompt: "qwen3-4b-instruct",
                      identifier: "voice.localLive.frontModel.model", keyboard: .default)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Key").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(status?.hasKey == true ? AppLocalization.string("Set") : AppLocalization.string("None"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SecureField(AppLocalization.string("Optional, for a hosted model"), text: $keyDraft)
                        .accessibilityLabel(Text("Key"))
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("voice.localLive.frontModel.key")
                }
                HStack(spacing: 16) {
                    Button(AppLocalization.string("Save")) { Task { await save() } }
                        .disabled(isSaving || !hasChanges)
                        .accessibilityIdentifier("voice.localLive.frontModel.save")
                    Spacer()
                    if status?.hasKey == true {
                        Button(AppLocalization.string("Remove key"), role: .destructive) { Task { await removeKey() } }
                            .font(.footnote)
                            .disabled(isSaving)
                    }
                }
                .buttonStyle(.borderless)
                statusLine
            }
        }
        .disabled(isSaving)
        .task(id: service.profile) { await load() }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let saveError {
            Label(saveError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if let status {
            if status.available {
                Label(AppLocalization.string("Calls answer with \(status.model ?? "") and hand the work to Hermes."), systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("voice.localLive.frontModel.status")
            } else {
                // Without one, the call still works: Hermes answers each turn.
                Label(status.reason ?? AppLocalization.string("No fast model is set, so Hermes answers each turn itself, which is slower to start talking."),
                      systemImage: status.configured ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(status.configured ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.localLive.frontModel.status")
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, identifier: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
            TextField(text: text, prompt: Text(verbatim: prompt)) { Text(verbatim: title) }
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .accessibilityIdentifier(identifier)
        }
    }

    private var trimmedURL: String { urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedModel: String { modelDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasChanges: Bool {
        trimmedURL != (status?.baseURL ?? "") || trimmedModel != (status?.model ?? "")
            || !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A profile switch starts from that profile's saved values.
    private func load() async {
        loaded = false
        status = nil
        saveError = nil
        keyDraft = ""
        let voice = await service.speechServerVoiceStatus()
        guard !Task.isCancelled else { return }
        apply(voice)
    }

    private func apply(_ voice: SpeechServerVoiceStatus) {
        status = voice.frontModel
        urlDraft = voice.frontModel?.baseURL ?? ""
        modelDraft = voice.frontModel?.model ?? ""
        loaded = true
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        if trimmedURL != (status?.baseURL ?? "") {
            guard await save(trimmedURL, for: Self.baseURLKey) else { return }
        }
        if trimmedModel != (status?.model ?? "") {
            guard await save(trimmedModel, for: Self.modelKey) else { return }
        }
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var keyWritten: Bool?
        if !key.isEmpty {
            guard await save(key, for: Self.apiKeyKey) else { return }
            keyDraft = ""
            keyWritten = true
        }
        applyAfterSave(await service.speechServerVoiceStatus(), keyWritten: keyWritten)
    }

    private func removeKey() async {
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        // A typed key left in the field would come back on the next Save.
        keyDraft = ""
        let removed = await save("", for: Self.apiKeyKey)
        applyAfterSave(await service.speechServerVoiceStatus(), keyWritten: removed ? false : nil)
    }

    /// The saved values as read back. A read that failed (or a plugin that
    /// doesn't report them) keeps the fields as they are, rather than
    /// blanking what was just saved; the key indicator still follows a key
    /// write that succeeded.
    private func applyAfterSave(_ voice: SpeechServerVoiceStatus, keyWritten: Bool? = nil) {
        guard voice.frontModel != nil else {
            if let keyWritten { status?.hasKey = keyWritten }
            return
        }
        apply(voice)
    }

    private func save(_ value: String, for key: String) async -> Bool {
        let saved = await service.save(value: value, for: key)
        if !saved {
            saveError = service.errorMessage ?? AppLocalization.string("Could not load voice settings to save this change.")
        }
        return saved
    }
}
