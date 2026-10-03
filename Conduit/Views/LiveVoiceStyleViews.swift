//
//  LiveVoiceStyleViews.swift
//  Conduit
//
//  Voice settings for how live calls sound (#290): a greeting when a call
//  connects, the tone, backchannels, and a look at what Conduit sends the
//  voice model.
//

import SwiftUI

/// What "What Conduit sends" shows: the text added to the live model's
/// instructions, and the greeting turn sent when a call connects.
struct LiveVoiceInstructionsPreviewContent: Equatable {
    var mode: String
    var instructions: String
    var openingTurn: String?
}

/// What Voice settings needs to show the live call style.
struct LiveVoiceStyleSettingsModel {
    /// The profile these settings belong to.
    var profile: String = ""
    var style: LiveVoiceStyle
    /// Saves to `profile`, even when it lands after a profile switch.
    var setStyle: (LiveVoiceStyle) -> Void
    /// The instructions the next call would get, and the mode they're for.
    var preview: () -> LiveVoiceInstructionsPreviewContent?
}

struct LiveVoiceStyleSettingsSection: View {
    let model: LiveVoiceStyleSettingsModel
    @State private var greets: Bool
    @State private var greeting: String
    /// Empty is the model's own tone (a Picker tag can't be nil).
    @State private var tone: String
    @State private var backchannels: Bool
    @State private var preview: LiveVoiceInstructionsPreviewContent?
    @State private var showsPreview = false
    @State private var greetingSave: Task<Void, Never>?
    /// The typed greeting not saved yet, pinned to its style and profile.
    @State private var pendingSave: (() -> Void)?
    /// The style this view last saved, so its own change isn't mistaken
    /// for one made elsewhere (another profile).
    @State private var lastSaved: LiveVoiceStyle?

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

    /// Saves the typed greeting now, to the profile it was typed in.
    private func flushPendingSave() {
        greetingSave?.cancel()
        pendingSave?()
        pendingSave = nil
    }

    private func save() {
        greetingSave?.cancel()
        pendingSave = nil
        let current = style
        lastSaved = current
        model.setStyle(current)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Live call style"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
            Toggle("Greet me when a call connects", isOn: Binding(
                get: { greets },
                set: { requested in
                    greets = requested
                    save()
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
                        // Saved once typing pauses, not on every keystroke:
                        // the style as typed, to the profile it was typed in,
                        // even if the section shows another one by then.
                        greetingSave?.cancel()
                        let pending = style
                        let setStyle = model.setStyle
                        lastSaved = pending
                        pendingSave = { setStyle(pending) }
                        greetingSave = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(600))
                            guard !Task.isCancelled else { return }
                            flushPendingSave()
                        }
                    }
                    .onSubmit {
                        // Shows what is saved and sent (one line, no double quotes).
                        greeting = LiveVoiceStyle.cleanedGreeting(greeting)
                        save()
                    }
                    .onDisappear { flushPendingSave() }
            }
            Text("The voice model greets you as soon as a call connects, so you know it's live. Leave the greeting empty for one in its own words. GPT-Live needs an up-to-date Hermes notifier plugin for this. Applies to the next call.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Tone", selection: Binding(
                get: { tone },
                set: { chosen in
                    tone = chosen
                    save()
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
                    save()
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
                    .frame(minHeight: 44)
            }
            .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
        }
        .onChange(of: model.style) { _, newValue in
            // This view's own save: the fields already show it (and turning
            // the greeting off keeps its text for turning it back on).
            guard newValue != lastSaved else { return }
            greets = newValue.greeting != nil
            // Changed elsewhere (another profile's settings): never while the
            // stored text is just this field's, cleaned.
            if let stored = newValue.greeting {
                if stored != LiveVoiceStyle.cleanedGreeting(greeting) { greeting = stored }
            } else {
                // Off (or another profile without one): its text mustn't carry over.
                greeting = ""
            }
            tone = newValue.tone?.rawValue ?? ""
            backchannels = newValue.backchannels
            // Now in sync: coming back to an earlier profile resyncs again.
            lastSaved = newValue
        }
        .onChange(of: model.profile) { _, _ in
            // Another profile, even one with the same style: what was typed
            // is saved to the earlier one first, then the fields show this one's.
            flushPendingSave()
            let style = model.style
            greets = style.greeting != nil
            greeting = style.greeting ?? ""
            tone = style.tone?.rawValue ?? ""
            backchannels = style.backchannels
            lastSaved = style
        }
        .sheet(isPresented: $showsPreview) {
            LiveVoiceInstructionsPreview(preview: preview)
        }
    }
}

/// The text Conduit adds to a live voice model's instructions.
struct LiveVoiceInstructionsPreview: View {
    let preview: LiveVoiceInstructionsPreviewContent?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let preview {
                        Text(AppLocalization.string("Conduit adds this to \(preview.mode)'s instructions for every call. Your Hermes server adds its own voice persona before it. Memory and personality are read when a call starts."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(verbatim: preview.instructions)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let opening = preview.openingTurn {
                            Text("Sent as the call's first turn when it connects:")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(verbatim: opening)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
