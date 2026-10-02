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
            GeminiLiveBarContent(controller: appState.geminiLiveController, name: "Gemini Live")
        case .grokLive?:
            GeminiLiveBarContent(controller: appState.grokLiveController, name: "Grok Live")
        case .gptLive?:
            GPTLiveBarContent(controller: appState.gptLiveController)
        case nil:
            EmptyView()
        }
    }
}

private struct GeminiLiveBarContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var controller: GeminiLiveConversationController
    let name: String

    var body: some View {
        LiveVoiceBarRow(
            name: name,
            status: status,
            symbol: symbol,
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

    var body: some View {
        LiveVoiceBarRow(
            name: "GPT-Live",
            status: status,
            symbol: symbol,
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
    let isMuted: Bool
    let canMute: Bool
    let onRestore: () -> Void
    let onToggleMute: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onRestore) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.conduitAura)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: name)
                            .font(.subheadline.weight(.semibold))
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens the call"))

            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .disabled(!canMute)
            .accessibilityLabel(isMuted ? Text("Unmute microphone") : Text("Mute microphone"))

            Button(action: onEnd) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.red))
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
