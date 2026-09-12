//
//  VoiceConversationSheet.swift
//  Conduit
//

import SwiftUI

/// The sheet is deliberately presentation-only. AppState remains responsible
/// for submitting, interrupting, and rendering the associated Hermes turn.
struct VoiceConversationSheet: View {
    @ObservedObject var controller: VoiceConversationController
    let profile: String
    let onClose: () -> Void
    /// One-shot gate armed by a fresh `openVoiceConversation` and consumed
    /// exactly once. A restored suspended conversation deliberately does NOT
    /// auto-listen: the gate stays disarmed even if SwiftUI recreates this
    /// view's identity while the presentation binding survives.
    let shouldAutoListen: () -> Bool
    var startsListening: Bool = true

    @State private var didRequestStart = false

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        statusCard
                        conversationCard
                        controlsCard
                        Text("Your conversation also continues in chat. Close ends this voice session.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: "Voice conversation", close: close)
            }
        }
        .task {
            guard startsListening, !didRequestStart else { return }
            didRequestStart = true
            guard shouldAutoListen() else { return }
            await controller.startListening()
        }
        .accessibilityElement(children: .contain)
    }

    private var statusCard: some View {
        ConduitSettingsSection(title: "\(profileDisplayName) voice", symbol: stateSymbol, tint: stateTint) {
            HStack(spacing: 12) {
                Image(systemName: stateSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(stateTint)
                    .frame(width: 44, height: 44)
                    .background(stateTint.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Voice status: \(statusTitle). \(statusDetail)")
            HStack(spacing: 8) {
                Text("Mic input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VoiceInputLevelMeter(level: inputMeterLevel, isActive: isInputMeterActive)
                    .frame(height: 20)
                    .accessibilityHint(Text(isInputMeterActive
                        ? "Shows audio reaching Conduit while the microphone is live."
                        : "The microphone is not capturing right now."))
                Spacer(minLength: 0)
            }
        }
    }

    private var conversationCard: some View {
        ConduitSettingsSection(title: "Conversation", symbol: "text.bubble", tint: .conduitAura) {
            if controller.conversationTranscript.isEmpty {
                Text("Your spoken words and Hermes' replies will appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .accessibilityLabel("No voice conversation messages yet")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.conversationTranscript) { entry in
                        VoiceConversationTranscriptBubble(entry: entry)
                    }
                }
            }
        }
    }

    private var controlsCard: some View {
        ConduitSettingsSection(title: "Microphone and audio", symbol: "slider.horizontal.3", tint: .conduitAccent) {
            HStack(spacing: 10) {
                Button { microphoneTapped() } label: {
                    Label(microphoneLabel, systemImage: microphoneSymbol)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent.opacity(0.16))
                .accessibilityHint(microphoneHint)
                .disabled(controller.state == .transcribing)

                Button { controller.setOutputMuted(!controller.isOutputMuted) } label: {
                    Label(controller.isOutputMuted ? "Unmute" : "Mute", systemImage: controller.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .conduitGlassControl(cornerRadius: 17, tint: controller.isOutputMuted ? .orange.opacity(0.18) : .conduitAura.opacity(0.14))
                .accessibilityHint("Mutes assistant audio without changing chat messages")
            }
            Text("Pause only affects the microphone. Close ends the voice session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileDisplayName: String {
        profile == "default" ? "Default profile" : profile.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Automatic speaker-safe suspension while Hermes audibly speaks on an
    /// open-speaker route: the mic control becomes Interrupt instead of a
    /// pause, so this never reads as a user-selected mic pause. An explicit
    /// user pause keeps precedence — the sheet stays in the paused state,
    /// and its Listen tap routes through `resumeMicrophone`, which acts as
    /// an interrupt while playback is suspended.
    private var isInterruptAvailable: Bool {
        controller.isPlaybackCaptureSuspended && !controller.isMicrophonePaused
    }

    /// The input meter is live exactly when microphone capture is live:
    /// listening, and (on headset routes) the thinking/speaking/muted
    /// windows where barge-in monitoring is actually armed. A user-paused
    /// mic, transcribing, and #146 speaker-safe suspension all read as
    /// inactive/zero — there, the status text explains why (e.g. "Hermes is
    /// speaking / Tap Interrupt to speak."), so a zero meter never implies
    /// malfunction.
    private var isInputMeterActive: Bool {
        guard !controller.isMicrophonePaused, !controller.isPlaybackCaptureSuspended else { return false }
        switch controller.state {
        case .listening, .thinking, .speaking, .muted: return true
        case .idle, .transcribing, .failed: return false
        }
    }

    private var inputMeterLevel: Float {
        isInputMeterActive ? controller.microphoneLevel : 0
    }

    private var microphoneLabel: String {
        if controller.state == .transcribing { return "Transcribing" }
        if isInterruptAvailable { return "Interrupt" }
        return microphoneIsActive ? "Pause mic" : "Listen"
    }

    private var microphoneSymbol: String {
        if controller.state == .transcribing { return "waveform" }
        if isInterruptAvailable { return "stop.fill" }
        return microphoneIsActive ? "mic.slash.fill" : "mic.fill"
    }

    private var microphoneHint: String {
        if isInterruptAvailable { return "Stops Hermes' speech and starts listening right away" }
        return microphoneIsActive ? "Pauses microphone capture while keeping the voice session open" : "Starts or resumes microphone capture"
    }

    private var microphoneIsActive: Bool {
        guard !controller.isMicrophonePaused else { return false }
        switch controller.state {
        case .listening, .thinking, .speaking, .muted: return true
        case .idle, .transcribing, .failed: return false
        }
    }

    private var statusTitle: String {
        if isInterruptAvailable { return "Hermes is speaking" }
        if controller.isMicrophonePaused { return "Microphone paused" }
        switch controller.state {
        case .idle: return "Ready to listen"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Hermes is thinking"
        case .speaking: return "Hermes is speaking"
        case .muted: return "Assistant audio muted"
        case .failed: return "Voice needs attention"
        }
    }

    private var statusDetail: String {
        if isInterruptAvailable { return "Tap Interrupt to speak." }
        if controller.isMicrophonePaused { return "Tap Listen when you are ready to resume." }
        switch controller.state {
        case .idle: return "Tap Listen when you are ready."
        case .listening: return "Pause the microphone whenever you need a break."
        case .transcribing: return "Sending your speech to Hermes."
        case .thinking: return "Speak to interrupt and start a new turn."
        case .speaking: return "Speak over Hermes to interrupt it."
        case .muted: return "Assistant text is still continuing in chat."
        case .failed(let detail): return detail
        }
    }

    private var stateSymbol: String {
        if controller.isMicrophonePaused { return "mic.slash" }
        switch controller.state {
        case .idle: return "mic"
        case .listening: return "waveform"
        case .transcribing: return "text.badge.checkmark"
        case .thinking: return "ellipsis.message"
        case .speaking: return "speaker.wave.3"
        case .muted: return "speaker.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var stateTint: Color {
        if controller.isMicrophonePaused { return .orange }
        switch controller.state {
        case .failed: return .red
        case .muted: return .orange
        case .listening, .speaking: return .conduitAccent
        default: return .conduitAura
        }
    }

    private func microphoneTapped() {
        if isInterruptAvailable {
            Task { await controller.interruptAssistantPlayback() }
        } else if microphoneIsActive {
            controller.pauseMicrophone()
        } else {
            Task { await controller.resumeMicrophone() }
        }
    }

    private func close() {
        onClose()
    }
}

private struct VoiceConversationTranscriptBubble: View {
    let entry: VoiceConversationTranscriptEntry

    private var isUser: Bool { entry.speaker == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(isUser ? "You" : "Hermes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .multilineTextAlignment(isUser ? .trailing : .leading)
        }
        .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
        .padding(12)
        .background((isUser ? Color.conduitAccent : Color.conduitAura).opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : "Hermes"): \(entry.text)")
    }
}
