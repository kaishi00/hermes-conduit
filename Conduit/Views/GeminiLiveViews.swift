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
}

struct GeminiLiveSettingsSection: View {
    let model: GeminiLiveSettingsModel
    @State private var enabled: Bool
    @State private var status: String?
    @State private var isAvailable: Bool?
    @State private var isChecking = false

    init(model: GeminiLiveSettingsModel) {
        self.model = model
        _enabled = State(initialValue: model.enabled)
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
            }
        }
        .task { if enabled { await check() } }
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
            .disabled(!controller.isActive)
            .conduitGlassControl(cornerRadius: 18, tint: .conduitAura.opacity(0.14))
        }
    }

    private var statusSymbol: String {
        switch controller.phase {
        case .idle, .connecting, .reconnecting: return "antenna.radiowaves.left.and.right"
        case .listening: return controller.isMicrophoneMuted ? "mic.slash" : "waveform"
        case .speaking: return "speaker.wave.3.fill"
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
        case .failed(let message): return message
        }
    }
}
