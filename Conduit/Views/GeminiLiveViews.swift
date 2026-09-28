//
//  GeminiLiveViews.swift
//  Conduit
//
//  Gemini Live voice mode: its Voice settings section and its sheet.
//

import SwiftUI

/// What Voice settings needs to show the Gemini Live option.
struct GeminiLiveSettingsModel {
    var enabled: Bool
    var setEnabled: (Bool) -> Void
    /// Asks the Hermes host whether it can serve Gemini Live.
    var checkAvailability: () async -> Result<GeminiLiveAvailability, Error>
    var search: GeminiLiveSearchMode = .automatic
    var setSearch: (GeminiLiveSearchMode) -> Void = { _ in }
    /// Prebuilt voice name; nil is Gemini's default voice.
    var voice: String? = nil
    var setVoice: (String?) -> Void = { _ in }
    var memory: Bool = true
    var setMemory: (Bool) -> Void = { _ in }
}

struct GeminiLiveSettingsSection: View {
    let model: GeminiLiveSettingsModel
    @State private var enabled: Bool
    @State private var search: GeminiLiveSearchMode
    /// Empty is Gemini's default voice (a Picker tag can't be nil).
    @State private var voice: String
    @State private var memory: Bool
    @State private var status: String?
    @State private var isAvailable: Bool?
    @State private var isChecking = false

