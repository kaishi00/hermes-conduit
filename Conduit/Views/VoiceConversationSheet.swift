//
//  VoiceConversationSheet.swift
//  Conduit
//

import SwiftUI

/// The sheet is deliberately presentation-only. AppState remains responsible
/// for submitting, interrupting, and rendering the associated Hermes turn.
struct VoiceConversationSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var controller: VoiceConversationController
    @ObservedObject var backgroundJobs: VoiceBackgroundJobSupervisor
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
                        backgroundJobsCard
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
                ConduitSheetHeader(title: AppLocalization.string("Voice conversation"), close: close)
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
        ConduitSettingsSection(title: AppLocalization.string("\(profileDisplayName) voice"), symbol: stateSymbol, tint: stateTint) {
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
        ConduitSettingsSection(title: AppLocalization.string("Conversation"), symbol: "text.bubble", tint: .conduitAura) {
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

    private var backgroundJobsCard: some View {
        ConduitSettingsSection(title: AppLocalization.string("Background jobs"), symbol: "square.stack.3d.up", tint: .conduitAccent) {
            if backgroundJobs.backgroundJobs.isEmpty {
                Text("Say “background job” and then a task to run it as its own chat while you keep talking.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(backgroundJobs.backgroundJobs.reversed()) { job in
                        HStack(spacing: 10) {
                            Image(systemName: Self.jobSymbol(job.status))
                                .foregroundStyle(Self.jobTint(job.status))
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                Text(Self.jobStatusLabel(job.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("Each job is its own chat in your session list. Say “job status” or “cancel background jobs” at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func jobSymbol(_ status: VoiceBackgroundJob.Status) -> String {
        switch status {
        case .starting, .running: return "hourglass"
        case .needsInput: return "exclamationmark.bubble"
        case .finished: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .cancelled: return "minus.circle"
        }
    }

    private static func jobTint(_ status: VoiceBackgroundJob.Status) -> Color {
        switch status {
        case .starting, .running: return .conduitAccent
        case .needsInput: return .orange
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private static func jobStatusLabel(_ status: VoiceBackgroundJob.Status) -> String {
        switch status {
        case .starting: return AppLocalization.string("Starting")
        case .running: return AppLocalization.string("Running")
        case .needsInput: return AppLocalization.string("Waiting for your input")
        case .finished: return AppLocalization.string("Finished")
        case .failed: return AppLocalization.string("Failed")
        case .cancelled: return AppLocalization.string("Cancelled")
        }
    }

    private var controlsCard: some View {
        ConduitSettingsSection(title: AppLocalization.string("Microphone and audio"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
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
        profile == "default" ? AppLocalization.string("Default profile") : profile.replacingOccurrences(of: "_", with: " ").capitalized
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
        if controller.state == .transcribing { return AppLocalization.string("Transcribing") }
        if isInterruptAvailable { return AppLocalization.string("Interrupt") }
        return microphoneIsActive ? AppLocalization.string("Pause mic") : AppLocalization.string("Listen")
    }

    private var microphoneSymbol: String {
        if controller.state == .transcribing { return "waveform" }
        if isInterruptAvailable { return "stop.fill" }
        return microphoneIsActive ? "mic.slash.fill" : "mic.fill"
    }

    private var microphoneHint: String {
        if isInterruptAvailable { return AppLocalization.string("Stops Hermes' speech and starts listening right away") }
        return microphoneIsActive ? AppLocalization.string("Pauses microphone capture while keeping the voice session open") : AppLocalization.string("Starts or resumes microphone capture")
    }

    private var microphoneIsActive: Bool {
        guard !controller.isMicrophonePaused else { return false }
        switch controller.state {
        case .listening, .thinking, .speaking, .muted: return true
        case .idle, .transcribing, .failed: return false
        }
    }

    private var statusTitle: String {
        if isInterruptAvailable { return AppLocalization.string("Hermes is speaking") }
        if controller.isMicrophonePaused { return AppLocalization.string("Microphone paused") }
        switch controller.state {
        case .idle: return AppLocalization.string("Ready to listen")
        case .listening: return AppLocalization.string("Listening")
        case .transcribing: return AppLocalization.string("Transcribing")
        case .thinking: return AppLocalization.string("Hermes is thinking")
        case .speaking: return AppLocalization.string("Hermes is speaking")
        case .muted: return AppLocalization.string("Assistant audio muted")
        case .failed: return AppLocalization.string("Voice needs attention")
        }
    }

    private var statusDetail: String {
        if isInterruptAvailable { return AppLocalization.string("Tap Interrupt to speak.") }
        if controller.isMicrophonePaused { return AppLocalization.string("Tap Listen when you are ready to resume.") }
        switch controller.state {
        case .idle: return AppLocalization.string("Tap Listen when you are ready.")
        case .listening: return AppLocalization.string("Pause the microphone whenever you need a break.")
        case .transcribing: return AppLocalization.string("Sending your speech to Hermes.")
        case .thinking: return AppLocalization.string("Speak to interrupt and start a new turn.")
        case .speaking: return AppLocalization.string("Speak over Hermes to interrupt it.")
        case .muted: return AppLocalization.string("Assistant text is still continuing in chat.")
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
            Text(isUser ? AppLocalization.string("You") : AppLocalization.string("Hermes"))
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
