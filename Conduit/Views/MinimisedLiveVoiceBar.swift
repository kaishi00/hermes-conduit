//
//  MinimisedLiveVoiceBar.swift
//  Conduit
//
//  A live call whose sheet was swiped away keeps running. This bar sits
//  above the composer while it does: tap it to bring the sheet back, or
//  mute or end the call from here.
//

import SwiftUI

struct MinimisedLiveVoiceBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.minimisedLiveVoice {
        case .geminiLive?:
            GeminiLiveBarContent(controller: appState.geminiLiveController, jobs: appState.voiceBackgroundJobSupervisor, name: "Gemini Live")
        case .grokLive?:
            GeminiLiveBarContent(controller: appState.grokLiveController, jobs: appState.voiceBackgroundJobSupervisor, name: "Grok Live")
        case .gptLive?:
            GPTLiveBarContent(controller: appState.gptLiveController, jobs: appState.voiceBackgroundJobSupervisor)
        case nil:
            EmptyView()
        }
    }
}

private struct GeminiLiveBarContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var controller: GeminiLiveConversationController
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    let name: String

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    var body: some View {
        LiveVoiceBarRow(
            name: name,
            status: status,
            symbol: symbol,
            thread: jobs.liveThread?.title,
            isFailed: isFailed,
            isMuted: controller.isMicrophoneMuted,
            canMute: controller.isActive && !controller.isEnding,
            onRestore: appState.restoreMinimisedLiveVoice,
            onToggleMute: { controller.setMicrophoneMuted(!controller.isMicrophoneMuted) },
            onEnd: appState.endMinimisedLiveVoice
        )
    }

    private var status: String {
        switch controller.phase {
        case .idle: return AppLocalization.string("Not connected")
        case .connecting: return AppLocalization.string("Connecting…")
        case .reconnecting: return AppLocalization.string("Reconnecting…")
        case .listening: return controller.isMicrophoneMuted ? AppLocalization.string("Microphone muted") : AppLocalization.string("Listening")
        case .speaking: return AppLocalization.string("Speaking")
        case .ending: return AppLocalization.string("Ending conversation…")
        case .failed: return AppLocalization.string("Call stopped. Tap to see why.")
        }
    }

    private var symbol: String {
        switch controller.phase {
        case .idle, .connecting, .reconnecting: return "antenna.radiowaves.left.and.right"
        case .listening: return controller.isMicrophoneMuted ? "mic.slash" : "waveform"
        case .speaking: return "speaker.wave.3.fill"
        case .ending: return "hand.wave.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

private struct GPTLiveBarContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var controller: GPTLiveConversationController
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor

    private var isFailed: Bool {
        if case .failed = controller.phase { return true }
        return false
    }

    var body: some View {
        LiveVoiceBarRow(
            name: "GPT-Live",
            status: status,
            symbol: symbol,
            thread: jobs.liveThread?.title,
            isFailed: isFailed,
            isMuted: controller.isMicrophoneMuted,
            canMute: controller.isActive && !controller.isEnding,
            onRestore: appState.restoreMinimisedLiveVoice,
            onToggleMute: { controller.setMicrophoneMuted(!controller.isMicrophoneMuted) },
            onEnd: appState.endMinimisedLiveVoice
        )
    }

    private var status: String {
        switch controller.phase {
        case .idle: return AppLocalization.string("Not connected")
        case .connecting: return AppLocalization.string("Connecting…")
        case .listening: return controller.isMicrophoneMuted ? AppLocalization.string("Microphone muted") : AppLocalization.string("Listening")
        case .speaking: return AppLocalization.string("Speaking")
        case .ending: return AppLocalization.string("Ending conversation…")
        case .failed: return AppLocalization.string("Call stopped. Tap to see why.")
        }
    }

    private var symbol: String {
        switch controller.phase {
        case .idle, .connecting: return "antenna.radiowaves.left.and.right"
        case .listening: return controller.isMicrophoneMuted ? "mic.slash" : "waveform"
        case .speaking: return "speaker.wave.3.fill"
        case .ending: return "hand.wave.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

private struct LiveVoiceBarRow: View {
    let name: String
    let status: String
    let symbol: String
    /// The chat the call is attached to, if any.
    let thread: String?
    let isFailed: Bool
    let isMuted: Bool
    let canMute: Bool
    let onRestore: () -> Void
    let onToggleMute: () -> Void
    let onEnd: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onRestore) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.conduitAura)
                        .frame(width: iconWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: thread.map { "\(name) · \($0)" } ?? name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(isFailed ? Text("Shows why the call stopped") : Text("Opens the call"))

            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canMute)
            .accessibilityLabel(isMuted ? Text("Unmute microphone") : Text("Mute microphone"))

            Button(action: onEnd) {
                Image(systemName: "phone.down.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 36, minHeight: 36)
                    .background(Circle().fill(Color.red))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("End call"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .conduitGlassControl(cornerRadius: 20, tint: .conduitAura.opacity(0.12))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