    init(model: GeminiLiveSettingsModel) {
        self.model = model
        _enabled = State(initialValue: model.enabled)
        _search = State(initialValue: model.search)
        _voice = State(initialValue: model.voice ?? "")
        _memory = State(initialValue: model.memory)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Gemini Live"), symbol: "waveform.badge.mic", tint: .conduitAura) {
            Toggle("Use Gemini Live for voice", isOn: Binding(
                get: { enabled },
                set: { requested in
                    enabled = requested
                    model.setEnabled(requested)
                    if requested { Task { await check() } }
                }
            ))
            Text("Talk with Gemini Live instead of the Hermes speech pipeline. Hermes still does the work: Gemini starts background jobs on this profile and tells you their results. The API key stays on your Hermes server. Approvals are never given by voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabled {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isAvailable == true ? Color.green : (isAvailable == false ? Color.orange : Color.secondary))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(status ?? AppLocalization.string("Not checked yet"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button {
                    Task { await check() }
                } label: {
                    Label(isChecking ? AppLocalization.string("Checking…") : AppLocalization.string("Check Gemini Live"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .disabled(isChecking)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.14))
                Picker("Web lookups", selection: Binding(
                    get: { search },
                    set: { chosen in
                        search = chosen
                        model.setSearch(chosen)
                    }
                )) {
                    Text("Automatic").tag(GeminiLiveSearchMode.automatic)
                    Text("Hermes web search").tag(GeminiLiveSearchMode.hermes)
                    Text("Google Search").tag(GeminiLiveSearchMode.google)
                    Text("Off").tag(GeminiLiveSearchMode.off)
                }
                .pickerStyle(.menu)
                Text("How Gemini answers quick questions like weather or news. Hermes web search uses the search your Hermes server is set up with (SearXNG, Firecrawl…). Google Search has its own quota on your Gemini key. Automatic uses Hermes when it has a search set up, otherwise Google. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Voice", selection: Binding(
                    get: { voice },
                    set: { chosen in
                        voice = chosen
                        model.setVoice(chosen.isEmpty ? nil : chosen)
                    }
                )) {
                    Text("Gemini default").tag("")
                    ForEach(GeminiLiveVoice.all) { option in
                        Text(verbatim: "\(option.name) · \(option.style)").tag(option.name)
                    }
                    // A voice saved by a newer build that this one doesn't list.
                    if !voice.isEmpty, !GeminiLiveVoice.all.contains(where: { $0.name == voice }) {
                        Text(verbatim: voice).tag(voice)
                    }
                }
                .pickerStyle(.menu)
                Text("The voice Gemini speaks with. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes memory", isOn: Binding(
                    get: { memory },
                    set: { requested in
                        memory = requested
                        model.setMemory(requested)
                    }
                ))
                Text("Gemini gets what your Hermes agent remembers about you, from whichever memory Hermes is set up with, and can search it for more. That memory is sent to Google with the conversation. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { if enabled { await check() } }
        // A profile switch can change the preference under a retained view.
        .onChange(of: model.enabled) { _, newValue in enabled = newValue }
        .onChange(of: model.search) { _, newValue in search = newValue }
        .onChange(of: model.voice) { _, newValue in voice = newValue ?? "" }
        .onChange(of: model.memory) { _, newValue in memory = newValue }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        switch await model.checkAvailability() {
        case .success(let availability):
            isAvailable = availability.isAvailable
            if case .available(let modelName) = availability {
                status = AppLocalization.string("Available (\(modelName))")
            } else {
                status = availability.userFacingReason
            }
        case .failure(let error):
            isAvailable = false
            status = error.localizedDescription
        }
    }
}

struct GeminiLiveVoiceSheet: View {
    @ObservedObject var controller: GeminiLiveConversationController
    let onClose: () -> Void
    let onRetry: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                VStack(spacing: 16) {
                    statusHeader
                    transcriptList
                    controls
                }
                .padding(16)
            }
            .navigationTitle("Gemini Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.conduitAura)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(controller.transcript) { entry in
                    Text(entry.text)
                        .font(.body)
                        .foregroundStyle(entry.speaker == .user ? Color.primary : Color.conduitAccent)
                        .frame(maxWidth: .infinity, alignment: entry.speaker == .user ? .trailing : .leading)
                        // Color and alignment alone don't tell VoiceOver who spoke.
                        .accessibilityLabel(entry.speaker == .user
                            ? AppLocalization.string("You: \(entry.text)")
                            : AppLocalization.string("Gemini: \(entry.text)"))
                }
            }
        }
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder
    private var controls: some View {
        if case .failed = controller.phase {
            Button(action: onRetry) {
                Label("Try again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .conduitGlassControl(cornerRadius: 18, tint: .conduitAccent.opacity(0.14))
        } else {
            if controller.phase == .speaking {
                // On an open speaker the mic is closed while Gemini talks,
                // so this is the way to cut in.
                Button {
                    controller.interruptSpeaking()
                } label: {
                    Label("Interrupt", systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .conduitGlassControl(cornerRadius: 18, tint: .conduitAccent.opacity(0.14))
            }
            Button {
                controller.setMicrophoneMuted(!controller.isMicrophoneMuted)
            } label: {
                Label(
                    controller.isMicrophoneMuted ? AppLocalization.string("Unmute microphone") : AppLocalization.string("Mute microphone"),
                    systemImage: controller.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .disabled(!controller.isActive || controller.isEnding)
            .conduitGlassControl(cornerRadius: 18, tint: .conduitAura.opacity(0.14))
        }
    }

    private var statusSymbol: String {
        switch controller.phase {
        case .idle, .connecting, .reconnecting: return "antenna.radiowaves.left.and.right"
        case .listening: return controller.isMicrophoneMuted ? "mic.slash" : "waveform"
        case .speaking: return "speaker.wave.3.fill"
        case .ending: return "hand.wave.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return AppLocalization.string("Not connected")
        case .connecting: return AppLocalization.string("Connecting to Gemini Live…")
        case .reconnecting: return AppLocalization.string("Reconnecting…")
        case .listening: return controller.isMicrophoneMuted ? AppLocalization.string("Microphone muted") : AppLocalization.string("Listening")
        case .speaking: return AppLocalization.string("Speaking")
        case .ending: return AppLocalization.string("Ending conversation…")
        case .failed(let message): return message
        }
    }
}

/// What Voice settings needs for the voice-job model choice.
struct VoiceJobModelSettingsModel {
    var provider: String?
    var model: String?
    var reasoningEffort: String?
    var loadProviders: () async -> [ProviderInfo]
    var save: (_ provider: String?, _ model: String?, _ reasoningEffort: String?) -> Void
}

/// The model and reasoning level for Hermes sessions that voice background
/// jobs create (both Voice modes). A faster model here keeps spoken
/// requests quick without changing the profile's main chat model.
struct VoiceJobModelSettingsSection: View {
    let settings: VoiceJobModelSettingsModel
    @State private var selection: String
    @State private var reasoning: String
    @State private var providers: [ProviderInfo] = []

    private static let profileDefault = ""

    init(settings: VoiceJobModelSettingsModel) {
        self.settings = settings
        _selection = State(initialValue: settings.model.map { Self.tag(provider: settings.provider, model: $0) } ?? Self.profileDefault)
        _reasoning = State(initialValue: settings.reasoningEffort ?? Self.profileDefault)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Voice jobs"), symbol: "bolt.horizontal.circle", tint: .conduitAccent) {
            Picker("Model", selection: $selection) {
                Text("Profile default").tag(Self.profileDefault)
                // Keep a saved choice visible even before the list loads.
                if selection != Self.profileDefault, !providers.contains(where: { provider in
                    provider.models.contains { Self.tag(provider: provider.name, model: $0.id) == selection }
                }) {
                    Text(Self.parse(selection).model).tag(selection)
                }
                ForEach(providers, id: \.name) { provider in
                    ForEach(provider.models, id: \.id) { model in
                        Text("\(model.label ?? model.id) · \(provider.name)")
                            .tag(Self.tag(provider: provider.name, model: model.id))
                    }
                }
            }
            .pickerStyle(.menu)
            Picker("Reasoning", selection: $reasoning) {
                Text("Profile default").tag(Self.profileDefault)
                // Same levels as the model picker's reasoning control.
                Text("None").tag("none")
                Text("Minimal").tag("minimal")
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
                Text("Extra High").tag("xhigh")
                Text("Max").tag("max")
            }
            .pickerStyle(.menu)
            Text("The model Hermes uses for background jobs started by voice. A fast model with low reasoning keeps spoken requests quick; your chats keep the profile's model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { providers = await settings.loadProviders() }
        .onChange(of: selection) { _, _ in save() }
        .onChange(of: reasoning) { _, _ in save() }
    }

    private func save() {
        let chosen = selection == Self.profileDefault ? nil : Self.parse(selection)
        settings.save(chosen?.provider, chosen?.model, reasoning == Self.profileDefault ? nil : reasoning)
    }

    /// Picker tag for a provider/model pair (provider may be empty).
    static func tag(provider: String?, model: String) -> String {
        "\(provider ?? "")\u{1F}\(model)"
    }

    static func parse(_ tag: String) -> (provider: String?, model: String) {
        let parts = tag.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (nil, tag) }
        return (parts[0].isEmpty ? nil : String(parts[0]), String(parts[1]))
    }
}
