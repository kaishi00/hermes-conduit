//
//  LiveVoiceStyleViews.swift
//  Conduit
//
//  Voice settings for how live calls sound (#290): a greeting when a call
//  connects, the tone, backchannels, and a look at what Conduit sends the
//  voice model.
//

import SwiftUI

/// What Voice settings needs to show the live call style.
struct LiveVoiceStyleSettingsModel {
    var style: LiveVoiceStyle
    var setStyle: (LiveVoiceStyle) -> Void
    /// The instructions the next call would get, and the mode they're for.
    var preview: () -> (mode: String, text: String)?
}

struct LiveVoiceStyleSettingsSection: View {
    let model: LiveVoiceStyleSettingsModel
    @State private var greets: Bool
    @State private var greeting: String
    /// Empty is the model's own tone (a Picker tag can't be nil).
    @State private var tone: String
    @State private var backchannels: Bool
    @State private var preview: (mode: String, text: String)?
    @State private var showsPreview = false

    init(model: LiveVoiceStyleSettingsModel) {
        self.model = model
        _greets = State(initialValue: model.style.greeting != nil)
        _greeting = State(initialValue: model.style.greeting ?? "")
        _tone = State(initialValue: model.style.tone?.rawValue ?? "")
        _backchannels = State(initialValue: model.style.backchannels)
    }

    private var style: LiveVoiceStyle {
        LiveVoiceStyle(
            tone: LiveVoiceTone(rawValue: tone),
            backchannels: backchannels,
            greeting: greets ? LiveVoiceStyle.cleanedGreeting(greeting) : nil
        )
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Live call style"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
            Toggle("Greet me when a call connects", isOn: Binding(
                get: { greets },
                set: { requested in
                    greets = requested
                    model.setStyle(style)
                }
            ))
            if greets {
                TextField(AppLocalization.string("Greeting"), text: $greeting, prompt: Text("A short greeting of its own"))
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onChange(of: greeting) { _, newValue in
                        if newValue.count > LiveVoiceStyle.maxGreetingCharacters {
                            greeting = String(newValue.prefix(LiveVoiceStyle.maxGreetingCharacters))
                        }
                        model.setStyle(style)
                    }
            }
            Text("The voice model greets you as soon as a call connects, so you know it's live. Leave the greeting empty for one in its own words. GPT-Live needs an up-to-date Hermes notifier plugin for this. Applies to the next call.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Tone", selection: Binding(
                get: { tone },
                set: { chosen in
                    tone = chosen
                    model.setStyle(style)
                }
            )) {
                Text("Model default").tag("")
                ForEach(LiveVoiceTone.allCases) { option in
                    Text(verbatim: option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            Text("How live calls sound. Model default keeps the voice model's tone and your Hermes server's persona. Applies to the next call.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Backchannels", isOn: Binding(
                get: { backchannels },
                set: { requested in
                    backchannels = requested
                    model.setStyle(style)
                }
            ))
            Text("Short sounds like “mm-hmm” while you talk. Turn them off for a quieter listener. Applies to the next call.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                preview = model.preview()
                showsPreview = true
            } label: {
                Label(AppLocalization.string("What Conduit sends"), systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
        }
        .onChange(of: model.style) { _, newValue in
            greets = newValue.greeting != nil
            // Changed elsewhere (another profile's settings): never while the
            // stored text is just this field's, cleaned.
            if let stored = newValue.greeting, stored != LiveVoiceStyle.cleanedGreeting(greeting) {
                greeting = stored
            }
            tone = newValue.tone?.rawValue ?? ""
            backchannels = newValue.backchannels
        }
        .sheet(isPresented: $showsPreview) {
            LiveVoiceInstructionsPreview(preview: preview)
        }
    }
}

/// The text Conduit adds to a live voice model's instructions.
struct LiveVoiceInstructionsPreview: View {
    let preview: (mode: String, text: String)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let preview {
                        Text(AppLocalization.string("Conduit adds this to \(preview.mode)'s instructions for every call. Your Hermes server adds its own voice persona before it. Memory and personality are read when a call starts."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(verbatim: preview.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Turn on a live voice mode to see what Conduit sends.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle(AppLocalization.string("What Conduit sends"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
